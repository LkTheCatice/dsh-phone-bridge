import Foundation
import CryptoKit

struct BridgeServerError: LocalizedError {
    let status: Int
    let code: String
    let message: String

    var errorDescription: String? { "\(code)（HTTP \(status)）：\(message)" }
}

/// 与 bridge 的 HTTP 通道：握手 → 每个请求单独加密封包。
///
/// 明文请求会被服务器拒绝（`e2ee-required`），所以这里所有调用都走 x-sealed。
final class BridgeClient {
    private(set) var config: PairingConfig
    private(set) var keys: BridgeSessionKeys?
    private(set) var clientId: String?
    private(set) var serverName: String = ""
    private let urlSession: URLSession

    init(config: PairingConfig) {
        self.config = config
        let conf = URLSessionConfiguration.ephemeral
        conf.timeoutIntervalForRequest = 30
        conf.timeoutIntervalForResource = 300
        conf.httpAdditionalHeaders = ["user-agent": "DSHRemote/0.1 iOS"]
        self.urlSession = URLSession(configuration: conf)
    }

    // MARK: - 握手

    func handshake() async throws {
        let (privateKey, _) = PairingStore.clientPrivateKey()
        let clientPub = BridgeCrypto.clientPublicRaw(privateKey)
        let body = try JSONSerialization.data(withJSONObject: [
            "clientPub": clientPub.base64EncodedString(),
            "clientName": "iphone",
        ])

        var request = URLRequest(url: URL(string: config.baseURL + "/v1/handshake")!)
        request.httpMethod = "POST"
        request.setValue(config.token, forHTTPHeaderField: "x-dsh-token")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw BridgeServerError(status: status, code: "handshake", message: text)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientId = obj["clientId"] as? String,
              let serverPubB64 = obj["serverPub"] as? String,
              let serverPub = Data(base64Encoded: serverPubB64) else {
            throw BridgeServerError(status: status, code: "handshake", message: "响应字段不全")
        }

        // TOFU：首次记录服务器公钥指纹，之后必须一致
        if !config.fingerprint.isEmpty {
            let actual = BridgeCrypto.sha256Base64URL(serverPub)
            guard actual == config.fingerprint else {
                throw BridgeServerError(
                    status: 495,
                    code: "fingerprint-mismatch",
                    message: "电脑公钥指纹不一致，可能连到了别的服务；指纹 \(actual)"
                )
            }
        }
        if let reported = obj["fingerprint"] as? String, !reported.isEmpty, config.fingerprint.isEmpty {
            config.fingerprint = reported
            PairingStore.save(config)
        }

        self.keys = try BridgeCrypto.derive(
            clientPrivate: privateKey,
            serverPubRaw: serverPub,
            token: config.token
        )
        self.clientId = clientId
        self.serverName = (obj["serverName"] as? String) ?? ""
    }

    var isReady: Bool { keys != nil && clientId != nil }

    // MARK: - 通用请求

    private func makeRequest(
        method: String,
        path: String,
        query: [(String, String)],
        body: Data?
    ) throws -> (URLRequest, String) {
        guard let keys, let clientId else {
            throw BridgeServerError(status: 401, code: "handshake-required", message: "还没有握手")
        }
        let aad = JS.aad(method: method, path: path, query: query)
        let q = JS.queryString(query)
        let urlString = config.baseURL + path + (q.isEmpty ? "" : "?" + q)
        guard let url = URL(string: urlString) else {
            throw BridgeServerError(status: 400, code: "bad-url", message: urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(config.token, forHTTPHeaderField: "x-dsh-token")
        request.setValue(clientId, forHTTPHeaderField: "x-client")
        request.setValue("1", forHTTPHeaderField: "x-sealed")
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        if let body, !body.isEmpty {
            request.httpBody = try BridgeCrypto.seal(body, key: keys.c2s, aad: aad)
        }
        return (request, aad)
    }

    private func decodeResponse(_ data: Data, aad: String, response: URLResponse) throws -> Data {
        guard let keys else {
            throw BridgeServerError(status: 401, code: "handshake-required", message: "还没有握手")
        }
        let http = response as? HTTPURLResponse
        let sealed = http?.value(forHTTPHeaderField: "x-sealed") == "1"
        guard sealed else { return data }
        return try BridgeCrypto.open(data, key: keys.s2c, aad: aad)
    }

    private func send(
        method: String,
        path: String,
        query: [(String, String)] = [],
        body: Data? = nil
    ) async throws -> Data {
        try await sendWithHeaders(method: method, path: path, query: query, body: body).0
    }

    /// 同 send，但把响应头一起带回来（文件大小等元信息在 header 里）
    private func sendWithHeaders(
        method: String,
        path: String,
        query: [(String, String)] = [],
        body: Data? = nil
    ) async throws -> (Data, [String: String]) {
        let (request, aad) = try makeRequest(method: method, path: path, query: query, body: body)
        let (data, response) = try await urlSession.data(for: request)
        let plain = try decodeResponse(data, aad: aad, response: response)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let obj = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
            throw BridgeServerError(
                status: status,
                code: (obj?["error"] as? String) ?? "http-\(status)",
                message: (obj?["message"] as? String) ?? String(data: plain, encoding: .utf8) ?? ""
            )
        }
        var headers: [String: String] = [:]
        if let http = response as? HTTPURLResponse {
            for (key, value) in http.allHeaderFields {
                guard let name = key as? String else { continue }
                headers[name.lowercased()] = String(describing: value)
            }
        }
        return (plain, headers)
    }

    func getJSON(_ path: String, query: [(String, String)] = []) async throws -> [String: Any] {
        let data = try await send(method: "GET", path: path, query: query)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func postJSON(_ path: String, query: [(String, String)] = [], json: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: json)
        let data = try await send(method: "POST", path: path, query: query, body: body)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func postRaw(_ path: String, query: [(String, String)], body: Data) async throws -> [String: Any] {
        let data = try await send(method: "POST", path: path, query: query, body: body)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func getRaw(_ path: String, query: [(String, String)]) async throws -> Data {
        try await send(method: "GET", path: path, query: query)
    }

    /// 需要读响应头时用（例如文件总大小）
    func getRawWithHeaders(
        _ path: String,
        query: [(String, String)]
    ) async throws -> (Data, [String: String]) {
        try await sendWithHeaders(method: "GET", path: path, query: query)
    }

    // MARK: - SSE

    /// 事件流地址（token 与 client 走 query：SSE 不方便自定义 header 的场景更稳）
    func streamURL(since: Int) -> URL? {
        var comps = URLComponents(string: config.baseURL + "/v1/stream")
        var items = [
            URLQueryItem(name: "token", value: config.token),
            URLQueryItem(name: "since", value: String(since)),
        ]
        if let clientId { items.append(URLQueryItem(name: "client", value: clientId)) }
        comps?.queryItems = items
        return comps?.url
    }

    func openDecryptor() -> ((Data) throws -> Data)? {
        guard let keys else { return nil }
        return { sealed in
            try BridgeCrypto.open(sealed, key: keys.s2c, aad: "SSE")
        }
    }

    // MARK: - 便捷封装

    func fetchState() async throws -> [String: Any] { try await getJSON("/v1/state") }
    func fetchSessions() async throws -> [String: Any] { try await getJSON("/v1/sessions") }

    func sendTask(text: String, sessionId: String?, mode: String? = nil) async throws -> [String: Any] {
        var json: [String: Any] = [
            "text": text,
            "requestId": UUID().uuidString,
        ]
        if let sessionId, !sessionId.isEmpty { json["sessionId"] = sessionId }
        if let mode { json["mode"] = mode }
        return try await postJSON("/v1/task", json: json)
    }

    func decide(approvalId: String, allow: Bool) async throws -> [String: Any] {
        try await postJSON("/v1/approval", json: [
            "id": approvalId,
            "decision": allow ? "allow" : "deny",
        ])
    }

    func cancel(sessionId: String) async throws -> [String: Any] {
        try await postJSON("/v1/cancel", json: ["sessionId": sessionId])
    }

    func newSession(cwd: String? = nil) async throws -> [String: Any] {
        var json: [String: Any] = [:]
        if let cwd, !cwd.isEmpty { json["cwd"] = cwd }
        return try await postJSON("/v1/session/new", json: json)
    }

    func renameSession(sessionId: String, title: String) async throws -> [String: Any] {
        try await postJSON("/v1/session/rename", json: ["sessionId": sessionId, "title": title])
    }

    func archiveSession(sessionId: String, archived: Bool) async throws -> [String: Any] {
        try await postJSON("/v1/session/archive", json: ["sessionId": sessionId, "archived": archived])
    }

    func comfyStatus() async throws -> [String: Any] {
        try await getJSON("/v1/comfy")
    }

    func balance() async throws -> [String: Any] {
        try await getJSON("/v1/balance")
    }

    func models(sessionId: String?) async throws -> [String: Any] {
        var query: [(String, String)] = []
        if let sessionId, !sessionId.isEmpty { query.append(("sessionId", sessionId)) }
        return try await getJSON("/v1/models", query: query)
    }

    func selectModel(
        sessionId: String,
        provider: String,
        model: String,
        reasoningEffort: String? = nil
    ) async throws -> [String: Any] {
        var payload: [String: Any] = [
            "sessionId": sessionId,
            "provider": provider,
            "model": model,
        ]
        if let reasoningEffort, !reasoningEffort.isEmpty {
            payload["reasoningEffort"] = reasoningEffort
        }
        return try await postJSON("/v1/session/model", json: payload)
    }

    func transcript(sessionId: String, limit: Int = 400) async throws -> [String: Any] {
        try await getJSON("/v1/transcript", query: [
            ("sessionId", sessionId),
            ("limit", String(limit)),
        ])
    }

    func sessions(archived: Bool = false) async throws -> [String: Any] {
        try await getJSON("/v1/sessions", query: archived ? [("archived", "1")] : [])
    }

    func mkdir(path: String) async throws -> [String: Any] {
        try await postJSON("/v1/fs/mkdir", query: [("path", path)], json: [:])
    }

    func delete(path: String, recursive: Bool = false) async throws -> [String: Any] {
        try await postJSON(
            "/v1/fs/delete",
            query: [("path", path), ("recursive", recursive ? "1" : "0")],
            json: [:]
        )
    }

    func listFiles(path: String) async throws -> [String: Any] {
        try await getJSON("/v1/fs/list", query: [("path", path)])
    }

    /// 最近一次 readFile 的返回信息（文件总大小、是否预览图）
    private(set) var lastFileSize: Int64?
    private(set) var lastWasPreview = false

    func readFile(
        path: String,
        offset: Int,
        limit: Int,
        preview: Bool = false,
        mode: String? = nil,
        /// 预览目标宽度（像素）。聊天列表用几百，点开看大图用 2048。
        maxWidth: Int? = nil
    ) async throws -> Data {
        var query: [(String, String)] = [
            ("path", path),
            ("offset", String(offset)),
            ("limit", String(limit)),
        ]
        if preview { query.append(("preview", "1")) }
        if preview, let maxWidth { query.append(("w", String(maxWidth))) }
        // mode=poster 时服务端只返回封面帧；不传则按类型自动（图片压缩 / 视频压预览）
        if let mode, !mode.isEmpty { query.append(("mode", mode)) }
        let (data, headers) = try await sendWithHeaders(method: "GET", path: "/v1/fs/read", query: query)
        if let sizeText = headers["x-file-size"], let size = Int64(sizeText) {
            lastFileSize = size
        }
        lastWasPreview = headers["x-preview"] == "1"
        return data
    }

    func writeFile(path: String, offset: Int, truncate: Bool, data: Data) async throws -> [String: Any] {
        try await postRaw("/v1/fs/write", query: [
            ("path", path),
            ("offset", String(offset)),
            ("truncate", truncate ? "1" : "0"),
        ], body: data)
    }
}
