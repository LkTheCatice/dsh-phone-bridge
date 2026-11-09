/**
 * 应用层端到端加密。
 *
 *   shared   = X25519(serverPriv, clientPub)
 *   okm      = HKDF-SHA256(shared, salt = token, info = "dsh-phone-bridge/v1", 64)
 *   c2s      = okm[0..32)    手机 → 电脑方向
 *   s2c      = okm[32..64)   电脑 → 手机方向
 *   封包     = nonce(12) || AES-256-GCM 密文 || tag(16)
 *   AAD      = `${METHOD} ${PATH}?${canonicalQuery}`
 *
 * 为什么要 AAD 绑定方法与路径：防止把「读文件」的密文重放到「写文件」端点上。
 * 为什么方向密钥分开：两侧各用一个 key，配合不同 AAD，杜绝双向反射。
 */

import crypto from "node:crypto";
import { rawToSpkiDer } from "./store.js";

const INFO = "dsh-phone-bridge/v1";
const NONCE_BYTES = 12;
const TAG_BYTES = 16;

/** canonical query：按 key 升序、同名多值保序、空 query 返回 "" */
export function canonicalQuery(searchParams) {
  if (!searchParams || typeof searchParams.entries !== "function") return "";
  const pairs = [];
  for (const [k, v] of searchParams.entries()) pairs.push([k, v]);
  pairs.sort((a, b) => (a[0] === b[0] ? 0 : a[0] < b[0] ? -1 : 1));
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}

export function aadFor(method, pathname, searchParams) {
  const q = canonicalQuery(searchParams);
  return q ? `${method} ${pathname}?${q}` : `${method} ${pathname}`;
}

/**
 * 由服务器私钥 + 手机 raw 公钥派生双向密钥。
 * @param {string} serverPrivPem
 * @param {string} clientPubRawB64 raw 32 字节、base64 编码
 * @param {string} token 作为 HKDF salt，使密钥与配对绑定
 */
export function deriveSessionKeys(serverPrivPem, clientPubRawB64, token) {
  const raw = Buffer.from(String(clientPubRawB64), "base64");
  if (raw.length !== 32) throw new Error("clientPub 必须是 32 字节");
  const priv = crypto.createPrivateKey(serverPrivPem);
  const pub = crypto.createPublicKey({
    key: rawToSpkiDer(raw),
    format: "der",
    type: "spki",
  });
  const shared = crypto.diffieHellman({ privateKey: priv, publicKey: pub });
  const okm = Buffer.from(
    crypto.hkdfSync("sha256", shared, Buffer.from(token, "utf8"), Buffer.from(INFO, "utf8"), 64),
  );
  return {
    c2s: Buffer.from(okm.subarray(0, 32)),
    s2c: Buffer.from(okm.subarray(32, 64)),
    sharedFingerprint: crypto.createHash("sha256").update(shared).digest("base64url"),
  };
}

/** 加密：任意 Buffer → nonce||ct||tag */
export function seal(key, aad, plaintext) {
  const nonce = crypto.randomBytes(NONCE_BYTES);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(Buffer.from(aad, "utf8"));
  const body = Buffer.isBuffer(plaintext) ? plaintext : Buffer.from(String(plaintext), "utf8");
  const ct = Buffer.concat([cipher.update(body), cipher.final()]);
  return Buffer.concat([nonce, ct, cipher.getAuthTag()]);
}

/** 解密：nonce||ct||tag → 明文 Buffer（AAD 不匹配或篡改会抛错） */
export function unseal(key, aad, sealed) {
  const buf = Buffer.isBuffer(sealed) ? sealed : Buffer.from(sealed);
  if (buf.length < NONCE_BYTES + TAG_BYTES) throw new Error("密文长度不足");
  const nonce = buf.subarray(0, NONCE_BYTES);
  const tag = buf.subarray(buf.length - TAG_BYTES);
  const ct = buf.subarray(NONCE_BYTES, buf.length - TAG_BYTES);
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAAD(Buffer.from(aad, "utf8"));
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ct), decipher.final()]);
}

export function sealToBase64(key, aad, plaintext) {
  return seal(key, aad, plaintext).toString("base64");
}

export function unsealFromBase64(key, aad, b64) {
  return unseal(key, aad, Buffer.from(String(b64), "base64"));
}
