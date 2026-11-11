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
    @Published private(set) var lastSeq: Int = UserDefaults.standard.integer(forKey: "dsh.lastSeq")
    @Published var lastError: String?
    @Published var busy: Bool = false
    /// 外部 App 递过来的文件，等用户选会话后再发
    @Published var pendingIncoming: IncomingFile?
    /// ComfyUI 状态（聊天页顶部状态点）
    @Published private(set) var comfy = ComfyStatus()
    /// 可选模型
    @Published private(set) var modelGroups: [ModelGroup] = []
    @Published private(set) var currentModel: ModelOption?
    /// 发送方式：排队 / 插队
    @Published var sendMode: SendMode = .queue
    /// 历史回填中
    @Published private(set) var historyLoading = false
    /// 服务端对历史读取的补充说明（比如冷会话读不到）
    @Published private(set) var historyNote: String?

    private var client: BridgeClient?
    private var streamTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// turn.start 的时间，用来在 turn.end 显示"用时 N 秒"
    private var turnStartedAt: [String: Date] = [:]

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
        if seq > lastSeq {
            lastSeq = seq
            // 每 20 帧落一次盘：冷启动时就能从上次的位置续传，
            // 不必把服务端缓冲里的 3000 帧全回放一遍
            if seq % 20 == 0 {
                UserDefaults.standard.set(seq, forKey: "dsh.lastSeq")
            }
        }
        guard let type = frame["type"] as? String else { return }
        let sid = (frame["sessionId"] as? String) ?? selectedSessionId ?? ""
        let turn = (frame["turn"] as? NSNumber)?.intValue ?? 0

        switch type {
        case "turn.start":
            turnStartedAt[sid] = Date()
            append(sid, ChatEntry(id: "\(sid)#turn\(turn)", kind: .system, text: "开始第 \(turn) 轮", at: Date(), running: true))

        case "assistant.thinking":
            let text = (frame["text"] as? String) ?? ""
            upsertStreaming(sid, id: "\(sid)#think\(turn)", kind: .thinking, delta: text, header: "", turn: turn)

        case "assistant.delta":
            let text = (frame["text"] as? String) ?? ""
            upsertStreaming(sid, id: "\(sid)#ans\(turn)", kind: .assistant, delta: text, header: "", turn: turn)

        case "tool.call":
            let callId = (frame["callId"] as? String) ?? UUID().uuidString
            let name = (frame["name"] as? String) ?? "tool"
            let detail = Self.jsonText(frame["args"])
            // text 存"中文动作名"，detail 存可展开的原始参数
            append(sid, ChatEntry(id: "\(sid)#tool\(callId)", kind: .toolCall, text: Self.toolLabel(name), detail: detail, at: Date(), running: true, turn: turn))

        case "tool.result":
            let callId = (frame["callId"] as? String) ?? ""
            let preview = Self.jsonText(frame["preview"])
            let ok = (frame["ok"] as? Bool) ?? true
            if !callId.isEmpty, var list = entries[sid],
               let idx = list.firstIndex(where: { $0.id == "\(sid)#tool\(callId)" }) {
                list[idx].detail = preview
                list[idx].running = false
                list[idx].ok = ok
                entries[sid] = list
            }
            // 找不到对应调用就丢掉：电脑端也不会把"工具完成"单独列一行

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
            // reason 是对象 {"kind":"completed"}，别把 JSON 原样怼到界面上
            let kind = (frame["reason"] as? [String: Any])?["kind"] as? String
                ?? (frame["reason"] as? String)
                ?? ""
            let elapsed: String
            if let started = turnStartedAt[sid] {
                let seconds = max(0, Int(Date().timeIntervalSince(started)))
                elapsed = seconds >= 60 ? "用时 \(seconds / 60) 分 \(seconds % 60) 秒" : "用时 \(seconds) 秒"
                turnStartedAt[sid] = nil
            } else {
                elapsed = ""
            }
            let label: String
            switch kind {
            case "completed", "": label = "本轮结束"
            case "cancelled", "canceled", "aborted": label = "本轮已中止"
            case "error": label = "本轮出错"
            default: label = "本轮结束 · \(kind)"
            }
            append(sid, ChatEntry(
                id: "\(sid)#end\(turn)",
                kind: .system,
                text: elapsed.isEmpty ? label : "\(label) · \(elapsed)",
                at: Date()
            ))
            for key in entries.keys {
                guard var list = entries[key] else { continue }
                for i in list.indices where list[i].running { list[i].running = false }
                entries[key] = list
            }
            // 本轮跑完就把过程收起来：思考 + 工具调用合成一行「本轮过程 · N 步」，
            // 点开才展开。否则几十轮下来 log 会把聊天记录埋掉。
            foldSteps(sid, turn: turn)
            // DSH 的标题是消息后异步生成的，turn.end 那一刻往往还没写进日志，
            // 所以延迟几秒再刷一次会话列表，标题才会显示出来
            Task {
                await refreshSessions()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await refreshSessions()
            }

        case "user.message":
            let text = (frame["text"] as? String) ?? ""
            // 双保险：服务端已过滤 DSH 注入的时间上下文，历史帧再挡一次
            let injected = text.hasPrefix("Time sampled while preparing")
                || text.hasPrefix("Browser time zone for this request")
                || text.hasPrefix("Elapsed since")
            guard !injected else { return }
            append(sid, ChatEntry(id: UUID().uuidString, kind: .user, text: text, at: Date()))

        default:
            break
        }
    }

    /// 轮询 ComfyUI 状态（聊天页顶部那个状态点）
    private var comfyTask: Task<Void, Never>?

    func startComfyPolling() {
        comfyTask?.cancel()
        comfyTask = Task { [weak self] in
            while !Task.isCancelled {
                if let client = self?.client {
                    if let raw = try? await client.comfyStatus() {
                        self?.applyComfy(raw)
                    }
                }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    private func applyComfy(_ raw: [String: Any]) {
        var status = ComfyStatus()
        status.online = (raw["online"] as? Bool) ?? false
        status.generating = (raw["generating"] as? Bool) ?? false
        status.running = (raw["running"] as? NSNumber)?.intValue ?? 0
        status.pending = (raw["pending"] as? NSNumber)?.intValue ?? 0
        status.version = raw["version"] as? String
        status.url = (raw["url"] as? String) ?? ""
        comfy = status
    }

    /// 拉取可用模型列表（打开选择器时调用）
    func loadModels() async {
        guard let client else { return }
        do {
            let raw = try await client.models(sessionId: selectedSessionId)
            var groups: [ModelGroup] = []
            if let rawGroups = raw["groups"] as? [[String: Any]] {
                for group in rawGroups {
                    let providerId = (group["id"] as? String) ?? ""
                    let providerName = (group["name"] as? String) ?? providerId
                    let models = (group["models"] as? [[String: Any]] ?? []).compactMap { item -> ModelOption? in
                        guard let id = item["id"] as? String else { return nil }
                        return ModelOption(
                            id: id,
                            name: (item["name"] as? String) ?? id,
                            provider: providerId,
                            providerName: providerName
                        )
                    }
                    if !models.isEmpty {
                        groups.append(ModelGroup(id: providerId, name: providerName, models: models))
                    }
                }
            }
            modelGroups = groups
            if let current = raw["current"] as? [String: Any],
               let provider = current["provider"] as? String,
               let model = current["model"] as? String {
                currentModel = ModelOption(
                    id: model,
                    name: model,
                    provider: provider,
                    providerName: groups.first(where: { $0.id == provider })?.name ?? provider
                )
            }
        } catch {
            lastError = "读取模型列表失败：\(error.localizedDescription)"
        }
    }

    func selectModel(_ option: ModelOption) async {
        guard let client, let sessionId = selectedSessionId else {
            lastError = "先选一个会话再换模型"
            return
        }
        do {
            _ = try await client.selectModel(sessionId: sessionId, provider: option.provider, model: option.id)
            currentModel = option
        } catch {
            lastError = "切换模型失败：\(error.localizedDescription)"
        }
    }

    private func append(_ sessionId: String, _ entry: ChatEntry) {
        guard !sessionId.isEmpty else { return }
        // 单个会话超过 600 条就丢掉最老的，避免长时间使用后内存一直涨
        entries[sessionId, default: []].append(entry)
        if let list = entries[sessionId], list.count > 600 {
            entries[sessionId] = Array(list.suffix(600))
        }
    }

    /// 把某一轮里的思考 + 工具调用折叠成单个可展开条目。
    /// 少于 3 步就不折 —— 只有一两步时折起来反而多一次点击。
    private func foldSteps(_ sessionId: String, turn: Int) {
        guard var list = entries[sessionId] else { return }
        let processKinds: Set<ChatEntry.Kind> = [.thinking, .toolCall]
        let stepIndexes = list.indices.filter {
            processKinds.contains(list[$0].kind) && list[$0].turn == turn
        }
        guard stepIndexes.count >= 3, let firstIdx = stepIndexes.first else { return }

        let foldedEntries = stepIndexes.map { list[$0] }
        let fold = ChatEntry(
            id: "\(sessionId)#fold\(turn)",
            kind: .collapsedSteps,
            text: "本轮过程 · \(foldedEntries.count) 步",
            detail: nil,
            at: Date(),
            running: false,
            ok: nil,
            turn: turn,
            folded: foldedEntries
        )
        // 从后往前删，索引才不会错位
        for idx in stepIndexes.reversed() {
            list.remove(at: idx)
        }
        list.insert(fold, at: min(firstIdx, list.count))
        entries[sessionId] = list
    }

    private func upsertStreaming(_ sessionId: String, id: String, kind: ChatEntry.Kind, delta: String, header: String, turn: Int = 0) {
        guard !sessionId.isEmpty else { return }
        var list = entries[sessionId] ?? []
        if let idx = list.firstIndex(where: { $0.id == id }) {
            list[idx].text += delta
            list[idx].running = true
        } else {
            list.append(ChatEntry(id: id, kind: kind, text: (header.isEmpty ? "" : header + "\n") + delta, at: Date(), running: true, turn: turn))
        }
        entries[sessionId] = list
    }

    /// 把工具名翻成电脑端那套中文动作词（"运行命令 / 读取 / 写入"…）
    static func toolLabel(_ name: String) -> String {
        switch name {
        case "pwsh", "bash", "shell", "terminal", "terminal_bash": return "运行命令"
        case "read", "read_image": return "读取"
        case "write", "edit", "str_replace_editor", "str_replace": return "写入"
        case "present": return "展示"
        case "skill": return "技能"
        case "todo_write": return "任务清单"
        case "subagent", "subagent_fork", "send_message", "list_agents": return "子代理"
        case "workflow": return "编排"
        case "web_search", "web_fetch": return "联网"
        case "ask_user_question": return "提问"
        case "load_workspace_dependencies": return "环境准备"
        default:
            if name.hasPrefix("schedule") { return "定时任务" }
            if name.hasPrefix("job") { return "后台任务" }
            if name.hasPrefix("video") { return "视频分析" }
            return name
        }
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
            // 服务端重启后 seq 会从头开始。本地存的上次 seq 如果比服务端还大，
            // 继续带 since=旧值会永远收不到新帧，必须归零重放。
            if let serverSeq = state["lastSeq"] as? NSNumber, serverSeq.intValue < lastSeq {
                lastSeq = serverSeq.intValue
                UserDefaults.standard.set(lastSeq, forKey: "dsh.lastSeq")
            }
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

    func send(text: String, mode: SendMode? = nil) async {
        guard let client else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let effective = mode ?? sendMode
        busy = true
        defer { busy = false }
        let target = selectedSessionId
        let sid = target ?? "pending"
        append(sid, ChatEntry(id: UUID().uuidString, kind: .user, text: trimmed, at: Date()))
        do {
            let result = try await client.sendTask(
                text: trimmed,
                sessionId: target,
                mode: effective == .steer ? "steer" : nil
            )
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

    /// 外部 App（微信 / QQ / 文件）通过「用其他应用打开」递进来的文件
    func ingestExternalFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var data: Data?
        do {
            data = try Data(contentsOf: url)
        } catch {
            data = nil
        }
        // 有的来源给的是「在文件 App 里的引用」，直接读可能失败，走协作副本
        if data == nil {
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            var copy: Data?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                copy = try? Data(contentsOf: readURL)
            }
            data = copy
        }

        guard let payload = data else {
            lastError = "读取不了这个文件：\(url.lastPathComponent)"
            return
        }
        pendingIncoming = IncomingFile(name: url.lastPathComponent, data: payload)
    }

    /// 把待发送文件上传到电脑并投递到指定会话（nil = 新建会话）
    func sendIncoming(_ file: IncomingFile, to sessionId: String?, note: String) async throws {
        let remote = try await uploadAttachment(file.data, filename: file.name)
        selectedSessionId = sessionId
        var text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = file.isImage ? "[图片] \(remote)" : "[文件] \(remote)"
        text = text.isEmpty ? tag : "\(text)\n\(tag)"
        await send(text: text)
    }

    /// 把某个会话的历史事件拉回来重建成聊天记录。
    /// 之前只显示「连上之后收到的事件」，所以重开 App 后旧对话是空的。
    func loadHistory(_ sessionId: String, limit: Int = 600) async {
        guard let client, !sessionId.isEmpty else { return }
        historyLoading = true
        defer { historyLoading = false }
        do {
            let raw = try await client.transcript(sessionId: sessionId, limit: limit)
            guard let frames = raw["frames"] as? [[String: Any]] else { return }
            // 重建：先清空，再按顺序喂给 apply（seq 传 0，不推进实时游标）
            entries[sessionId] = []
            for frame in frames {
                apply(seq: 0, frame: frame)
            }
            historyNote = raw["note"] as? String
        } catch {
            lastError = "读取历史失败：\(error.localizedDescription)"
        }
    }

    /// 清除某个会话在本机的聊天记录。
    /// keepTurns 为 nil 表示全清；否则至少保留最近 N 轮（用户要求最少 5 轮防误删）。
    func clearEntries(_ sessionId: String, keepTurns: Int?) {
        guard let list = entries[sessionId], !list.isEmpty else { return }
        if let keep = keepTurns, keep > 0 {
            let turns = list.compactMap { $0.turn > 0 ? $0.turn : nil }
            if let maxTurn = turns.max() {
                let keepFrom = max(1, maxTurn - keep + 1)
                entries[sessionId] = list.filter { $0.turn >= keepFrom || $0.turn == 0 }
                return
            }
        }
        entries[sessionId] = []
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
