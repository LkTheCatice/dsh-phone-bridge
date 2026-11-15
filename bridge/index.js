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
// ComfyUI 自带的解释器（有它就用来读图片元信息）；没有就走 PATH 里的 python
const PYTHON_FALLBACK = process.env.DSH_PYTHON
  || (process.env.COMFYUI_HOME
    ? path.join(process.env.COMFYUI_HOME, "python_embeded", "python.exe")
    : "");

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
import { FrameBuffer, isDroppedEvent, normalizeEvent, sessionIdOf } from "./lib/events.js";
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
/**
 * 探测本机局域网 IPv4。
 *
 * 用途：`lanHost` 没配时自动挑一个，避免"换 WiFi 后手机连不上"。
 * 做法是 UDP "connect" 到公网地址：不真的发包，只让系统选出一条出口网卡，
 * 然后读 socket 的本地地址 —— 这是拿到"对外 IP"最省事且不依赖外部服务的办法。
 */
function detectLanIp() {
  /**
   * 用 os.networkInterfaces() 挑一个"像物理网卡"的 IPv4。
   *
   * 为什么不用 UDP connect：`dgram.connect` 是异步的，回调没到之前
   * `sock.address()` 还是 0.0.0.0 —— 第一次写就是这么踩的（探测永远返回空）。
   */
  try {
    const os = require("node:os");
    const all = os.networkInterfaces() || {};
    const skip = /(loopback|vmware|virtualbox|vethernet|hyper-v|docker|wsl|tap|tun|bluetooth)/i;
    const prefer = /(wi-?fi|wlan|以太网|ethernet|en0|eth)/i;
    const candidates = [];
    for (const [name, list] of Object.entries(all)) {
      if (!list || skip.test(name)) continue;
      for (const item of list) {
        if (!item || item.family !== "IPv4" || item.internal) continue;
        const ip = String(item.address || "");
        if (!ip || ip.startsWith("127.") || ip.startsWith("169.254.")) continue;
        candidates.push({ name, ip, preferred: prefer.test(name) ? 1 : 0 });
      }
    }
    if (!candidates.length) return "";
    candidates.sort((a, b) => b.preferred - a.preferred);
    return candidates[0].ip;
  } catch {
    return "";
  }
}

function detectWorkspaceRoots() {
  const out = [];
  try {
    const file = path.join(dshHome(), "storages", "workspace.json");
    const doc = readJson(file, null);
    const table = doc?.tables?.workspaces ?? {};
    out.push(
      ...Object.values(table)
        .map((ws) => (ws && typeof ws.path === "string" ? ws.path : null))
        .filter(Boolean),
    );
  } catch {
    /* 工作区表读不到就只靠下面的额外根 */
  }
  out.push(...detectExtraRoots());
  return out;
}

/**
 * 额外允许的根目录：**产物目录**。
 *
 * 起因：手机上打开 `📄 输出文件` 的图片（本地生成的图 /
 * 本地生成的文档）会报「读不到这张图（路径可能不在电脑允许的目录里）」——
 * 因为这些目录在 DSH 工作区之外，安全白名单里没有。
 *
 * 来源（按优先级）：
 *   1. 环境变量 DSH_PHONE_ROOTS：分号分隔，最灵活
 *   2. `~/.dsh/storages/phone-roots.json`：{ "roots": ["D:/x", ...] }
 *   3. （已移除：不再内置任何开发者本机目录）
 *
 * 仍然只加**具体目录**，不开盘符；realpath 校验照旧（符号链接逃逸照样失败）。
 */
function detectExtraRoots() {
  const candidates = [];

  const env = process.env.DSH_PHONE_ROOTS;
  if (env) {
    candidates.push(...String(env).split(path.delimiter === ";" ? ";" : ":"));
  }

  const json = readJson(path.join(dshHome(), "storages", "phone-roots.json"), null);
  if (json && Array.isArray(json.roots)) candidates.push(...json.roots.map(String));

  // 不再内置任何"某人的目录"：额外根只从上面两个来源来
  // （DSH_PHONE_ROOTS 环境变量 / ~/.dsh/storages/phone-roots.json）。

  const out = [];
  for (const raw of candidates) {
    const value = String(raw || "").trim();
    if (!value) continue;
    try {
      if (fs.existsSync(value)) out.push(value);
    } catch {
      /* 不存在就跳过 */
    }
  }
  return out;
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
  // 进程内诊断计数：给 /v1/diag 用（省得每次都翻几千行 bridge.log）
  const diagStats = {
    startedAt: Date.now(),
    frames: Object.create(null),   // frame.type -> count
    dropped: Object.create(null),  // 被过滤掉的 DSH 事件类型 -> count
    stalls: { count: 0, maxMs: 0, over1s: 0, last: [] },
    queue: { items: null, at: null, target: null },
  };
  /**
   * 把日志里出现的绝对路径压成「…/文件名」。
   *
   * 起因（隐私审计）：bridge.log 里会记下 `D:\...\某个目录\xxx.png` 这种完整路径，
   * 等于把用户的目录结构写进了一个明文日志文件。默认改成只留文件名，
   * 需要完整路径时设 DSH_PHONE_LOG_FULL=1。
   */
  const PATH_RE = /(?:[A-Za-z]:[\\/]|\\{2}[^\\s"']+[\\/])(?:[^\\s"'<>|*?\r\n]+[\\/])*([^\\s"'<>|*?\r\n\\/]+)/g;
  function redactPaths(value) {
    if (typeof value === "string") {
      return value.replace(PATH_RE, (_m, base) => (base ? "…/" + base : "…"));
    }
    if (Array.isArray(value)) return value.map(redactPaths);
    if (value && typeof value === "object") {
      const out = {};
      for (const [k, v] of Object.entries(value)) out[k] = redactPaths(v);
      return out;
    }
    return value;
  }

  function logLine(entry) {
    try {
      // 顺手把手机报上来的卡顿记进统计（logLine 里就有一行 STUCK …ms mark=…）
      const d = typeof entry?.d === "string" ? entry.d : "";
      if (d.startsWith("STUCK ")) {
        const ms = Number((d.match(/STUCK (\d+)ms/) || [])[1] || 0);
        diagStats.stalls.count += 1;
        diagStats.stalls.maxMs = Math.max(diagStats.stalls.maxMs, ms);
        if (ms > 1000) diagStats.stalls.over1s += 1;
        diagStats.stalls.last.push({ at: Date.now(), ms, mark: (d.match(/mark=(\S+)/) || [])[1] || "" });
        if (diagStats.stalls.last.length > 12) diagStats.stalls.last.shift();
      }
      if (!logPath) logPath = path.join(stateDir(), "bridge.log");
      fs.mkdirSync(path.dirname(logPath), { recursive: true });
      try {
        // 轮转而不是清空：以前一超过 2MB 就把整个文件抹掉，
        // 正好把要排查的那段一起弄丢了（用户实拍："日志突然空了"）。
        // 现在改成 bridge.log → bridge.log.1（只留一代，最多 2 × 2MB）。
        if (fs.statSync(logPath).size > 2 * 1024 * 1024) {
          try { fs.renameSync(logPath, logPath + ".1"); } catch { fs.writeFileSync(logPath, ""); }
        }
      } catch {
        /* 文件还不存在 */
      }
      // 脱敏：
      //   默认 —— 把绝对路径压成「…/文件名」，避免日志里带出你的目录结构
      //   LOG_MIN=1 —— 只留 at/step/错误码（更狠，丢掉路径与会话 id）
      //   LOG_FULL=1 —— 完全原样（自己排障时用）
      let payload = entry;
      if (process.env.DSH_PHONE_LOG_MIN === "1") {
        payload = { step: entry?.step, error: entry?.error, err: entry?.err };
      } else if (process.env.DSH_PHONE_LOG_FULL !== "1") {
        payload = redactPaths(entry);
      }
      fs.appendFileSync(logPath, JSON.stringify({ at: new Date().toISOString(), ...payload }) + "\n");
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
  const frames = new FrameBuffer(12000);
  const streamClients = new Set();
  const e2ee = new Map(); // clientId -> {c2s, s2c, createdAt, lastSeen, name}
  const approvals = new Map(); // id -> {tool, reason, since, decide}
  /**
   * 认证失败计数：来源 IP → { start, count }
   *
   * 升级（2026-11-14）：
   *   · 阈值分档：20 次 → 封 1 分钟；40 次 → 5 分钟；80 次 → 30 分钟
   *   · **跨重启保留**：写到 stateDir/authfails.json，避免"重启就清空"绕过
   */
  const authFails = new Map();
  const AUTH_FAIL_FILE = () => path.join(stateDir(), "authfails.json");
  const BAN_STEPS = [
    { count: 80, ms: 30 * 60 * 1000 },
    { count: 40, ms: 5 * 60 * 1000 },
    { count: 20, ms: 60 * 1000 },
  ];
  let authFailsLoaded = false;
  function loadAuthFails() {
    if (authFailsLoaded) return;
    authFailsLoaded = true;
    try {
      const doc = readJson(AUTH_FAIL_FILE(), null);
      if (doc && typeof doc === "object") {
        for (const [ip, row] of Object.entries(doc)) {
          if (!row || typeof row !== "object") continue;
          const start = Number(row.start) || 0;
          const count = Number(row.count) || 0;
          const bannedUntil = Number(row.bannedUntil) || 0;
          if (!count) continue;
          // 超过 24 小时没动静的直接丢掉（别把文件越写越大）
          if (Date.now() - Math.max(start, bannedUntil) > 24 * 60 * 60 * 1000) continue;
          authFails.set(ip, { start, count, bannedUntil });
        }
      }
    } catch {
      /* 读不到就当空表 */
    }
  }
  /** 读手机报上来的签名状态（没有就返回 null） */
  function readSigning() {
    try {
      return readJson(path.join(stateDir(), "signing.json"), null);
    } catch {
      return null;
    }
  }

  function saveAuthFails() {
    try {
      const doc = {};
      for (const [ip, row] of authFails) doc[ip] = row;
      fs.mkdirSync(stateDir(), { recursive: true });
      fs.writeFileSync(AUTH_FAIL_FILE(), JSON.stringify(doc), "utf8");
    } catch {
      /* 写失败不影响限速本身 */
    }
  }
  function noteAuthFail(req) {
    loadAuthFails();
    const src = String(req.socket?.remoteAddress || "-");
    const now = Date.now();
    const row = authFails.get(src);
    if (!row) {
      authFails.set(src, { start: now, count: 1, bannedUntil: 0 });
    } else {
      // 已经过了封禁期且距上次失败超过 10 分钟 → 重新计数
      const stale = now - row.start > 10 * 60 * 1000 && now > (row.bannedUntil || 0);
      if (stale) {
        authFails.set(src, { start: now, count: 1, bannedUntil: 0 });
      } else {
        row.count += 1;
        for (const step of BAN_STEPS) {
          if (row.count >= step.count) {
            row.bannedUntil = Math.max(row.bannedUntil || 0, now + step.ms);
            break;
          }
        }
      }
    }
    if (authFails.size > 200) {
      for (const [k, v] of authFails) {
        if (now - (v.start || 0) > 60 * 60 * 1000 && now > (v.bannedUntil || 0)) authFails.delete(k);
      }
    }
    saveAuthFails();
  }

  /** 转发去重：key = 目标会话|路径|说明 → 上次发送时间 */
  const recentForwards = new Map();
  const seenEvents = new WeakSet();

  let seq = 0;
  // 手机回答提问用的共享状态。
  // 注意：这里声明在 applyBridge 作用域，因为 HTTP 路由里也要用；
  // 下面的 ask 块里还会再声明一份同名变量用于本地逻辑，靠块作用域隔开。
  let askReadyUntil = 0;
  const ASK_READY_TTL_MS = 30_000;
  const pendingAsks = new Map(); // id -> { resolve, timer, sessionId }
  const ASK_TIMEOUT_MS = 100_000;
  let askSerial = 0;
    // ── 手机端回答「提问」（两边同时显示，谁先答谁生效） ────────────────
  //
  // DSH 的 ask_user_question 是**阻塞式**的，走一条 waterfall：
  //   ctx.waterfall("user-questions/request", request, noAnswerer)
  // 桌面端插件在这条链上注册了应答者，渲染面板、点完把 { answers } 返回来。
  //
  // 这里同时接两条路：
  //   · next()  → 交给桌面端（它照常弹面板）
  //   · 手机    → 推 ask.asked 给 App
  // 两个答案赛跑，谁先到谁生效；**输的那一侧立刻清掉**：
  //   · 桌面先答 → 广播 ask.cancelled，手机卡片消失
  //   · 手机先答 → 直接把答案 return，桌面面板由它自己收尾

  /// 建一个"等手机回答"的挂起项，返回 { id, promise, cancel }
  /// 尽力让桌面端把面板收起来。
  ///
  /// 桌面卡片只有在 `hasWaterfall()` 变成 false 后才会被 reconcile 移除。
  /// 带 timeout 的提问在宿主侧有一份 wait（`userQuestions.waits`），
  /// 把它 close 掉会 abort 掉前端那条 claim 流 —— 前端于是 detach waterfall，面板收起。
  ///
  /// 这是**内部字段**，DSH 换版本可能变；所以整段 try/catch + 留痕，
  /// 失败也不影响答案已经正确返回这件事。
  function closeDesktopPanel(agent, callId) {
    if (!agent || !callId) {
      // 没有 callId 说明这次提问不是 timed（没走 askTimed），
      // 宿主侧没有 wait 可关 —— 只能靠前端自己的倒计时。
      logLine({ step: "ask.desktop-close", ok: false, why: "not-timed", hasAgent: Boolean(agent), hasCallId: Boolean(callId) });
      return;
    }
    try {
      const uq = ctx.get?.("userQuestions") || ctx.userQuestions;
      const waits = uq?.waits;
      const calls = waits?.get?.(agent);
      const wait = calls?.get?.(callId);
      if (wait?.close) {
        wait.close(new Error("answered-on-phone"));
        logLine({ step: "ask.desktop-close", ok: true });
      } else {
        logLine({ step: "ask.desktop-close", ok: false, why: "no-wait" });
      }
    } catch (error) {
      logLine({ step: "ask.desktop-close", ok: false, why: String(error?.message || error) });
    }
  }
  // 最近一次见到手机的时刻（连上 / 上报 askReady 都算）。
  // 用途：手机在后台被挂起时 streamClients 会归零，但我们不该立刻放弃它 ——
  // 用户可能只是锁屏了，解锁后就要看到这张卡片。
  // 提问的分发策略。
  //
  // 为什么默认是 "auto"（单端）而不是两端同时弹：
  // 本机装的 ask_user_question 是 **legacy 模式**（dsh-tool-ask-user 的
  // config.mode 默认 legacy），它没有 timeout、没有 callId —— 于是
  //   · 桌面那张卡没有倒计时，不会自己消失
  //   · 宿主侧没有 wait 可关，桥也没法替它收尾
  // 结论：这种提问**只能有一个主人**。手机在线就手机答，手机不在才给电脑。
  //
  // 如果哪天把 tool-ask-user 切成 timed 模式（有 timeout / callId），
  // 就可以把这里改成 "dual"：两端同时显示，靠倒计时和 waits.close() 收尾。
  const askMode = String(config?.ask?.mode || config?.askMode || "auto").toLowerCase() === "dual"
    ? "dual"
    : "auto";
  // 提问的等待窗口（毫秒）。按"用户此刻有多可能回来看手机"分三档：
  //   · 手机在线且声明过能力   → 久等（默认 10 分钟）——人就在手机旁边
  //   · 手机不在线但配了推送   → 短等（默认 2 分钟）——推送会把人叫回来，等他开 App
  //   · 手机不在线也没推送     → 不等，立刻交给电脑（否则两端都看不到）
  const ASK_HOLD_ONLINE_MS = Number(config?.ask?.holdOnlineMs) || 600_000;
  const ASK_HOLD_PUSH_MS = Number(config?.ask?.holdPushMs) || 120_000;
  let lastPhoneSeen = 0;
  const PHONE_AROUND_MS = 15 * 60_000;
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
    // 帧类型分布（/v1/diag）：判断「少推了哪些帧」用
    const t = String(full.type || "?");
    diagStats.frames[t] = (diagStats.frames[t] || 0) + 1;
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
        // 关键探测：事件**外层**有哪些字段。
        // 队列属于 agent（agent/inbox/spliced），而 updateQueue 报
        // "reading 'kind'" —— 很可能是因为只传了 sessionId、缺 agentId。
        try {
          const outer = {};
          for (const k of Object.keys(event).slice(0, 24)) {
            if (k === "data") continue;
            const v = event[k];
            outer[k] = v && typeof v === "object" ? JSON.stringify(v).slice(0, 200) : String(v).slice(0, 120);
          }
          logLine({ step: "inbox.event", keys: Object.keys(event).slice(0, 24), outer });
        } catch { /* ignore */ }

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
        // 诊断：队列状态也记一份（/v1/diag 里能直接看到「现在排了几条」）
        diagStats.queue = { items: items.length, at: Date.now(), target: frame.target };
      } catch (e) {
        logLine({ step: "queue.changed/failed", error: String(e?.message || e).slice(0, 160) });
      }
    }
    if (seenEvents.has(event)) return;
    seenEvents.add(event);
    try {
      if (isDroppedEvent(event.type)) {
        // 手机端不渲染的事件：只记数，不产帧（/v1/diag 里能看到少了什么）
        diagStats.dropped[String(event.type)] = (diagStats.dropped[String(event.type)] || 0) + 1;
      } else {
        for (const frame of normalizeEvent(session, event)) broadcast(frame);
      }
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

  /// 通知桌面端：这次提问已经结算了，把卡片收起来。
  ///
  /// 走的是 DSH 的 Remote 事件通道（`phone-bridge/ask-settled`）。
  /// 需要在 DSH 里打一个小补丁才会生效 —— 见 tools/patch-dsh-ask.mjs：
  ///   · dsh-api-remotes     把这个事件加进转发白名单
  ///   · dsh-client-ui-*     收到事件后移除该会话的提问卡片
  /// 补丁没打也不会报错，只是前端收不到（面板只能等它自己超时）。
  function tellClientsAskSettled(sessionId) {
    if (!sessionId) return;
    try {
      if (typeof ctx.emit === "function") {
        ctx.emit("phone-bridge/ask-settled", { sessionId });
        logLine({ step: "ask.settle-emit", sessionId: String(sessionId).slice(-8) });
      }
    } catch (error) {
      logLine({ step: "ask.settle-emit", err: String(error?.message || error) });
    }
  }

  function createAskWaiter(request, timeoutMs = ASK_TIMEOUT_MS) {
    askSerial += 1;
    const id = "ask_" + askSerial;
    const sessionId = String(request?.agent?.session || "");
    const agent = request?.agent;
    const callId = String(request?.wait?.callId || "");
    let done = false;
    let finish = () => {};

    const promise = new Promise((resolve) => {
      finish = (value) => {
        if (done) return;
        done = true;
        const item = pendingAsks.get(id);
        if (item) {
          clearTimeout(item.timer);
          if (Array.isArray(item.nudge)) item.nudge.forEach(clearTimeout);
          else clearTimeout(item.nudge);
        }
        pendingAsks.delete(id);
        resolve(value);
      };
    });

    // 推送提醒：8 秒一次、之后每 60 秒再补一次（最多 3 次）。
    // 手机不长开时，靠这个把人叫回来；第一次没看到还有第二次。
    const nudge = notifier.enabled ? [] : undefined;
    if (nudge) {
      const first = (request?.questions || [])[0];
      [8_000, 60_000, 120_000].forEach((after, index) => {
        nudge.push(setTimeout(() => {
          if (!pendingAsks.has(id)) return;
          notifier.push({
            title: index === 0 ? "电脑在等你回答" : "还在等你的回答",
            body: String(first?.question || "有一个提问等你处理"),
            group: "DSH",
          }).catch(() => {});
          logLine({ step: "ask.push", id, round: index + 1 });
        }, after));
      });
    }

    // 超时的处理分两种，取决于这次提问有没有带 timeout：
    //  · 带了  → 到点后 DSH 会把它转成「continued」（迟到还能答），
    //            我们把这张卡片**留着**，改走 RPC 通道回答（会作为一条
    //            user-question-reply 消息进会话，桌面端卡片随之关闭）
    //  · 没带  → 只能由 waterfall 回答，到点就撤回提示、交回电脑
    const timer = setTimeout(() => {
      const item = pendingAsks.get(id);
      if (!item) return;
      if (callId) {
        item.mode = "rpc";
        broadcast({
          type: "ask.asked",   // 重推一次，让手机知道"还可以答，只是改成迟答"
          id,
          sessionId,
          callId,
          questions: item.questions,
          late: true,
        });
        logLine({ step: "ask.late-window", id });
        return;
      }
      broadcast({ type: "ask.cancelled", id, reason: "timeout" });
      finish(null);
    }, timeoutMs);

    pendingAsks.set(id, {
      resolve: (value) => finish(value),
      timer,
      nudge,
      sessionId,
      questions: request?.questions || [],
      agent,
      callId,
      mode: "waterfall",
    });

    broadcast({
      type: "ask.asked",
      id,
      sessionId,
      callId,
      questions: request?.questions || [],
    });

    return {
      id,
      promise,
      cancel(reason) {
        if (done) return;
        broadcast({ type: "ask.cancelled", id, reason: String(reason || "cancelled") });
        finish(null);
      },
    };
  }

  // ── 提问：**不再拦截**，只做"手机遥控桌面" ─────────────────────────
  //
  // 之前是桥接管 DSH 的提问 waterfall（等于自己当应答者），带来两个副作用：
  //   · 电脑端要么看不到、要么看到一张关不掉的卡
  //   · 桥得自己造等待窗口、超时、交回电脑一整套规则
  //
  // 现在改成：**DSH 的提问原样走它自己的通道，桌面端永远是主人**。
  // 手机端只是"镜像 + 遥控"：
  //   · 从 tool.call 帧里的 args.questions 还原出选项卡片（App 侧做）
  //   · 手机选了之后 → POST /v1/ask/submit → ctx.emit("phone-bridge/ask-submit")
  //   · 桌面端（打过补丁）收到事件后替用户按下提交 → 原生结算 → 两端一起收尾
  //
  // 于是这里不再注册应答者，只有一条"把手机的答案转发给桌面"的事件。
  logLine({ step: "ask.passthrough", note: "不拦截提问，桌面端持有，手机为镜像+遥控" });


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
    process.env.FFMPEG || "",
    // winget 装的默认位置
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

    // 解释器可能不存在（换了机器 / 没装 ComfyUI）：不存在就直接跳过压缩，
    // 让客户端拿原图，而不是让 spawn 报一个看不懂的错。
    const python = cfg.pythonPath || PYTHON_FALLBACK;
    if (!python || !fs.existsSync(python)) {
      logLine({ step: "preview.no-python", hint: "设置 config.pythonPath 或装 Pillow 才能压缩预览图" });
      return null;
    }
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
    if (!safeEqual(token, pair.token)) {
      noteAuthFail(req);
      throw new HttpError(401, "unauthorized", "token 无效");
    }

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

    // 续传游标：手机把 seq 存在本地（UserDefaults），**跨桥重启依然是旧值**。
    // 桥一重启 seq 从 1 重新数，于是 since=820 这种值永远大于 lastSeq →
    // frames.since(820) 返回空，等于「重启前那段全丢」。
    // 实测：11:17 重启后手机带 since=820 连上来，紧接着写的文件推不出提示。
    // 判断依据：since 比当前末尾还大，说明这个游标来自上一轮进程 —— 当作 0 处理，
    // 把缓冲区里现有的帧都补一遍（手机端按条目 id 去重，重复应用无害）。
    const rawSince = Number(url.searchParams.get("since")) || 0;
    let since = rawSince > frames.lastSeq ? 0 : rawSince;
    // 缺口检测：客户端游标比缓冲区最老帧还小 → 中间那段已经滚出缓冲，永久丢了。
    // 先发一条 stream.gap 让界面能明确提示"离线期间有帧未收到"，而不是静默少一段。
    const oldest = frames.oldestSeq;
    let gap = null;
    if (since > 0 && oldest > 0 && since < oldest - 1) {
      gap = { type: "stream.gap", from: since + 1, to: oldest - 1, lost: oldest - 1 - since };
      logLine({ step: "stream.gap", lost: gap.lost, since, oldest });
    }
    if (since !== rawSince) {
      logLine({ step: "stream.since-reset", asked: rawSince, lastSeq: frames.lastSeq });
    }
    if (gap) send({ ...gap, seq: frames.lastSeq });
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
    // ── /admin/* 的 CSRF 闸门 ────────────────────────────────────────────
    //
    // 背景（2026-11-14 安全自测）：这些端点只靠"来源是 loopback"来做边界，
    // 而浏览器里任何一个网页都能向 127.0.0.1:8765 发请求 ——
    // 加上响应头是 `access-control-allow-origin: *`，
    // 于是：页面能读到设备指纹，还能 POST /admin/settings 把 autoApprove 打开，
    // 或 POST /admin/devices/status 批准任意设备（实测可用）。
    //
    // 修法：要求一个**自定义请求头**。浏览器跨域发自定义头必须先过预检，
    // 而预检允许的 headers 里没有它 → 网页发不出来；本机插件不受影响。
    if (pathname.startsWith("/admin/") && req.headers["x-dsh-admin"] !== "1") {
      throw new HttpError(403, "admin-header-required", "缺少 x-dsh-admin 头（防跨站请求）");
    }

    // 自测：造一条审批请求，走真实 askPhone 的广播路径。
    // 放在 /admin 下：免 E2EE（本机脚本方便调用），仍受 loopback + x-dsh-admin 保护。
    if (method === "POST" && pathname === "/admin/dev/approval-sim") {
      if (!streamClients.size) throw new HttpError(409, "no-client", "手机还没连上");
      const raw = await readJsonBody().catch(() => ({}));
      const decision = await askPhone({
        callId: "sim-" + Date.now(),
        sessionId: String(raw.sessionId || ""),
        toolName: String(raw.tool || "write"),
        displayReason: String(raw.reason || "自测：模拟一次越界写操作"),
      });
      logLine({ step: "approval.sim", decision });
      return sendJson(res, 200, { ok: true, decision });
    }

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
          lanHost: effectiveLanHost,
        signing: readSigning(),
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

    // 0) 认证失败限速：同一来源 60 秒内失败 20 次就拒绝。
    //
    // token 是 43 字符随机串，暴力破解本来就不现实；
    // 这条是防"日志灌注 / 白跑 CPU"：以前 15 次错 token 全返回 401，没有任何成本。
    {
      loadAuthFails();
      const src = String(req.socket?.remoteAddress || "-");
      const now = Date.now();
      const cur = authFails.get(src);
      if (cur && (cur.bannedUntil || 0) > now) {
        const left = Math.ceil(((cur.bannedUntil - now) / 1000));
        throw new HttpError(429, "too-many-attempts", `认证失败次数过多，请 ${left} 秒后再试`);
      }
      // 滑窗过期且没有封禁 → 清掉，重新开始计数
      if (cur && now - (cur.start || 0) > 10 * 60 * 1000 && now > (cur.bannedUntil || 0)) {
        authFails.delete(src);
      }
    }

    // 1) 健康检查：明文、无鉴权，只暴露最小事实
    if (pathname === "/v1/health") {
      // 诊断通道：App 把点击瞬间的滚动状态塞在 ?d= 里，会进 bridge.log 供排查
      const diag = url.searchParams.get("d");
      if (diag) logLine({ step: "diag", d: diag });
      // 只回最小事实。
      // 以前还带 `sessions`（会话总数）、`lastSeq`、`phoneOnline` ——
      // 这个端点**不需要 token**，响应头又是 `access-control-allow-origin: *`，
      // 等于任何网页都能探到"这台机器上有多少会话、手机在不在线"（隐私）。
      return sendJson(res, 200, {
        ok: true,
        version: VERSION,
        bridge: name,
        e2eeRequired: cfg.requireE2ee,
      });
    }

    // 1.5) 诊断摘要：只允许本机回环（和 /admin/* 同一套规则）。
    //
    // 为什么要它：排查手机端问题过去全靠翻 bridge.log（已经 2500+ 行），
    // 一次「卡不卡、少了哪些帧、卡在哪个 mark」要 grep 好几遍。
    // 这里把进程内计数直接吐出来：帧类型分布、被丢掉的事件、卡顿次数/最长值、队列长度。
    // 明文是为了能用 curl 直接看；内容不含任何 token/正文，且只对本机开放。
    if (pathname === "/v1/diag") {
      const remote = String(req.socket?.remoteAddress || "");
      const loopback =
        remote === "127.0.0.1" || remote === "::1" || remote === "::ffff:127.0.0.1";
      if (!loopback) throw new HttpError(403, "forbidden", "诊断接口只允许在本机访问");
      // 光靠 loopback 不够：网页也能向 127.0.0.1 发请求，
      // 而响应头是 `access-control-allow-origin: *` → 任意网页都能读到这些统计。
      if (!safeEqual(tokenOf(req, url), pair.token)) {
        throw new HttpError(401, "unauthorized", "token 无效");
      }
      const uptimeSec = Math.round((Date.now() - diagStats.startedAt) / 1000);
      return sendJson(res, 200, {
        ok: true,
        bridge: name,
        version: VERSION,
        uptimeSec,
        phoneOnline: phoneOnline(),
        clients: streamClients.size,
        lastSeq: frames.lastSeq,
        buffered: frames.items.length,
        frames: diagStats.frames,
        droppedEvents: diagStats.dropped,
        stalls: diagStats.stalls,
        queue: diagStats.queue,
      });
    }

    // 2) 握手：明文，但需要 token
    if (pathname === "/v1/handshake") {
      const token = req.headers["x-dsh-token"] || "";
      if (!safeEqual(token, pair.token)) {
        noteAuthFail(req);
        throw new HttpError(401, "unauthorized", "token 无效");
      }
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
      // 分页：before = 已加载的条数（从尾部往前数）。
      // QQ 那种「上拉加载更早」就是靠它：每次多要 before 更大的那一批。
      const before = Math.max(0, Number(url.searchParams.get("before")) || 0);
      const paginate = (all) => {
        const total = all.length;
        const end = Math.max(0, total - before);
        const start = Math.max(0, end - limit);
        return {
          frames: all.slice(start, end),
          total,
          hasMore: start > 0,
          nextBefore: before + (end - start),
        };
      };

      if (!session) {
        const fromLog = framesFromLog(sessionId);
        if (fromLog) {
          const page = paginate(fromLog);
          return sendJson(res, 200, {
            ok: true,
            sessionId,
            source: "log",
            ...page,
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
      const page = paginate(frames);
      return sendJson(res, 200, {
        ok: true,
        sessionId,
        eventCount: events.length,
        ...page,
      }, ctxEnc);
    }

    // ComfyUI 在线/生图状态
    if (method === "GET" && pathname === "/v1/comfy") {
      const status = await comfyStatus();
      return sendJson(res, 200, { ok: true, ...status, at: Date.now() }, ctxEnc);
    }

    // 可用模型列表（附当前会话的选择）
    // 账户余额：走 DSH 自带的 accountController，不碰 API key
    // 队列写操作：转发给 sessionController.updateQueue。
    //
    // 参数结构是从 DSH 打包源码里读出来的（app.asar 内 zod schema）：
    //   updateQueue({
    //     sessionId: string,
    //     itemId:    string,
    //     action: { kind: "edit", content: [{type:"text",text}] }
    //           | { kind: "remove" }
    //           | { kind: "steer" }
    //   }) -> { accepted: true }
    //
    // 之前七轮全失败，就是因为我按事件里的 {target,start,removedCount,inserted}
    // 去猜 —— 而真正的参数是 action.kind，读不到它就报
    // "Cannot read properties of undefined (reading 'kind')"。
    if (method === "POST" && pathname === "/v1/queue/update") {
      const body = await readJsonBody();
      const ctrlQ = sessionController || ctx.sessionController;
      const svcQ = ctrlQ && ctrlQ.typertRemote && ctrlQ.typertRemote.service;
      if (!svcQ || typeof svcQ.updateQueue !== "function") {
        throw new HttpError(503, "not-ready", "updateQueue 不可用");
      }
      const sessionId = String(body.sessionId || "");
      const itemId = String(body.itemId || "");
      const kind = String(body.kind || "");
      if (!sessionId) throw new HttpError(400, "bad-request", "需要 sessionId");
      if (!itemId) throw new HttpError(400, "bad-request", "需要 itemId");
      if (!["edit", "remove", "steer"].includes(kind)) {
        throw new HttpError(400, "bad-request", "kind 必须是 edit / remove / steer");
      }
      let action;
      if (kind === "edit") {
        const text = String(body.text || "");
        if (!text.trim()) throw new HttpError(400, "bad-request", "edit 需要非空 text");
        action = { kind: "edit", content: [{ type: "text", text }] };
      } else {
        action = { kind };
      }
      try {
        const result = await svcQ.updateQueue({ sessionId, itemId, action });
        logLine({ step: "queue.update/ok", sessionId, itemId, kind });
        return sendJson(res, 200, { ok: true, result: result ?? null }, ctxEnc);
      } catch (error) {
        const message = String(error?.message || error);
        logLine({
          step: "queue.update",
          sessionId,
          itemId,
          kind,
          error: message.slice(0, 240),
          stack: String(error?.stack || "").split("\n").slice(0, 4).join(" | ").slice(0, 400),
        });
        throw new HttpError(500, "update-failed", message.slice(0, 200));
      }
    }

    if (method === "GET" && pathname === "/v1/balance") {
      const account = ctx.get?.("accountController") || ctx.accountController;
      if (!account || typeof account.getBalance !== "function") {
        return sendJson(res, 200, { ok: false, status: "unavailable", wallets: [], bonuses: [] }, ctxEnc);
      }
      // getBalance(client) 需要一个 client 描述对象，平台请求头要用它的三个字段：
      //   x-client-version / x-client-locale / x-client-timezone-offset
      // （见 app.asar 里 platformClientHeaders 的实现）
      // 之前不传就报 "Cannot read properties of undefined (reading 'version')" ——
      // 一直误判成「没登录」，其实是少传了这个参数。
      const platformClient = {
        version: VERSION || "0.0.0",
        locale: "zh-CN",
        timezoneOffsetSeconds: -new Date().getTimezoneOffset() * 60,
      };
      try {
        const result = await account.getBalance(platformClient);
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
          const profile = await account.getProfile(platformClient);
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
              // **只记形状，不记内容**：以前这里 JSON.stringify 整个字段，
              // 而 session 的某些字段里含完整的系统提示词 / 历史消息文本，
              // 结果这些私有内容被写进了明文 bridge.log（2026-11-14 隐私审计发现）。
              if (typeof v === "function") { probe.queueLike[k] = "<fn>"; continue; }
              if (Array.isArray(v)) { probe.queueLike[k] = `Array(${v.length})`; continue; }
              if (v && typeof v === "object") {
                probe.queueLike[k] = `{${Object.keys(v).slice(0, 12).join(",")}}`;
              } else {
                probe.queueLike[k] = `<${typeof v}>`;
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
            try {
            const svc2 = tr && tr.service;
            const uq = svc2 && svc2.updateQueue;
            if (typeof uq === "function") {
              probe.updateQueueSig = {
                length: uq.length,
                src: String(uq).slice(0, 260),
              };
            }
            // 真正的实现在 svc.commands.updateQueue 里。
            // 六种 request 形状全报 "reading 'kind'"，说明不是字段名问题，
            // 得看它内部读谁的 kind —— 这是最后一次探测。
            const cmds = svc2 && svc2.commands;
            if (cmds) {
              probe.commandsKeys = Object.keys(cmds).slice(0, 30);
              const cuq = cmds.updateQueue;
              if (typeof cuq === "function") {
                probe.commandsUpdateQueue = {
                  length: cuq.length,
                  src: String(cuq).slice(0, 900),
                };
              }
            }
          } catch (e) {
            probe.commandsProbeError = String(e?.message || e).slice(0, 160);
          }
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

        // 默认不落盘：这些探针只在排障时需要，而且内容涉及会话内部结构。
        if (process.env.DSH_PHONE_DEBUG === "1") logLine(probe);
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

      /**
       * cwd 只在「它确实是 DSH 已注册的工作区」时才传。
       *
       * 以前手机把 `roots.first`（那是**文件白名单根**，不一定是工作区）直接塞进来，
       * DSH 会按这个路径另建一个工作区分组 —— 会话确实建了，也回了一个 id，
       * 但桌面端当前工作区的列表里根本看不到（用户实报："手机能建，电脑没更新"）。
       * 不传 cwd 时走的就是桌面端默认工作区，和 /v1/answer 里自动建会话那条路径一致。
       */
      /* 只认 **DSH 已注册的工作区**；cfg.roots 是手机的文件白名单，
         拿它当 cwd 会把会话建到别的工作区分组里去（这正是"电脑看不到"的原因）。*/
      const known = new Set(
        detectWorkspaceRoots()
          .map((r) => String(r || "").replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase())
          .filter(Boolean),
      );
      const wanted = body.cwd ? String(body.cwd).replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase() : "";
      const useCwd = wanted && known.has(wanted) ? String(body.cwd) : null;

      const made = await ctrl.create(useCwd ? { cwd: useCwd } : {});
      const sessionId = String(made?.sessionId || "");
      if (!sessionId) throw new HttpError(500, "create-failed", "新建会话失败");
      logLine({ step: "session/new", sessionId, cwd: useCwd || "(default workspace)", requested: body.cwd || null });
      return sendJson(res, 200, { ok: true, sessionId, cwd: useCwd || null }, ctxEnc);
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

    // ── 产物转发：把一个文件"引用"发到另一个会话 ────────────────────────
    //
    // 只发路径，不传文件本体：
    //   · DSH 与文件在同一台电脑上，路径对两个会话都有效
    //   · 手机没法预览/下载的类型（dmg/exe/7z…）也能转发
    // 白名单校验跟文件读取用同一套 roots，越界直接 400。
    // ── 签名状态：手机把"证书还剩几天"报上来 ────────────────────
    //
    // 目的：免费签名 7 天到期后 App 直接打不开，用户完全不知道。
    // 手机自己读得到（embedded.mobileprovision），报上来之后：
    //   · 电脑端面板能显示剩余天数并给一键续签入口
    //   · 快到期时写进日志，方便事后追溯"为什么某天开始连不上"
    if (method === "POST" && pathname === "/v1/signing") {
      const body = await readJsonBody();
      const expiresAt = String(body.expiresAt || "");
      const daysLeft = Number(body.daysLeft);
      const doc = {
        expiresAt: expiresAt || null,
        daysLeft: Number.isFinite(daysLeft) ? daysLeft : null,
        updatedAt: new Date().toISOString(),
      };
      try {
        fs.writeFileSync(path.join(stateDir(), "signing.json"), JSON.stringify(doc, null, 2), "utf8");
      } catch {
        /* 写不进去也不影响 */
      }
      logLine({ step: "signing", daysLeft: doc.daysLeft, expiresAt: doc.expiresAt });
      if (doc.daysLeft !== null && doc.daysLeft <= 2) {
        console.warn(`[phone-bridge] 手机 App 签名还剩 ${doc.daysLeft} 天，记得重新安装（见 docs/续签.md）`);
      }
      return sendJson(res, 200, { ok: true }, ctxEnc);
    }

    // 自测：造一条假提问推到手机，等它回答。
    // 用途：验证「桥 → 手机 → 桥」这条链路；真实提问要靠 ask_user_question 工具，
    // 而 agent 侧不一定有这个工具，所以留一个可点名触发的自测入口。
    if (method === "POST" && pathname === "/v1/ask/selftest") {
      if (!streamClients.size) throw new HttpError(409, "no-client", "手机还没连上");
      askSerial += 1;
      const id = "selftest_" + askSerial;
      const payload = [
        {
          id: "q1",
          header: "自测",
          question: "这是一条来自桥的自测提问，随便选一个",
          options: [
            { label: "选项 A", description: "第一个选项" },
            { label: "选项 B" },
          ],
          multiSelect: false,
        },
      ];
      const answer = await new Promise((resolve) => {
        const timer = setTimeout(() => {
          pendingAsks.delete(id);
          broadcast({ type: "ask.cancelled", id, reason: "timeout" });
          resolve(null);
        }, 60_000);
        pendingAsks.set(id, { resolve, timer, sessionId: "" });
        broadcast({ type: "ask.asked", id, sessionId: "", callId: "", questions: payload });
      });
      return sendJson(res, 200, { ok: Boolean(answer), answer }, ctxEnc);
    }

    if (method === "POST" && pathname === "/v1/ask/ready") {
      askReadyUntil = Date.now() + ASK_READY_TTL_MS;
      lastPhoneSeen = Date.now();
      return sendJson(res, 200, { ok: true, ttlMs: ASK_READY_TTL_MS, clients: streamClients.size }, ctxEnc);
    }

    // 手机提交提问的答案 → 转发给桌面端，由它替用户按下"提交"。
    // 这是"镜像 + 遥控"模型的唯一入口：DSH 的提问通道完全不动。
    if (method === "POST" && pathname === "/v1/ask/submit") {
      const body = await readJsonBody();
      const sessionId = String(body.sessionId || "");
      const answers = Array.isArray(body.answers) ? body.answers : [];
      if (!sessionId) throw new HttpError(400, "bad-request", "缺少 sessionId");
      const clean = answers
        .filter((a) => a && typeof a.id === "string")
        .map((a) => ({
          id: a.id,
          selected: Array.isArray(a.selected) ? a.selected.filter((s) => typeof s === "string") : [],
          ...(typeof a.custom === "string" && a.custom.trim() ? { custom: a.custom.trim() } : {}),
        }));
      if (clean.length === 0) throw new HttpError(400, "bad-request", "答案为空");

      let emitted = false;
      try {
        if (typeof ctx.emit === "function") {
          ctx.emit("phone-bridge/ask-submit", { sessionId, answers: clean });
          emitted = true;
        }
      } catch (error) {
        logLine({ step: "ask.submit.error", msg: String(error?.message || error) });
      }
      logLine({ step: "ask.submit", sessionId: sessionId.slice(-8), n: clean.length, emitted });
      if (!emitted) {
        throw new HttpError(503, "not-ready", "桌面端没接收这次提交（DSH 补丁未打或版本不匹配）");
      }
      return sendJson(res, 200, { ok: true }, ctxEnc);
    }

    if (method === "GET" && pathname === "/v1/ask/pending") {
      const list = [];
      for (const [id, item] of pendingAsks) {
        list.push({ id, sessionId: item.sessionId, questions: item.questions || [] });
      }
      return sendJson(res, 200, { ok: true, pending: list }, ctxEnc);
    }

    if (method === "POST" && pathname === "/v1/ask/answer") {
      const body = await readJsonBody();
      const id = String(body.id || "");
      const answers = Array.isArray(body.answers) ? body.answers : [];
      const item = pendingAsks.get(id);
      if (!item) {
        throw new HttpError(404, "not-found", "这条提问已经不在了（可能已超时或在电脑上答过）");
      }
      const clean = answers
        .filter((a) => a && typeof a.id === "string")
        .map((a) => ({
          id: a.id,
          selected: Array.isArray(a.selected) ? a.selected.filter((s) => typeof s === "string") : [],
          ...(typeof a.custom === "string" && a.custom.trim() ? { custom: a.custom.trim() } : {}),
        }));
      if (clean.length === 0) throw new HttpError(400, "bad-request", "答案为空");

      // 两条通道，**先试干净的那条**：
      //
      //   ① RPC（ctx.userQuestions.answer）—— 只对「continued」状态的提问有效。
      //      提问带了 timeout、且倒计时已过，DSH 就会把它转成 continued。
      //      走这条时答案会作为一条 user-question-reply 消息进会话，
      //      会话投影随之结算 → **桌面端卡片自动关闭**，不留残影。
      //
      //   ② waterfall（我们自己的 promise）—— 提问还活着的窗口内使用。
      //      快（毫秒级返回），但桌面端会保留它自己的面板，直到它自己的倒计时结束。
      //
      // 顺序很重要：能走 ① 就走 ①。这样"手机答完电脑还挂着"只在
      // 极短的窗口内可能出现，而且最迟在提问超时时必被收起。
      const uq = ctx.get?.("userQuestions") || ctx.userQuestions;
      if (uq?.answer && item.agent && item.callId) {
        let accepted = false;
        for (let i = 0; i < 4 && !accepted; i += 1) {
          try {
            accepted = (await uq.answer(item.agent, item.callId, { answers: clean })) === true;
          } catch (error) {
            const code = error?.code || "";
            if (code === "REPLY_QUEUED") { accepted = true; break; }
            logLine({ step: "ask.rpc.error", msg: String(error?.message || error) });
            break;
          }
          if (!accepted) await new Promise((r) => setTimeout(r, 250));
        }
        if (accepted) {
          tellClientsAskSettled(item.sessionId);
          clearTimeout(item.timer);
          if (Array.isArray(item.nudge)) item.nudge.forEach(clearTimeout);
          else clearTimeout(item.nudge);
          pendingAsks.delete(id);
          broadcast({ type: "ask.answered", id, via: "rpc" });
          logLine({ step: "ask.answered", id, n: clean.length, via: "rpc" });
          return sendJson(res, 200, { ok: true, via: "rpc" }, ctxEnc);
        }
      }

      // ② 还没到 continued，就走我们还握着的 waterfall
      clearTimeout(item.timer);
      if (Array.isArray(item.nudge)) item.nudge.forEach(clearTimeout);
      else clearTimeout(item.nudge);
      pendingAsks.delete(id);
      item.resolve({ answers: clean });
      // 让桌面端把卡片收起来（需要 DSH 补丁；没有也不影响答案）
      tellClientsAskSettled(item.sessionId);
      // 错开一拍再叫停桌面面板：先保证答案已经交回去
      setTimeout(() => {
        // 防御：这个函数必须存在于当前作用域，否则宁可不动也不许抛（曾把宿主打崩）
        try {
          if (typeof closeDesktopPanel === "function") closeDesktopPanel(item.agent, item.callId);
        } catch (error) {
          logLine({ step: "ask.desktop-close", ok: false, why: String(error?.message || error) });
        }
      }, 0);
      broadcast({ type: "ask.answered", id, via: "waterfall" });
      logLine({ step: "ask.answered", id, n: clean.length, via: "waterfall" });
      return sendJson(res, 200, { ok: true, via: "waterfall" }, ctxEnc);
    }

    if (method === "POST" && pathname === "/v1/session/forward") {
      const body = await readJsonBody();
      const ctrl = sessionController || ctx.sessionController;
      if (!ctrl) throw new HttpError(503, "not-ready", "sessionController 尚未就绪");

      const toSessionId = String(body.toSessionId || "");
      const target = String(body.path || "").trim();
      const forwardedText = String(body.text || "").trim();
      const note = String(body.note || "").trim();
      const fromTitle = String(body.fromTitle || "").trim();
      const attachCommand = body.attachCommand === true;
      // 二选一：转发文件（path）或转发一段文本（text）。
      // 文本转发用在「把上一轮的结论交给另一个会话接着做」——
      // 手机上没有多窗口，这是最常用的交接方式。
      if (!toSessionId || (!target && !forwardedText)) {
        throw new HttpError(400, "bad-request", "需要 toSessionId 以及 path 或 text");
      }

      // 路径必须在允许的根下面（和 /v1/fs/read 同一套判断）
      const normalized = target.replace(/\\/g, "/");
      if (target) {
        const roots = safeFs.allowedRoots().map((r) => String(r || "").replace(/\\/g, "/").toLowerCase());
        const inside = roots.some((root) => normalized.toLowerCase().startsWith(root.replace(/\/+$/, "") + "/"))
          || roots.some((root) => normalized.toLowerCase() === root.replace(/\/+$/, ""));
        if (!inside) {
          throw new HttpError(400, "outside-roots", "该路径不在允许的目录里：" + roots.join(" / "));
        }
      }

      // 3 秒内同目标 + 同路径 + 同说明，只发一次（防连点）
      const key = toSessionId + "|" + (target ? normalized.toLowerCase() : "text:" + forwardedText.slice(0, 40)) + "|" + note;
      const now = Date.now();
      if (recentForwards.has(key) && now - recentForwards.get(key) < 3000) {
        return sendJson(res, 200, { ok: true, deduped: true }, ctxEnc);
      }
      recentForwards.set(key, now);
      if (recentForwards.size > 200) {
        for (const [k, ts] of recentForwards) if (now - ts > 60000) recentForwards.delete(k);
      }

      const lines = [];
      lines.push(fromTitle ? "[转发] 来自「" + fromTitle + "」" : "[转发]");
      lines.push("");
      if (target) lines.push(target);
      if (forwardedText) lines.push(forwardedText);
      if (note) { lines.push(""); lines.push(note); }
      if (attachCommand) {
        lines.push("");
        lines.push("请把上面这个文件作为输入继续处理。");
      }
      const text = lines.join("\n");

      const requestId = String(body.requestId || randomUUID());
      try {
        const result = await ctrl.prompt(
          { sessionId: toSessionId, content: [{ type: "text", text }], requestId },
          AbortSignal.timeout(cfg.approvalTimeoutMs * 4),
        );
        logLine({ step: "session/forward", toSessionId, path: target || "(text)", chars: text.length });
        return sendJson(res, 200, {
          ok: true,
          toSessionId,
          requestId,
          accepted: result?.accepted !== false,
        }, ctxEnc);
      } catch (error) {
        logLine({ step: "session/forward", toSessionId, error: String(error?.message || error).slice(0, 300) });
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

  // lanHost：配置优先；没配就自动探测（换网络不用改配置）
  const effectiveLanHost = cfg.lanHost || detectLanIp();

  // 只看一眼系统盘加没加密：没加密就提醒一次（不阻断，也不影响启动）
  // 动机：会话日志只压缩不加密，磁盘没加密 = 硬盘被拿走就能读全量对话。
  setTimeout(() => {
    try {
      const { spawn } = require("node:child_process");
      const child = spawn(
        "powershell",
        ["-NoProfile", "-NonInteractive", "-Command",
          "$v=(Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop).ProtectionStatus; Write-Output $v"],
        { stdio: ["ignore", "pipe", "ignore"], windowsHide: true },
      );
      let out = "";
      child.stdout.on("data", (b) => { out += b.toString(); });
      child.on("error", () => {});
      child.on("close", () => {
        const value = out.trim();
        if (/^(0|Off)$/i.test(value)) {
          console.warn("[phone-bridge] 提示：系统盘未开启 BitLocker。会话日志只压缩不加密，建议开启磁盘加密。");
          logLine({ step: "warn.bitlocker", protection: "off" });
        }
      });
    } catch {
      /* 查不到就算了 */
    }
  }, 4000);

  server.listen(cfg.port, "127.0.0.1", () => {
    const address = server.address();
    const actual = typeof address === "object" && address ? address.port : cfg.port;
    resolveReady({ port: actual, pair: { token: pair.token, fingerprint: pair.fingerprint } });
    console.log(`[phone-bridge] 监听 127.0.0.1:${actual}`);
    console.log(`[phone-bridge] 配对串: dshnb://pair?host=127.0.0.1&port=${actual}&token=${pair.token}&fp=${pair.fingerprint}`);
    console.log(`[phone-bridge] 状态目录: ${stateDir()}`);
    if (effectiveLanHost) {
      const lan = http.createServer(makeHandler("lan"));
      lan.listen(actual, effectiveLanHost, () => {
        const how = cfg.lanHost ? "配置" : "自动探测";
        console.log(`[phone-bridge] 局域网监听 ${effectiveLanHost}:${actual}（${how}，内容仍需 E2EE 解密）`);
        console.log(`[phone-bridge] 手机可用: dshnb://pair?host=${effectiveLanHost}&port=${actual}&token=***&fp=${pair.fingerprint}`);
      });
      lan.on("error", (error) => {
        // 探测到的 IP 被占用/换网时不要影响 loopback 服务
        console.error(`[phone-bridge] 局域网监听 ${effectiveLanHost} 失败（不影响本机使用）: ${error?.message || error}`);
      });
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
