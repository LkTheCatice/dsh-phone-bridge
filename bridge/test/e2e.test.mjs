/**
 * 端到端冒烟测试：用一个假的 cordis ctx 起真正的 HTTP 服务，
 * 走完 配对 → 握手 → 加密请求 → 文件读写 → 拒绝越界 的全链路。
 */

import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-phone-bridge-"));
process.env.DSH_HOME = path.join(sandbox, "dsh-home");
fs.mkdirSync(process.env.DSH_HOME, { recursive: true });

const { apply } = await import("../index.js");
const { aadFor, seal, unseal } = await import("../lib/seal.js");

function mockCtx() {
  const handlers = new Map();
  return {
    handlers,
    on(name, fn) {
      if (!handlers.has(name)) handlers.set(name, []);
      handlers.get(name).push(fn);
    },
    emit(name, ...args) {
      for (const fn of handlers.get(name) || []) return fn(...args);
      return undefined;
    },
    inject() {
      /* 测试里不提供 sessionController：验证降级路径 */
    },
    effect(fn) {
      const dispose = fn();
      return () => dispose?.();
    },
  };
}

test("配对 → 握手 → 加密请求 → 文件读写 → 拒绝越界", async (t) => {
  const ctx = mockCtx();
  const bridge = apply(ctx, { port: 0, roots: [sandbox], requireE2ee: true });
  const { port, pair } = await bridge.ready;
  const base = `http://127.0.0.1:${port}`;
  t.after(async () => {
    await bridge.stop();
  });

  // 1) 健康检查不需要 token
  const health = await fetch(`${base}/v1/health`);
  assert.equal(health.status, 200);
  const healthBody = await health.json();
  assert.equal(healthBody.ok, true);
  assert.equal(healthBody.e2eeRequired, true);

  // 2) 错误 token 被拒
  const bad = await fetch(`${base}/v1/handshake`, {
    method: "POST",
    headers: { "x-dsh-token": "wrong", "content-type": "application/json" },
    body: JSON.stringify({ clientPub: "x" }),
  });
  assert.equal(bad.status, 401);

  // 3) 握手：新设备会被设备闸门拦成 pending，这正是真实流程的第一步
  const client = crypto.generateKeyPairSync("x25519", {
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });
  const clientPubPem = client.publicKey;
  const der = Buffer.from(clientPubPem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""), "base64");
  const clientPubRaw = der.subarray(der.length - 32);

  const handshake = () =>
    fetch(`${base}/v1/handshake`, {
      method: "POST",
      headers: { "x-dsh-token": pair.token, "content-type": "application/json" },
      body: JSON.stringify({ clientPub: clientPubRaw.toString("base64"), clientName: "test-iphone" }),
    });

  const first = await handshake();
  assert.equal(first.status, 403, "陌生设备必须先被拦下");
  assert.equal((await first.json()).error, "device-pending");

  // 4) 电脑端批准（管理接口只接受回环请求）
  const devices = await (await fetch(`${base}/admin/devices`)).json();
  assert.equal(devices.pendingCount, 1);
  const pendingFp = devices.devices.find((d) => d.status === "pending").fingerprint;
  const approve = await fetch(`${base}/admin/devices/status`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ fingerprint: pendingFp, status: "approved" }),
  });
  assert.equal(approve.status, 200);

  // 5) 批准后再握手
  const hs = await handshake();
  assert.equal(hs.status, 200);
  const hsBody = await hs.json();
  assert.equal(hsBody.fingerprint, pair.fingerprint);

  // 手机侧自己派生（与服务器算法一致）
  const serverPubRaw = Buffer.from(hsBody.serverPub, "base64");
  const serverPubKey = crypto.createPublicKey({
    key: Buffer.concat([Buffer.from("302a300506032b656e032100", "hex"), serverPubRaw]),
    format: "der",
    type: "spki",
  });
  const shared = crypto.diffieHellman({
    privateKey: crypto.createPrivateKey(client.privateKey),
    publicKey: serverPubKey,
  });
  const okm = Buffer.from(
    crypto.hkdfSync("sha256", shared, Buffer.from(pair.token, "utf8"), Buffer.from("dsh-phone-bridge/v1", "utf8"), 64),
  );
  const keys = { c2s: Buffer.from(okm.subarray(0, 32)), s2c: Buffer.from(okm.subarray(32, 64)) };

  async function sealedFetch(method, pathname, { query = new URLSearchParams(), json, raw } = {}) {
    const url = new URL(pathname, base);
    for (const [k, v] of query.entries()) url.searchParams.append(k, v);
    const aad = aadFor(method, pathname, url.searchParams);
    const plain =
      raw !== undefined
        ? raw
        : json !== undefined
          ? Buffer.from(JSON.stringify(json), "utf8")
          : Buffer.alloc(0);
    const body = seal(keys.c2s, aad, plain);
    const res = await fetch(url, {
      method,
      headers: {
        "x-dsh-token": pair.token,
        "x-client": hsBody.clientId,
        "x-sealed": "1",
        "content-type": "application/octet-stream",
      },
      body: method === "GET" ? undefined : body,
    });
    return { res, aad };
  }

  // 4) 未加密请求被拒（强制 E2EE）
  const plainState = await fetch(`${base}/v1/state`, { headers: { "x-dsh-token": pair.token } });
  assert.equal(plainState.status, 401);
  assert.equal((await plainState.json()).error, "e2ee-required");

  // 5) 加密请求成功并正确解密
  const stateRes = await sealedFetch("GET", "/v1/state");
  assert.equal(stateRes.res.status, 200);
  const stateText = unseal(keys.s2c, stateRes.aad, Buffer.from(await stateRes.res.arrayBuffer())).toString("utf8");
  const state = JSON.parse(stateText);
  assert.equal(state.ok, true);
  assert.ok(Array.isArray(state.roots));

  // 6) 用错的 AAD 解不开（防跨端点重放）
  const replay = await sealedFetch("GET", "/v1/state");
  const replayBody = Buffer.from(await replay.res.arrayBuffer());
  assert.throws(() => unseal(keys.s2c, aadFor("POST", "/v1/task", new URLSearchParams("")), replayBody));

  // 7) 文件写入 → 读回
  const target = path.join(sandbox, "note.txt");
  const payload = Buffer.from("私密内容 · secret payload 🐟", "utf8");
  const writeRes = await sealedFetch("POST", "/v1/fs/write", {
    query: new URLSearchParams({ path: target, offset: "0", truncate: "1" }),
    raw: payload,
  });
  assert.equal(writeRes.res.status, 200);
  const written = JSON.parse(unseal(keys.s2c, writeRes.aad, Buffer.from(await writeRes.res.arrayBuffer())).toString("utf8"));
  assert.equal(written.size, payload.length);
  assert.equal(fs.readFileSync(target, "utf8"), payload.toString("utf8"));

  const readRes = await sealedFetch("GET", "/v1/fs/read", {
    query: new URLSearchParams({ path: target, offset: "0" }),
  });
  assert.equal(readRes.res.status, 200);
  const readBack = unseal(keys.s2c, readRes.aad, Buffer.from(await readRes.res.arrayBuffer()));
  assert.deepEqual(readBack, payload);

  // 8) 越界路径被拒
  const escape = await sealedFetch("GET", "/v1/fs/list", {
    query: new URLSearchParams({ path: path.join(sandbox, "..", "..", "..", "Windows") }),
  });
  assert.equal(escape.res.status, 403);
  const escapeBody = JSON.parse(unseal(keys.s2c, escape.aad, Buffer.from(await escape.res.arrayBuffer())).toString("utf8"));
  assert.match(escapeBody.message, /不在允许的根目录内|不存在/);

  // 9) SSE 用 ?token= 可连（不强制加密封包）
  const controller = new AbortController();
  const streamRes = await fetch(`${base}/v1/stream?token=${encodeURIComponent(pair.token)}&since=0`, {
    signal: controller.signal,
  });
  assert.equal(streamRes.status, 200);
  assert.match(streamRes.headers.get("content-type"), /text\/event-stream/);
  controller.abort();
});
