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
 * 手机端**不渲染**的 DSH 事件：直接不产帧。
 *
 * 这些类型以前走 default 分支变成 `event` 帧（raw 还要裁到 8KB）推给手机，
 * 而手机 apply() 对 `event` 只是 break —— 白传、白解析、白占环形缓冲。
 * 一次历史回填 200 帧里这类占三成以上（`request/header` 单条 44KB、
 * `system/message` 是整份系统提示词、`job/*` 每步两条）。
 *
 * 判断依据：Swift 侧没有任何 `dshType` / `assistant.raw` 的消费点
 * （在 Sources 里 grep 0 命中），所以丢掉是安全的。
 */
const DROPPED_DSH_EVENTS = new Set([
  "request/header",
  "request/context",
  "system/message",
  "job/registered",
  "job/settled",
  "session-log-deepseek/delivery-accepted",
  "workspace/changes",
  "step/start",
  "step/end",
  "session/title",
  "session/title-llm-request",
  "session/end-seed",
  "permission/preset",
  "sandbox/mode",
  "approval/policy",
]);

/** 这个 DSH 事件是不是"手机端不会用到"的（给 /v1/diag 统计用） */
export function isDroppedEvent(type) {
  return DROPPED_DSH_EVENTS.has(String(type || ""));
}

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

/** 手机端能直接展示的扩展名 */
const INLINE_MEDIA_EXT = new Set([
  "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp",
  "mp4", "mov", "m4v", "webm", "avi", "mkv",
  "mp3", "m4a", "wav", "aac", "flac",
]);

/**
 * 值得在手机上提示「产出了文件」的扩展名 —— **只留真正的产物**。
 *
 * 之前把 swift/js/py/md/txt 也算进来了，于是每次改源码都冒一条
 * 「📄 输出文件 · AppModel.swift」，夹在工具行中间像日志噪声（用户实拍）。
 * 现在只认办公文档 / 安装包 / 压缩包这类"能给出去的东西"。
 */
const DELIVERABLE_EXT = new Set([
  "docx", "doc", "xlsx", "xls", "pptx", "ppt", "pdf",
  "epub", "ipa", "apk", "dmg", "zip", "tar", "gz", "7z", "rar",
]);

/** 只有这些工具会「产出新文件」（read/grep 也有 file_path，不能算） */
const OUTPUT_TOOLS = new Set(["write", "present"]);

function fileExt(p) {
  const m = String(p || "").match(/\.([A-Za-z0-9]{1,8})$/);
  return m ? m[1].toLowerCase() : "";
}

/**
 * 从工具参数里取「产出的文件路径」列表。
 *   - write  ：{ file_path }
 *   - present：{ files: [{ path, description }] }   ← 交付物通常走这个
 * 返回去重后的路径数组。
 */
function extractOutputPaths(data) {
  let args = data?.arguments ?? data?.args ?? data?.input ?? null;
  if (typeof args === "string") {
    try { args = JSON.parse(args); } catch { return []; }
  }
  if (!args || typeof args !== "object") return [];
  const out = [];
  const push = (v) => {
    const p = String(v || "").trim();
    if (p) out.push(p);
  };
  push(args.file_path || args.filePath);
  if (Array.isArray(args.files)) for (const f of args.files) push(f?.path || f?.file_path || f);
  push(args.path || args.target);
  return [...new Set(out)];
}

/** 值不值得提示：已知产物扩展名，且不是图片/视频，也不是临时目录里的东西 */
function isDeliverableFile(path) {
  const ext = fileExt(path);
  if (!ext) return false;
  if (INLINE_MEDIA_EXT.has(ext)) return false;
  if (!DELIVERABLE_EXT.has(ext)) return false;
  const normalized = String(path).replace(/\\/g, "/").toLowerCase();
  const noisy = ["/_diag/", "/tmp/", "/temp/", "/.git/", "/node_modules/", "/build/", "/deriveddata/"];
  return !noisy.some((seg) => normalized.includes(seg));
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

  // 手机端用不到的事件：不产帧（见 DROPPED_DSH_EVENTS 的说明）
  if (DROPPED_DSH_EVENTS.has(type)) return [];

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
    case "tool/call/start": {
      const toolName = String(data.name || data.toolName || data.message?.name || "");
      frames.push({
        ...base,
        type: "tool.call",
        turn,
        callId: toolCallId(data),
        name: toolName,
        args: clip(data.arguments ?? data.args ?? data.input ?? null, RAW_LIMIT),
      });
      // 产物提示：手机端只渲染图片/视频，docx/pptx/pdf/ipa 这类文件以前完全看不见。
      // 只有 write / present 且扩展名属于「产物类」才发（读源码、改 .swift 都不发，
      // 否则每条写入都会插一条，夹在工具行中间像噪声 —— 用户实拍）。
      // present 的 files[] 可能有多条，逐个发。
      if (OUTPUT_TOOLS.has(toolName)) {
        for (const outputPath of extractOutputPaths(data)) {
          if (!isDeliverableFile(outputPath)) continue;
          frames.push({
            ...base,
            type: "file.output",
            turn,
            path: outputPath,
            tool: toolName,
          });
        }
      }
      break;
    }

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
