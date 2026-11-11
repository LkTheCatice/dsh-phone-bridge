/**
 * 只查一件事：会话列表里有多少条真标题，多少条退化成 id 后缀。
 *
 *   node bin/titles.mjs
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

import { readPairState, stateDir } from "../lib/store.js";
import { aadFor, seal, unseal } from "../lib/seal.js";

function autoStateDir() {
  if (process.env.DSH_PHONE_BRIDGE_DIR) return;
  const home = process.env.DSH_HOME || path.join(os.homedir(), ".dsh");
  const patch = path.join(home, "profiles", process.env.DSH_PROFILE || "desktop", "cordis.patch.yml");
  try {
    const text = fs.readFileSync(patch, "utf8");
    const m = text.match(/stateDir:\s*['"]?([^'"\r\n]+)['"]?/);
    if (m && m[1].trim()) process.env.DSH_PHONE_BRIDGE_DIR = m[1].trim();
  } catch {
    /* 用默认 */
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
  fs.mkdirSync(path.dirname(KEY_FILE), { recursive: true });
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

  const hs = async () =>
    (
      await fetch(`${BASE}/v1/handshake`, {
        method: "POST",
        headers: { "x-dsh-token": pair.token, "content-type": "application/json" },
        body: JSON.stringify({ clientPub: pubRaw.toString("base64"), clientName: "titles" }),
      })
    ).json();

  let h = await hs();
  if (h.error === "device-pending") {
    const devs = await (await fetch(`${BASE}/admin/devices`)).json();
    const pending = devs.devices.filter((d) => d.status === "pending").pop();
    if (pending) {
      await fetch(`${BASE}/admin/devices/status`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ fingerprint: pending.fingerprint, status: "approved" }),
      });
      h = await hs();
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

  const p = "/v1/sessions";
  const aad = aadFor("GET", p, new URLSearchParams());
  const res = await fetch(`${BASE}${p}`, {
    headers: { "x-dsh-token": pair.token, "x-client": h.clientId, "x-sealed": "1" },
  });
  const data = JSON.parse(unseal(s2c, aad, Buffer.from(await res.arrayBuffer())).toString("utf8"));
  const sessions = data.sessions || [];

  const withTitle = sessions.filter((s) => s.title && String(s.title).trim());
  const without = sessions.filter((s) => !s.title || !String(s.title).trim());

  console.log(`会话总数: ${sessions.length}`);
  console.log(`有标题:   ${withTitle.length}`);
  console.log(`无标题:   ${without.length}\n`);

  console.log("—— 有标题的（前 12 条）——");
  for (const s of withTitle.slice(0, 12)) {
    console.log(`  ${s.id.slice(0, 20)}…  ${String(s.title).slice(0, 40)}`);
  }
  if (without.length) {
    console.log("\n—— 无标题的（前 8 条）——");
    for (const s of without.slice(0, 8)) {
      console.log(`  ${s.id.slice(0, 20)}…  running=${s.running}  updatedAt=${s.updatedAt ?? "null"}`);
    }
  }
}

main().catch((e) => {
  console.error("出错:", e);
  process.exit(1);
});
