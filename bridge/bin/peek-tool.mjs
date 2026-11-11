/**
 * 看 /v1/transcript 返回的 tool.call 帧到底长什么样 —— 摘要选错字段时用它对照。
 *
 *   node bin/peek-tool.mjs [sessionId前缀]
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

import { readPairState, stateDir } from "../lib/store.js";
import { aadFor, unseal } from "../lib/seal.js";

function autoStateDir() {
  if (process.env.DSH_PHONE_BRIDGE_DIR) return;
  const home = process.env.DSH_HOME || path.join(os.homedir(), ".dsh");
  const patch = path.join(home, "profiles", process.env.DSH_PROFILE || "desktop", "cordis.patch.yml");
  try {
    const text = fs.readFileSync(patch, "utf8");
    const m = text.match(/stateDir:\s*['"]?([^'"\r\n]+)['"]?/);
    if (m && m[1].trim()) process.env.DSH_PHONE_BRIDGE_DIR = m[1].trim();
  } catch {
    /* 默认 */
  }
}

autoStateDir();

const BASE = process.env.DSH_BRIDGE_URL || "http://127.0.0.1:8765";
const KEY_FILE = path.join(stateDir(), "verify-key.pem");

function loadKey() {
  if (fs.existsSync(KEY_FILE)) return crypto.createPrivateKey(fs.readFileSync(KEY_FILE, "utf8"));
  const { privateKey } = crypto.generateKeyPairSync("x25519", {
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });
  fs.writeFileSync(KEY_FILE, privateKey);
  return crypto.createPrivateKey(privateKey);
}

async function main() {
  const pair = readPairState();
  const priv = loadKey();
  const der = Buffer.from(
    crypto.createPublicKey(priv).export({ type: "spki", format: "pem" }).replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""),
    "base64",
  );
  const pubRaw = der.subarray(der.length - 32);

  const handshake = async () =>
    (
      await fetch(`${BASE}/v1/handshake`, {
        method: "POST",
        headers: { "x-dsh-token": pair.token, "content-type": "application/json" },
        body: JSON.stringify({ clientPub: pubRaw.toString("base64"), clientName: "peek" }),
      })
    ).json();

  let h = await handshake();
  if (h.error === "device-pending") {
    const devs = await (await fetch(`${BASE}/admin/devices`)).json();
    const pending = devs.devices.filter((d) => d.status === "pending").pop();
    if (pending) {
      await fetch(`${BASE}/admin/devices/status`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ fingerprint: pending.fingerprint, status: "approved" }),
      });
      h = await handshake();
    }
  }
  if (!h.clientId) {
    console.log("握手失败:", JSON.stringify(h));
    process.exit(1);
  }

  const serverKey = crypto.createPublicKey({
    key: Buffer.concat([Buffer.from("302a300506032b656e032100", "hex"), Buffer.from(h.serverPub, "base64")]),
    format: "der",
    type: "spki",
  });
  const shared = crypto.diffieHellman({ privateKey: priv, publicKey: serverKey });
  const okm = Buffer.from(
    crypto.hkdfSync("sha256", shared, Buffer.from(pair.token), Buffer.from("dsh-phone-bridge/v1"), 64),
  );
  const s2c = Buffer.from(okm.subarray(32, 64));

  async function get(p, query = []) {
    const u = new URL(p, BASE);
    for (const [k, v] of query) u.searchParams.append(k, v);
    const aad = aadFor("GET", p, u.searchParams);
    const res = await fetch(u, {
      headers: { "x-dsh-token": pair.token, "x-client": h.clientId, "x-sealed": "1" },
    });
    return JSON.parse(unseal(s2c, aad, Buffer.from(await res.arrayBuffer())).toString("utf8"));
  }

  const argPrefix = process.argv[2] || "";
  const state = await get("/v1/state");
  const target =
    state.sessions.find((s) => argPrefix && s.id.startsWith(argPrefix)) || state.sessions[0];
  console.log(`会话: ${target.id}  (${target.title || "无标题"})\n`);

  const tr = await get("/v1/transcript", [["sessionId", target.id], ["limit", "2000"]]);
  const frames = tr.frames || [];
  console.log(`source=${tr.source || "live"}  frames=${frames.length}  note=${tr.note || "-"}\n`);

  const calls = frames.filter((f) => f.type === "tool.call");
  console.log(`tool.call 共 ${calls.length} 条，看最后 6 条：\n`);
  for (const call of calls.slice(-6)) {
    console.log(`工具: ${call.tool ?? call.name ?? "?"}`);
    console.log(`  args: ${JSON.stringify(call.args).slice(0, 300)}`);
    console.log(`  其它键: ${Object.keys(call).filter((k) => !["type", "tool", "name", "args"].includes(k)).join(", ")}\n`);
  }
}

main().catch((e) => {
  console.error("出错:", e);
  process.exit(1);
});
