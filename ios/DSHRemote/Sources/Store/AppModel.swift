import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var pairing: PairingConfig?
    @Published private(set) var serverInfo: String = ""
    @Published private(set) var sessions: [SessionRow] = []
    @Published var selectedSessionId: String?
    @Published private(set) var entries: [String: [ChatEntry]] = [:]
    @Published private(set) var pendingApprovals: [ApprovalRow] = []
    @Published private(set) var roots: [String] = []
    @Published private(set) var lastSeq: Int = 0
    @Published var lastError: String?
    @Published var busy: Bool = false

    private var client: BridgeClient?
    private var streamTask: Task<Void, Never>?
    private var reconnectAttempt = 0

    init() {
        pairing = PairingStore.load()
    }

    var isPaired: Bool { pairing != nil }
    var isConnected: Bool { phase == .connected }

    // MARK: - 配对与连接

    func pair(uri: String) async {
        do {
            let config = try PairingStore.parse(uri)
            PairingStore.save(config)
            pairing = config
            await connect()
        } catch {
            lastError = error.localizedDescription
            phase = .failed(error.localizedDescription)
        }
    }

    func updatePairing(host: String, port: Int, token: String, useTLS: Bool) async {
        let config = PairingConfig(host: host, port: port, token: token, fingerprint: "", useTLS: useTLS)
        PairingStore.save(config)
        pairing = config
        await connect()
    }

    func connect() async {
        guard let config = pairing else { return }
        disconnect()
        phase = .connecting
        let client = BridgeClient(config: config)
        self.client = client
        do {
            try await client.handshake()
            self.pairing = client.config
            serverInfo = client.serverName
            phase = .connected
            lastError = nil
            await refresh()
            startStream()
        } catch {
            phase = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        client = nil
        phase = .disconnected
        reconnectAttempt = 0
    }

    func forgetPairing() {
        disconnect()
        PairingStore.clear()
        pairing = nil
        sessions = []
        entries = [:]
        pendingApprovals = []
    }

    // MARK: - 事件流

    private func startStream() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                guard let client = self.client else { return }
                let since = self.lastSeq
                do {
                    try await EventStream.run(client: client, since: since) { [weak self] seq, frame in
                        Task { @MainActor in self?.apply(seq: seq, frame: frame) }
                    }
                } catch {
                    if Task.isCancelled { return }
                    self.phase = .failed(error.localizedDescription)
                }
                if Task.isCancelled { return }
                attempt += 1
                let delay = min(pow(2.0, Double(attempt)), 15.0)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                // 重连前重新握手：clientId 会换新，但派生密钥不变（同一对 X25519）
                if let client = self.client {
                    try? await client.handshake()
                    self.phase = .connected
                    attempt = 0
                }
            }
        }
    }

    // MARK: - 帧处理

    private func apply(seq: Int, frame: [String: Any]) {
        if seq > lastSeq { lastSeq = seq }
        guard let type = frame["type"] as? String else { return }
        let sid = (frame["sessionId"] as? String) ?? selectedSessionId ?? ""
        let turn = (frame["turn"] as? NSNumber)?.intValue ?? 0

        switch type {
        case "turn.start":
            append(sid, ChatEntry(id: "\(sid)#turn\(turn)", kind: .system, text: "开始第 \(turn) 轮", at: Date(), running: true))

        case "assistant.thinking":
            let text = (frame["text"] as? String) ?? ""
            upsertStreaming(sid, id: "\(sid)#think\(turn)", kind: .thinking, delta: text, header: "思考")

        case "assistant.delta":
            let text = (frame["text"] as? String) ?? ""
            upsertStreaming(sid, id: "\(sid)#ans\(turn)", kind: .assistant, delta: text, header: "")

        case "tool.call":
            let callId = (frame["callId"] as? String) ?? UUID().uuidString
            let name = (frame["name"] as? String) ?? "tool"
            let detail = Self.jsonText(frame["args"])
            append(sid, ChatEntry(id: "\(sid)#tool\(callId)", kind: .toolCall, text: name, detail: detail, at: Date(), running: true))

        case "tool.result":
            let callId = (frame["callId"] as? String) ?? ""
            let preview = Self.jsonText(frame["preview"])
            let ok = (frame["ok"] as? Bool) ?? true
            if !callId.isEmpty, var list = entries[sid],
               let idx = list.firstIndex(where: { $0.id == "\(sid)#tool\(callId)" }) {
                list[idx].detail = preview
                list[idx].running = false
                list[idx].text = "\(list[idx].text) \(ok ? "✓" : "✗")"
                entries[sid] = list
            } else {
                append(sid, ChatEntry(id: UUID().uuidString, kind: .toolResult, text: ok ? "工具完成" : "工具失败", detail: preview, at: Date()))
            }

        case "approval.asked":
            let id = (frame["id"] as? String) ?? ""
            guard !id.isEmpty else { return }
            let row = ApprovalRow(
                id: id,
                tool: (frame["tool"] as? String) ?? "permission",
                reason: (frame["reason"] as? String) ?? "",
                since: Date(),
                deadline: (frame["timeoutMs"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue / 1000) }
            )
            if !pendingApprovals.contains(where: { $0.id == id }) {
                pendingApprovals.append(row)
            }

        case "approval.decided":
            let id = (frame["id"] as? String) ?? ""
            pendingApprovals.removeAll { $0.id == id }

        case "turn.end":
            let reason = Self.jsonText(frame["reason"])
            append(sid, ChatEntry(id: "\(sid)#end\(turn)", kind: .system, text: "本轮结束 · \(reason)", at: Date()))
            for key in entries.keys {
                guard var list = entries[key] else { continue }
                for i in list.indices where list[i].running { list[i].running = false }
                entries[key] = list
            }
            Task { await refreshSessions() }

        case "user.message":
            let text = (frame["text"] as? String) ?? ""
            append(sid, ChatEntry(id: UUID().uuidString, kind: .user, text: text, at: Date()))

        default:
            break
        }
    }

    private func append(_ sessionId: String, _ entry: ChatEntry) {
        guard !sessionId.isEmpty else { return }
        entries[sessionId, default: []].append(entry)
    }

    private func upsertStreaming(_ sessionId: String, id: String, kind: ChatEntry.Kind, delta: String, header: String) {
        guard !sessionId.isEmpty else { return }
        var list = entries[sessionId] ?? []
        if let idx = list.firstIndex(where: { $0.id == id }) {
            list[idx].text += delta
            list[idx].running = true
        } else {
            list.append(ChatEntry(id: id, kind: kind, text: (header.isEmpty ? "" : header + "\n") + delta, at: Date(), running: true))
        }
        entries[sessionId] = list
    }

    /// 安全地把任意值转成可显示的 JSON 文本。
    ///
    /// 关键：`JSONSerialization.data(withJSONObject:)` 对顶层标量（字符串/数字/bool）
    /// 抛的是 **ObjC 异常（NSException）**，Swift 的 `try?` 捕不到，会直接 SIGABRT。
    /// DSH 的 `tool.call` 事件里 `args` 经常就是一段 JSON 字符串 —— 就是这个把 App 崩了。
    /// 所以必须先 `isValidJSONObject` 判断，绝不能让异常冒出去。
    private static func jsonText(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        if JSONSerialization.isValidJSONObject(value),
           let d = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return String(describing: value)
    }

    // MARK: - 动作

    func refresh() async {
        guard let client else { return }
        do {
            let state = try await client.fetchState()
            if let rows = state["sessions"] as? [[String: Any]] {
                sessions = rows.compactMap(SessionRow.parse)
            }
            if let rootsRaw = state["roots"] as? [String] { roots = rootsRaw }
            if selectedSessionId == nil { selectedSessionId = sessions.first?.id }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshSessions() async {
        guard let client else { return }
        if let result = try? await client.fetchSessions(),
           let rows = result["sessions"] as? [[String: Any]] {
            sessions = rows.compactMap(SessionRow.parse)
        }
    }

    func send(text: String) async {
        guard let client else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busy = true
        defer { busy = false }
        let target = selectedSessionId
        let sid = target ?? "pending"
        append(sid, ChatEntry(id: UUID().uuidString, kind: .user, text: trimmed, at: Date()))
        do {
            let result = try await client.sendTask(text: trimmed, sessionId: target)
            if let newId = result["sessionId"] as? String {
                if selectedSessionId == nil { selectedSessionId = newId }
                if sid != newId, let moved = entries.removeValue(forKey: "pending") {
                    entries[newId, default: []].append(contentsOf: moved)
                }
                await refreshSessions()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            append(selectedSessionId ?? "pending", ChatEntry(id: UUID().uuidString, kind: .system, text: "发送失败：\(error.localizedDescription)", at: Date()))
        }
    }

    func newSession() async {
        selectedSessionId = nil
        await refreshSessions()
        if let first = sessions.first { selectedSessionId = first.id }
    }

    /// 在电脑上真的新建一个会话（不是只清空本地选择）
    func createNewSession() async {
        guard let client else { return }
        do {
            let result = try await client.newSession(cwd: roots.first)
            guard let sid = result["sessionId"] as? String, !sid.isEmpty else {
                lastError = "服务端没有返回新会话 id"
                return
            }
            selectedSessionId = sid
            entries[sid] = []
            await refreshSessions()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func rename(_ sessionId: String, to title: String) async {
        guard let client else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await client.renameSession(sessionId: sessionId, title: trimmed)
            if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[idx].title = trimmed
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func archive(_ sessionId: String, archived: Bool = true) async {
        guard let client else { return }
        do {
            _ = try await client.archiveSession(sessionId: sessionId, archived: archived)
            sessions.removeAll { $0.id == sessionId }
            if selectedSessionId == sessionId { selectedSessionId = sessions.first?.id }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 上传附件到工作区的 uploads/ 下，返回远端绝对路径（发送时塞进消息里）
    func uploadAttachment(_ data: Data, filename: String) async throws -> String {
        guard let client else {
            throw BridgeServerError(status: 0, code: "offline", message: "未连接")
        }
        _ = client
        let root = (roots.first ?? "").replacingOccurrences(of: "\\", with: "/")
        let stamp = Int(Date().timeIntervalSince1970)
        let safe = filename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        let remote = "\(root)/uploads/\(stamp)-\(safe)"
        try await upload(localData: data, remotePath: remote)
        return remote
    }

    func decide(_ approval: ApprovalRow, allow: Bool) async {
        guard let client else { return }
        do {
            _ = try await client.decide(approvalId: approval.id, allow: allow)
            pendingApprovals.removeAll { $0.id == approval.id }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelCurrentTurn() async {
        guard let client, let sid = selectedSessionId else { return }
        _ = try? await client.cancel(sessionId: sid)
    }

    func entriesForSelection() -> [ChatEntry] {
        guard let sid = selectedSessionId else { return [] }
        return entries[sid] ?? []
    }

    // MARK: - 文件

    func listFiles(path: String) async throws -> [FsEntry] {
        guard let client else { throw BridgeServerError(status: 0, code: "offline", message: "未连接") }
        let result = try await client.listFiles(path: path)
        let resolved = (result["path"] as? String) ?? path
        let rows = (result["entries"] as? [[String: Any]]) ?? []
        return rows.compactMap { FsEntry.parse($0, parent: resolved) }
    }

    func download(path: String, chunkSize: Int = 1024 * 1024) async throws -> Data {
        guard let client else { throw BridgeServerError(status: 0, code: "offline", message: "未连接") }
        var data = Data()
        var offset = 0
        var guardCount = 0
        while true {
            let chunk = try await client.readFile(path: path, offset: offset, limit: chunkSize)
            if chunk.isEmpty { break }
            data.append(chunk)
            offset += chunk.count
            guardCount += 1
            if guardCount > 8192 { break }
        }
        return data
    }

    func upload(localData: Data, remotePath: String, chunkSize: Int = 1024 * 1024) async throws {
        guard let client else { throw BridgeServerError(status: 0, code: "offline", message: "未连接") }
        var offset = 0
        if localData.isEmpty {
            _ = try await client.writeFile(path: remotePath, offset: 0, truncate: true, data: Data())
            return
        }
        while offset < localData.count {
            let end = min(offset + chunkSize, localData.count)
            let chunk = localData.subdata(in: offset..<end)
            _ = try await client.writeFile(path: remotePath, offset: offset, truncate: offset == 0, data: chunk)
            offset = end
        }
    }
}
