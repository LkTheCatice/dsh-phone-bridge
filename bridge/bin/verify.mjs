/**
 * 服务端功能验收：这次重启后才可用的那批端点，一次全跑。
 *
 *   node bin/verify.mjs
 *
 * 覆盖：ComfyUI 状态 / 模型目录 / 会话历史 / 标题诊断 / 上传（含新建多级目录）
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

import { readPairState, stateDir } from "../lib/store.js";
import { aadFor, seal, unseal } from "../lib/seal.js";

/** 状态目录可能被搬到别的盘，先看配置里的 stateDir，别死认 ~/.dsh */
function autoStateDir() {
  if (process.env.DSH_PHONE_BRIDGE_DIR) return;
  const dshHome = process.env.DSH_HOME || path.join(os.homedir(), ".dsh");
  const profile = process.env.DSH_PROFILE || "desktop";
  const patch = path.join(dshHome, "profiles", profile, "cordis.patch.yml");
  try {
    const text = fs.readFileSync(patch, "utf8");
    const m = text.match(/stateDir:\s*['"]?([^'"\r\n]+)['"]?/);
    if (m && m[1].trim()) process.env.DSH_PHONE_BRIDGE_DIR = m[1].trim();
  } catch {
    /* 读不到就用默认 */
  }
}

autoStateDir();

const here = path.dirname(fileURLToPath(import.meta.url));
const BASE = process.env.DSH_BRIDGE_URL || "http://127.0.0.1:8765";
const KEY_FILE = path.join(stateDir(), "verify-key.pem");

function loadKey() {
  if (fs.existsSync(KEY_FILE)) return crypto.createPrivateKey(fs.readFileSync(KEY_FILE, "utf8"));
  const { privateKey } = crypto.generateKeyPairSync("x25519", {
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });
  fs.mkdirSync(path.dirname(KEY_FILE), { recursive: true });
  fs.writeFileSync(KEY_FILE, privateKey);
  return crypto.createPrivateKey(privateKey);
}

const ok = (m) => console.log(`  ✓ ${m}`);
const bad = (m) => console.log(`  ✗ ${m}`);

async function main() {
  const pair = readPairState();
  if (!pair) {
    console.log("找不到配对凭据，先重启一次 DSH");
    process.exit(1);
  }
  const priv = loadKey();
  const pubPem = crypto.createPublicKey(priv).export({ type: "spki", format: "pem" });
  const der = Buffer.from(pubPem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""), "base64");
  const pubRaw = der.subarray(der.length - 32);

  const handshake = () =>
    fetch(`${BASE}/v1/handshake`, {
      method: "POST",
      headers: { "x-dsh-token": pair.token, "content-type": "application/json" },
      body: JSON.stringify({ clientPub: pubRaw.toString("base64"), clientName: "verify" }),
    });

  let hs = await (await handshake()).json();
  if (hs.error === "device-pending") {
    const devs = await (await fetch(`${BASE}/admin/devices`)).json();
    const pending = devs.devices.filter((d) => d.status === "pending").pop();
    if (pending) {
      await fetch(`${BASE}/admin/devices/status`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ fingerprint: pending.fingerprint, status: "approved" }),
      });
      hs = await (await handshake()).json();
    }
  }
  if (!hs.clientId) {
    console.log("握手失败:", JSON.stringify(hs));
    process.exit(1);
  }

  const serverKey = crypto.createPublicKey({
    key: Buffer.concat([Buffer.from("302a300506032b656e032100", "hex"), Buffer.from(hs.serverPub, "base64")]),
    format: "der",
    type: "spki",
  });
  const shared = crypto.diffieHellman({ privateKey: priv, publicKey: serverKey });
  const okm = Buffer.from(
    crypto.hkdfSync("sha256", shared, Buffer.from(pair.token), Buffer.from("dsh-phone-bridge/v1"), 64),
  );
  const keys = { c2s: Buffer.from(okm.subarray(0, 32)), s2c: Buffer.from(okm.subarray(32, 64)) };

  async function call(method, p, { query = [], json, raw } = {}) {
    const url = new URL(p, BASE);
    for (const [k, v] of query) url.searchParams.append(k, v);
    const aad = aadFor(method, p, url.searchParams);
    const body =
      raw !== undefined ? raw : json !== undefined ? Buffer.from(JSON.stringify(json)) : Buffer.alloc(0);
    const res = await fetch(url, {
      method,
      headers: {
        "x-dsh-token": pair.token,
        "x-client": hs.clientId,
        "x-sealed": "1",
        "content-type": "application/octet-stream",
      },
      body: method === "GET" ? undefined : seal(keys.c2s, aad, body),
    });
    const buf = Buffer.from(await res.arrayBuffer());
    let parsed = null;
    try {
      parsed = JSON.parse(unseal(keys.s2c, aad, buf).toString("utf8"));
    } catch {
      parsed = null;
    }
    return { status: res.status, data: parsed, bytes: buf.length };
  }

  console.log("DSH 手机桥 · 服务端验收\n");

  console.log("[1] /v1/comfy（ComfyUI 状态）");
  const comfy = await call("GET", "/v1/comfy");
  if (comfy.status === 200 && comfy.data?.online) {
    ok(`在线 · ${comfy.data.generating ? "生图中" : "空闲"} · running=${comfy.data.running} pending=${comfy.data.pending} v${comfy.data.version}`);
  } else {
    bad(`返回 ${comfy.status} ${JSON.stringify(comfy.data)}`);
  }

  console.log("[2] /v1/models（模型目录）");
  const state = await call("GET", "/v1/state");
  const sessionId = state.data?.sessions?.[0]?.id;
  const models = await call("GET", "/v1/models", { query: sessionId ? [["sessionId", sessionId]] : [] });
  if (models.status === 200) {
    const groups = models.data?.groups || [];
    const total = groups.reduce((n, g) => n + (g.models?.length || 0), 0);
    ok(`${groups.length} 个 provider / ${total} 个模型${models.data?.current ? ` · 当前 ${models.data.current.provider}/${models.data.current.model}` : ""}`);
    for (const g of groups.slice(0, 3)) {
      console.log(`      ${g.name}: ${g.models.map((m) => m.name).slice(0, 4).join(", ")}`);
    }
  } else {
    bad(`返回 ${models.status}`);
  }

  console.log("[3] /v1/transcript（会话历史）");
  if (sessionId) {
    const tr = await call("GET", "/v1/transcript", { query: [["sessionId", sessionId], ["limit", "500"]] });
    if (tr.status === 200) {
      const frames = tr.data?.frames || [];
      const kinds = {};
      for (const f of frames) kinds[f.type] = (kinds[f.type] || 0) + 1;
      if (frames.length) {
        ok(`${frames.length} 帧 · ${Object.entries(kinds).slice(0, 5).map(([k, v]) => `${k}×${v}`).join(", ")}`);
      } else {
        bad(`0 帧（note: ${tr.data?.note || "无"}）`);
      }
    } else {
      bad(`返回 ${tr.status}`);
    }
  } else {
    bad("没有会话可测");
  }

  console.log("[4] /v1/debug/title（标题诊断）");
  if (sessionId) {
    const tt = await call("GET", "/v1/debug/title", { query: [["sessionId", sessionId]] });
    if (tt.status === 200) {
      const r = tt.data?.report || {};
      ok(`service=${r.hasSessionTitle} store=${r.hasSessionsStore} session=${r.hasSession} titleEvent=${r.hasTitleEvent} → "${r.resolved ?? "null"}"`);
    } else {
      bad(`返回 ${tt.status}`);
    }
  }

  console.log("[5] 上传（含自动新建多级目录）");
  const root = (state.data?.roots || [])[0];
  if (root) {
    const target = `${root.replace(/\\/g, "/")}/uploads/verify-${Date.now()}/probe.txt`;
    const payload = Buffer.from("hello from verify", "utf8");
    const up = await call("POST", "/v1/fs/write", {
      query: [["path", target], ["offset", "0"], ["truncate", "1"]],
      raw: payload,
    });
    if (up.status === 200) {
      ok(`写入成功 ${up.data?.written} 字节 → ${target}`);
    } else {
      bad(`返回 ${up.status} ${JSON.stringify(up.data)}`);
    }
    const rd = await call("GET", "/v1/fs/read", { query: [["path", target], ["offset", "0"]] });
    if (rd.status === 200) ok(`回读成功（${rd.bytes} 字节密文）`);
    else bad(`回读返回 ${rd.status} ${JSON.stringify(rd.data)}`);
  } else {
    bad("没有 roots 可测");
  }

  console.log("\n验收结束。");
}

main().catch((error) => {
  console.error("验收脚本出错:", error);
  process.exit(1);
});
