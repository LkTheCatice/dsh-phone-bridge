/**
 * DSH 会话事件 → 手机帧的归一化，以及断线续传用的环形缓冲。
 *
 * DSH 的事件形状会随版本变，这里的原则是「宽进严出」：
 *   - 已知事件映射成稳定帧类型
 *   - 未知事件原样透传（raw 截断），前端不认识就忽略
 *   - 文本/思考用递归提取，不假设 block 层级
 */

export const FRAME_VERSION = 1;

const RAW_LIMIT = 8 * 1024;
const TEXT_LIMIT = 32 * 1024;

/**
 * 剥掉 `<system-reminder>…</system-reminder>` / `<system>…</system>` 这类系统包裹块。
 *
 * 这些是给模型看的注入内容（技能目录变更、hook 提醒之类），
 * 混在用户消息里会被当成用户发言显示出来 —— 手机上就是整段原文。
 */
function stripSystemBlocks(text) {
  if (typeof text !== "string" || !text) return text ?? "";
  return text
    .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/gi, "")
    .replace(/<system>[\s\S]*?<\/system>/gi, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function clip(value, limit) {
  if (value == null) return null;
  const text = typeof value === "string" ? value : JSON.stringify(value);
  if (text.length <= limit) return typeof value === "string" ? text : JSON.parse(text);
  return { truncated: true, bytes: text.length, preview: text.slice(0, limit) };
}

/** 递归找 {type:'text',text} / {type:'thinking',thinking} / 纯字符串片段 */
function collectText(node, out = { text: "", thinking: "" }, depth = 0) {
  if (node == null || depth > 6) return out;
  if (Array.isArray(node)) {
    for (const item of node) collectText(item, out, depth + 1);
    return out;
  }
  if (typeof node === "string") {
    out.text += node;
    return out;
  }
  if (typeof node !== "object") return out;

  const type = typeof node.type === "string" ? node.type : "";
  if (type.includes("thinking") && typeof node.thinking === "string") {
    out.thinking += node.thinking;
    return out;
  }
  if (type === "text" && typeof node.text === "string") {
    out.text += node.text;
    return out;
  }
  if (typeof node.text === "string" && !type) out.text += node.text;

  for (const key of ["content", "delta", "message", "parts", "blocks"]) {
    if (key in node) collectText(node[key], out, depth + 1);
  }
  return out;
}

function usageOf(data) {
  const raw = data?.usage || data?.message?.usage;
  if (!raw || typeof raw !== "object") return null;
  const input = Number(raw.inputTokens ?? raw.input_tokens ?? raw.prompt_tokens ?? 0);
  const output = Number(raw.outputTokens ?? raw.output_tokens ?? raw.completion_tokens ?? 0);
  const cacheRead = Number(raw.cacheReadTokens ?? raw.cache_read_input_tokens ?? raw.prompt_cache_hit_tokens ?? 0);
  if (!input && !output && !cacheRead) return null;
  return {
    input,
    output,
    cacheRead,
    total: Number(raw.totalTokens ?? raw.total_tokens ?? 0) || input + output + cacheRead,
  };
}

function toolCallId(data) {
  return (
    data?.callId ||
    data?.toolCallId ||
    data?.message?.toolCallId ||
    data?.message?.callId ||
    data?.message?.source?.callId ||
    data?.id ||
    null
  );
}

export function sessionIdOf(session, data) {
  const candidates = [
    data?.sessionId,
    session?.id,
    session?.header?.id,
    session?.sessionId,
  ];
  for (const c of candidates) {
    if (typeof c === "string" && c) return c;
  }
  return "unknown";
}

/**
 * 单个 DSH 事件 → 手机帧数组（可能 0 或多帧）。
 * @param {object} session cordis 事件里的 session 对象
 * @param {object} event  { type, data }
 */
export function normalizeEvent(session, event) {
  if (!event || typeof event !== "object") return [];
  const type = String(event.type || "");
  const data = event.data && typeof event.data === "object" ? event.data : {};
  const sessionId = sessionIdOf(session, data);
  const frames = [];
  // 带上事件原始时间（毫秒）。回填历史时手机端要用它算每轮用时，
  // 否则 turn.start / turn.end 在同一毫秒内连续处理，永远显示「用时 0 秒」。
  const eventAt = typeof event.time === "number" ? event.time : null;
  const base = eventAt ? { sessionId, at: eventAt } : { sessionId };
  const turn = Number(data.turn ?? 0) || null;

  switch (type) {
    case "turn/start":
      frames.push({ ...base, type: "turn.start", turn });
      break;

    case "turn/end":
      frames.push({
        ...base,
        type: "turn.end",
        turn,
        reason: clip(data.reason ?? data.status ?? null, 512),
      });
      break;

    case "assistant/message":
    case "assistant/attempt": {
      const { text, thinking } = collectText(data, { text: "", thinking: "" });
      if (thinking) frames.push({ ...base, type: "assistant.thinking", turn, text: clip(thinking, TEXT_LIMIT) });
      if (text) frames.push({ ...base, type: "assistant.delta", turn, text: clip(text, TEXT_LIMIT) });
      const usage = usageOf(data);
      if (usage) frames.push({ ...base, type: "assistant.usage", turn, usage });
      if (!text && !thinking && !usage) {
        frames.push({ ...base, type: "assistant.raw", turn, raw: clip(data, RAW_LIMIT) });
      }
      break;
    }

    case "tool/call":
    case "tool/call/start":
      frames.push({
        ...base,
        type: "tool.call",
        turn,
        callId: toolCallId(data),
        name: String(data.name || data.toolName || data.message?.name || ""),
        args: clip(data.arguments ?? data.args ?? data.input ?? null, RAW_LIMIT),
      });
      break;

    case "tool/result":
      frames.push({
        ...base,
        type: "tool.result",
        turn,
        callId: toolCallId(data),
        ok: data.ok !== false && !data.error,
        preview: clip(
          data.message?.content ?? data.content ?? data.result ?? data.error ?? null,
          RAW_LIMIT,
        ),
      });
      break;

    case "approval/asked":
      frames.push({
        ...base,
        type: "approval.asked",
        id: String(data.id || data.requestId || ""),
        tool: String(data.toolName || data.tool || "permission"),
        reason: String(data.reason || data.displayReason || ""),
      });
      break;

    case "approval/decided":
      frames.push({
        ...base,
        type: "approval.decided",
        id: String(data.id || data.requestId || ""),
        decision: String(data.decision || data.outcome || ""),
      });
      break;

    case "user/message": {
      const raw = collectText(data).text;
      // 系统注入剥掉再判断：`<system-reminder>...</system-reminder>`
      // 这类包裹式内容（技能目录变更、hook 提醒）会整段混进用户消息，
      // 之前只按固定前缀过滤，于是整块原文被当成用户发言显示在手机上。
      const text = stripSystemBlocks(raw);
      // DSH 会把两类内容注入到用户消息里，都是给模型看的，不该进手机聊天记录：
      //   1. time-context：  Time sampled while preparing turn N…
      //   2. runtime-context：Current working directory / DSH file policy / Approval prompts…
      const injected =
        !text.trim() ||
        /^(Time sampled while preparing|Browser time zone for this request|Elapsed since)/im.test(text) ||
        /Current DSH file policy|Approval prompts are disabled in this session|Current DeepSeek Harness implementation checkout|Current DeepSeek Harness Web GUI URL/i.test(
          text,
        ) ||
        // 3. checkpoint：上下文压缩时 DSH 会把一段
        //    「This is an automatically generated checkpoint condensing an earlier span…」
        //    注入成 user/message。它是给模型看的，之前直接在手机上显示成「我」说的话
        //    （用户实拍：整屏都是 <compacted-summary> 原文）。
        /automatically generated checkpoint|<compacted-summary>|condensing an earlier span/i.test(text) ||
        // 4. 后台任务的命令回显：我起 background job 时，整段 PowerShell
        //    脚本（几百行）会被当成 user/message 推进来，手机上就是满屏代码
        //    （用户实拍）。特征很明显：`$script = @'` / `background job pwsh-…`。
        /background job pwsh-|\$script\s*=\s*@'|\$env:PYTHONIOENCODING/i.test(text) ||
        // 5. 后台任务的**完成通知**：`background job pwsh-… (pwsh: …) finished
        //    [status: completed, exit code: 1]. Read its output with job_output.`
        //    这条也是 user/message，手机上会显示成一个「我」的气泡，整段是英文命令行
        //    （用户实拍 23:25 的截图）。它只在任务结束时出现一次，所以以前没被发现。
        /^background job\s+\S+/i.test(text.trim()) ||
        /Read its output with job_output/i.test(text) ||
        /\[status:\s*(completed|failed|killed|cancelled|canceled)[^\]]*exit code:\s*-?\d+\]/i.test(text) ||
        // 6. 排队/插队/取消这类 inbox 回执，DSH 偶尔也会以 user/message 形式送进来
        /^(agent\/inbox|queue)[\s/:]/i.test(text.trim());
      if (!injected) {
        frames.push({ ...base, type: "user.message", turn, text: clip(text, TEXT_LIMIT) });
      }
      break;
    }

    default:
      frames.push({ ...base, type: "event", dshType: type, raw: clip(data, RAW_LIMIT) });
      break;
  }

  return frames;
}

/** 固定容量环形缓冲，按 seq 续传 */
export class FrameBuffer {
  constructor(capacity = 2000) {
    this.capacity = capacity;
    this.items = [];
  }

  push(frame) {
    this.items.push(frame);
    if (this.items.length > this.capacity) this.items.splice(0, this.items.length - this.capacity);
    return frame;
  }

  since(seq) {
    const from = Number(seq) || 0;
    if (!from) return this.items.slice();
    return this.items.filter((f) => f.seq > from);
  }

  get lastSeq() {
    return this.items.length ? this.items[this.items.length - 1].seq : 0;
  }
}
