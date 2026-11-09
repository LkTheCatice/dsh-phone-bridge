import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";

import {
  aadFor,
  canonicalQuery,
  deriveSessionKeys,
  seal,
  sealToBase64,
  unseal,
  unsealFromBase64,
} from "../lib/seal.js";
import { fingerprintOfPubPem, rawToSpkiDer, spkiPemToRaw, stateDir } from "../lib/store.js";

function makePair() {
  const server = crypto.generateKeyPairSync("x25519", {
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });
  const client = crypto.generateKeyPairSync("x25519", {
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });
  return { server, client };
}

test("raw/spki 互转可逆", () => {
  const { publicKey } = crypto.generateKeyPairSync("x25519", {
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });
  const raw = spkiPemToRaw(publicKey);
  assert.equal(raw.length, 32);
  const der = rawToSpkiDer(raw);
  const back = crypto.createPublicKey({ key: der, format: "der", type: "spki" });
  assert.equal(spkiPemToRaw(back.export({ type: "spki", format: "pem" })).toString("hex"), raw.toString("hex"));
  assert.equal(fingerprintOfPubPem(publicKey).length > 20, true);
});

test("两端 ECDH 派生出相同密钥对", () => {
  const { server, client } = makePair();
  const token = "test-token-abc";
  const clientRaw = spkiPemToRaw(client.publicKey);

  const serverSide = deriveSessionKeys(server.privateKey, clientRaw.toString("base64"), token);

  // 手机侧独立算一遍
  const shared = crypto.diffieHellman({
    privateKey: crypto.createPrivateKey(client.privateKey),
    publicKey: crypto.createPublicKey(server.publicKey),
  });
  const okm = Buffer.from(
    crypto.hkdfSync(
      "sha256",
      shared,
      Buffer.from(token, "utf8"),
      Buffer.from("dsh-phone-bridge/v1", "utf8"),
      64,
    ),
  );
  assert.deepEqual(serverSide.c2s, Buffer.from(okm.subarray(0, 32)));
  assert.deepEqual(serverSide.s2c, Buffer.from(okm.subarray(32, 64)));
  assert.notDeepEqual(serverSide.c2s, serverSide.s2c);
});

test("封包往返 + AAD 绑定 + 篡改检测", () => {
  const { server, client } = makePair();
  const keys = deriveSessionKeys(server.privateKey, spkiPemToRaw(client.publicKey).toString("base64"), "t");

  const aad = aadFor("POST", "/v1/task", new URLSearchParams(""));
  const sealed = seal(keys.c2s, aad, JSON.stringify({ text: "跑一下测试" }));
  assert.equal(unseal(keys.c2s, aad, sealed).toString("utf8"), JSON.stringify({ text: "跑一下测试" }));

  // 换 AAD（重放到别的端点）
  assert.throws(() => unseal(keys.c2s, aadFor("POST", "/v1/approval", new URLSearchParams("")), sealed));

  // 换方向密钥
  assert.throws(() => unseal(keys.s2c, aad, sealed));

  // 篡改密文
  const tampered = Buffer.from(sealed);
  tampered[tampered.length - 5] ^= 0xff;
  assert.throws(() => unseal(keys.c2s, aad, tampered));
});

test("canonicalQuery 排序稳定，AAD 与 query 顺序无关", () => {
  const a = new URLSearchParams("path=%2Fa.txt&offset=0");
  const b = new URLSearchParams("offset=0&path=%2Fa.txt");
  assert.equal(canonicalQuery(a), canonicalQuery(b));
  assert.equal(aadFor("GET", "/v1/fs/read", a), aadFor("GET", "/v1/fs/read", b));
  assert.equal(aadFor("GET", "/v1/health", new URLSearchParams("")), "GET /v1/health");
});

test("base64 便捷封装可用", () => {
  const { server, client } = makePair();
  const keys = deriveSessionKeys(server.privateKey, spkiPemToRaw(client.publicKey).toString("base64"), "t");
  const aad = aadFor("GET", "/v1/state", new URLSearchParams(""));
  const b64 = sealToBase64(keys.s2c, aad, "hello");
  assert.equal(unsealFromBase64(keys.s2c, aad, b64).toString("utf8"), "hello");
});

test("stateDir 落在 DSH_HOME 下", () => {
  assert.match(stateDir(), /phone-bridge$/);
});
