#!/usr/bin/env node
/**
 * 从「手机视角」验收整条链路。
 *
 *   node bin/smoke.mjs                       # 连本机 8765 上正在运行的桥
 *   node bin/smoke.mjs https://xxx.ts.net    # 连 Tailscale 域名
 *   node bin/smoke.mjs --demo                # 不依赖 DSH：自带一个假 ctx 起服务自测
 *
 * 做的事：握手 → 派生密钥 → 加密 GET /v1/state → 打印会话数、
 * 文件根目录、待审批数。任何一步不对都会以非零码退出。
 */

import http from "node:http";
import crypto from "node:crypto";
import { readPairState, stateDir } from "../lib/store.js";
import { aadFor, seal, unseal } from "../lib/seal.js";

const args = process.argv.slice(2);
const demo = args.includes("--demo");
const rawTarget = args.find((a) => !a.startsWith("--")) || "127.0.0.1";

/** 允许写 host、host:port 或完整 URL */
function normalizeBase(value) {
  let base = value.trim();
  if (!/^https?:\/\//i.test(base)) base = "http://" + base;
  if (!/:\d+$/i.test(base)) base = base.replace(/\/+$/, "") + ":8765";
  return base.replace(/\/+$/, "");
}

const target = normalizeBase(rawTarget);

function log(step, detail = "") {
  console.log(`  ${step}${detail ? "  " + detail : ""}`);
}

function fail(message) {
  console.error(`\n✗ ${message}`);
  process.exit(1);
}

async function startDemo() {
  // 隔离状态目录：demo 不该污染真实配对凭据
  const os = await import("node:os");
  const fs = await import("node:fs");
  const path = await import("node:path");
  if (!process.env.DSH_HOME) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-smoke-"));
    process.env.DSH_HOME = dir;
    log("demo", `隔离 DSH_HOME=${dir}`);
  }

  const { apply } = await import("../index.js");
  const handlers = new Map();
  const ctx = {
    on(name, fn) {
      handlers.set(name, [...(handlers.get(name) || []), fn]);
    },
    inject() {},
    effect(fn) {
      const dispose = fn();
      return () => dispose?.();
    },
  };
  const bridge = apply(ctx, { port: 0, requireE2ee: true });
  const ready = await bridge.ready;
  return { base: `http://127.0.0.1:${ready.port}`, stop: bridge.stop };
}

async function main() {
  console.log("\nDSH 手机桥 · 链路验收\n");

  let handle = null;
  let base = target;
  if (demo) {
    log("demo", "启动一个不带 DSH 的假实例");
    handle = await startDemo();
    base = handle.base;
  }

  const pair = readPairState();
  if (!pair) {
    fail(
      `找不到配对凭据（${stateDir()}\\pair.json）。\n` +
        "  请先安装插件并重启一次 DSH，让它在运行中生成凭据；\n" +
        "  或者把 cordis.patch.yml 里的 stateDir 指到正确目录。",
    );
  }
  log("token", pair.token.slice(0, 10) + "…");
  log("指纹", pair.fingerprint);

  // 1) health
  const health = await fetch(base + "/v1/health").then((r) => r.json()).catch((error) => fail(`health 请求失败：${error.message}`));
  if (!health.ok) fail("health 未返回 ok");
  log("health", `v${health.version} · e2eeRequired=${health.e2eeRequired}`);

  // 2) 握手
  const client = crypto.generateKeyPairSync("x25519");
  const clientPubRaw = client.publicKey.export({ format: "jwk" }).x
    ? Buffer.from(client.publicKey.export({ format: "jwk" }).x, "base64url")
    : null;
  if (!clientPubRaw) {
    // 老版本 Node 没有 jwk/x：从 DER 里截最后 32 字节
    const der = client.publicKey.export({ format: "der", type: "spki" });
    clientPubRaw = der.subarray(der.length - 32);
  }

  const hsRes = await fetch(base + "/v1/handshake", {
    method: "POST",
    headers: { "x-dsh-token": pair.token, "content-type": "application/json" },
    body: JSON.stringify({ clientPub: clientPubRaw.toString("base64"), clientName: "smoke" }),
  });
  const hs = await hsRes.json();
  if (!hsRes.ok) fail(`握手失败：${JSON.stringify(hs)}`);
  log("握手", `clientId=${String(hs.clientId).slice(0, 8)}…`);

  if (hs.fingerprint !== pair.fingerprint) fail(`服务器指纹不一致：${hs.fingerprint}`);
  log("指纹校验", "一致");

  // 3) 手机侧独立派生密钥
  const serverPubRaw = Buffer.from(hs.serverPub, "base64");
  const serverPub = crypto.createPublicKey({
    key: Buffer.concat([Buffer.from("302a300506032b656e032100", "hex"), serverPubRaw]),
    format: "der",
    type: "spki",
  });
  const shared = crypto.diffieHellman({
    privateKey: client.privateKey, // generateKeyPairSync 返回的已是 KeyObject
    publicKey: serverPub,
  });
  const okm = Buffer.from(
    crypto.hkdfSync("sha256", shared, Buffer.from(pair.token, "utf8"), Buffer.from("dsh-phone-bridge/v1", "utf8"), 64),
  );
  const keys = { c2s: Buffer.from(okm.subarray(0, 32)), s2c: Buffer.from(okm.subarray(32, 64)) };
  log("密钥", "X25519 + HKDF-SHA256 派生完成");

  // 4) 加密请求
  const path = "/v1/state";
  const url = new URL(path, base);
  const aad = aadFor("GET", path, url.searchParams);
  const res = await fetch(url, {
    headers: {
      "x-dsh-token": pair.token,
      "x-client": hs.clientId,
      "x-sealed": "1",
    },
  });
  if (!res.ok) {
    const text = await res.text();
    fail(`加密请求失败 HTTP ${res.status}：${text.slice(0, 200)}`);
  }
  const sealedBody = Buffer.from(await res.arrayBuffer());
  const plain = unseal(keys.s2c, aad, sealedBody);
  const state = JSON.parse(plain.toString("utf8"));
  log("解密", `${plain.length} 字节`);
  log("会话", `${(state.sessions || []).length} 个`);
  log("文件根", `${(state.roots || []).length} 个${state.roots?.length ? "：" + state.roots.join(", ") : ""}`);
  log("待审批", String(state.pending?.approvals?.length ?? 0));

  // 5) 越界访问必须被拒
  const escapePath = "/v1/fs/list";
  const escapeUrl = new URL(escapePath, base);
  escapeUrl.searchParams.set("path", process.platform === "win32" ? "C:\\Windows" : "/etc");
  const escapeAad = aadFor("GET", escapePath, escapeUrl.searchParams);
  const escapeRes = await fetch(escapeUrl, {
    headers: { "x-dsh-token": pair.token, "x-client": hs.clientId, "x-sealed": "1" },
  });
  if (escapeRes.status !== 403) fail(`越界访问没被拒绝（HTTP ${escapeRes.status}）`);
  log("越界防护", "403 已拒绝");

  console.log("\n✓ 链路正常。手机 App 用同一串配对即可。\n");
  if (handle) await handle.stop();
}

main().catch((error) => fail(error?.stack || String(error)));
