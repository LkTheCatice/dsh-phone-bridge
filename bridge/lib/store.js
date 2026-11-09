/**
 * 状态与密钥的落盘。
 *
 * 目录：$DSH_HOME/phone-bridge/
 *   pair.json     配对 token + 服务器 X25519 密钥 + 手机首次绑定的公钥指纹
 *
 * 安全约定：
 *   - 目录 0700，文件 0600（Windows 上 mode 不生效，靠用户目录 ACL）
 *   - token / 私钥只在本进程内存与这个文件里出现，永不进日志
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

const X25519_SPKI_PREFIX = Buffer.from("302a300506032b656e032100", "hex");

export function dshHome() {
  return process.env.DSH_HOME || path.join(os.homedir(), ".dsh");
}

/**
 * 状态目录可以被搬到任意盘（例如 D:\dsh-phone-bridge）：
 * 插件配置里写 `stateDir: "D:\\dsh-phone-bridge"` 即可。
 * 这样 token 与服务器私钥不必留在 C 盘的用户目录里。
 */
let stateDirOverride = null;

export function setStateDirOverride(dir) {
  if (!dir) {
    stateDirOverride = null;
    return;
  }
  stateDirOverride = path.resolve(String(dir));
}

export function stateDir() {
  if (stateDirOverride) return stateDirOverride;
  if (process.env.DSH_PHONE_BRIDGE_DIR) return path.resolve(process.env.DSH_PHONE_BRIDGE_DIR);
  return path.join(dshHome(), "phone-bridge");
}

export function stateFile(name) {
  return path.join(stateDir(), name);
}

export function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

export function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2), { encoding: "utf8", mode: 0o600 });
  fs.renameSync(tmp, file);
}

/** raw 32 字节 X25519 公钥 → SPKI DER（Node 只认 DER/PEM） */
export function rawToSpkiDer(raw) {
  if (!Buffer.isBuffer(raw) || raw.length !== 32) {
    throw new Error("X25519 公钥必须是 32 字节 raw");
  }
  return Buffer.concat([X25519_SPKI_PREFIX, raw]);
}

/** SPKI PEM → raw 32 字节 */
export function spkiPemToRaw(pem) {
  const b64 = String(pem).replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Buffer.from(b64, "base64");
  if (der.length < 32) throw new Error("X25519 公钥 PEM 解析失败");
  return der.subarray(der.length - 32);
}

export function fingerprintOfPubPem(pem) {
  return crypto
    .createHash("sha256")
    .update(spkiPemToRaw(pem))
    .digest("base64url");
}

/**
 * 读取（必要时创建）配对状态。
 * @returns {{token:string, privPem:string, pubPem:string, pubRaw:string, fingerprint:string, createdAt:string, pinnedClient:string|null}}
 */
export function ensurePairState() {
  const file = stateFile("pair.json");
  let doc = readJson(file, null);
  let changed = false;

  if (!doc || doc.version !== 1) {
    doc = { version: 1 };
    changed = true;
  }
  if (!doc.token) {
    doc.token = crypto.randomBytes(32).toString("base64url");
    changed = true;
  }
  if (!doc.e2ee?.privPem || !doc.e2ee?.pubPem) {
    const { publicKey, privateKey } = crypto.generateKeyPairSync("x25519", {
      publicKeyEncoding: { type: "spki", format: "pem" },
      privateKeyEncoding: { type: "pkcs8", format: "pem" },
    });
    doc.e2ee = { privPem: privateKey, pubPem: publicKey };
    changed = true;
  }
  if (!doc.createdAt) {
    doc.createdAt = new Date().toISOString();
    changed = true;
  }
  if (doc.clients === undefined) doc.clients = [];
  if (doc.pinnedClient !== undefined) delete doc.pinnedClient;

  const pubRaw = spkiPemToRaw(doc.e2ee.pubPem);
  const fingerprint = fingerprintOfPubPem(doc.e2ee.pubPem);

  if (changed) writeJson(file, doc);

  return {
    token: doc.token,
    privPem: doc.e2ee.privPem,
    pubPem: doc.e2ee.pubPem,
    pubRaw: pubRaw.toString("base64"),
    fingerprint,
    createdAt: doc.createdAt,
    clients: doc.clients ?? [],
  };
}

/**
 * 只读地取配对状态 —— 绝不创建、绝不生成新 token。
 *
 * 验证工具（smoke）必须用它：以前它走 ensurePairState，在状态文件缺失时会
 * 悄悄生成一套新凭据，等于把正在运行的实例顶掉。
 *
 * @returns {null | {token:string, fingerprint:string, clients:Array, createdAt:string, stateDir:string}}
 */
export function readPairState() {
  const file = stateFile("pair.json");
  const doc = readJson(file, null);
  if (!doc || !doc.token || !doc.e2ee?.pubPem) return null;
  return {
    token: doc.token,
    fingerprint: fingerprintOfPubPem(doc.e2ee.pubPem),
    clients: Array.isArray(doc.clients) ? doc.clients : [],
    createdAt: doc.createdAt ?? null,
    stateDir: stateDir(),
  };
}

/** 轮换 token：旧 token 立即失效，已建立 E2EE 的手机需重新配对。 */
export function rotateToken() {
  const file = stateFile("pair.json");
  const doc = readJson(file, { version: 1 }) || { version: 1 };
  doc.version = 1;
  doc.token = crypto.randomBytes(32).toString("base64url");
  doc.rotatedAt = new Date().toISOString();
  writeJson(file, doc);
  return doc.token;
}

/**
 * 登记一台已握手的手机。
 *
 * 为什么不是"只允许一台"：token 已经是 256 位随机主凭据，再叠一层一票否决会让
 * 重装 App、换手机、自测全部卡死（而且没有命令行能让它恢复）。这里改成保留最近
 * limit 台的名单 —— 既不卡流程，又能在配对串里审计"到底有哪些设备连过"。
 *
 * @returns {{ok:boolean, known:boolean, count:number, known_name?:string}}
 */
export function registerClient(fingerprint, name = "iphone", limit = 8) {
  const file = stateFile("pair.json");
  const doc = readJson(file, null);
  if (!doc) return { ok: false, known: false, count: 0 };
  const now = new Date().toISOString();
  const clients = Array.isArray(doc.clients) ? doc.clients : [];
  const existing = clients.find((c) => c && c.fingerprint === fingerprint);
  if (existing) {
    existing.lastSeen = now;
    if (name) existing.name = String(name).slice(0, 40);
  } else {
    clients.push({
      fingerprint,
      name: String(name || "iphone").slice(0, 40),
      firstSeen: now,
      lastSeen: now,
    });
  }
  while (clients.length > limit) clients.shift();
  doc.clients = clients;
  writeJson(file, doc);
  return {
    ok: true,
    known: Boolean(existing),
    count: clients.length,
    known_name: existing?.name,
  };
}

export function listClients() {
  const doc = readJson(stateFile("pair.json"), null);
  return Array.isArray(doc?.clients) ? doc.clients : [];
}

/** 清空设备名单（不影响 token 与服务器密钥）。 */
export function clearClients() {
  const file = stateFile("pair.json");
  const doc = readJson(file, null);
  if (!doc) return 0;
  const count = Array.isArray(doc.clients) ? doc.clients.length : 0;
  doc.clients = [];
  writeJson(file, doc);
  return count;
}
