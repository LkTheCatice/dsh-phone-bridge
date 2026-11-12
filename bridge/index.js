/**
 * dsh-phone-bridge —— 让 iPhone 驱动本机 DeepSeek Harness 会话的本地桥。
 *
 * 设计要点
 *   1. 只监听 loopback（可选一个内网 IP），永不监听公网
 *   2. 除 /v1/health 与 /v1/handshake 外，请求体必须端到端加密（X25519 + AES-256-GCM）
 *   3. 会话生命周期走 ctx.sessionController（create / prompt / list / cancel），
 *      不自己拼消息结构，不绕开鉴权与幂等
 *   4. 审批：手机在线时才拦，超时或无人应答就交回桌面端原流程 —— 不制造卡死
 *   5. 文件访问只允许白名单根，realpath 校验，分块读写
 */

import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { zstdDecompressSync } from "node:zlib";
import { randomUUID, createHash } from "node:crypto";
import { URL } from "node:url";

const execFileAsync = promisify(execFile);
const fsp = fs.promises;
/** Pillow 所在解释器：这台机器上 ComfyUI 自带 */
const PYTHON_FALLBACK = "E:\\AI\\ComfyUI\\python_embeded\\python.exe";

import {
  clearClients,
  dshHome,
  ensurePairState,
  getAutoApprove,
  listClients,
  readJson,
  registerClient,
  removeClient,
  rotateToken,
  setAutoApprove,
  setClientStatus,
  setStateDirOverride,
  stateDir,
} from "./lib/store.js";
import {
  aadFor,
  deriveSessionKeys,
  seal,
  unseal,
} from "./lib/seal.js";
import { createSafeFs, FsDenied } from "./lib/fs-safe.js";
import { FrameBuffer, normalizeEvent, sessionIdOf } from "./lib/events.js";
import { createNotifier } from "./lib/notify.js";

export const name = "dsh-phone-bridge";
export const inject = [];
export const VERSION = "0.1.0";

const MAX_JSON_BYTES = 16 * 1024 * 1024;
const MAX_FILE_CHUNK = 1024 * 1024;
const SSE_HEARTBEAT_MS = 15000;
const PUBLIC_PATHS = new Set(["/v1/health", "/v1/handshake"]);

/**
 * DSH 自己的工作区就是手机该看到的那几个目录。
 * 从 storages/workspace.json 读，不猜 process.cwd()：
 * Electron 进程的 cwd 是 profile 目录，根本不是用户以为的"工作区"。
 */
function detectWorkspaceRoots() {  try {
    const file = path.join(dshHome(), "storages", "workspace.json");
    const doc = readJson(file, null);
    const table = doc?.tables?.workspaces ?? {};
    return Object.values(table)
      .map((ws) => (ws && typeof ws.path === "string" ? ws.path : null))
      .filter(Boolean);
  } catch {
    return [];
  }
}

class HttpError extends Error {
  constructor(status, code, message, detail) {
    super(message || code);
    this.status = status;
    this.code = code;
    this.detail = detail;
  }
}

function jsonError(res, error) {
  const status = error?.status || (error instanceof FsDenied ? 403 : 500);
  const body = {
    error: error?.code || (status === 500 ? "internal" : "error"),
    message: String(error?.message || error),
  };
  if (error?.detail !== undefined) body.detail = error.detail;

  if (res.headersSent) {
    if (!res.writableEnded) res.end();
    return;
  }

  const text = JSON.stringify(body);
  // 已建立 E2EE 的请求，错误体也加密：错误文案里可能带路径、参数等敏感信息
  const enc = res.__enc;
  if (enc?.sealed) {
    const sealed = seal(enc.s2c, enc.aad, text);
    res.writeHead(status, {
      "content-type": "application/octet-stream",
      "x-sealed": "1",
      "cache-control": "no-store",
      "content-length": sealed.length,
    });
    res.end(sealed);
    return;
  }

  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "content-length": Buffer.byteLength(text),
  });
  res.end(text);
}

function readBody(req, limit = MAX_JSON_BYTES) {  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new HttpError(413, "payload-too-large", `请求体超过 ${limit} 字节`));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function tokenOf(req, url) {
  const header = req.headers["x-dsh-token"];
  if (header) return String(header);
  const auth = req.headers["authorization"];
  if (auth) return String(auth).replace(/^Bearer\s+/i, "");
  return url?.searchParams?.get("token") || "";
}

function safeEqual(a, b) {  const ba = Buffer.from(String(a || ""), "utf8");
  const bb = Buffer.from(String(b || ""), "utf8");
  if (ba.length !== bb.length) return false;
  return createHash("sha256").update(ba).digest().equals(createHash("sha256").update(bb).digest());
}

function normalizeSessionRow(row) {  if (!row || typeof row !== "object") return null;
  const id = String(row.sessionId ?? row.id ?? "");
  if (!id) return null;
  const status = row.status ?? (row.running ? "running" : "");
  return {
    id,
    title: row.title ?? row.name ?? null,
    cwd: row.cwd ?? row.path ?? null,
    running: status === "running" || row.running === true,
    agentAvailable: row.agentAvailable !== false,
    updatedAt: row.updatedAt ?? row.mtime ?? row.updated ?? null,
  };
}

/**
 * cordis 插件入口。
 *
 * 外面这层 try/catch 是刻意的：这个插件挂了不该把整个 DSH 拖下水 ——
 * 端口被占、状态目录没权限、某版本 API 变了，都只让手机功能不可用，
 * 桌面端继续照常工作。
 */
export function apply(ctx, config = {}) {
  try {
    return applyBridge(ctx, config);
  } catch (error) {
    console.error(`[phone-bridge] 启动失败，手机功能不可用（不影响 DSH 其他能力）：${error?.stack || error}`);
    return {
      ready: Promise.resolve({ port: 0, pair: null }),
      stop: async () => {},
    };
  }
}

function applyBridge(ctx, config) {
  // 状态目录可以先搬走：必须在 ensurePairState 之前生效
  if (config.stateDir) setStateDirOverride(config.stateDir);

  // 请求 / 错误日志写文件：DSH 桌面版没有日志目录，console 输出拿不到，
  // 手机端出问题时这是唯一的现场证据。
  let logPath = null;
  function logLine(entry) {
    try {
      if (!logPath) logPath = path.join(stateDir(), "bridge.log");
      fs.mkdirSync(path.dirname(logPath), { recursive: true });
      try {
        if (fs.statSync(logPath).size > 2 * 1024 * 1024) fs.writeFileSync(logPath, "");
      } catch {
        /* 文件还不存在 */
      }
      fs.appendFileSync(logPath, JSON.stringify({ at: new Date().toISOString(), ...entry }) + "\n");
    } catch {
      /* 日志失败不能影响主流程 */
    }
  }

  const cfg = {
    port: config.port === 0 ? 0 : Number(config.port) || 8765,
    lanHost: String(config.lanHost || "").trim(),
    askPhone: config.askPhone !== false,
    approvalTimeoutMs: Number(config.approvalTimeoutMs) || 90000,
    roots: Array.isArray(config.roots) ? config.roots.map(String) : [],
    requireE2ee: config.requireE2ee !== false,
    notify: config.notify && typeof config.notify === "object" ? config.notify : {},
    maxFileBytes: Number(config.maxFileBytes) || 512 * 1024 * 1024,
    // ComfyUI 地址（qwen-paint 插件用的是同一个），用于手机上看在线/生图状态
    comfyUrl: String(config.comfyUrl || "http://127.0.0.1:8188").replace(/\/+$/, ""),
  };

  const pair = ensurePairState();
  const notifier = createNotifier(cfg.notify);
  const frames = new FrameBuffer(3000);
  const streamClients = new Set();
  const e2ee = new Map(); // clientId -> {c2s, s2c, createdAt, lastSeen, name}
  const approvals = new Map(); // id -> {tool, reason, since, decide}
  const seenEvents = new WeakSet();

  let seq = 0;
  let sessionController = null;
  let agentRegistry = null;
  let workspaceRegistry = null;
  let server = null;
  let closed = false;
  let resolveReady;
  const ready = new Promise((resolve) => {
    resolveReady = resolve;
  });

  const safeFs = createSafeFs({
    roots: () => [...cfg.roots, ...detectWorkspaceRoots(), process.cwd()],
    maxChunkBytes: MAX_FILE_CHUNK,
    maxFileBytes: cfg.maxFileBytes,
  });

  // ── 事件订阅 ────────────────────────────────────────────────────────────────

  function broadcast(frame) {
    seq += 1;
    const full = { v: 1, seq, at: Date.now(), ...frame };
    frames.push(full);
    const line = JSON.stringify(full);
    for (const client of streamClients) {
      try {
        client.send(full, line);
      } catch {
        streamClients.delete(client);
      }
    }
    return full;
  }

  // 帧类型统计：只统计「谁产生了什么类型的帧」，不存内容。
  // 目的是回答「电脑端排队/插队时，桥到底收到什么事件」——
  // 手机发消息才会触发 queue.probe，电脑端操作是黑盒。
  const frameStats = new Map();
  function noteFrameType(type) {
    const k = String(type || "?");
    frameStats.set(k, (frameStats.get(k) || 0) + 1);
  }
  const frameStatsTimer = setInterval(() => {
    if (!frameStats.size) return;
    const counts = [...frameStats.entries()].sort((a, b) => b[1] - a[1]);
    frameStats.clear();
    logLine({ step: "frame.stats", counts: counts.slice(0, 30) });
  }, 30_000);
  frameStatsTimer.unref?.();

  function onSessionEvent(session, event) {
    if (closed || !event || typeof event !== "object") return;
    noteFrameType(event.type);

    // 队列事件 → 手机帧。
    //
    // 实测（2026-11-12）确认 agent/inbox/spliced 就是队列操作，语义是：
    //   target=next-turn + inserted=[消息]            → 排队
    //   target=next-turn + removedCount>0 + inserted  → 修改内容（同一 rpcId 替换）
    //   target=next-turn + removedCount>0 + inserted=[] → 取出/取消
    //   target=next-step + inserted=[消息]            → 插队（立即执行）
    // 一次事件 = target + start（位置）+ removedCount + inserted，原子操作。
    //
    // 手机端据此自己维护一份队列：排队就加、移除就删、改内容就替换。
    if (event.type === "agent/inbox/spliced") {
      try {
        const d = event.data || {};
        const items = (Array.isArray(d.inserted) ? d.inserted : []).map((it) => {
          const content = Array.isArray(it?.content) ? it.content : [];
          const text = content
            .map((c) => (c && typeof c === "object" && c.type === "text" ? String(c.text || "") : ""))
            .join("");
          return {
            id: String(it?.id || ""),
            rpcId: String(it?.source?.rpcId || ""),
            text: text.slice(0, 400),
          };
        });
        const frame = {
          type: "queue.changed",
          sessionId: sessionIdOf(session, d),
          target: String(d.target || ""),
          start: Number(d.start || 0),
          removed: Number(d.removedCount || 0),
          outcome: String(d.outcome || ""),
          items,
        };
        broadcast(frame);
        // 确认帧真的发出去了：手机队列区一直是空的，
        // 需要区分「没广播」和「广播了但手机没处理」。
        logLine({
          step: "queue.changed/sent",
          clientCount: streamClients.size,
          sessionId: frame.sessionId,
          target: frame.target,
          start: frame.start,
          removed: frame.removed,
          itemCount: items.length,
        });
      } catch (e) {
        logLine({ step: "queue.changed/failed", error: String(e?.message || e).slice(0, 160) });
      }
    }
    if (seenEvents.has(event)) return;
    seenEvents.add(event);
    try {
      for (const frame of normalizeEvent(session, event)) broadcast(frame);
      if (event.type === "turn/end") {
        const sid = sessionIdOf(session, event.data);
        const reason = event.data?.reason?.kind || event.data?.status || "end";
        notifier
          .push({
            title: "DSH 任务结束",
            body: `会话 ${sid.slice(-6)} · ${String(reason).slice(0, 40)}`,
            group: "DSH",
          })
          .catch(() => {});
      }
    } catch (error) {
      console.warn("[phone-bridge] 事件归一化失败:", error?.message || error);
    }
  }

  try {
    ctx.on("session/event", onSessionEvent);
  } catch (error) {
    console.warn("[phone-bridge] 无法订阅 session/event:", error?.message || error);
  }

  // ── 审批挂起 ────────────────────────────────────────────────────────────────

  function phoneOnline() {
    return streamClients.size > 0;
  }

  function askPhone(request) {
    const id = String(request?.callId || request?.id || randomUUID());
    return new Promise((resolve) => {
      const decide = (decision) => {
        clearTimeout(timer);
        approvals.delete(id);
        broadcast({ type: "approval.decided", id, decision, sessionId: "unknown" });
        resolve(decision);
      };
      const timer = setTimeout(() => decide("passthrough"), cfg.approvalTimeoutMs);
      timer.unref?.();
      approvals.set(id, {
        id,
        tool: String(request?.toolName || request?.tool || "permission"),
        reason: String(request?.displayReason || request?.reason || ""),
        since: Date.now(),
        decide,
      });
      broadcast({
        type: "approval.asked",
        id,
        tool: approvals.get(id).tool,
        reason: approvals.get(id).reason,
        sessionId: String(request?.sessionId || "unknown"),
        timeoutMs: cfg.approvalTimeoutMs,
      });
    });
  }

  try {
    ctx.on("approval/request", async (request, next) => {
      const proceed = () => (typeof next === "function" ? next() : undefined);
      if (!cfg.askPhone || closed || !phoneOnline()) return proceed();
      const decision = await askPhone(request);
      if (decision === "allow") return proceed();
      if (decision === "deny") return "deny";
      return proceed();
    });
  } catch (error) {
    console.warn("[phone-bridge] 无法挂载审批中间件:", error?.message || error);
  }

  // ── 延迟获取 DSH 服务 ───────────────────────────────────────────────────────

  try {
    ctx.inject(["sessionController"], (scope) => {
      sessionController = scope.sessionController || scope.get?.("sessionController") || null;
      if (sessionController) console.log("[phone-bridge] sessionController 就绪");
    });
  } catch (error) {
    console.warn("[phone-bridge] sessionController 注入失败:", error?.message || error);
  }
  try {
    ctx.inject(["agents"], (scope) => {
      agentRegistry = scope.agents || scope.get?.("agents") || null;
    });
  } catch {
    /* 可选服务 */
  }
  try {
    ctx.inject(["workspaceRegistry"], (scope) => {
      workspaceRegistry = scope.workspaceRegistry || scope.get?.("workspaceRegistry") || null;
    });
  } catch {
    /* 归档功能会降级 */
  }

  /**
   * 冷会话（没加载进 store）拿不到 session 对象，但标题其实已经写进磁盘上的
   * 会话日志了：<DSH_HOME>/sessions/<工作区>/<会话 id>/session.v4.jsonl.zstd，
   * 里面有一条 `session/title` 事件。node 24 自带 zstd 解压，直接读。
   */
  const titleLogCache = new Map(); // sessionId -> { title, mtimeMs }
  let logIndexCache = { at: 0, map: new Map() };

  function sessionLogIndex() {
    if (Date.now() - logIndexCache.at < 60_000) return logIndexCache.map;
    const map = new Map();
    const home = process.env.DSH_HOME || path.join(os.homedir(), ".dsh");
    const root = path.join(home, "sessions");
    try {
      for (const ws of fs.readdirSync(root, { withFileTypes: true })) {
        if (!ws.isDirectory()) continue;
        const wsPath = path.join(root, ws.name);
        let subs = [];
        try {
          subs = fs.readdirSync(wsPath, { withFileTypes: true });
        } catch {
          continue;
        }
        for (const entry of subs) {
          if (!entry.isDirectory()) continue;
          const file = path.join(wsPath, entry.name, "session.v4.jsonl.zstd");
          if (fs.existsSync(file)) map.set(entry.name, file);
        }
      }
    } catch {
      /* 没有 sessions 目录就当没有 */
    }
    logIndexCache = { at: Date.now(), map };
    return map;
  }

  function titleFromLog(sessionId) {
    const file = sessionLogIndex().get(sessionId);
    if (!file) return null;
    let stat;
    try {
      stat = fs.statSync(file);
    } catch {
      return null;
    }
    // 和 framesFromLog 一致：超大日志不解析，别堵事件循环
    if (stat.size > MAX_LOG_BYTES) return null;
    const cached = titleLogCache.get(sessionId);
    if (cached && cached.mtimeMs === stat.mtimeMs) return cached.title;
    let title = null;
    try {
      const text = zstdReadAll(fs.readFileSync(file)).toString("utf8");
      for (const line of text.split("\n")) {
        if (!line.includes("session/title")) continue;
        try {
          const event = JSON.parse(line);
          if (event?.type === "session/title" && typeof event.data?.title === "string") {
            title = event.data.title.trim();
          }
        } catch {
          /* 跳过坏行 */
        }
      }
    } catch {
      return null;
    }
    titleLogCache.set(sessionId, { title, mtimeMs: stat.mtimeMs });
    return title;
  }

  /**
   * 解压「流式追加写」的 zstd 文件。
   *
   * DSH 每追加一批事件就写一个独立的 zstd frame，而 Electron 44 内置的 zlib
   * （Chromium 实现，不是 Node 原生）的 zstdDecompressSync 只处理**第一个** frame：
   * 890KB 的会话日志只解出 230 字符 —— 标题和历史因此全读不到。
   * 独立 node 里没这毛病，所以命令行验证一直是通的。
   *
   * 这里按 zstd magic number 手动切分，逐片解压再拼接，绕开它的 frame 行为。
   */
  const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

  function zstdReadAll(buffer) {
    const starts = [];
    let index = buffer.indexOf(ZSTD_MAGIC, 0);
    while (index !== -1) {
      starts.push(index);
      index = buffer.indexOf(ZSTD_MAGIC, index + 4);
    }
    if (starts.length <= 1) return zstdDecompressSync(buffer);

    const parts = [];
    for (let i = 0; i < starts.length; i += 1) {
      const start = starts[i];
      const end = i + 1 < starts.length ? starts[i + 1] : buffer.length;
      try {
        parts.push(zstdDecompressSync(buffer.subarray(start, end)));
      } catch {
        /* 分片切错就跳过：宁可少一条事件，也别整个失败 */
      }
    }
    if (parts.length === 0) return zstdDecompressSync(buffer);
    return Buffer.concat(parts);
  }

  /**
   * 日志重建的护栏。
   *
   * 解压 + 逐行 JSON.parse 是**同步** CPU 操作，而 DSH 是单线程 Node ——
   * App 快速切会话会串行阻塞事件循环，这就是能把 DSH 拖死的原因。
   * 所以：按 mtime 缓存结果（第二次起毫秒级命中）、限制缓存规模、超大日志直接拒绝。
   */
  const framesLogCache = new Map(); // sessionId -> { frames, mtimeMs }
  const FRAMES_CACHE_LIMIT = 6;
  const MAX_LOG_BYTES = 24 * 1024 * 1024;

  // MARK: 图片预览压缩
  const PREVIEW_MAX_PIXEL = 2048;
  const PREVIEW_QUALITY = 86;
  const PREVIEW_MIN_BYTES = 800 * 1024;
  const IMAGE_EXT = new Set([".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif"]);
  const VIDEO_EXT = new Set([".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi"]);
  const previewCacheDir = path.join(stateDir(), "preview-cache");

  /** ffmpeg 可执行文件位置（winget / 手动放置 / PATH 三处找） */
  const FFMPEG_CANDIDATES = [
    // 显式指定优先（换机器时不用改代码）
    process.env.DSH_FFMPEG || "",
    "D:\\tools\\ffmpeg\\ffmpeg.exe",
    // 本机实际的 ffmpeg（E:\AI\ffmpeg，9.0.2 完整版）
    "E:\\AI\\ffmpeg\\ffmpeg.exe",
    path.join(process.env.LOCALAPPDATA || "", "Microsoft", "WinGet", "Links", "ffmpeg.exe"),
  ];

  async function ffmpegPath() {
    if (ffmpegPath._cache !== undefined) return ffmpegPath._cache;
    let found = null;
    for (const candidate of FFMPEG_CANDIDATES) {
      if (!candidate) continue;
      try {
        await fsp.access(candidate);
        found = candidate;
        break;
      } catch {
        /* 继续找 */
      }
    }
    if (!found) {
      // 最后看 PATH
      try {
        const { stdout } = await execFileAsync("where", ["ffmpeg"], { windowsHide: true });
        const line = String(stdout).split(/\r?\n/).map((s) => s.trim()).filter(Boolean)[0];
        if (line) found = line;
      } catch {
        /* 没有就没有 */
      }
    }
    ffmpegPath._cache = found;
    return found;
  }

  /**
   * 视频封面帧：抽第 0 秒的一帧做成小图。
   * 手机侧大视频只显示这张封面 + 「点击下载」，不会因为滚过去就吃掉几十 MB。
   */
  async function videoPoster(real, stat) {
    const ffmpeg = await ffmpegPath();
    if (!ffmpeg) return null;
    const key = createHash("sha1").update(`poster|${real}|${stat.mtimeMs}`).digest("hex");
    const cachedPath = path.join(previewCacheDir, `${key}.jpg`);
    try {
      return { buffer: await fsp.readFile(cachedPath) };
    } catch {
      /* 无缓存 */
    }
    try {
      await fsp.mkdir(previewCacheDir, { recursive: true });
      await execFileAsync(
        ffmpeg,
        [
          "-y", "-loglevel", "error",
          "-ss", "0.5",            // 稍微进去一点，避开开头的黑帧
          "-i", real,
          "-vframes", "1",
          "-vf", "scale=720:-2",
          "-q:v", "4",
          cachedPath,
        ],
        { timeout: 30000, windowsHide: true },
      );
      return { buffer: await fsp.readFile(cachedPath) };
    } catch (error) {
      logLine({ step: "poster/failed", error: String(error?.message || error).slice(0, 160) });
      return null;
    }
  }

  /**
   * 视频压缩：给手机看的预览版。
   * 长边 1280、CRF 32、veryfast —— 手机上看清楚够用，体积通常降到 1/5 以下。
   * 只在 preview=1 且文件超过阈值时调用，原件始终留在电脑上。
   */
  async function videoPreview(real, stat) {
    const ffmpeg = await ffmpegPath();
    if (!ffmpeg) return null;
    const key = createHash("sha1").update(`video|${real}|${stat.mtimeMs}`).digest("hex");
    const cachedPath = path.join(previewCacheDir, `${key}.mp4`);
    try {
      return { buffer: await fsp.readFile(cachedPath) };
    } catch {
      /* 无缓存 */
    }
    try {
      await fsp.mkdir(previewCacheDir, { recursive: true });
      await execFileAsync(
        ffmpeg,
        [
          "-y", "-loglevel", "error",
          "-i", real,
          "-vf", "scale='min(1280,iw)':-2",
          "-c:v", "libx264", "-crf", "32", "-preset", "veryfast",
          "-c:a", "aac", "-b:a", "96k",
          "-movflags", "+faststart",
          cachedPath,
        ],
        { timeout: 180000, windowsHide: true },
      );
      const buffer = await fsp.readFile(cachedPath);
      logLine({ step: "video-preview", srcBytes: stat.size, outBytes: buffer.length });
      return { buffer };
    } catch (error) {
      logLine({ step: "video-preview/failed", error: String(error?.message || error).slice(0, 160) });
      return null;
    }
  }

  /**
   * 生成图片预览：电脑侧压好再传，手机只为「看一眼确认」。
   *
   * 用 Pillow 而不是 ffmpeg/ImageMagick —— 这台机器上那两个都没装，
   * 但 ComfyUI 的 python_embeded 自带 Pillow。
   * 结果按 path+mtime 缓存，同一张图只压一次。
   * 小于 800KB 的图不压（原样更清楚）；视频/音频不处理。
   */
  async function imagePreview(target, options = {}) {
    const ext = path.extname(String(target)).toLowerCase();
    const isVideo = VIDEO_EXT.has(ext);
    if (!IMAGE_EXT.has(ext) && !isVideo) return null;

    let real;
    try {
      real = await safeFs.resolveAllowed(target);
    } catch {
      return null;
    }
    let stat;
    try {
      stat = await fsp.stat(real);
    } catch {
      return null;
    }

    // 视频有两条路：只要封面帧，或者要压好的预览片
    if (isVideo) {
      if (options.mode === "poster") return videoPoster(real, stat);
      return videoPreview(real, stat);
    }

    // 聊天列表里的缩略图只需几百像素；点开大图才要 2048。
    // 由调用方用 ?w= 指定，缺省仍用 PREVIEW_MAX_PIXEL。
    const maxPixel = Math.min(
      Math.max(Number(options.maxPixel) || PREVIEW_MAX_PIXEL, 64),
      PREVIEW_MAX_PIXEL,
    );

    // 太小的图不必压（压了反而更大）
    if (stat.size < PREVIEW_MIN_BYTES && maxPixel >= PREVIEW_MAX_PIXEL) return null;

    const key = createHash("sha1")
      .update(`${real}|${stat.mtimeMs}|${maxPixel}|${PREVIEW_QUALITY}`)
      .digest("hex");
    const cachedPath = path.join(previewCacheDir, `${key}.jpg`);
    try {
      return { buffer: await fsp.readFile(cachedPath) };
    } catch {
      /* 无缓存，生成 */
    }

    const python = cfg.pythonPath || PYTHON_FALLBACK;
    const script = [
      "import sys",
      "from PIL import Image",
      "src, dst, maxpx, q = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])",
      "im = Image.open(src)",
      "im.thumbnail((maxpx, maxpx), Image.LANCZOS)",
      "im.convert('RGB').save(dst, 'JPEG', quality=q, optimize=True)",
    ].join("\n");

    try {
      await fsp.mkdir(previewCacheDir, { recursive: true });
      await execFileAsync(
        python,
        ["-c", script, real, cachedPath, String(maxPixel), String(PREVIEW_QUALITY)],
        { timeout: 25000, windowsHide: true },
      );
      const buffer = await fsp.readFile(cachedPath);
      logLine({ step: "preview", srcBytes: stat.size, outBytes: buffer.length });
      return { buffer };
    } catch (error) {
      logLine({ step: "preview/failed", error: String(error?.message || error).slice(0, 160) });
      return null;
    }
  }

  /** 冷会话的历史：直接用磁盘日志重建（和标题走同一套 zstd 读取） */
  function framesFromLog(sessionId) {
    const file = sessionLogIndex().get(sessionId);
    if (!file) return null;

    let stat;
    try {
      stat = fs.statSync(file);
    } catch {
      return null;
    }
    // 超大日志不重建：宁可让界面显示「这段太长」，也别堵住事件循环
    if (stat.size > MAX_LOG_BYTES) {
      logLine({ step: "transcript/log", sessionId, skipped: "log-too-large", size: stat.size });
      return null;
    }
    const cached = framesLogCache.get(sessionId);
    if (cached && cached.mtimeMs === stat.mtimeMs) return cached.frames;

    try {
      const text = zstdReadAll(fs.readFileSync(file)).toString("utf8");
      const frames = [];
      // normalizeEvent 只在 sessionIdOf 里用 session，给个最小替身就够
      const stub = { id: sessionId };
      for (const line of text.split("\n")) {
        if (!line) continue;
        let event;
        try {
          event = JSON.parse(line);
        } catch {
          continue;
        }
        for (const frame of normalizeEvent(stub, event)) {
          // "event" 是没被归一化的原始事件，手机端不渲染，纯占带宽
          if (frame.type === "event") continue;
          frames.push(frame);
        }
      }
      framesLogCache.set(sessionId, { frames, mtimeMs: stat.mtimeMs });
      // 简易 LRU：只留最近几个会话，避免内存随会话数增长
      while (framesLogCache.size > FRAMES_CACHE_LIMIT) {
        const oldest = framesLogCache.keys().next().value;
        framesLogCache.delete(oldest);
      }
      return frames;
    } catch (error) {
      logLine({ step: "transcript/log", sessionId, error: String(error?.message || error).slice(0, 200) });
      return null;
    }
  }

  /**
   * 会话标题不在 list() 的返回里，只能从会话日志里折出来。
   *
   * 三条路依次尝试：
   *   1. 官方 sessionTitle 服务（需要热会话）
   *   2. 直接折叠 session 的事件（同样需要热会话）
   *   3. 读磁盘日志（冷会话也能拿到，覆盖列表里绝大多数会话）
   */  function titleOf(sessionId) {
    try {
      const store = ctx.get?.("sessions");
      const session = store?.get?.(sessionId);
      if (session) {
        const titles = ctx.get?.("sessionTitle");
        if (titles && typeof titles.get === "function") {
          const snapshot = titles.get(session);
          const title = typeof snapshot === "string" ? snapshot : snapshot?.title;
          if (typeof title === "string" && title.trim()) return title.trim();
        }

        const events = typeof session.snapshotEvents === "function" ? session.snapshotEvents() : null;
        if (Array.isArray(events)) {
          for (let i = events.length - 1; i >= 0; i -= 1) {
            const event = events[i];
            if (event && event.type === "session/title") {
              const title = event.data?.title;
              if (typeof title === "string" && title.trim()) return title.trim();
              break;
            }
          }
        }
      }
    } catch {
      /* 任何一步失败都落到日志兜底 */
    }
    return titleFromLog(sessionId);
  }

  /** 标题读取链路的诊断：把每一步的中间状态暴露出来 */
  function titleDiagnostics(sessionId) {
    const report = {
      sessionId,
      hasGet: typeof ctx.get === "function",
      serviceNames: [],
      hasSessionTitle: false,
      hasSessionsStore: false,
      hasSession: false,
      serviceValue: null,
      eventTitle: null,
    };
    try {
      const titles = ctx.get?.("sessionTitle");
      const store = ctx.get?.("sessions");
      report.hasSessionTitle = Boolean(titles) && typeof titles.get === "function";
      report.hasSessionsStore = Boolean(store) && typeof store.get === "function";
      const session = store?.get?.(sessionId);
      report.hasSession = Boolean(session);
      if (session && titles && typeof titles.get === "function") {
        try {
          const snapshot = titles.get(session);
          report.serviceValue = snapshot === undefined ? null : JSON.parse(JSON.stringify(snapshot));
        } catch (error) {
          report.serviceValue = { error: String(error?.message || error) };
        }
      }
      const events = session && typeof session.snapshotEvents === "function" ? session.snapshotEvents() : null;
      if (Array.isArray(events)) {
        for (let i = events.length - 1; i >= 0; i -= 1) {
          if (events[i]?.type === "session/title") {
            report.eventTitle = events[i].data?.title ?? null;
            break;
          }
        }
        report.eventCount = events.length;
        report.hasTitleEvent = report.eventTitle !== null;
      }
      report.resolved = titleOf(sessionId);
    } catch (error) {
      report.error = String(error?.message || error);
    }
    return report;
  }

  /** 查 ComfyUI 是否在线、是否在生图（手机上的状态灯用它） */
  async function comfyStatus() {
    const base = cfg.comfyUrl;
    try {
      const signal = AbortSignal.timeout(2500);
      const [statsRes, queueRes] = await Promise.all([
        fetch(`${base}/system_stats`, { signal }),
        fetch(`${base}/queue`, { signal }),
      ]);
      if (!statsRes.ok) return { online: false, url: base };
      let stats = null;
      try {
        stats = await statsRes.json();
      } catch {
        /* 结构变化时忽略 */
      }
      let running = 0;
      let pending = 0;
      if (queueRes.ok) {
        try {
          const queue = await queueRes.json();
          running = Array.isArray(queue?.queue_running) ? queue.queue_running.length : 0;
          pending = Array.isArray(queue?.queue_pending) ? queue.queue_pending.length : 0;
        } catch {
          /* 忽略 */
        }
      }
      const device = Array.isArray(stats?.devices) ? stats.devices[0] : null;
      return {
        online: true,
        url: base,
        generating: running > 0,
        running,
        pending,
        version: stats?.system?.comfyui_version ?? null,
        vramFreeMB: device?.vram_free ? Math.round(Number(device.vram_free) / 1024 / 1024) : null,
        vramTotalMB: device?.vram_total ? Math.round(Number(device.vram_total) / 1024 / 1024) : null,
      };
    } catch {
      return { online: false, url: base };
    }
  }

  /** 当前会话的模型选择 + 全部可用模型 */
  async function modelCatalog() {
    const ctrl = sessionController || ctx.sessionController;
    if (!ctrl || typeof ctrl.modelCatalog !== "function") return { groups: [], failures: [], default: null };
    try {
      const raw = await ctrl.modelCatalog();
      const groups = Array.isArray(raw?.groups) ? raw.groups : [];
      return {
        groups: groups.map((group) => ({
          id: String(group?.id ?? ""),
          name: String(group?.name ?? group?.id ?? ""),
          models: (Array.isArray(group?.models) ? group.models : []).map((model) => ({
            id: String(model?.id ?? ""),
            name: String(model?.name ?? model?.id ?? ""),
            description: model?.description ?? null,
          })),
        })),
        failures: Array.isArray(raw?.failures) ? raw.failures : [],
        default: raw?.default ?? null,
      };
    } catch (error) {
      logLine({ step: "modelCatalog", error: String(error?.message || error).slice(0, 300) });
      return { groups: [], failures: [{ message: String(error?.message || error) }], default: null };
    }
  }

  /** 读某个会话当前用的模型：从 session 的模型选择投影里拿 */
  function currentSelection(sessionId) {
    try {
      const store = ctx.get?.("sessions");
      const session = store?.get?.(sessionId);
      if (!session) return null;
      const agents = ctx.get?.("agents");
      const selection = agents?.selectionFor?.(session)?.current;
      if (!selection) return null;
      return { provider: selection.provider ?? null, model: selection.model ?? null };
    } catch {
      return null;
    }
  }

  async function listSessions() {
    const ctrl = sessionController || ctx.sessionController;
    if (ctrl && typeof ctrl.list === "function") {
      try {
        const raw = await ctrl.list({}, AbortSignal.timeout(15000));
        const rows = Array.isArray(raw) ? raw : raw?.sessions ?? raw?.items ?? [];
        const mapped = rows.map(normalizeSessionRow).filter(Boolean);
        // 给最近的会话补齐标题。热会话走服务/事件，冷会话走磁盘日志；
        // 日志有 60 秒索引缓存 + 按 mtime 的单条缓存，所以多补一些也不会明显变慢。
        for (let i = 0; i < Math.min(mapped.length, 60); i += 1) {
          if (!mapped[i].title) {
            const t = titleOf(mapped[i].id);
            if (t) mapped[i].title = t;
          }
        }
        if (mapped.length) return mapped;
      } catch (error) {
        console.warn("[phone-bridge] sessionController.list 失败:", error?.message || error);
      }
    }
    const reg = agentRegistry || ctx.agents;
    if (reg && typeof reg.list === "function") {
      try {
        return (reg.list() || [])
          .map((agent) => normalizeSessionRow({ id: agent?.id, status: agent?.status, cwd: agent?.cwd }))
          .filter(Boolean);
      } catch {
        /* 忽略 */
      }
    }
    return [];
  }

  // ── HTTP ────────────────────────────────────────────────────────────────────

  function sendJson(res, status, payload, ctxEnc) {
    const text = JSON.stringify(payload);
    if (ctxEnc?.sealed) {
      const sealed = seal(ctxEnc.s2c, ctxEnc.aad, text);
      res.writeHead(status, {
        "content-type": "application/octet-stream",
        "x-sealed": "1",
        "cache-control": "no-store",
        "content-length": sealed.length,
      });
      res.end(sealed);
      return;
    }
    res.writeHead(status, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "content-length": Buffer.byteLength(text),
    });
    res.end(text);
  }

  function sendBinary(res, status, buffer, ctxEnc, extraHeaders = {}) {
    const body = ctxEnc?.sealed ? seal(ctxEnc.s2c, ctxEnc.aad, buffer) : buffer;
    res.writeHead(status, {
      "content-type": "application/octet-stream",
      ...(ctxEnc?.sealed ? { "x-sealed": "1" } : {}),
      "cache-control": "no-store",
      "content-length": body.length,
      ...extraHeaders,
    });
    res.end(body);
  }

  function openStream(req, res, url) {
    const token = tokenOf(req, url);
    if (!safeEqual(token, pair.token)) throw new HttpError(401, "unauthorized", "token 无效");

    const clientId = String(req.headers["x-client"] || url.searchParams.get("client") || "");
    const keys = clientId ? e2ee.get(clientId) : null;

    res.writeHead(200, {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-store",
      connection: "keep-alive",
      "x-accel-buffering": "no",
    });
    res.write(": connected\n\n");

    const send = (frame, preRendered) => {
      const line = preRendered || JSON.stringify(frame);
      if (keys) {
        const sealed = seal(keys.s2c, "SSE", line).toString("base64");
        res.write(`event: sealed\ndata: ${sealed}\n\n`);
      } else {
        res.write(`data: ${line}\n\n`);
      }
    };

    const client = { id: clientId || randomUUID(), send, res };
    streamClients.add(client);

    const since = Number(url.searchParams.get("since")) || 0;
    for (const frame of frames.since(since)) send(frame);

    const beat = setInterval(() => {
      try {
        res.write(": ping\n\n");
      } catch {
        /* 断线由 close 处理 */
      }
    }, SSE_HEARTBEAT_MS);
    beat.unref?.();

    const cleanup = () => {
      clearInterval(beat);
      streamClients.delete(client);
    };
    req.on("close", cleanup);
    req.on("error", cleanup);
  }

  // ── 管理接口（只给本机 DSH 界面用）────────────────────────────────────────
  //
  // 安全边界：只接受来自回环地址的请求，因此手机和局域网一律 403。
  // 不校验 token 是刻意的 —— 能访问 loopback 的只有本机进程，而它们本来就能读
  // pair.json。真正的安全边界在「设备闸门」（handshake 检查 status）。

  function corsHeaders(res) {
    res.setHeader("access-control-allow-origin", "*");
    res.setHeader("access-control-allow-methods", "GET,POST,OPTIONS");
    res.setHeader("access-control-allow-headers", "content-type");
    res.setHeader("access-control-max-age", "600");
  }

  /** 与握手时同一套派生，用来判断某台设备此刻是否在线 */
  function clientIdFor(fingerprint) {
    return createHash("sha256")
      .update(`dsh-phone-bridge|${fingerprint}|${pair.token}`)
      .digest("base64url")
      .slice(0, 32);
  }

  function dropClientRuntime(fingerprint) {
    const cid = clientIdFor(fingerprint);
    e2ee.delete(cid);
    for (const stream of [...streamClients]) {
      if (stream.id !== cid) continue;
      try {
        stream.res.end();
      } catch {
        /* 已经断了 */
      }
      streamClients.delete(stream);
    }
  }

  async function handleAdmin(req, res, url, method, pathname) {
    corsHeaders(res);
    if (method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    const readJson = async () => {
      const raw = await readBody(req, 256 * 1024);
      if (!raw.length) return {};
      try {
        return JSON.parse(raw.toString("utf8"));
      } catch {
        throw new HttpError(400, "bad-json", "请求体不是 JSON");
      }
    };

    // 诊断：标题日志兜底为什么在服务进程里读不到
    if (method === "GET" && pathname === "/admin/debug/env") {
      const home = process.env.DSH_HOME || path.join(os.homedir(), ".dsh");
      const sessionsRoot = path.join(home, "sessions");
      const probe = url.searchParams.get("sessionId") || "";
      const index = sessionLogIndex();
      const report = {
        node: process.versions.node,
        electron: process.versions.electron || null,
        homedir: os.homedir(),
        dshHomeEnv: process.env.DSH_HOME || null,
        resolvedSessionsRoot: sessionsRoot,
        sessionsRootExists: fs.existsSync(sessionsRoot),
        logIndexSize: index.size,
        zstdAvailable: typeof zstdDecompressSync,
      };
      if (probe) {
        const file = index.get(probe);
        report.probeId = probe;
        report.probeFile = file || null;
        if (file) {
          report.probePathExists = fs.existsSync(file);
          try {
            const raw = fs.readFileSync(file);
            const text = zstdReadAll(raw).toString("utf8");
            report.probeBytes = text.length;
            report.probeRawBytes = raw.length;
            report.probeHasTitleEvent = text.includes("session/title");
            let title = null;
            for (const line of text.split("\n")) {
              if (!line.includes("session/title")) continue;
              try {
                const ev = JSON.parse(line);
                if (ev?.type === "session/title" && ev.data?.title) title = ev.data.title;
              } catch {
                /* 坏行跳过 */
              }
            }
            report.probeTitle = title;
          } catch (error) {
            report.probeError = String(error?.message || error).slice(0, 200);
          }
        }
        report.titleOf = titleOf(probe);
        report.framesFromLog = (() => {
          const frames = framesFromLog(probe);
          return frames === null ? null : frames.length;
        })();
      }
      // /admin/* 是免 E2EE 的本机接口，没有会话密钥，传 ctxEnc 会导致加密失败 500
      return sendJson(res, 200, { ok: true, report });
    }

    if (method === "GET" && pathname === "/admin/devices") {
      const devices = listClients().map((c) => {
        const cid = clientIdFor(c.fingerprint);
        const known = e2ee.has(cid);
        const streaming = [...streamClients].some((s) => s.id === cid);
        return {
          fingerprint: c.fingerprint,
          name: c.name || "未知设备",
          status: c.status || "approved",
          firstSeen: c.firstSeen || null,
          lastSeen: c.lastSeen || null,
          statusChangedAt: c.statusChangedAt || null,
          online: Boolean(known && streaming),
        };
      });
      return sendJson(res, 200, {
        ok: true,
        autoApprove: getAutoApprove(),
        server: {
          fingerprint: pair.fingerprint,
          createdAt: pair.createdAt,
          port: cfg.port,
          lanHost: cfg.lanHost,
          e2eeRequired: cfg.requireE2ee,
          stateDir: stateDir(),
        },
        devices,
        pendingCount: devices.filter((d) => d.status === "pending").length,
        onlineCount: devices.filter((d) => d.online).length,
      });
    }

    if (method === "POST" && pathname === "/admin/devices/status") {
      const body = await readJson();
      const fingerprint = String(body.fingerprint || "");
      const status = String(body.status || "");
      if (!fingerprint || !["approved", "pending", "blocked"].includes(status)) {
        throw new HttpError(400, "bad-request", "需要 fingerprint，且 status ∈ approved|pending|blocked");
      }
      const updated = setClientStatus(fingerprint, status);
      if (!updated) throw new HttpError(404, "not-found", "没有这台设备的记录");
      if (status !== "approved") dropClientRuntime(fingerprint);
      logLine({ step: "admin/status", device: fingerprint.slice(0, 12), status });
      return sendJson(res, 200, { ok: true, fingerprint, status });
    }

    if (method === "POST" && pathname === "/admin/devices/remove") {
      const body = await readJson();
      const fingerprint = String(body.fingerprint || "");
      if (!fingerprint) throw new HttpError(400, "bad-request", "需要 fingerprint");
      dropClientRuntime(fingerprint);
      const removed = removeClient(fingerprint);
      logLine({ step: "admin/remove", device: fingerprint.slice(0, 12), removed });
      return sendJson(res, 200, { ok: true, removed });
    }

    if (method === "POST" && pathname === "/admin/settings") {
      const body = await readJson();
      if (typeof body.autoApprove === "boolean") setAutoApprove(body.autoApprove);
      return sendJson(res, 200, { ok: true, autoApprove: getAutoApprove() });
    }

    if (method === "POST" && pathname === "/admin/rotate-token") {
      const next = rotateToken();
      pair.token = next;
      e2ee.clear();
      for (const stream of [...streamClients]) {
        try {
          stream.res.end();
        } catch {
          /* 忽略 */
        }
        streamClients.delete(stream);
      }
      logLine({ step: "admin/rotate-token" });
      return sendJson(res, 200, { ok: true, note: "token 已轮换，所有手机需要重新配对" });
    }

    throw new HttpError(404, "not-found", `管理接口不存在: ${method} ${pathname}`);
  }

  async function handle(req, res) {
    const url = new URL(req.url || "/", `http://${req.headers.host || "127.0.0.1"}`);
    const pathname = url.pathname;
    const method = (req.method || "GET").toUpperCase();

    if (closed) throw new HttpError(503, "closed", "bridge 已关闭");

    // 0) 管理接口：只允许本机回环访问（手机/局域网一律拒绝），免 token 但受来源限制
    if (pathname.startsWith("/admin/")) {
      const remote = String(req.socket?.remoteAddress || "");
      const loopback =
        remote === "127.0.0.1" ||
        remote === "::1" ||
        remote === "::ffff:127.0.0.1";
      if (!loopback) throw new HttpError(403, "forbidden", "管理接口只允许在本机访问");
      return handleAdmin(req, res, url, method, pathname);
    }

    // 1) 健康检查：明文、无鉴权，只暴露最小事实
    if (pathname === "/v1/health") {
      // 诊断通道：App 把点击瞬间的滚动状态塞在 ?d= 里，会进 bridge.log 供排查
      const diag = url.searchParams.get("d");
      if (diag) logLine({ step: "diag", d: diag });
      return sendJson(res, 200, {
        ok: true,
        version: VERSION,
        bridge: name,
        e2eeRequired: cfg.requireE2ee,
        phoneOnline: phoneOnline(),
        lastSeq: frames.lastSeq,
        sessions: (await listSessions()).length,
      });
    }

    // 2) 握手：明文，但需要 token
    if (pathname === "/v1/handshake") {
      const token = req.headers["x-dsh-token"] || "";
      if (!safeEqual(token, pair.token)) throw new HttpError(401, "unauthorized", "token 无效");
      const raw = await readBody(req, 64 * 1024);
      let body;
      try {
        body = JSON.parse(raw.toString("utf8") || "{}");
      } catch {
        throw new HttpError(400, "bad-json", "请求体不是 JSON");
      }
      const clientPub = String(body.clientPub || "");
      if (!clientPub) throw new HttpError(400, "bad-request", "缺少 clientPub");
      const keys = deriveSessionKeys(pair.privPem, clientPub, pair.token);
      const clientFingerprint = createHash("sha256")
        .update(Buffer.from(clientPub, "base64"))
        .digest("base64url");
      const registration = registerClient(
        clientFingerprint,
        String(body.clientName || "iphone"),
        8,
        getAutoApprove(),
      );

      // 设备闸门：没批准过的设备一律拦在握手这一步，连 e2ee 都不建立
      if (registration.status === "blocked") {
        logLine({ step: "handshake", device: clientFingerprint.slice(0, 12), denied: "blocked" });
        throw new HttpError(403, "device-blocked", "该设备已被这台电脑拉黑");
      }
      if (registration.status !== "approved") {
        logLine({ step: "handshake", device: clientFingerprint.slice(0, 12), denied: "pending" });
        throw new HttpError(
          403,
          "device-pending",
          "这台电脑还没批准该设备。请在 DeepSeek Harness 的「设置 → 手机设备」里点允许。",
        );
      }

      // clientId 必须是**确定性**的：同一台手机（同一公钥）每次握手拿到同一个 id。
      // 以前用 randomUUID()，每次握手都塞一条新记录，超过上限就把最早的那条（往往是
      // 手机自己）挤掉 —— 于是手机后续请求全变 401 handshake-required。这是必崩的设计。
      const clientId = createHash("sha256")
        .update(`dsh-phone-bridge|${clientFingerprint}|${pair.token}`)
        .digest("base64url")
        .slice(0, 32);

      e2ee.set(clientId, {
        c2s: keys.c2s,
        s2c: keys.s2c,
        createdAt: Date.now(),
        lastSeen: Date.now(),
        name: String(body.clientName || "iphone").slice(0, 40),
      });
      // 上限 32 且按 lastSeen 淘汰：确定性 id 之后这里基本只会有一条（每台设备一条）
      if (e2ee.size > 32) {
        const oldest = [...e2ee.entries()].sort((a, b) => a[1].lastSeen - b[1].lastSeen)[0];
        if (oldest) e2ee.delete(oldest[0]);
      }
      return sendJson(res, 200, {
        ok: true,
        v: 1,
        clientId,
        serverPub: pair.pubRaw,
        fingerprint: pair.fingerprint,
        client: registration.known ? "known" : "new",
        knownClients: registration.count,
        serverName: `${process.platform}/${process.arch}`,
      });
    }

    // 3) 其余端点：token 必填
    const token = tokenOf(req, url);
    if (!safeEqual(token, pair.token)) throw new HttpError(401, "unauthorized", "token 无效");

    // 4) SSE：不走加密封包（每帧单独加密），因此放在 E2EE 强制检查之前
    if (method === "GET" && pathname === "/v1/stream") {
      return openStream(req, res, url);
    }

    // 5) 解密路径
    const sealed = req.headers["x-sealed"] === "1";
    const aad = aadFor(method, pathname, url.searchParams);
    let ctxEnc = null;
    if (sealed) {
      const clientId = String(req.headers["x-client"] || "");
      const keys = e2ee.get(clientId);
      if (!keys) throw new HttpError(401, "handshake-required", "请先调用 /v1/handshake");
      keys.lastSeen = Date.now();
      ctxEnc = { sealed: true, c2s: keys.c2s, s2c: keys.s2c, aad };
      res.__enc = ctxEnc;
    } else if (cfg.requireE2ee && !PUBLIC_PATHS.has(pathname)) {
      throw new HttpError(401, "e2ee-required", "该端点只接受端到端加密的请求");
    }

    async function readJsonBody() {
      const raw = await readBody(req);
      if (!raw.length) return {};
      const plain = ctxEnc ? unseal(ctxEnc.c2s, aad, raw) : raw;
      try {
        return JSON.parse(plain.toString("utf8") || "{}");
      } catch {
        throw new HttpError(400, "bad-json", "请求体不是 JSON");
      }
    }

    // 5) 路由
    if (method === "GET" && pathname === "/v1/state") {
      const sessions = await listSessions();
      return sendJson(res, 200, {
        ok: true,
        version: VERSION,
        platform: process.platform,
        sessions,
        pending: {
          approvals: [...approvals.values()].map(({ id, tool, reason, since }) => ({ id, tool, reason, since })),
          questions: [],
        },
        notify: { enabled: notifier.enabled, kind: notifier.kind },
        roots: safeFs.allowedRoots(),
        lastSeq: frames.lastSeq,
      }, ctxEnc);
    }

    if (method === "GET" && pathname === "/v1/sessions") {
      // ?archived=1 只返回已归档；不带则返回未归档的（和电脑端列表一致）
      const wantArchived = url.searchParams.get("archived") === "1";
      let archivedIds = [];
      try {
        const registry = ctx.get?.("workspaceRegistry");
        if (registry && Array.isArray(registry.archivedSessionIds)) {
          archivedIds = registry.archivedSessionIds;
        }
      } catch {
        /* 拿不到就当没有归档 */
      }
      const archivedSet = new Set(archivedIds.map(String));
      const all = await listSessions();
      const rows = all
        .map((row) => ({ ...row, archived: archivedSet.has(row.id) }))
        .filter((row) => (wantArchived ? row.archived : !row.archived));
      return sendJson(res, 200, {
        ok: true,
        sessions: rows,
        archivedTotal: archivedSet.size,
      }, ctxEnc);
    }

    // 会话历史：把一条会话的事件流重新归一化成手机帧，打开会话时用它回填
    if (method === "GET" && pathname === "/v1/transcript") {
      const sessionId = url.searchParams.get("sessionId") || "";
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit")) || 400, 1), 2000);
      if (!sessionId) throw new HttpError(400, "bad-request", "需要 sessionId");
      const session = ctx.get?.("sessions")?.get?.(sessionId);

      // 热会话走事件流；冷会话（没加载进 store）直接从磁盘日志重建，
      // 否则列表里 45 个会话点进去全是空的。
      if (!session) {
        const fromLog = framesFromLog(sessionId);
        if (fromLog) {
          return sendJson(res, 200, {
            ok: true,
            sessionId,
            source: "log",
            total: fromLog.length,
            frames: fromLog.slice(-limit),
          }, ctxEnc);
        }
        return sendJson(res, 200, {
          ok: true,
          sessionId,
          source: "none",
          frames: [],
          note: "冷会话且找不到日志文件",
        }, ctxEnc);
      }

      let events = [];
      try {
        events = typeof session.snapshotEvents === "function" ? session.snapshotEvents() : [];
      } catch (error) {
        logLine({ step: "transcript", sessionId, error: String(error?.message || error).slice(0, 200) });
      }
      const frames = [];
      for (const event of events) {
        for (const frame of normalizeEvent(session, event)) {
          frames.push(frame);
        }
      }
      return sendJson(res, 200, {
        ok: true,
        sessionId,
        eventCount: events.length,
        total: frames.length,
        frames: frames.slice(-limit),
      }, ctxEnc);
    }

    // ComfyUI 在线/生图状态
    if (method === "GET" && pathname === "/v1/comfy") {
      const status = await comfyStatus();
      return sendJson(res, 200, { ok: true, ...status, at: Date.now() }, ctxEnc);
    }

    // 可用模型列表（附当前会话的选择）
    // 账户余额：走 DSH 自带的 accountController，不碰 API key
    if (method === "GET" && pathname === "/v1/balance") {
      const account = ctx.get?.("accountController") || ctx.accountController;
      if (!account || typeof account.getBalance !== "function") {
        return sendJson(res, 200, { ok: false, status: "unavailable", wallets: [], bonuses: [] }, ctxEnc);
      }
      try {
        const result = await account.getBalance();
        // 返回形如 null | { status:"ready", value:[{currency,balance}], bonusWallets:[...] } | { status:"failed" }
        if (!result || result.status !== "ready") {
          return sendJson(res, 200, {
            ok: false,
            status: result?.status || "unavailable",
            wallets: [],
            bonuses: [],
          }, ctxEnc);
        }
        const normalize = (list) =>
          (Array.isArray(list) ? list : [])
            .map((item) => ({
              currency: String(item?.currency || ""),
              balance: String(item?.balance ?? ""),
            }))
            .filter((item) => item.currency);
        return sendJson(res, 200, {
          ok: true,
          status: "ready",
          wallets: normalize(result.value),
          bonuses: normalize(result.bonusWallets),
        }, ctxEnc);
      } catch (error) {
        const message = String(error?.message || error);
        // 探测：getBalance 内部失败时，把栈和 account 对象的形状记下来。
        // 当前症状：报 "Cannot read properties of undefined (reading 'version')"，
        // 但用户在电脑上是登录状态 —— 说明它不是「没登录」，而是某个 client 没初始化。
        try {
          logLine({
            step: "balance.error",
            error: message.slice(0, 240),
            stack: String(error?.stack || "").split("\n").slice(0, 4).join(" | ").slice(0, 400),
            accountKeys: (() => {
              try { return Object.keys(account || {}).slice(0, 24); } catch { return ["<无法枚举>"]; }
            })(),
            accountProto: (() => {
              try {
                return Object.getOwnPropertyNames(Object.getPrototypeOf(account) || {}).slice(0, 24);
              } catch { return ["<无原型>"]; }
            })(),
          });
        } catch { /* 探测失败不影响兜底 */ }
        // getBalance 挂在 platformClientHeaders 上失败（要读某个 client 的 version），
        // 但 account 还暴露了 getState / getProfile —— 它们可能直接给出登录态，
        // 也许余额该从那儿拿，而不是 getBalance。
        try {
          const state = await account.getState();
          logLine({
            step: "balance.state",
            keys: state && typeof state === "object" ? Object.keys(state).slice(0, 24) : [],
            state: JSON.stringify(state).slice(0, 900),
          });
        } catch (e2) {
          logLine({ step: "balance.state/failed", error: String(e2?.message || e2).slice(0, 200) });
        }
        try {
          const profile = await account.getProfile();
          logLine({
            step: "balance.profile",
            keys: profile && typeof profile === "object" ? Object.keys(profile).slice(0, 24) : [],
            profile: JSON.stringify(profile).slice(0, 700),
          });
        } catch (e3) {
          logLine({ step: "balance.profile/failed", error: String(e3?.message || e3).slice(0, 200) });
        }

        logLine({ step: "balance", error: message.slice(0, 200) });
        // getBalance 内部会读账号客户端的状态；它没初始化时就是这类
        // "Cannot read properties of undefined (reading 'version')"，
        // 通常意味着电脑上的 DSH 还没登录 DeepSeek 账号。
        // 用 getState() 兜底：它不依赖那个没初始化的 client，能给出
        //   status: "credential-stored"（说明凭据在、已登录）
        //   links:  { usageUrl, topUpUrl }
        // 之前这里一律判成 not-signed-in，于是手机上显示「电脑上的 DSH 还没登录」——
        // 是误报（用户明明登录着）。
        let stateStatus = "";
        let links = {};
        try {
          const st = await account.getState();
          stateStatus = String(st?.status || "");
          links = (st && typeof st.links === "object" && st.links) || {};
        } catch { /* 拿不到就退回旧判断 */ }

        const signedOut = !stateStatus && /version|undefined|null/i.test(message);
        return sendJson(res, 200, {
          ok: false,
          status: stateStatus || (signedOut ? "not-signed-in" : "failed"),
          detail: message.slice(0, 160),
          links,
          wallets: [],
          bonuses: [],
        }, ctxEnc);
      }
    }

    if (method === "GET" && pathname === "/v1/models") {
      const catalog = await modelCatalog();
      const sessionId = url.searchParams.get("sessionId") || "";
      const current = sessionId ? currentSelection(sessionId) : null;
      return sendJson(res, 200, { ok: true, ...catalog, current }, ctxEnc);
    }

    // 标题读取链路诊断：查为什么某个会话显示的是 id 而不是标题
    if (method === "GET" && pathname === "/v1/debug/title") {
      const sessionId = url.searchParams.get("sessionId") || "";
      if (!sessionId) {
        const rows = await listSessions();
        return sendJson(res, 200, {
          ok: true,
          hint: "带上 ?sessionId=xxx 看单个会话的诊断",
          sessions: rows.slice(0, 10).map((row) => ({ id: row.id, title: row.title })),
        }, ctxEnc);
      }
      return sendJson(res, 200, { ok: true, report: titleDiagnostics(sessionId) }, ctxEnc);
    }

    // 切换某个会话的模型
    if (method === "POST" && pathname === "/v1/session/model") {
      const body = await readJsonBody();
      const ctrl = sessionController || ctx.sessionController;
      if (!ctrl) throw new HttpError(503, "not-ready", "sessionController 尚未就绪");
      const sessionId = String(body.sessionId || "");
      const provider = String(body.provider || "");
      const model = String(body.model || "");
      if (!sessionId || !provider || !model) {
        throw new HttpError(400, "bad-request", "需要 sessionId、provider、model");
      }
      try {
        const result = await ctrl.selectModel(
          {
            sessionId,
            provider,
            model,
            ...(body.reasoningEffort ? { reasoningEffort: String(body.reasoningEffort) } : {}),
          },
          AbortSignal.timeout(20000),
        );
        logLine({ step: "session/model", sessionId, provider, model });
        return sendJson(res, 200, { ok: true, sessionId, provider, model, result: result ?? null }, ctxEnc);
      } catch (error) {
        logLine({ step: "session/model", sessionId, error: String(error?.message || error).slice(0, 300) });
        throw error;
      }
    }

    if (method === "POST" && pathname === "/v1/task") {
      const body = await readJsonBody();
      const text = String(body.text || "").trim();
      if (!text) throw new HttpError(400, "bad-request", "缺少 text");
      const ctrl = sessionController || ctx.sessionController;
      if (!ctrl) throw new HttpError(503, "not-ready", "sessionController 尚未就绪，稍等几秒重试");

      let sessionId = typeof body.sessionId === "string" && body.sessionId ? body.sessionId : null;
      let created = false;
      if (!sessionId) {
        try {
          const made = await ctrl.create({});
          sessionId = String(made?.sessionId || "");
        } catch (error) {
          logLine({ step: "create", error: String(error?.message || error).slice(0, 400) });
          throw error;
        }
        if (!sessionId) throw new HttpError(500, "create-failed", "新建会话失败");
        created = true;
      }
      const requestId = String(body.requestId || randomUUID());
      // 注意：ctx.sessionController 是 Typert Remote 门面，签名是 prompt(request, signal)。
      // 第二参数必须是 AbortSignal（内部会调 signal.throwIfAborted()），
      // source 由门面自己构造（{kind:"user", rpcId:request.requestId}），不能自己传。
      logLine({ step: "task", sessionId, created, textLen: text.length, requestId });
      let result;
      try {
        result = await ctrl.prompt(
          {
            sessionId,
            content: [{ type: "text", text }],
            requestId,
            ...(body.mode === "steer" ? { mode: "steer" } : {}),
          },
          AbortSignal.timeout(cfg.approvalTimeoutMs * 4),
        );
      } catch (error) {
        logLine({
          step: "prompt",
          sessionId,
          error: String(error?.message || error).slice(0, 400),
          code: error?.code ?? null,
        });
        throw error;
      }

      // 诊断：把 DSH 的 prompt 返回值**完整**记一条。
      // 目的是确认「排队」时到底有没有队列信息（queued / position / pending…）。
      // 手机端现在只能知道 accepted，拿不到排队状态，这是排队功能的第一块拼图。
      try {
        logLine({
          step: "task.result",
          sessionId,
          mode: body.mode || "queue",
          keys: result && typeof result === "object" ? Object.keys(result) : [],
          result: JSON.stringify(result).slice(0, 1200),
        });
      } catch { /* 记日志失败不影响主流程 */ }

      // 探索：队列到底存在哪？
      // task.result 只有 accepted，手机端拿不到「排在队列第几」「队列里有什么」。
      // 这里把 sessionController 与 session 对象上和队列相关的键、以及同名下标的值
      // 都 dump 到日志，用来确定「排队转插队 / 显示排队内容」该调哪个接口。
      // 纯只读探测，不改任何状态。
      try {
        const probe = { step: "queue.probe", sessionId, mode: body.mode || "queue" };
        const ctrlKeys = [];
        try { ctrlKeys.push(...Object.keys(ctrl)); } catch {}
        if (!ctrlKeys.length) {
          try { ctrlKeys.push(...Object.getOwnPropertyNames(Object.getPrototypeOf(ctrl))); } catch {}
        }
        probe.ctrlKeys = ctrlKeys.filter((k) => !k.startsWith("_")).slice(0, 80);
        probe.queueMethods = probe.ctrlKeys.filter((k) => /queue|pending|list|status|message|prompt/i.test(k));

        const sessions = (() => { try { return ctx.get?.("sessions"); } catch { return null; } })();
        const session = (() => { try { return sessions?.get?.(sessionId); } catch { return null; } })();
        if (session) {
          probe.sessionKeys = Object.keys(session).slice(0, 80);
          probe.queueLike = {};
          for (const k of probe.sessionKeys) {
            if (!/queue|pending|prompt|turn|busy|running|message|state/i.test(k)) continue;
            try {
              const v = session[k];
              if (typeof v === "function") { probe.queueLike[k] = "<fn>"; continue; }
              if (v && typeof v === "object") {
                const s = JSON.stringify(v);
                probe.queueLike[k] = String(s).slice(0, 600);
              } else {
                probe.queueLike[k] = String(v).slice(0, 200);
              }
            } catch { probe.queueLike[k] = "<err>"; }
          }
        }
        // 第二层：把可疑对象的形状挖出来
        // 第一轮已知：ctrl 上没有 queue/pending 方法，session 上也没有 queue 字段。
        // 候选集中在 controlState / listState / derived / derivedNodes / eventsSnapshot。
        const describe = (v) => {
          if (v === null || v === undefined) return "null";
          if (typeof v === "function") return "<fn>";
          if (typeof v !== "object") return String(v).slice(0, 120);
          if (Array.isArray(v)) {
            const head = v.length ? JSON.stringify(v[0]).slice(0, 200) : "";
            return `Array(${v.length})` + (head ? " first=" + head : "");
          }
          const keys = Object.keys(v).slice(0, 24);
          const out = { keys };
          for (const k of keys) {
            if (!/queue|pending|list|item|message|task|busy|run/i.test(k)) continue;
            try { out[k] = JSON.stringify(v[k]).slice(0, 300); } catch { out[k] = "<err>"; }
          }
          return out;
        };

        // typertRemote 是「远程调用门面」，可能是唯一能发起 splice 的入口
        try {
          const tr = ctrl.typertRemote;
          const own = tr ? Object.keys(tr).slice(0, 40) : [];
          let proto = [];
          try {
            proto = tr ? Object.getOwnPropertyNames(Object.getPrototypeOf(tr) || {}).slice(0, 40) : [];
          } catch { /* ignore */ }
          probe.typertRemote = { own, proto };
          // typertRemote 只是 { service, serviceKey, namespace } 的包装，
          // 真正的调用入口应该在 service 上。这是最后一次探测：
          // 如果 service 也没有 splice / inbox 之类的方法，就说明 DSH
          // 没把队列写操作暴露给外部，手机的编辑/删除/插队只能停在「读」。
          try {
            const svc = tr && tr.service;
            probe.typertService = {
              type: typeof svc,
              serviceKey: String((tr && tr.serviceKey) || ""),
              namespace: String((tr && tr.namespace) || ""),
              keys: svc && typeof svc === "object" ? Object.keys(svc).slice(0, 40) : [],
              proto: (() => {
                try { return Object.getOwnPropertyNames(Object.getPrototypeOf(svc) || {}).slice(0, 40); }
                catch { return []; }
              })(),
              str: typeof svc === "string" || typeof svc === "number" ? String(svc) : "",
            };
          } catch (e) {
            probe.typertService = { error: String(e?.message || e).slice(0, 120) };
          }
        } catch (e) {
          probe.typertRemote = { error: String(e?.message || e).slice(0, 120) };
        }

        probe.deep = {};
        for (const key of ["controlState", "listState", "history", "commands", "agents"]) {
          try { probe.deep["ctrl." + key] = describe(ctrl[key]); } catch (e) { probe.deep["ctrl." + key] = "<err>"; }
        }
        if (session) {
          for (const key of ["derived", "derivedNodes", "eventsSnapshot", "header", "log"]) {
            try { probe.deep["session." + key] = describe(session[key]); } catch (e) { probe.deep["session." + key] = "<err>"; }
          }
        }

        // 第三层：队列信息是否藏在事件日志里
        // 前两轮确认：控制器上没有队列接口，session 上也没有 queue 字段。
        // session.log 有近万条事件 —— 排队的痕迹最可能在这里（比如 xxx/queued）。
        try {
          const log = session?.log;
          if (Array.isArray(log)) {
            const types = {};
            for (const e of log) {
              const t = String(e?.type || "?");
              types[t] = (types[t] || 0) + 1;
            }
            probe.logTypes = Object.entries(types)
              .sort((a, b) => b[1] - a[1])
              .slice(0, 40);
            probe.queueishTop = probe.logTypes.filter(([t]) => /queue|pending|wait|enqueue|steer/i.test(t));
          }
          probe.streamsShape = describe(ctrl?.controlState?.streams);
        } catch (e) {
          probe.logProbeError = String(e?.message || e).slice(0, 160);
        }

        logLine(probe);
      } catch (e) {
        logLine({ step: "queue.probe/failed", error: String(e?.message || e).slice(0, 200) });
      }

      return sendJson(res, 200, {
        ok: true,
        sessionId,
        created,
        requestId,
        accepted: result?.accepted !== false,
      }, ctxEnc);
    }

    if (method === "POST" && pathname === "/v1/approval") {
      const body = await readJsonBody();
      const id = String(body.id || "");
      const pending = approvals.get(id);
      if (!pending) throw new HttpError(404, "not-found", "该审批已过期或不存在");
      const decision = body.decision === "deny" ? "deny" : "allow";
      pending.decide(decision);
      return sendJson(res, 200, { ok: true, id, decision }, ctxEnc);
    }

    if (method === "POST" && pathname === "/v1/answer") {
      const body = await readJsonBody();
      const ctrl = sessionController || ctx.sessionController;
      if (!ctrl) throw new HttpError(503, "not-ready", "sessionController 尚未就绪");
      const sessionId = String(body.sessionId || "");
      const text = String(body.text || "").trim();
      if (!sessionId || !text) throw new HttpError(400, "bad-request", "需要 sessionId 与 text");
      const requestId = String(body.requestId || randomUUID());
      const result = await ctrl.prompt(
        { sessionId, content: [{ type: "text", text }], requestId },
        AbortSignal.timeout(cfg.approvalTimeoutMs * 4),
      );
      return sendJson(res, 200, { ok: true, sessionId, requestId, accepted: result?.accepted !== false, bestEffort: true }, ctxEnc);
    }

    if (method === "POST" && pathname === "/v1/cancel") {
      const body = await readJsonBody();
      const ctrl = sessionController || ctx.sessionController;
      const sessionId = String(body.sessionId || "");
      if (!ctrl || !sessionId) throw new HttpError(400, "bad-request", "需要 sessionId");
      await ctrl.cancel({ sessionId });
      return sendJson(res, 200, { ok: true, sessionId }, ctxEnc);
    }

    // ── 会话管理：新建 / 改名 / 归档 ─────────────────────────────────────────
    if (method === "POST" && pathname === "/v1/session/new") {
      const body = await readJsonBody();
      const ctrl = sessionController || ctx.sessionController;
      if (!ctrl) throw new HttpError(503, "not-ready", "sessionController 尚未就绪");
      const made = await ctrl.create(body.cwd ? { cwd: String(body.cwd) } : {});
      const sessionId = String(made?.sessionId || "");
      if (!sessionId) throw new HttpError(500, "create-failed", "新建会话失败");
      logLine({ step: "session/new", sessionId });
      return sendJson(res, 200, { ok: true, sessionId }, ctxEnc);
    }

    if (method === "POST" && pathname === "/v1/session/rename") {
      const body = await readJsonBody();
      const ctrl = sessionController || ctx.sessionController;
      const sessionId = String(body.sessionId || "");
      const title = String(body.title || "").trim();
      if (!ctrl || !sessionId || !title) throw new HttpError(400, "bad-request", "需要 sessionId 与 title");
      try {
        const result = await ctrl.rename({ sessionId, title });
        logLine({ step: "session/rename", sessionId, title });
        return sendJson(res, 200, { ok: true, sessionId, title: result?.title ?? title }, ctxEnc);
      } catch (error) {
        logLine({ step: "session/rename", sessionId, error: String(error?.message || error).slice(0, 300) });
        throw error;
      }
    }

    if (method === "POST" && pathname === "/v1/session/archive") {
      const body = await readJsonBody();
      const registry = workspaceRegistry || ctx.workspaceRegistry;
      const sessionId = String(body.sessionId || "");
      const wantArchived = body.archived !== false;
      if (!registry || !sessionId) throw new HttpError(400, "bad-request", "需要 sessionId（且 workspaceRegistry 可用）");
      try {
        if (wantArchived) await registry.archiveSession(sessionId);
        else await registry.unarchiveSession(sessionId);
        logLine({ step: "session/archive", sessionId, archived: wantArchived });
        return sendJson(res, 200, { ok: true, sessionId, archived: wantArchived }, ctxEnc);
      } catch (error) {
        logLine({ step: "session/archive", sessionId, error: String(error?.message || error).slice(0, 300) });
        throw error;
      }
    }

    if (method === "GET" && pathname === "/v1/fs/list") {
      const target = url.searchParams.get("path") || safeFs.allowedRoots()[0];
      return sendJson(res, 200, { ok: true, ...(await safeFs.list(target)) }, ctxEnc);
    }

    if (method === "GET" && pathname === "/v1/fs/stat") {
      const target = url.searchParams.get("path") || "";
      return sendJson(res, 200, { ok: true, ...(await safeFs.stat(target)) }, ctxEnc);
    }

    if (method === "GET" && pathname === "/v1/fs/read") {
      const target = url.searchParams.get("path") || "";
      const offset = Number(url.searchParams.get("offset")) || 0;
      const limit = Number(url.searchParams.get("limit")) || MAX_FILE_CHUNK;

      // preview=1：电脑侧先压好再传。
      // 图片用 Pillow 缩到 2048；视频用 ffmpeg 抽封面（mode=poster）或压成 720p 预览。
      // 手机只为「看一眼确认」，原件始终在电脑上。
      if (url.searchParams.get("preview") === "1" && offset === 0) {
        const mode = url.searchParams.get("mode") || "auto";
        const preview = await imagePreview(target, { mode, maxPixel: Number(url.searchParams.get("w")) || undefined });
        if (preview) {
          return sendBinary(res, 200, preview.buffer, ctxEnc, {
            "x-file-size": String(preview.buffer.length),
            "x-chunk-offset": "0",
            "x-chunk-eof": "1",
            "x-preview": "1",
          });
        }
      }

      const file = await safeFs.read(target, { offset, limit });
      return sendBinary(res, 200, file.buffer, ctxEnc, {
        "x-file-size": String(file.size),
        "x-chunk-offset": String(file.offset),
        "x-chunk-eof": file.eof ? "1" : "0",
      });
    }

    if (method === "POST" && pathname === "/v1/fs/write") {
      const target = url.searchParams.get("path") || "";
      const offset = Number(url.searchParams.get("offset")) || 0;
      const truncate = url.searchParams.get("truncate") === "1";
      const raw = await readBody(req, cfg.maxFileBytes + 1024);
      const plain = ctxEnc ? unseal(ctxEnc.c2s, aad, raw) : raw;
      const result = await safeFs.write(target, { offset, truncate }, plain);
      return sendJson(res, 200, { ok: true, ...result }, ctxEnc);
    }

    // 新建目录（多级）
    if (method === "POST" && pathname === "/v1/fs/mkdir") {
      const target = url.searchParams.get("path") || "";
      if (!target) throw new HttpError(400, "bad-request", "缺少 path");
      const result = await safeFs.mkdir(target);
      logLine({ step: "fs/mkdir", path: result.path });
      return sendJson(res, 200, { ok: true, ...result }, ctxEnc);
    }

    // 删除文件 / 空目录（recursive=1 才允许删非空目录）
    if (method === "POST" && pathname === "/v1/fs/delete") {
      const target = url.searchParams.get("path") || "";
      if (!target) throw new HttpError(400, "bad-request", "缺少 path");
      const recursive = url.searchParams.get("recursive") === "1";
      const result = await safeFs.remove(target, { recursive });
      logLine({ step: "fs/delete", path: result.path, dir: result.dir, recursive });
      return sendJson(res, 200, { ok: true, ...result }, ctxEnc);
    }

    if (method === "POST" && pathname === "/v1/admin/rotate-token") {
      const next = rotateToken();
      pair.token = next;
      e2ee.clear();
      for (const client of streamClients) {
        try {
          client.res.end();
        } catch {
          /* 忽略 */
        }
      }
      streamClients.clear();
      return sendJson(res, 200, { ok: true, note: "旧 token 已失效，需重新配对" }, ctxEnc);
    }

    if (method === "POST" && pathname === "/v1/admin/unpair") {
      const removed = clearClients();
      e2ee.clear();
      return sendJson(res, 200, { ok: true, removed, note: "设备名单已清空；token 与服务器密钥未变" }, ctxEnc);
    }

    if (method === "GET" && pathname === "/v1/admin/clients") {
      return sendJson(res, 200, { ok: true, clients: listClients() }, ctxEnc);
    }

    throw new HttpError(404, "not-found", `没有该端点: ${method} ${pathname}`);
  }

  // ── 启动 ────────────────────────────────────────────────────────────────────

  // 一份 handler，两个监听口共用：手机走内网地址，不能让它绕开日志与错误处理
  function makeHandler(tag) {
    return (req, res) => {
      const startedAt = Date.now();
      const route = String(req.url || "").split("?")[0];
      res.on("finish", () => {
        logLine({ if: tag, m: req.method, p: route, s: res.statusCode, ms: Date.now() - startedAt });
      });
      handle(req, res).catch((error) => {
        logLine({
          if: tag,
          m: req.method,
          p: route,
          err: String(error?.code || error?.name || "error"),
          msg: String(error?.message || error).slice(0, 400),
        });
        if (error instanceof SyntaxError) jsonError(res, new HttpError(400, "bad-request", error.message));
        else jsonError(res, error);
      });
    };
  }

  server = http.createServer(makeHandler("loopback"));

  server.on("clientError", (error, socket) => {
    try {
      socket?.end?.("HTTP/1.1 400 Bad Request\r\n\r\n");
    } catch {
      /* 忽略 */
    }
  });

  server.on("error", (error) => {
    console.error(`[phone-bridge] HTTP 错误: ${error?.message || error}`);
  });

  ctx.effect(() => () => {
    closed = true;
    for (const client of streamClients) {
      try {
        client.res.end();
      } catch {
        /* 忽略 */
      }
    }
    streamClients.clear();
    for (const pending of approvals.values()) pending.decide("passthrough");
    approvals.clear();
    if (server) {
      try {
        server.close();
      } catch {
        /* 忽略 */
      }
      server = null;
    }
    console.log("[phone-bridge] 已关闭");
  }, "phone-bridge.http");

  server.listen(cfg.port, "127.0.0.1", () => {
    const address = server.address();
    const actual = typeof address === "object" && address ? address.port : cfg.port;
    resolveReady({ port: actual, pair: { token: pair.token, fingerprint: pair.fingerprint } });
    console.log(`[phone-bridge] 监听 127.0.0.1:${actual}`);
    console.log(`[phone-bridge] 配对串: dshnb://pair?host=127.0.0.1&port=${actual}&token=${pair.token}&fp=${pair.fingerprint}`);
    console.log(`[phone-bridge] 状态目录: ${stateDir()}`);
    if (cfg.lanHost) {
      const lan = http.createServer(makeHandler("lan"));
      lan.listen(actual, cfg.lanHost, () => {
        console.log(`[phone-bridge] 局域网监听 ${cfg.lanHost}:${actual}（内容仍需 E2EE 解密）`);
      });
      lan.on("error", (error) => console.error(`[phone-bridge] 局域网监听失败: ${error?.message || error}`));
      ctx.effect(() => () => {
        try {
          lan.close();
        } catch {
          /* 忽略 */
        }
      }, "phone-bridge.lan");
    }
  });

  return {
    ready,
    stop: () =>
      new Promise((resolve) => {
        closed = true;
        if (!server) return resolve();
        server.close(() => resolve());
      }),
  };
}
