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
import path from "node:path";
import { randomUUID, createHash } from "node:crypto";
import { URL } from "node:url";

import {
  clearClients,
  dshHome,
  ensurePairState,
  listClients,
  readJson,
  registerClient,
  rotateToken,
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

  function onSessionEvent(session, event) {
    if (closed || !event || typeof event !== "object") return;
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

  async function listSessions() {
    const ctrl = sessionController || ctx.sessionController;
    if (ctrl && typeof ctrl.list === "function") {
      try {
        const raw = await ctrl.list({}, AbortSignal.timeout(15000));
        const rows = Array.isArray(raw) ? raw : raw?.sessions ?? raw?.items ?? [];
        const mapped = rows.map(normalizeSessionRow).filter(Boolean);
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

  async function handle(req, res) {
    const url = new URL(req.url || "/", `http://${req.headers.host || "127.0.0.1"}`);
    const pathname = url.pathname;
    const method = (req.method || "GET").toUpperCase();

    if (closed) throw new HttpError(503, "closed", "bridge 已关闭");

    // 1) 健康检查：明文、无鉴权，只暴露最小事实
    if (pathname === "/v1/health") {
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
      const registration = registerClient(clientFingerprint, String(body.clientName || "iphone"));
      const clientId = randomUUID();
      e2ee.set(clientId, {
        c2s: keys.c2s,
        s2c: keys.s2c,
        createdAt: Date.now(),
        lastSeen: Date.now(),
        name: String(body.clientName || "iphone").slice(0, 40),
      });
      // 只保留最近的 8 个会话密钥，防内存堆积
      if (e2ee.size > 8) {
        const oldest = [...e2ee.entries()].sort((a, b) => a[1].createdAt - b[1].createdAt)[0];
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
      return sendJson(res, 200, { ok: true, sessions: await listSessions() }, ctxEnc);
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

  server = http.createServer((req, res) => {
    const startedAt = Date.now();
    const route = String(req.url || "").split("?")[0];
    res.on("finish", () => {
      // SSE 是长连接，finish 时才记；其余端点这就是一行请求日志
      logLine({ m: req.method, p: route, s: res.statusCode, ms: Date.now() - startedAt });
    });
    handle(req, res).catch((error) => {
      logLine({
        m: req.method,
        p: route,
        err: String(error?.code || error?.name || "error"),
        msg: String(error?.message || error).slice(0, 400),
      });
      if (error instanceof SyntaxError) jsonError(res, new HttpError(400, "bad-request", error.message));
      else jsonError(res, error);
    });
  });

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
      const lan = http.createServer((req, res) => {
        handle(req, res).catch((error) => jsonError(res, error));
      });
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
