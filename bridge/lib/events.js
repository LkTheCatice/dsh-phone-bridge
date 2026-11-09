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
  const base = { sessionId };
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

    case "user/message":
      frames.push({ ...base, type: "user.message", turn, text: clip(collectText(data).text, TEXT_LIMIT) });
      break;

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
