import Foundation

/// SSE 读取。
///
/// 服务端两种帧：
///   `data: {json}`                      —— 未加密（仅在未握手时）
///   `event: sealed` + `data: <base64>`   —— 用 s2c 解，AAD 固定 "SSE"
///
/// 断线由调用方带 `since` 重连，服务端环形缓冲补齐缺口。
enum EventStream {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "无法构造事件流地址" }
    }

    static func run(
        client: BridgeClient,
        since: Int,
        onFrame: @escaping (Int, [String: Any]) -> Void
    ) async throws {
        guard let url = client.streamURL(since: since) else { throw Unavailable() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.timeoutInterval = 60 * 60

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BridgeServerError(status: code, code: "stream", message: "事件流被拒绝")
        }

        let decrypt = client.openDecryptor()
        var currentEvent = ""

        for try await rawLine in bytes.lines {
            if Task.isCancelled { return }
            let line = String(rawLine)
            if line.isEmpty {
                currentEvent = ""
                continue
            }
            if line.hasPrefix(":") { continue } // 心跳注释

            if line.hasPrefix("event:") {
                currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)

            var jsonData: Data?
            if currentEvent == "sealed" {
                if let raw = Data(base64Encoded: payload), let decrypt {
                    jsonData = try? decrypt(raw)
                }
            } else {
                jsonData = payload.data(using: .utf8)
            }

            guard let jsonData,
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }
            let seq = (obj["seq"] as? Int) ?? ((obj["seq"] as? NSNumber)?.intValue ?? 0)
            onFrame(seq, obj)
        }
    }
}
