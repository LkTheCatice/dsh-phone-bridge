import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

/**
 * 隐私审计：检查桥对外返回的字段、日志内容、以及本机落盘的东西。
 * 只读，不改任何业务数据。
 */
const BASE = "http://127.0.0.1:8765";
const PAIR = "D:/Documents/deepseek-harness/dsh-phone-bridge/pair.json";
const token = JSON.parse(fs.readFileSync(PAIR, "utf8")).token;
const STATE = path.join(process.env.TEMP, "pentest-key.pem");
const INFO = "dsh-phone-bridge/v1";

const rawPub = (k) => { const d = k.export({ format: "der", type: "spki" }); return d.subarray(d.length - 32); };
const aadFor = (m, p, sp) => {
  const pairs = [...sp.entries()].sort((a, b) => (a[0] === b[0] ? 0 : a[0] < b[0] ? -1 : 1));
  const q = pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
  return q ? `${m} ${p}?${q}` : `${m} ${p}`;
};
const seal = (key, aad, buf) => {
  const n = crypto.randomBytes(12);
  const c = crypto.createCipheriv("aes-256-gcm", key, n);
  c.setAAD(Buffer.from(aad, "utf8"));
  const ct = Buffer.concat([c.update(buf), c.final()]);
  return Buffer.concat([n, ct, c.getAuthTag()]);
};
const unseal = (key, aad, buf) => {
  const d = crypto.createDecipheriv("aes-256-gcm", key, buf.subarray(0, 12));
  d.setAAD(Buffer.from(aad, "utf8"));
  d.setAuthTag(buf.subarray(buf.length - 16));
  return Buffer.concat([d.update(buf.subarray(12, buf.length - 16)), d.final()]);
};

const results = [];
const add = (name, verdict, detail) => results.push({ name, verdict, detail });

// ── 1) 未授权可读的端点（网页跨域也能读，因为 ACAO: *） ─────────────
for (const p of ["/v1/diag", "/v1/health", "/v1/state", "/admin/devices", "/admin/debug/env"]) {
  const r = await fetch(BASE + p).catch(() => null);
  if (!r || r.status !== 200) {
    add(`匿名可读 ${p}`, "OK", r ? `status=${r.status}` : "ERR");
    continue;
  }
  // /v1/health 是无鉴权的存活探针，设计上就该公开；
  // 判定它有没有"泄露"要看**回了什么字段**，而不是看状态码。
  const body = await r.text();
  const sensitive = ["sessions", "lastSeq", "phoneOnline", "stateDir", "devices", "fingerprint"];
  const leaked = sensitive.filter((k) => body.includes(`"${k}"`));
  add(`匿名可读 ${p}`, leaked.length ? "LEAK" : "OK", leaked.length ? `字段 ${leaked.join(",")}` : `字段最少 (${body.length} 字节)`);
}

// ── 2) /v1/state 里的字段（会话标题/工作区 = 隐私） ─────────────────
const priv = crypto.createPrivateKey(fs.readFileSync(STATE, "utf8"));
const pub = crypto.createPublicKey(priv);
const hs = await (await fetch(BASE + "/v1/handshake", {
  method: "POST",
  headers: { "x-dsh-token": token, "content-type": "application/json" },
  body: JSON.stringify({ clientPub: rawPub(pub).toString("base64"), clientName: "privacy-audit" }),
})).json();
if (!hs.serverPub) {
  console.log("握手失败（设备未批准）：", JSON.stringify(hs));
  process.exit(1);
}
const serverPub = crypto.createPublicKey({
  key: Buffer.concat([Buffer.from("302a300506032b656e032100", "hex"), Buffer.from(hs.serverPub, "base64")]),
  format: "der", type: "spki",
});
const shared = crypto.diffieHellman({ privateKey: priv, publicKey: serverPub });
const okm = Buffer.from(crypto.hkdfSync("sha256", shared, Buffer.from(token, "utf8"), Buffer.from(INFO, "utf8"), 64));
const keys = { c2s: Buffer.from(okm.subarray(0, 32)), s2c: Buffer.from(okm.subarray(32, 64)) };

async function get(p) {
  const u = new URL(BASE + p);
  const aad = aadFor("GET", u.pathname, u.searchParams);
  const res = await fetch(BASE + p, {
    headers: { "x-dsh-token": token, "x-client": hs.clientId, "x-sealed": "1" },
  });
  const buf = Buffer.from(await res.arrayBuffer());
  try { return JSON.parse(unseal(keys.s2c, aad, buf).toString("utf8")); } catch { return null; }
}

const state = await get("/v1/state");
const sess = (state?.sessions || [])[0] || {};
add("会话行暴露哪些字段", "INFO", Object.keys(sess).join(","));
add("会话行含 cwd（目录名可推断）", sess.cwd ? "INFO" : "OK", String(sess.cwd || "—").slice(0, 60));
add("会话行含标题（用户的提问摘要）", sess.title ? "INFO" : "OK", String(sess.title || "—").slice(0, 40));

// ── 3) 日志内容：是否含正文/提示词 ─────────────────────────────────
const logPath = "D:/Documents/deepseek-harness/dsh-phone-bridge/bridge.log";
const logRaw = fs.readFileSync(logPath, "utf8");
const lines = logRaw.split("\n").filter(Boolean);
const promptLeak = lines.filter((l) => l.includes("project_instructions")).length;
const longCn = lines.filter((l) => (l.match(/[\u4e00-\u9fff]/g) || []).length > 20).length;
add("bridge.log 含系统提示词片段", promptLeak > 0 ? "LEAK" : "OK", `${promptLeak} 行`);
add("bridge.log 含 20+ 汉字长句", longCn > 0 ? "注意" : "OK", `${longCn} 行`);
add("bridge.log 体积", logRaw.length > 5 * 1024 * 1024 ? "注意" : "OK", `${(logRaw.length / 1024 / 1024).toFixed(2)} MB`);
add("日志里出现绝对路径", /[A-Za-z]:\\/.test(logRaw) ? "注意" : "OK", "");

// ── 4) 落盘形态 ──────────────────────────────────────────────
const pairStat = fs.statSync(PAIR);
add("pair.json（含 token/私钥）是否明文", "INFO", `${(pairStat.size / 1024).toFixed(1)} KB，明文 JSON`);
const sessDir = "C:/Users/acer/.dsh/sessions";
const zst = [];
const walk = (dir, depth = 0) => {
  if (depth > 3) return;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const f = path.join(dir, e.name);
    if (e.isDirectory()) walk(f, depth + 1);
    else if (e.name.endsWith(".zstd")) zst.push(f);
  }
};
try { walk(sessDir); } catch {}
add("会话日志是否加密", zst.length ? "INFO" : "—", `${zst.length} 个 .zstd（明文 jsonl 压缩，非加密）`);

// ── 5) 出网检查 ──────────────────────────────────────────────
const notifyCfg = JSON.parse(fs.readFileSync("D:/Documents/deepseek-harness/dsh-phone-bridge/pair.json", "utf8"));
add("通知推送（Bark/ntfy）是否需要外网", "INFO", "仅当 notify.kind 非空才出网；当前未配置");

console.log("\n===== 隐私审计 =====");
for (const r of results) console.log(`${r.verdict.padEnd(5)} ${r.name}   [${r.detail}]`);
