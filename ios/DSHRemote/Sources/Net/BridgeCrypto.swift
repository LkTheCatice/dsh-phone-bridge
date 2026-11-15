import Foundation
import CryptoKit

/// 与 `bridge/lib/seal.js` 完全对应的客户端加密实现。
///
///   shared = X25519(clientPriv, serverPub)
///   okm    = HKDF-SHA256(shared, salt = token, info = "dsh-phone-bridge/v1", 64)
///   c2s    = okm[0..32)   → 发出去
///   s2c    = okm[32..64)  → 收进来
///   封包    = nonce(12) || ct || tag(16)   （正是 AES.GCM 的 .combined 布局）
struct BridgeSessionKeys {
    let c2s: SymmetricKey
    let s2c: SymmetricKey
}

enum BridgeCryptoError: LocalizedError {
    case badServerKey
    case notCombined
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .badServerKey: return L("服务器公钥格式不对（需要 32 字节 X25519 raw）", "Server public key has the wrong format (expected 32-byte raw X25519)")
        case .notCombined: return L("AES-GCM 封包缺少 combined 表示", "AES-GCM packet is missing its combined form")
        case .decryptFailed: return L("解密失败：密钥或 AAD 不一致，或数据被篡改", "Decryption failed: key/AAD mismatch or tampered data")
        }
    }
}

enum BridgeCrypto {
    static let info = Data("dsh-phone-bridge/v1".utf8)

    static func makeClientKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    static func clientPublicRaw(_ key: Curve25519.KeyAgreement.PrivateKey) -> Data {
        key.publicKey.rawRepresentation
    }

    /// 派生双向密钥。serverPubRaw 是握手响应里的 serverPub（base64 解码后的 32 字节）。
    static func derive(
        clientPrivate: Curve25519.KeyAgreement.PrivateKey,
        serverPubRaw: Data,
        token: String
    ) throws -> BridgeSessionKeys {
        guard serverPubRaw.count == 32 else { throw BridgeCryptoError.badServerKey }
        let serverPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPubRaw)
        let shared = try clientPrivate.sharedSecretFromKeyAgreement(with: serverPub)
        let sharedData = shared.withUnsafeBytes { Data($0) }

        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedData),
            salt: Data(token.utf8),
            info: info,
            outputByteCount: 64
        )
        let bytes = okm.withUnsafeBytes { Data($0) }
        return BridgeSessionKeys(
            c2s: SymmetricKey(data: bytes.prefix(32)),
            s2c: SymmetricKey(data: bytes.suffix(32))
        )
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, aad: String) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(aad.utf8))
        guard let combined = box.combined else { throw BridgeCryptoError.notCombined }
        return combined
    }

    static func open(_ sealed: Data, key: SymmetricKey, aad: String) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key, authenticating: Data(aad.utf8))
        } catch {
            throw BridgeCryptoError.decryptFailed
        }
    }

    static func sha256Base64URL(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
