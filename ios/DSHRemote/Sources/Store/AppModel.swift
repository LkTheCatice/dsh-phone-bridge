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
    /// 已归档的会话（列表里单独一段，可取消归档）
    @Published private(set) var archivedSessions: [SessionRow] = []
    @Published var selectedSessionId: String? {
        didSet {
            guard selectedSessionId != oldValue else { return }
            syncCurrentEntries()
        }
    }

    /// 当前会话的条目。
    ///
    /// 单独抽出来是有原因的：`entries` 是全局字典，任何**其他会话**收到消息
    /// 也会触发 objectWillChange，ChatView 跟着重建，
    /// `onChange(of: entries.count)` 就会在错误时机被触到 —— 表现就是
    /// 「明明在这个对话，却被别的对话的更新拉到底部」。
    /// 现在 ChatView 只观察这个属性，别的会话怎么变都不影响它。
    @Published private(set) var currentEntries: [ChatEntry] = []
    /// 当前会话内容的变化计数。
    ///
    /// 自动跟随靠它触发，而不是监听 `entries.last?.text`：
    /// 最后一条若是 thinking 或工具行，文本不变但高度在长，
    /// 只看 text 就会漏掉，位置掉队后 atBottom 判为 false，跟随彻底停摆。
    @Published private(set) var streamTick = 0
    /// 历史重建完成的计数。界面靠它决定「该滚到底了」——
    /// 回填时底部哨兵还没渲染，proxy.scrollTo 找不到目标，
    /// 所以必须等渲染完再滚，否则冷启动会停在最早的消息上。
    @Published private(set) var historyVersion = 0

    private func syncCurrentEntries() {
        pendingSync = false
        let next = selectedSessionId.flatMap { entriesStorage[$0] } ?? []
        // 整数组比较：只比 count / last 会漏掉「中间某条在变」的情况，
        // 那正是跟随失效的原因之一。ChatEntry 实现了 ==，逐项比较很快。
        guard next != currentEntries else { return }
        currentEntries = next
        streamTick &+= 1
    }

    /// 标记「当前会话内容可能变了」。
    ///
    /// 不立即同步：流式输出每秒二三十个 delta，每次都做一遍 O(n) 数组比较
    /// （元素里有多个 String 字段）会把主线程压死 —— 这是这一轮卡死的第二个原因。
    /// 攒到 60ms 再一次性比对，视觉上完全无感，开销降到原来的 1/5。
    private func markCurrentDirty() {
        guard !pendingSync else { return }
        pendingSync = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.pendingSync else { return }
            self.syncCurrentEntries()
        }
    }
    private var pendingSync = false
    /// 聊天条目。
    ///
    /// 刻意不用 `@Published`：回填历史时会有几百次写入，每次 @Published 都会发一次
    /// objectWillChange，等于让整个 ChatView 重建几百遍 —— 切会话时「触控发钝」就是这个。
    /// 改成手动发通知：批量期间闭嘴，结束时一次性刷新。
    private var entriesStorage: [String: [ChatEntry]] = [:]
    var entries: [String: [ChatEntry]] {
        get { entriesStorage }
        set {
            entriesStorage = newValue
            if !isBatchingEntries {
                objectWillChange.send()
                // 攒 60ms 再比对当前会话，别让每个流式 delta 都跑一遍全量比较
                markCurrentDirty()
            }
        }
    }
    /// 批量写入中：期间不对外发变更通知
    private var isBatchingEntries = false

    func beginBatch() {
        isBatchingEntries = true
    }

    func endBatch() {
        guard isBatchingEntries else { return }
        isBatchingEntries = false
        objectWillChange.send()
        syncCurrentEntries()
    }
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
    /// 有结果但还没点开看过的会话（列表里显示「已完成」蓝点）
    @Published private(set) var unreadSessions: Set<String> = []
    /// 每个会话各自的输入框草稿，切会话不会串
    @Published var drafts: [String: String] = [:]
    /// 轻量提示（3 秒自动消失），比 alert 不打断操作
    @Published var toast: String?

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

    func connect() async {        guard let config = pairing else { return }
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

    /// 断线横幅上的「重连」：清掉退避计数再连一次
    func reconnect() async {
        disconnect()
        await connect()
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

    /// 跳转期间冻结内容更新。
    ///
    /// 这是「跳不到底」的根因：算高度和真正跳转之间内容还在追加，
    /// 算出来的目标位置立刻过期，算法再准也追不上。
    /// 冻结后 contentSize 稳定，跳转才准；解冻时把积压的帧一次性应用，
    /// 自动跟随会顺势把这段时间的新内容补上。
    private(set) var isContentFrozen = false
    private var frozenFrames: [(frame: [String: Any], isHistory: Bool)] = []

    func freezeContent() {
        isContentFrozen = true
    }

    func unfreezeContent() {
        guard isContentFrozen else { return }
        isContentFrozen = false
        let pending = frozenFrames
        frozenFrames.removeAll()
        guard !pending.isEmpty else { return }
        beginBatch()
        for item in pending {
            apply(seq: 0, frame: item.frame, isHistory: item.isHistory)
        }
        endBatch()
    }

    private func apply(seq: Int, frame: [String: Any], isHistory: Bool = false) {
        // 冻结期只入队，不动 entries —— contentSize 才能保持不变
        if isContentFrozen {
            frozenFrames.append((frame: frame, isHistory: isHistory))
            return
        }
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
            // 用帧里的事件时间，不要用 Date()：回填历史时两者差距是几十毫秒，
            // turn.start/turn.end 会被挤在同一瞬间，于是永远显示「用时 0 秒」
            let startedAt = Self.frameDate(frame)
            turnStartedAt[sid] = startedAt
            append(sid, ChatEntry(id: "\(sid)#turn\(turn)", kind: .system, text: "开始第 \(turn) 轮", at: startedAt, running: true))

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
            // text 存中文动作名；detail 存可展开的原始参数；
            // summary 是列表上那一行摘要 —— 在这里算一次，别留给 View 反复解析
            append(sid, ChatEntry(
                id: "\(sid)#tool\(callId)",
                kind: .toolCall,
                text: Self.toolLabel(name),
                detail: detail,
                at: Date(),
                running: true,
                turn: turn,
                summary: ToolSummary.make(from: detail)
            ))

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
                // 同样用帧里的事件时间，历史轮次才算得出真实时长
                let endedAt = Self.frameDate(frame)
                let seconds = max(0, Int(endedAt.timeIntervalSince(started)))
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
            // 所以延迟几秒再刷一次会话列表，标题才会显示出来。
            // 回填历史时必须跳过：一次历史里几十个 turn.end，否则会刷爆 /v1/sessions
            if !isHistory {
                // 不是当前正在看的会话 → 标记为「已完成未看」
                if sid != selectedSessionId {
                    unreadSessions.insert(sid)
                }
                Task {
                    await refreshSessions()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await refreshSessions()
                }
            }

        case "user.message":
            let text = (frame["text"] as? String) ?? ""
            // 双保险：服务端已过滤 DSH 注入的时间/运行时上下文，历史帧再挡一次
            let injected = text.hasPrefix("Time sampled while preparing")
                || text.hasPrefix("Browser time zone for this request")
                || text.hasPrefix("Elapsed since")
                || text.contains("Current DSH file policy")
                || text.contains("Approval prompts are disabled in this session")
            guard !injected else { return }
            // 去重：send() 已经本地乐观插入过同一条，服务端回显时不能再插一次
            // —— 否则自己发的消息会显示两遍。
            let recent = entries[sid]?.suffix(3) ?? []
            let duplicated = recent.contains { item in
                item.kind == .user
                    && item.text == text
                    && abs(item.at.timeIntervalSinceNow) < 15
            }
            guard !duplicated else { return }
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
                        // reasoning.efforts 是可选块，只有支持档位的模型才有
                        var efforts: [ReasoningEffort] = []
                        if let reasoning = item["reasoning"] as? [String: Any],
                           let rawEfforts = reasoning["efforts"] as? [[String: Any]] {
                            efforts = rawEfforts.compactMap { entry in
                                guard let effortId = entry["id"] as? String else { return nil }
                                return ReasoningEffort(
                                    id: effortId,
                                    name: (entry["name"] as? String) ?? effortId,
                                    detail: entry["description"] as? String
                                )
                            }
                        }
                        return ModelOption(
                            id: id,
                            name: (item["name"] as? String) ?? id,
                            provider: providerId,
                            providerName: providerName,
                            efforts: efforts
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
                let matched = groups.flatMap(\.models).first { $0.id == model && $0.provider == provider }
                var option = ModelOption(
                    id: model,
                    name: matched?.name ?? model,
                    provider: provider,
                    providerName: groups.first(where: { $0.id == provider })?.name ?? provider,
                    efforts: matched?.efforts ?? []
                )
                option.effort = current["reasoningEffort"] as? String
                currentModel = option
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
            _ = try await client.selectModel(
                sessionId: sessionId,
                provider: option.provider,
                model: option.id,
                reasoningEffort: option.effort
            )
            currentModel = option
        } catch {
            lastError = "切换模型失败：\(error.localizedDescription)"
        }
    }

    /// 只换推理档位（模型不变）
    func selectEffort(_ effort: String?, for option: ModelOption) async {
        var updated = option
        updated.effort = effort
        await selectModel(updated)
    }

    private func append(_ sessionId: String, _ entry: ChatEntry) {
        guard !sessionId.isEmpty else { return }
        var item = entry
        // 和上一条隔了 5 分钟以上才打时间戳，否则每条都挂时间太吵
        let previous = entries[sessionId]?.last
        if let previous {
            if item.at.timeIntervalSince(previous.at) >= 300 {
                item.timeLabel = Self.clockFormatter.string(from: item.at)
            }
        } else {
            item.timeLabel = Self.clockFormatter.string(from: item.at)
        }
        entries[sessionId, default: []].append(item)
        trimIfNeeded(sessionId)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 单个会话超过 600 条就丢最老的，避免长时间使用后内存一直涨。
    /// 必须按 turn 边界裁：直接 suffix(600) 会把「本轮过程 · N 步」这种
    /// 折叠块从中间切开，界面上会露出一半。
    private func trimIfNeeded(_ sessionId: String) {
        guard let list = entries[sessionId], list.count > 600 else { return }
        var keepFrom = 0
        var counted = 0
        for entry in list.reversed() {
            counted += 1
            if counted >= 600 {
                keepFrom = entry.turn
                break
            }
        }
        entries[sessionId] = list.filter { $0.turn >= keepFrom || $0.turn == 0 }
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
        // 就地改字典里的数组。之前是「取出来 → 改 → 塞回去」，
        // 每次 delta 都会 CoW 复制整个数组（几百条），流式输出时开销很明显。
        if let index = entries[sessionId]?.firstIndex(where: { $0.id == id }) {
            entries[sessionId]?[index].text += delta
            entries[sessionId]?[index].running = true
            return
        }
        append(sessionId, ChatEntry(
            id: id,
            kind: kind,
            text: (header.isEmpty ? "" : header + "\n") + delta,
            at: Date(),
            running: true,
            turn: turn
        ))
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
    /// 帧自带的事件时间（毫秒）。回填历史时用它算每轮用时，
    /// 否则 turn.start / turn.end 在同一毫秒内处理，永远是「用时 0 秒」。
    private static func frameDate(_ frame: [String: Any]) -> Date {
        if let ms = (frame["at"] as? NSNumber)?.doubleValue, ms > 0 {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return Date()
    }

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
        // 已归档的会话单独拉一份，列表里给它一个分区
        if let result = try? await client.sessions(archived: true),
           let rows = result["sessions"] as? [[String: Any]] {
            archivedSessions = rows.compactMap(SessionRow.parse)
        }
    }

    /// 取消归档，让会话回到主列表
    func unarchive(_ sessionId: String) async {
        await archive(sessionId, archived: false)
        await refreshSessions()
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

    /// 打开某个会话时把它标记成已读
    func markRead(_ sessionId: String) {
        unreadSessions.remove(sessionId)
    }

    /// 草稿用的键：还没选会话时共用一个「新对话」草稿位
    func draftKey(_ sessionId: String?) -> String {
        sessionId ?? "__new__"
    }

    func showToast(_ text: String) {
        toast = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self?.toast == text { self?.toast = nil }
        }
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
            // 整段批量写，期间不发变更通知：几百帧就是几百次写入，
            // 逐次通知会让 ChatView 重建几百遍，切会话时手感发钝就是这个原因。
            beginBatch()
            entries[sessionId] = []
            for frame in frames {
                // seq 传 0 不推进实时游标；isHistory=true 避免每个 turn.end 都去刷会话列表
                apply(seq: 0, frame: frame, isHistory: true)
            }
            endBatch()
            historyNote = raw["note"] as? String
            // 通知界面：历史重建完成，可以滚到底了
            historyVersion &+= 1
        } catch {
            endBatch()
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

    /// 临时诊断：给服务端日志打一个标记，用来确认「按钮点击到底有没有被接收」。
    ///
    /// 走 /v1/health（免认证、开销极小），不经过 E2EE 握手。
    /// 如果日志里出现这条请求 → 点击到达了，问题在 scrollTo；
    /// 没有 → 点击没到达，还是 hit testing 的事。
    /// 定位完就删。
    func pingDiagnostic(_ tag: String) {
        guard let pairing else { return }
        // 参数名必须是 d —— 服务端 /v1/health 里读的就是它，拼错就一条日志都不会有
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? tag
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/v1/health?d=\(encoded)") else { return }
        Task.detached(priority: .background) {
            _ = try? await URLSession.shared.data(from: url)
        }
    }

    /// 账户余额（设置页显示）
    struct Wallet: Identifiable, Equatable {
        let currency: String
        let balance: String
        var id: String { currency }
        var isBonus: Bool = false
    }

    @Published private(set) var wallets: [Wallet] = []
    @Published private(set) var walletsStatus: String = "idle"
    /// 服务端给的失败原因（显示在设置页，便于判断是没登录还是网络问题）
    @Published private(set) var walletsDetail: String?

    func loadBalance() async {
        guard let client else { return }
        walletsStatus = "loading"
        do {
            let raw = try await client.balance()
            let status = (raw["status"] as? String) ?? "unknown"
            walletsStatus = status
            walletsDetail = raw["detail"] as? String
            func parse(_ key: String, bonus: Bool) -> [Wallet] {
                (raw[key] as? [[String: Any]] ?? []).compactMap { item in
                    guard let currency = item["currency"] as? String, !currency.isEmpty else { return nil }
                    return Wallet(
                        currency: currency,
                        balance: (item["balance"] as? String) ?? "-",
                        isBonus: bonus
                    )
                }
            }
            wallets = parse("wallets", bonus: false) + parse("bonuses", bonus: true)
        } catch {
            walletsStatus = "failed"
            walletsDetail = error.localizedDescription
            wallets = []
        }
    }

    /// 只取文件大小：读 1 字节，靠响应头拿总大小，不下载内容
    func probeFileSize(path: String) async -> Int64 {
        guard let client else { return 0 }
        _ = try? await client.readFile(path: path, offset: 0, limit: 1)
        return client.lastFileSize ?? 0
    }

    /// 取视频封面帧（电脑侧 ffmpeg 抽第 0.5 秒，720 宽，通常 20–40KB）
    func downloadPoster(path: String) async -> Data? {
        guard let client else { return nil }
        return try? await client.readFile(
            path: path,
            offset: 0,
            limit: 4 * 1024 * 1024,
            preview: true,
            mode: "poster"
        )
    }

    func entriesForSelection() -> [ChatEntry] {
        // 直接读发布属性：ChatView 依赖它，才能和其他会话的写入隔离开
        currentEntries
    }

    // MARK: - 文件

    func listFiles(path: String) async throws -> [FsEntry] {
        guard let client else { throw BridgeServerError(status: 0, code: "offline", message: "未连接") }
        let result = try await client.listFiles(path: path)
        let resolved = (result["path"] as? String) ?? path
        let rows = (result["entries"] as? [[String: Any]]) ?? []
        return rows.compactMap { FsEntry.parse($0, parent: resolved) }
    }

    @discardableResult
    func mkdir(path: String) async throws -> [String: Any] {
        guard let client else { throw BridgeServerError(status: 0, code: "offline", message: "未连接") }
        return try await client.mkdir(path: path)
    }

    @discardableResult
    func deleteFile(path: String, recursive: Bool = false) async throws -> [String: Any] {
        guard let client else { throw BridgeServerError(status: 0, code: "offline", message: "未连接") }
        return try await client.delete(path: path, recursive: recursive)
    }

    /// 回前台后的宽限期：期间不显示断线横幅。
    /// 从后台切回来时连接还没恢复，立即弹「未连接」其实是误报。
    @Published private(set) var suppressDisconnect = false

    func beginReconnectGrace(seconds: Double = 3) {
        suppressDisconnect = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            suppressDisconnect = false
        }
    }

    func download(
        path: String,
        chunkSize: Int = 1024 * 1024,
        onProgress: ((Int64, Int64) -> Void)? = nil
    ) async throws -> Data {
        guard let client else { throw BridgeServerError(status: 0, code: "offline", message: "未连接") }
        var data = Data()
        var offset = 0
        var guardCount = 0
        var total: Int64 = 0
        while true {
            let chunk = try await client.readFile(path: path, offset: offset, limit: chunkSize)
            if chunk.isEmpty { break }
            data.append(chunk)
            offset += chunk.count
            guardCount += 1
            // 总大小由首包响应头带回；拿不到就只报已下载量
            if total == 0, let size = client.lastFileSize, size > 0 { total = size }
            onProgress?(Int64(data.count), total)
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
