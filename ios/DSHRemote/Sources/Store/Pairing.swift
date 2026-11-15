import Foundation
import Security
import CryptoKit

typealias CryptoKitCurveKey = Curve25519.KeyAgreement.PrivateKey

/// 极简 Keychain 封装：只存 32 字节私钥、token 与配置 JSON。
/// 默认 accessibility = afterFirstUnlockThisDeviceOnly —— 不出现在备份里，也不跨设备。
enum Keychain {
    private static let service = "dev.yg.dshremote"

    static func set(_ data: Data, for key: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 配对配置 + 配对串解析。
struct PairingConfig: Codable, Equatable {
    var host: String
    var port: Int
    var token: String
    var fingerprint: String
    var useTLS: Bool

    var baseURL: String {
        let scheme = useTLS ? "https" : "http"
        return "\(scheme)://\(host):\(port)"
    }

    var displayName: String { "\(host):\(port)" }
}

enum PairingError: LocalizedError {
    case badURI
    case missingField(String)

    var errorDescription: String? {
        switch self {
        case .badURI: return L("配对串格式不对，应以 dshnb://pair? 开头", "Invalid pairing code — it should start with dshnb://pair?")
        case .missingField(let f): return L("配对串缺少字段：\(f)", "Pairing code is missing: \\(f)")
        }
    }
}

enum PairingStore {
    private static let configKey = "pairing.config"
    private static let privKeyName = "client.x25519.private"

    static func parse(_ raw: String) throws -> PairingConfig {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw PairingError.badURI }
        // 宽容：允许用户直接粘贴 node 输出的整段（取第一行）
        text = text.split(separator: "\n").first.map(String.init) ?? text
        guard let comps = URLComponents(string: text), comps.scheme == "dshnb" else {
            throw PairingError.badURI
        }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard let host = value("host"), !host.isEmpty else { throw PairingError.missingField("host") }
        guard let portText = value("port"), let port = Int(portText) else { throw PairingError.missingField("port") }
        guard let token = value("token"), !token.isEmpty else { throw PairingError.missingField("token") }
        let fp = value("fp") ?? ""
        return PairingConfig(
            host: host,
            port: port,
            token: token,
            fingerprint: fp,
            useTLS: host.hasSuffix(".ts.net") || value("tls") == "1"
        )
    }

    static func save(_ config: PairingConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        Keychain.set(data, for: configKey)
    }

    static func load() -> PairingConfig? {
        guard let data = Keychain.get(configKey) else { return nil }
        return try? JSONDecoder().decode(PairingConfig.self, from: data)
    }

    static func clear() {
        Keychain.delete(configKey)
    }

    /// 客户端 X25519 私钥：首次生成后一直复用（服务器按公钥指纹绑定本机）
    static func clientPrivateKey() -> (key: CryptoKitCurveKey, isNew: Bool) {
        if let data = Keychain.get(privKeyName), data.count == 32,
           let key = try? CryptoKitCurveKey(rawRepresentation: data) {
            return (key, false)
        }
        let key = CryptoKitCurveKey()
        Keychain.set(key.rawRepresentation, for: privKeyName)
        return (key, true)
    }

    static func forgetDeviceKey() {
        Keychain.delete(privKeyName)
    }
}
