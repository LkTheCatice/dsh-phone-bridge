import Foundation
import SwiftUI
import Combine

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
    /// 会话列表搬到独立对象：它每条消息结束都刷新，留在 AppModel 上会让
    /// 订阅 AppModel 的 ChatView 白重算（实测 700ms 级）。见 SessionListStore 注释。
    let sessionList = SessionListStore()
    @Published var selectedSessionId: String? {
        didSet {
            guard selectedSessionId != oldValue else { return }
            // 切会话时**先释放旧对话**，再让 ChatView 触发新会话的 loadHistory。
            // 同一时刻内存里只保留一份对话：既省内存，也避免「两个会话的
            // 条目同时在 body 里被扫描」这种隐性开销。
            if let old = oldValue {
                entriesStorage.removeValue(forKey: old)
            }
            syncCurrentEntries()
            refreshCurrentTitle()
        }
    }

    /// 当前会话标题（单独一个标量，也单独 @Published）。
    ///
    /// 为什么不让 ChatView 自己去 `sessions` 里查：那样**任何**会话列表刷新
    /// （每条消息结束都会刷、服务端偶尔还会抽风到 800ms+）都会让整棵 ChatView
    /// 重算 body —— 15 条气泡连带重新排版，实测一次 700ms 级的卡顿就是这么来的。
    /// 现在会话列表怎么变，聊天树都不关心，除非标题真的变了。
    @Published private(set) var currentSessionTitle: String = "新会话"

    private func refreshCurrentTitle() {
        let next: String
        if let id = selectedSessionId {
            if let row = sessionList.rows.first(where: { $0.id == id }) {
                next = row.displayTitle
            } else {
                next = "会话 \(id.suffix(8))"
            }
        } else {
            next = "新会话"
        }
        if next != currentSessionTitle { currentSessionTitle = next }
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
        stallWatcher.setMark("sync")
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
        // 35ms → 350ms：流式刷新率从 16 次/秒 降到 ~3 次/秒。
        //
        // 为什么必须降：每一次刷新都会让 ChatView 重算 body 并让 LazyVStack
        // 重新测量可见条目（10 条气泡 × 每条 5~10 个 Text ≈ 50~100 个文本节点，
        // 一次测量 250~1000ms）。16 次/秒的请求 × 1 秒的成本 = 永远追不上，
        // 主线程饱和 → 表现为「发送后第一次点击就卡死」（STUCK 31648ms mark=body）。
        // 代价：文字成段出现（约 0.35 秒一批），不再逐字蹦。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
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
                // **不要在这里 objectWillChange.send()**。
                // 流式输出时每个 delta 都会走这个 setter，立刻发通知就等于
                // 每秒让所有订阅 AppModel 的视图重算几十次 —— 而数据往往还没变。
                // 通知改由 markCurrentDirty 的节流回调触发：
                // syncCurrentEntries() 里给 @Published currentEntries 赋值时才发。
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
    /// 已处理到的最大事件序号。
    ///
    /// **刻意不是 @Published**：它每个流式帧都在涨（seq 递增），
    /// 之前每帧都发 objectWillChange，等于每秒让所有订阅 AppModel 的视图重算几十次。
    /// 只有设置页要显示它，进设置页时读一次就够，不需要实时刷新。
    private(set) var lastSeq: Int = UserDefaults.standard.integer(forKey: "dsh.lastSeq")
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

    // MARK: - 诊断实验开关（设置页可切，重启保留）
    //
    // 主因已经按真机日志修掉（preference 自激、超长排版、AttributedString 每帧重算）。
    // 剩下两个开关当作逃生阀，也可以在机器上验证残余抖动：
    //   ① 自动跟随：每个 streamTick 都 proxy.scrollTo(bottomAnchor)
    //   ② 文本选择：默认关（见下）
    @Published var expNoAutoFollow = UserDefaults.standard.bool(forKey: "dsh.exp.noAutoFollow") {
        didSet { UserDefaults.standard.set(expNoAutoFollow, forKey: "dsh.exp.noAutoFollow") }
    }
    /// 是否开启气泡文本选择。**默认关闭**。
    ///
    /// `.textSelection(.enabled)` 在 iOS 上给每段文字装一个 UITextInteraction，
    /// 十几条消息 × 每段一个，全都在 LazyVStack 里随重排反复建立/拆除 ——
    /// 这是布局阶段最贵的一块。真机实测关掉后主线程明显轻。需要复制长按文字时再开。
    @Published var expTextSelection = UserDefaults.standard.bool(forKey: "dsh.exp.textSelection") {
        didSet { UserDefaults.standard.set(expTextSelection, forKey: "dsh.exp.textSelection") }
    }

    private var client: BridgeClient?
    private var streamTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// turn.start 的时间，用来在 turn.end 显示"用时 N 秒"
    private var turnStartedAt: [String: Date] = [:]

    /// 会话列表变化时刷新标题标量（标题要单独一个 @Published，
    /// 否则 ChatView 得自己去 sessions 里查，列表一刷新整棵聊天树就重算）
    private var cancellables = Set<AnyCancellable>()

    init() {
        pairing = PairingStore.load()
        sessionList.$rows
            .sink { [weak self] _ in
                // @Published 的 sink 在 willSet 阶段触发，延一拍才能读到新值
                DispatchQueue.main.async { self?.refreshCurrentTitle() }
            }
            .store(in: &cancellables)
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
        // 后台卡死监视器上报要用（非隔离全局，主线程卡住时它照发不误）
        stallWatcher.configure(host: config.host, port: config.port)
        let client = BridgeClient(config: config)
        self.client = client
        do {
            try await client.handshake()
            self.pairing = client.config
            serverInfo = client.serverName
            phase = .connected
            lastError = nil
            // 版本指纹：日志里必须有它，否则分不清手机上跑的是哪一版
            pingDiagnostic("build=\(Self.appVersion)")
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
        sessionList.rows = []
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

    /// 帧应用入口。全程在主线程（本类是 @MainActor）。
    ///
    /// 历史回填会连续调用几百次，实测一口气跑完占主线程 1032ms
    /// （看门狗 `stall=1032ms`，而 /v1/transcript 服务端只用了 25ms），
    /// 所以 loadHistory 里做了分片 + Task.yield，见那里的注释。
    private func apply(seq: Int, frame: [String: Any], isHistory: Bool = false) {
        if seq > lastSeq {
            lastSeq = seq
            // 每 20 帧落一次盘：冷启动时就能从上次的位置续传，
            // 不必把服务端缓冲里的 3000 帧全回放一遍
            if seq % 20 == 0 {
                UserDefaults.standard.set(seq, forKey: "dsh.lastSeq")
            }
        }
        guard let type = frame["type"] as? String else { return }
        // 卡死取证：主线程最后进入的是哪一帧
        stallWatcher.setMark("apply:\(type)")
        let sid = (frame["sessionId"] as? String) ?? selectedSessionId ?? ""
        let turn = (frame["turn"] as? NSNumber)?.intValue ?? 0

        // 运行状态：只看帧类型，不碰内容 —— 未选中的会话也能在列表里显示「在跑」
        switch type {
        case "turn.start", "assistant.delta", "assistant.thinking", "tool.call":
            sessionList.markRunning(sid, true)
        case "turn.end":
            sessionList.markRunning(sid, false)
        default:
            break
        }

        // 没被选中的会话**不落条目**（用户要求：先不加载，点开时再拉历史）。
        // 之前是所有会话的对话都堆在内存里、每个 delta 都可能触发 append 与裁剪，
        // 切会话时两份对话还同时在 body 里被扫描。副作用只有一个：把未读标上。
        if !isHistory, !sid.isEmpty, sid != "pending", sid != selectedSessionId {
            if type == "turn.end", !isHistory {
                unreadSessions.insert(sid)
                Task { await refreshSessions(force: true) }
            }
            return
        }

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
                    // 一轮结束时刷两次：立刻一次、3 秒后再一次（等标题落盘）。
                    // force 是为了绕过 2 秒节流 —— 这两次是刻意的，不是重复请求。
                    await refreshSessions(force: true)
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await refreshSessions(force: true)
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
        stallWatcher.setMark("apply:done")
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

    /// 单会话保留的条目上限。
    ///
    /// 原来给到 600 —— 那意味着 LazyVStack 要维护 600 个条目的布局上下文，
    /// 每次发消息、每次流式刷新都在这个规模上重算，主线程被压住，
    /// 输入法事件排不上队，「打开软件时第一个字母不进拼音」和「发送瞬间卡死」都是它。
    /// 降到 220 后渲染负担约为原来的 1/3，滚动起点也更快。
    private static let maxEntriesPerSession = 80

    /// 满 cap 之后不要每条都裁：裁一次是 O(n) 的全量 filter，而流式输出时
    /// 每个 delta 都会走一遍 append —— 等于每帧一次 220 元素的复制。
    /// 留一截余量（cap + 40）再裁，裁剪次数降到 1/40，内存上限仍然是硬的。
    private static let trimSlack = 40

    /// 历史回填期间关掉逐条裁剪：几百帧连续 append，逐条裁就是 O(n²)。
    /// 回填结束时统一裁一次（见 loadHistory）。
    private var suppressTrim = false

    /// 超过上限就丢最老的，避免长时间使用后内存一直涨。
    /// 必须按 turn 边界裁：直接 suffix 会把「本轮过程 · N 步」这种
    /// 折叠块从中间切开，界面上会露出一半。
    private func trimIfNeeded(_ sessionId: String) {
        guard !suppressTrim else { return }
        let cap = Self.maxEntriesPerSession
        guard let list = entries[sessionId], list.count > cap + Self.trimSlack else { return }
        var keepFrom = 0
        var counted = 0
        for entry in list.reversed() {
            counted += 1
            if counted >= cap {
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
                sessionList.rows = rows.compactMap(SessionRow.parse)
            }
            if let rootsRaw = state["roots"] as? [String] { roots = rootsRaw }
            // 服务端重启后 seq 会从头开始。本地存的上次 seq 如果比服务端还大，
            // 继续带 since=旧值会永远收不到新帧，必须归零重放。
            if let serverSeq = state["lastSeq"] as? NSNumber, serverSeq.intValue < lastSeq {
                lastSeq = serverSeq.intValue
                UserDefaults.standard.set(lastSeq, forKey: "dsh.lastSeq")
            }
            if selectedSessionId == nil { selectedSessionId = sessionList.rows.first?.id }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 会话列表刷新节流：2 秒内只真正拉一次。
    ///
    /// 之前发一条消息会触发 3 处同时刷新（发送后、会话列表、主界面），
    /// 日志里能看到同一秒 5 次 /v1/sessions —— 每次都是 47 条的服务端查询，
    /// 白白多花几倍流量和时间。
    private var lastSessionsFetch: Date = .distantPast
    private var sessionsFetchInFlight = false

    func refreshSessions(force: Bool = false) async {
        guard let client else { return }
        guard !sessionsFetchInFlight else { return }
        if !force, Date().timeIntervalSince(lastSessionsFetch) < 2 { return }
        sessionsFetchInFlight = true
        lastSessionsFetch = Date()
        defer { sessionsFetchInFlight = false }

        // 两个请求并行：串行要 2×RTT（实测 220ms），并行只花一次往返。
        // 这段在主线程上等，直接决定「打字时会不会丢字母」。
        async let mainTask = client.fetchSessions()
        async let archTask = client.sessions(archived: true)
        let mainResult = try? await mainTask
        let archResult = try? await archTask

        if let rows = mainResult?["sessions"] as? [[String: Any]] {
            sessionList.rows = rows.compactMap(SessionRow.parse)
        }
        // 已归档的会话单独一份，列表里给它一个分区
        if let rows = archResult?["sessions"] as? [[String: Any]] {
            sessionList.archived = rows.compactMap(SessionRow.parse)
        }
    }

    /// 取消归档，让会话回到主列表
    func unarchive(_ sessionId: String) async {
        await archive(sessionId, archived: false)
        await refreshSessions()
    }

    /// 临时打点：把耗时发到服务端日志，用来定位「发送瞬间卡死」到底卡在哪一步。
    /// 定位完就删。
    private func trace(_ label: String) {
        pingDiagnostic(label)
    }

    /// 供视图侧打点
    func traceFollow(_ label: String) {
        pingDiagnostic(label)
    }

    /// 主线程看门狗。
    ///
    /// Timer 跑在主线程上：主线程一被占住 Timer 就停跑，
    /// 恢复后间隔会明显变大 —— 这样能直接量出「卡了多久」，
    /// 也能区分「真卡死」和「只是网络慢」。
    ///
    /// 这一版把阈值从 1 秒降到 120ms，并且每 2 秒输出一行窗口统计。
    /// 原因：旧阈值下 2200 行日志只有孤零零一条 `stall=1032ms`，
    /// 所有 100~900ms 的抖动全被吞掉 —— 「有时候卡一下」根本没被量到。
    ///
    /// 判读表：
    /// - 一行 `wd` 都不出现 → 主线程彻底锁死，Timer 停跑（真死锁）
    /// - `gap>120ms:0`、body 也不高 → 主线程干净，卡不在渲染侧
    /// - `gap>120ms:` 有一堆 + `body` 很高 → 失效风暴：每次状态写入都让整棵树重算并重新布局
    /// - `body` 不高但 `max` 很大 → 单次阻塞操作（回填、解析、同步 IO）
    private var watchdogTimer: Timer?

    /// 每个回调各记一次。只累加整数、不发通知，不会引起任何重算。
    func recordBodyEval() { watchdogStats.bodies += 1; watchdogStats.lastTag = "body"; stallWatcher.setMark("body") }
    func recordFollowEvent() { watchdogStats.follows += 1; watchdogStats.lastTag = "follow" }
    func recordSubmitEvent() { watchdogStats.submits += 1; watchdogStats.lastTag = "submit" }

    /// 标记「主线程最后进入了哪条路径」。主线程一旦卡住，后台的 StallWatcher
    /// 会把这个值连同卡了多久一起发出来 —— 这是卡死期间唯一的证据来源。
    func markMain(_ tag: String) { stallWatcher.setMark(tag) }

    /// 起后台卡死监视线程。
    ///
    /// 为什么必须独立线程：主线程上的看门狗在卡死时自己也不跑，两秒才汇总一次，
    /// 结果就是「卡死期间零日志」。这个线程每 100ms 看主线程的心跳有没有动，
    /// 超过 700ms 一动不动就直接用 URLSession 上报（URLSession 走自己的线程）。
    private func startStallWatcher() {
        guard stallWatcher.claimStart() else { return }
        Thread.detachNewThread {
            var lastBeat = -1
            var lastChange = CFAbsoluteTimeGetCurrent()
            var reported = 0.0
            while true {
                Thread.sleep(forTimeInterval: 0.1)
                let snap = stallWatcher.snapshot()
                let now = CFAbsoluteTimeGetCurrent()
                if snap.beat != lastBeat {
                    lastBeat = snap.beat
                    lastChange = now
                    reported = 0
                    continue
                }
                let stuck = now - lastChange
                guard stuck > 0.7, stuck - reported > 0.5 else { continue }
                reported = stuck
                StallWatcher.send(host: snap.host, port: snap.port,
                                  tag: "STUCK \(Int(stuck * 1000))ms mark=\(snap.mark)")
            }
        }
    }

    /// 看门狗。三档输出，频率由高到低：
    ///
    /// - 每拍（0.25s）：只推进后台 StallWatcher 的心跳，不发请求。
    ///   卡死时由那个独立线程上报 `STUCK <ms> mark=<x>`（主线程死了它照样活着）。
    /// - 每 2 秒：**只有真卡顿才说话** —— `wd over=N max=Xms last=<x>`，
    ///   量的是「超出正常周期的部分」（`gap - 0.25s`）。
    /// - 每 10 秒：无条件一行 `hb`，带这一段的回调计数。
    ///   这是给「瞬时卡死来不及被 STUCK 抓到」留的上下文 —— 出问题时能看出
    ///   那段时间 body 求值/跟随/发送各发生了几次、最后动的是谁。
    ///
    /// 正常使用时日志量 ≈ 6 行/分钟（以前是 240 行/分钟）。
    func startWatchdog() {
        guard watchdogTimer == nil else { return }
        startStallWatcher()
        watchdogStats.last = CFAbsoluteTimeGetCurrent()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            // 心跳：后台 StallWatcher 靠它判断主线程还动不动
            stallWatcher.tick()
            let now = CFAbsoluteTimeGetCurrent()
            let overMs = Int((now - watchdogStats.last - 0.25) * 1000)
            watchdogStats.last = now
            if overMs > 120 {
                watchdogStats.stalled += 1
                watchdogStats.worstOver = max(watchdogStats.worstOver, overMs)
            }
            watchdogStats.ticks += 1

            // ① 每 2 秒：只有卡顿才报
            if watchdogStats.ticks % 8 == 0, watchdogStats.stalled > 0 {
                let stalled = watchdogStats.stalled
                let worst = watchdogStats.worstOver
                let tag = watchdogStats.lastTag
                watchdogStats.stalled = 0
                watchdogStats.worstOver = 0
                Task { @MainActor in
                    self?.pingDiagnostic("wd over>120ms:\(stalled) max:\(worst)ms last=\(tag)")
                }
            }

            // ② 每 10 秒：无条件心跳（计数在 10 秒窗口内累计）
            guard watchdogStats.ticks % 40 == 0 else { return }
            let b = watchdogStats.bodies
            let f = watchdogStats.follows
            let s = watchdogStats.submits
            let bubbles = stallWatcher.takeBubbles()
            let worst10 = watchdogStats.worstOver
            let tag = watchdogStats.lastTag
            watchdogStats.bodies = 0
            watchdogStats.follows = 0
            watchdogStats.submits = 0
            watchdogStats.worstOver = 0
            watchdogStats.stalled = 0
            Task { @MainActor in
                self?.pingDiagnostic("hb body=\(b) bubble=\(bubbles) follow=\(f) send=\(s) worst=\(worst10)ms last=\(tag)")
            }
        }
    }

    func send(text: String, mode: SendMode? = nil) async {
        guard let client else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let effective = mode ?? sendMode
        let t1 = CFAbsoluteTimeGetCurrent()
        trace("s0-trim=\(Int((t1 - t0) * 1000))ms")

        busy = true
        defer { busy = false }
        let t2 = CFAbsoluteTimeGetCurrent()
        trace("s1-busy=\(Int((t2 - t1) * 1000))ms")

        let target = selectedSessionId
        let sid = target ?? "pending"
        append(sid, ChatEntry(id: UUID().uuidString, kind: .user, text: trimmed, at: Date()))
        let t3 = CFAbsoluteTimeGetCurrent()
        trace("s2-append=\(Int((t3 - t2) * 1000))ms n=\(entriesStorage[sid]?.count ?? -1)")
        do {
            let result = try await client.sendTask(
                text: trimmed,
                sessionId: target,
                mode: effective == .steer ? "steer" : nil
            )
            let t4 = CFAbsoluteTimeGetCurrent()
            trace("s3-task=\(Int((t4 - t3) * 1000))ms")
            if let newId = result["sessionId"] as? String {
                if selectedSessionId == nil { selectedSessionId = newId }
                if sid != newId, let moved = entries.removeValue(forKey: "pending") {
                    entries[newId, default: []].append(contentsOf: moved)
                }
                let t5 = CFAbsoluteTimeGetCurrent()
                trace("s4-move=\(Int((t5 - t4) * 1000))ms")
                await refreshSessions()
                let t6 = CFAbsoluteTimeGetCurrent()
                trace("s5-refresh=\(Int((t6 - t5) * 1000))ms")
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            append(selectedSessionId ?? "pending", ChatEntry(id: UUID().uuidString, kind: .system, text: "发送失败：\(error.localizedDescription)", at: Date()))
        }
        let tEnd = CFAbsoluteTimeGetCurrent()
        trace("s9-total=\(Int((tEnd - t0) * 1000))ms")
    }

    func newSession() async {
        selectedSessionId = nil
        await refreshSessions()
        if let first = sessionList.rows.first { selectedSessionId = first.id }
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
            if let idx = sessionList.rows.firstIndex(where: { $0.id == sessionId }) {
                sessionList.rows[idx].title = trimmed
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func archive(_ sessionId: String, archived: Bool = true) async {
        guard let client else { return }
        do {
            _ = try await client.archiveSession(sessionId: sessionId, archived: archived)
            sessionList.rows.removeAll { $0.id == sessionId }
            if selectedSessionId == sessionId { selectedSessionId = sessionList.rows.first?.id }
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
    /// limit 从服务端取多少帧；实际留在内存里的条数还要过 220 的修剪。
    func loadHistory(_ sessionId: String, limit: Int = 120) async {
        guard let client, !sessionId.isEmpty else { return }
        historyLoading = true
        defer { historyLoading = false }
        do {
            // 服务端读历史走的是内存快照（session.snapshotEvents）。
            // 如果此刻 DSH 正在往这个会话追加事件，快照会处于中间状态，
            // 它的严格校验会抛出 SessionFormatError（step/start 对不上 open turn）——
            // 这是读写竞态，几秒后自愈，不是数据损坏。
            // 所以这里重试两次，别让用户看到「历史加载失败」这种吓人的东西。
            var raw: [String: Any] = [:]
            var lastError: Error?
            for attempt in 0..<3 {
                do {
                    raw = try await client.transcript(sessionId: sessionId, limit: limit)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < 2 {
                        trace("hist-retry=\(attempt + 1) sid=\(sessionId.suffix(6))")
                        try? await Task.sleep(nanoseconds: 400_000_000)
                    }
                }
            }
            if let lastError { throw lastError }
            guard let frames = raw["frames"] as? [[String: Any]] else { return }
            let started = CFAbsoluteTimeGetCurrent()
            var worstChunkMs = 0
            var chunkStart = started
            // 整段批量写，期间不发变更通知：几百帧就是几百次写入，
            // 逐次通知会让 ChatView 重建几百遍，切会话时手感发钝就是这个原因。
            beginBatch()
            suppressTrim = true          // 逐条裁是 O(n²)：回填期间关掉，收尾统一裁一次
            entries[sessionId] = []
            for (index, frame) in frames.enumerated() {
                // seq 传 0 不推进实时游标；isHistory=true 避免每个 turn.end 都去刷会话列表
                apply(seq: 0, frame: frame, isHistory: true)
                // 每 40 帧让出一次主线程。
                //
                // 实测依据：/v1/transcript 服务端 25ms 就返回 200，
                // 而客户端随后记录到 stall=1032ms —— 这 1 秒全花在这一圈 apply 上，
                // 期间触控事件一条都排不进来。分片 + yield 之后每片只有几十毫秒，
                // 主线程在片与片之间能跑 Timer 和触摸。
                guard index % 40 == 39 else { continue }
                let now = CFAbsoluteTimeGetCurrent()
                worstChunkMs = max(worstChunkMs, Int((now - chunkStart) * 1000))
                await Task.yield()
                chunkStart = CFAbsoluteTimeGetCurrent()
            }
            suppressTrim = false
            trimIfNeeded(sessionId)
            // 历史回填完成后清掉残留的 running。
            // 拉的是最近 N 帧，很可能截在某一轮中间 —— 那些没有 turn.end 收尾的
            // 工具条会永远 running=true，界面上永远转着「进行中」。
            if var list = entriesStorage[sessionId] {
                var changed = false
                for i in list.indices where list[i].running {
                    list[i].running = false
                    changed = true
                }
                if changed { entriesStorage[sessionId] = list }
            }
            endBatch()
            let totalMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            trace("hist n=\(frames.count) total=\(totalMs)ms worstChunk=\(worstChunkMs)ms")
            historyNote = raw["note"] as? String
            // 通知界面：历史重建完成，可以滚到底了
            historyVersion &+= 1
        } catch {
            suppressTrim = false
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
    /// CI 注入的版本指纹（CFBundleShortVersionString = git 短 sha，
    /// CFBundleVersion = run 号）。日志里看 `build=xxxxxxx.42` 就知道装的是哪一版。
    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(short).\(build) os=\(os.majorVersion).\(os.minorVersion)"
    }

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

// MARK: - 看门狗计数器（文件级，非隔离）

/// 看门狗要用的几个数字。
///
/// 为什么单独放一个普通 class：`Timer.scheduledTimer` 的闭包是**非隔离**上下文，
/// 直接读写 `@MainActor` 类上的属性，编译器会一条一条报 main actor-isolated 警告
/// （上一版一次就多了 11 条，把真正该看的警告淹掉了）。
/// 这些数字本来就只由主线程读写，装进一个非隔离的引用类型就够了。
private final class WatchdogStats {
    var last: CFAbsoluteTime = 0
    var ticks = 0
    /// 超出正常 Timer 周期的时间（毫秒累加口径见 watchdog：gap - 0.25s）
    var stalled = 0
    var worstOver = 0
    // 活动计数：谁在疯跑，就看这几个数在哪个回调里涨
    var bodies = 0
    var follows = 0
    var submits = 0
    /// 最近一次活动来自哪个回调
    var lastTag = "-"
}

/// 文件级全局（非隔离）：Timer 闭包与 AppModel 都能直接访问
private let watchdogStats = WatchdogStats()

/// 主线程卡死监视器（后台线程读它、上报它）。
///
/// 所有观测手段都挂在主线程上时，卡死期间一定是零日志。所以心跳、标记、上报
/// 全部走不依赖主线程的路径：心跳由主线程 Timer 递增，检查与上报由独立 Thread 完成。
///
/// ⚠️ 这里的状态被**两个线程**同时访问（主线程写、监视线程读），所以一律藏在
/// 一把锁后面。第一版直接暴露 `var mark: String` 给两边用 —— String 是引用计数
/// 类型，主线程每拍赋值、后台每 100ms 读取，无同步就是典型的
/// 「读到已释放的 buffer」→ EXC_BAD_ACCESS 闪退（真机上正是这个症状）。
final class StallWatcher {
    private let lock = NSLock()
    private var beatValue = 0
    private var markValue = "-"
    private var hostValue = ""
    private var portValue = 0
    private var startedValue = false
    /// 气泡 body 求值次数（用来区分「单次布局慢」和「重算风暴」）
    private var bubbleValue = 0

    func tick() {
        lock.lock()
        beatValue &+= 1
        lock.unlock()
    }

    func tickBubble() {
        lock.lock()
        bubbleValue += 1
        lock.unlock()
    }

    func takeBubbles() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let v = bubbleValue
        bubbleValue = 0
        return v
    }

    func setMark(_ text: String) {
        lock.lock()
        markValue = text
        lock.unlock()
    }

    func configure(host: String, port: Int) {
        lock.lock()
        hostValue = host
        portValue = port
        lock.unlock()
    }

    /// 一次性取快照，避免多次加锁之间状态变化
    func snapshot() -> (beat: Int, mark: String, host: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (beatValue, markValue, hostValue, portValue)
    }

    /// 只让第一个调用者启动监视线程
    func claimStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if startedValue { return false }
        startedValue = true
        return true
    }

    /// 非隔离上报：主线程卡死时它照样能发出去
    nonisolated static func send(host: String, port: Int, tag: String) {
        guard !host.isEmpty, port > 0,
              let escaped = tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "http://\(host):\(port)/v1/health?d=\(escaped)") else { return }
        URLSession.shared.dataTask(with: url).resume()
    }
}

let stallWatcher = StallWatcher()

