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

    @Published private(set) var phase: Phase = .disconnected {
        didSet { scheduleBannerUpdate() }
    }

    /// 断线横幅是否显示。
    ///
    /// 不能直接绑 `phase != .connected`：重连循环里 phase 会反复
    /// failed → connected → failed（每次尝试都先置 failed），
    /// 横幅跟着闪烁，用户看到「未连接」在反复刷新（用户实拍确认）。
    /// 这里做 1.5 秒防抖：只有断线持续到这个时长才真的弹横幅。
    @Published private(set) var showDisconnectBanner = false
    private var bannerTask: Task<Void, Never>?

    private func scheduleBannerUpdate() {
        bannerTask?.cancel()
        if phase == .connected || suppressDisconnect {
            if showDisconnectBanner { showDisconnectBanner = false }
            return
        }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.phase != .connected, !self.suppressDisconnect {
                self.showDisconnectBanner = true
            }
        }
    }
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
    /// 聊天数据（条目 / 流式心跳 / 生成状态 / 历史版本）搬到了独立 store，
    /// 否则 ChatView 会因为 @EnvironmentObject 全量订阅，每 350ms 白重算一次。
    let chat = ChatStore()
    /// 当前会话内容的变化计数。
    ///
    /// 自动跟随靠它触发，而不是监听 `entries.last?.text`：
    /// 最后一条若是 thinking 或工具行，文本不变但高度在长，
    /// 只看 text 就会漏掉，位置掉队后 atBottom 判为 false，跟随彻底停摆。
    /// 当前会话是否正在生成（turn.start ~ turn.end）。
    ///
    /// 用途：流式期间 ChatView 改用「极简渲染」——只画纯文本、不画 markdown/图片/按钮。
    /// 因为这台设备上 LazyVStack + 富文本单次布局就要几百毫秒，
    /// 而流式每秒触发多次重排，无论单段优化到多便宜都会饱和（实测 b:sys 也能卡 14 秒）。
    /// 只在 true/false 翻转时写，不会造成额外通知。
    /// 历史重建完成的计数。界面靠它决定「该滚到底了」——
    /// 回填时底部哨兵还没渲染，proxy.scrollTo 找不到目标，
    /// 所以必须等渲染完再滚，否则冷启动会停在最早的消息上。

    /// 手指在滚动/惯性期间不更新列表（由 View 层通过 onScrollPhaseChange 设置）。
    /// 拖动时每来一帧就重排列表，滚动必然卡死 —— 等手停下来再补
    /// （实测拖动卡死 14900ms，mark=apply:done，即卡在应用帧这一步）。
    private var suppressEntriesUntil: CFAbsoluteTime = 0

    func setSuppressEntries(_ seconds: Double) {
        suppressEntriesUntil = CFAbsoluteTimeGetCurrent() + seconds
    }

    /// 滚动停稳后调用：把滚动期间积压的更新立刻补上
    func resumePendingSync() {
        pendingSync = false
        syncCurrentEntries()
    }

    private func syncCurrentEntries() {
        stallWatcher.setMark("sync")
        // 滚动中：延后，别打断手感
        if CFAbsoluteTimeGetCurrent() < suppressEntriesUntil {
            scheduleSync(after: 0.25)
            return
        }
        pendingSync = false
        let next = selectedSessionId.flatMap { entriesStorage[$0] } ?? []
        // 整数组比较：只比 count / last 会漏掉「中间某条在变」的情况，
        // 那正是跟随失效的原因之一。ChatEntry 实现了 ==，逐项比较很快。
        chat.setEntries(next)
        chat.bumpTick()
    }

    /// 标记「当前会话内容可能变了」。
    ///
    /// 不立即同步：流式输出每秒二三十个 delta，每次都做一遍 O(n) 数组比较
    /// （元素里有多个 String 字段）会把主线程压死 —— 这是这一轮卡死的第二个原因。
    /// 攒到 60ms 再一次性比对，视觉上完全无感，开销降到原来的 1/5。
    private func scheduleSync(after delay: Double) {
        guard !pendingSync else { return }
        pendingSync = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.syncCurrentEntries()
        }
    }

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
    /// ComfyUI 状态搬到独立 store：它 8 秒轮询一次，
    /// 留在 AppModel 里会让 ChatView（订阅整个 model）跟着重算。
    let comfyStore = ComfyStore()
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
    /// 富文本（markdown）总开关。**默认开启**。
    ///
    /// 曾经默认关闭，是因为当时渲染是「一条消息 N 个 SwiftUI Text」，
    /// 打开就会卡死。现在渲染管道换成了「一个 cell = 一个 UITextView = 一个
    /// NSAttributedString」，且行内富化改成扫描式分段（零 NSRange 替换、已被
    /// selftest 覆盖），打开是安全的。
    ///
    /// 保留开关作为逃生阀：万一某条特殊内容把渲染拖慢，可以一键退回纯文本。
    /// 注意 UserDefaults 里已存的值优先（老用户仍是关闭状态，需要手动打开）。
    @Published var richTextEnabled = UserDefaults.standard.object(forKey: "dsh.richText") as? Bool ?? true {
        didSet { UserDefaults.standard.set(richTextEnabled, forKey: "dsh.richText") }
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

    /// 本轮的「输出文件」提示先攒着，等 turn.end 统一落到列表末尾。
    /// 用户要求：产物提示跟着当轮走，不要夹在工具行中间（那样像日志噪声）。
    private var pendingFileHints: [String: [(path: String, at: Date, turn: Int)]] = [:]

    /// 每个 (会话, 轮次) 的「顺序时钟」，见 append 里的说明。
    private var turnClock: [String: Date] = [:]

    /// 把攒着的产物提示写进列表。
    ///
    /// 位置由**插入顺序**决定（append 里对同一 turn 做单调时钟），
    /// 所以只要在合适时机调用即可：
    ///   - 实时：turn.end 里调用（在「本轮结束」之前）
    ///   - 历史回放：这一页加载完后调用（有些轮次的 turn.end 不在本页）
    private func flushFileHints(_ sessionId: String, turn only: Int? = nil, except: Int? = nil) {
        guard var hints = pendingFileHints[sessionId], !hints.isEmpty else { return }
        let ready = hints.filter { hint in
            if let only, hint.turn != only { return false }
            if let except, hint.turn == except { return false }   // 还在跑的那一轮先不落位
            return true
        }
        guard !ready.isEmpty else { return }
        hints.removeAll { h in ready.contains { $0.path == h.path && $0.turn == h.turn } }
        pendingFileHints[sessionId] = hints.isEmpty ? nil : hints

        for hint in ready {
            append(sessionId, ChatEntry(
                id: "\(sessionId)#file\(hint.turn)_\(hint.path)",
                kind: .fileOutput,
                text: "📄 输出文件 · \(Self.fileName(hint.path))",
                detail: hint.path,
                at: Date(),
                turn: hint.turn
            ))
        }
    }

    /// 取文件名：按 **/ 和 \ 两种分隔符**切（NSString.lastPathComponent 只认 "/"，
    /// Windows 路径 D:\a\b.md 会整条返回，提示里就是一大串全路径）。
    static func fileName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? path
    }

    /// 一轮里的「第几段回答」。
    ///
    /// 插队（steer）在 DSH 里是把消息塞进**当前轮的下一步**，所以插队那条的
    /// 回答和本轮前面的回答共用同一个 `turn`。原来气泡 id 固定是 `sid#ans<turn>`，
    /// 两段文本会被拼进**同一个**气泡，而那个气泡在插队消息**上方** ——
    /// 表现就是「插队执行成功了，但手机端看不到它的输出」（用户实拍）。
    ///
    /// 分隔点取「每来一条 user.message 就开新段」：插队回显正好是一条
    /// `user/message`（见 22:57:57 的 `USER『报这个 …』`），后续 delta 因此落到
    /// 新的气泡 id 上，自然排在插队消息下面。
    private var answerSegment: [String: Int] = [:]

    /// 每个会话当前所在的轮次。
    ///
    /// 有些帧（尤其 user/message）不带 turn，靠它把轮次补齐 ——
    /// 否则这些条目 turn=0，排序时永远排在最前。
    private var currentTurn: [String: Int] = [:]

    /// 当前轮的回答段落号（0 是本轮第一段）
    private func segmentNow(_ sessionId: String) -> Int {
        answerSegment[sessionId] ?? 0
    }

    /// 开新一段回答
    private func advanceSegment(_ sessionId: String) {
        answerSegment[sessionId] = (answerSegment[sessionId] ?? 0) + 1
    }

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

    /// 前后台切换时的连接处理。
    ///
    /// 为什么需要它：App 进后台后系统会挂起/断开 SSE，回到前台时
    /// `phase` 仍是 `.connected` 但流已经死了，界面上表现为「未连接」却又不会自动恢复。
    /// 这里按当前状态分别处理：
    /// - 已连接 → 重启事件流（旧的多半已断）并补一次状态
    /// - 连接中 → 等它自己出结果
    /// - 其余（失败/断开）→ 重新连接
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // 主动停掉流，避免后台被系统拒绝后再带着一堆错误重连
            streamTask?.cancel()
            // 但状态必须一起改：之前只取消流、phase 仍留在 .connected，
            // 于是后台期间界面写着「已连接」，实际一个帧都收不到
            // （用户实测：「显示已连接但收不到消息」）。
            // 注意：这个函数的参数也叫 phase（ScenePhase），
            // 所以必须写 self.phase —— 否则是在给 let 参数赋值。
            if self.phase == .connected { self.phase = .disconnected }
            // 回前台的头几秒不弹断线横幅 —— 那是误报
            suppressDisconnect = true
        case .active:
            guard pairing != nil else { return }
            Task { [weak self] in
                guard let self else { return }
                switch self.phase {
                case .connected:
                    self.startStream()
                    await self.refresh()
                case .connecting:
                    break
                default:
                    await self.reconnect()
                }
            }
        default:
            break
        }
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
                // 追踪：SSE 从 06:35 之后就再没连上过，但 health 一直正常，
                // 手机以为自己是连着的。要看清是哪一步退出了循环。
                self.trace("stream.attempt=\(attempt)")
                guard let client = self.client else {
                    self.trace("stream.exit:no-client")
                    return
                }
                let since = self.lastSeq
                self.trace("stream.connecting since=\(since)")
                do {
                    try await EventStream.run(client: client, since: since) { [weak self] seq, frame in
                        Task { @MainActor in self?.apply(seq: seq, frame: frame) }
                    }
                } catch {
                    if Task.isCancelled {
                        self.trace("stream.exit:cancelled")
                        return
                    }
                    self.trace("stream.error=\(error.localizedDescription.prefix(60))")
                    self.phase = .failed(error.localizedDescription)
                }
                self.trace("stream.ended attempt=\(attempt)")
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
        // user/message 帧里 DSH 经常不带 turn（插队回显就是这种：22:57:57 那条
        // `USER『报这个 …』` 的 data 里没有 turn）。原来一律落到 0，而 0 在
        // 「按 turn 排序」里永远排最前 —— 上拉加载更早之后，提问就会跑到整屏最上面。
        // 没带 turn 就用当前轮的轮次补上。
        let frameTurn = (frame["turn"] as? NSNumber)?.intValue ?? 0
        let turn = frameTurn > 0 ? frameTurn : (currentTurn[sid] ?? 0)

        // 运行/流式状态：**只认实时帧**。
        //
        // 用户实拍：上翻历史时点开另一个会话，列表里好几个会话都挂着「正在处理」的
        // 小转圈（10 分钟前、8 小时前那些早就结束的）。原因是回填历史帧时这些
        // 状态也照样被写：一页 120 帧里有 turn.start / tool.call 却没有对应的
        // turn.end，于是 running 被置 true 后再也不会被清掉。
        // 历史帧只用来建条目，不能改"谁在跑"。
        if !isHistory {
            switch type {
            case "turn.start", "assistant.delta", "assistant.thinking":
                chat.setStreaming(true)
            case "turn.end":
                chat.setStreaming(false)
            default:
                break
            }

            switch type {
            case "turn.start", "assistant.delta", "assistant.thinking", "tool.call":
                sessionList.markRunning(sid, true)
            case "turn.end":
                sessionList.markRunning(sid, false)
            default:
                break
            }
        }

        // 队列帧要在会话过滤**之前**处理。
        // 原因：agent/inbox/spliced 的 data 里不一定带 sessionId，
        // 落到下面的 sid 比较就会不匹配、被 return 掉 —— 表现就是
        // 电脑端明明在排队，手机队列区却一直是空的（用户实测）。
        if type == "queue.changed" {
            let target = (frame["target"] as? String) ?? ""
            let start = (frame["start"] as? NSNumber)?.intValue ?? 0
            let removed = (frame["removed"] as? NSNumber)?.intValue ?? 0
            let rawItems = (frame["items"] as? [[String: Any]]) ?? []
            let items = rawItems.map { row in
                QueueItem(
                    id: (row["id"] as? String) ?? "",
                    rpcId: (row["rpcId"] as? String) ?? "",
                    text: (row["text"] as? String) ?? ""
                )
            }
            chat.applyQueueChange(target: target, start: start, removed: removed, items: items)
            // 真·排队时，把本地那条「乐观插入」的气泡撤掉。
            //
            // 起因（用户实拍）：发送时界面判断「不忙」→ 本地先插了一条气泡；
            // 而 DSH 那边其实还在跑（一轮里有工具调用的阶段，最后一条 assistant
            // 的 running 已经翻 false），于是这条被真的排进队列 ——
            // 结果同一条消息「既在队列里、又在对话里」。
            //
            // 队列区本来就会显示它，所以这里删掉气泡，和「排队只在队列里显示」一致。
            if target == "next-turn", !items.isEmpty {
                for item in items {
                    guard let list = entriesStorage[sid], !list.isEmpty else { break }
                    if let idx = list.lastIndex(where: { candidate in
                        candidate.id.hasPrefix("local-") && BubbleIds.matchesQueueItem(item.text, candidate.text)
                    }) {
                        entriesStorage[sid]?.remove(at: idx)
                        trace("queue.drop-local sid=\(sid.suffix(6)) q=\(chat.queue.count)")
                    }
                }
            }
            // 追一段：手机队列区一直不显示，需要确认这一帧到底有没有到、
            // 解析出几条、处理后队列里有几条。
            trace("q.changed t=\(target) s=\(start) r=\(removed) n=\(items.count) q=\(chat.queue.count)")
            return
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
            // 记下当前轮：后面不带 turn 的帧（插队回显等）要靠它补齐
            currentTurn[sid] = turn
            // 新一轮从第 0 段开始；插队会把它往后推
            answerSegment[sid] = 0
            append(sid, ChatEntry(id: "\(sid)#turn\(turn)", kind: .system, text: "开始第 \(turn) 轮", at: startedAt, running: true, turn: turn))

        case "assistant.thinking":
            let text = (frame["text"] as? String) ?? ""
            upsertStreaming(sid, id: BubbleIds.thinking(sid, turn: turn, segment: segmentNow(sid)), kind: .thinking, delta: text, header: "", turn: turn, at: Self.frameDate(frame))

        case "assistant.delta":
            let text = (frame["text"] as? String) ?? ""
            // 带段落号：插队后同一 turn 的新回答另起一条，否则会拼回插队消息上方的旧气泡
            upsertStreaming(sid, id: BubbleIds.answer(sid, turn: turn, segment: segmentNow(sid)), kind: .assistant, delta: text, header: "", turn: turn, at: Self.frameDate(frame))

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
                // 同样用帧时间：Date() 在续传/回填时是「现在」，
                // 会把工具行排到同一轮正文的后面（用户实拍）。
                at: Self.frameDate(frame),
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

        case "file.output":
            // 产出了文件（docx / pptx / pdf / ipa / zip …）。
            // 图片和视频手机能直接预览，这类不行 —— 以前用户完全看不到
            // 「电脑那边写了什么文件」。
            //
            // 位置：**一律先攒着**，由调用方在「这一轮结束」时 flush：
            //   - 实时 → turn.end
            //   - 历史回放 → 这一页加载完（老轮次的 turn.end 可能不在本页）
            // 两种路径走同一套逻辑，位置只由插入顺序决定（append 里的本轮时钟），
            // 不依赖帧时间戳 —— 那正是之前"重载后卡片跑到正文上方"的根因。
            let path = (frame["path"] as? String) ?? ""
            guard !path.isEmpty else { return }
            var hints = pendingFileHints[sid] ?? []
            if !hints.contains(where: { $0.path == path && $0.turn == turn }) {
                hints.append((path: path, at: Self.frameDate(frame), turn: turn))
            }
            pendingFileHints[sid] = hints

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
            // 顺序很重要：先折叠过程拿到步数，再写「本轮结束」那一行，
            // 这样步数能直接并进同一条系统行里（用户要求「本轮步数位置改成
            // 和本轮同时一起」—— 之前是「本轮结束 · 用时 N 秒」和
            // 「本轮过程 · M 步」分成两行，看着散）。
            let foldedSteps = foldSteps(sid, turn: turn)
            // 产物提示落在本轮末尾（结束行之前），别夹在工具行中间
            flushFileHints(sid, turn: turn)
            var endText = elapsed.isEmpty ? label : "\(label) · \(elapsed)"
            if foldedSteps > 0 { endText += " · \(foldedSteps) 步" }
            append(sid, ChatEntry(
                id: "\(sid)#end\(turn)",
                kind: .system,
                text: endText,
                // 用帧里的时间，不用 Date()：回填/续传时 Date() 是「现在」，
                // 和工具行、正文的时间轴对不上，按 at 排序会把顺序搞乱
                // （用户实拍：上一轮的回答下面又冒出了上一轮的工具行）。
                at: Self.frameDate(frame),
                // turn 必须带上：不带就是 0，而「按 (turn, at) 排序」会把 0 排到最前
                // —— 「开始第 N 轮 / 本轮结束 / 我的提问」就是这么从原位消失、
                // 跑到整屏最上面的（用户实拍两轮回答之间只剩折叠块）。
                turn: turn
            ))
            for key in entries.keys {
                guard var list = entries[key] else { continue }
                for i in list.indices where list[i].running { list[i].running = false }
                entries[key] = list
            }
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
                // 后台任务的完成通知也是 user/message：
                //   background job pwsh-… (pwsh: …) finished [status: completed, exit code: 1].
                //   Read its output with job_output.
                // 以前会整段显示成一个「我」的气泡（用户实拍 23:25）。桥已经过滤，
                // 这里再挡一次：桥要重启 DSH 才换新代码，App 不能指望它。
                || text.hasPrefix("background job ")
                || text.contains("Read its output with job_output")
                || text.contains("[status: completed, exit code:")
                || text.contains("[status: failed, exit code:")
                || text.hasPrefix("agent/inbox")
            guard !injected else { return }
            // 每来一条真正的用户消息就开新一段回答：插队（next-step）就是靠这个
            // 把「插队那条的输出」从上一个气泡里分出来，落到自己下面。
            advanceSegment(sid)
            // 去重：send() 已经本地乐观插入过同一条，服务端回显时不能再插一次。
            //
            // ① 首选：找本地那条 local- 前缀且文本相同的，直接替换成服务端的正式 id。
            //    不设时间窗 —— 排队时服务端可能几十秒后才回显，用 15 秒窗口会漏。
            //    比较用 sameMessage 归一化：插队占位存的是队列项原文，服务端回显
            //    可能多出 `[附件] …` 之类的装饰，直接 == 会匹配不上，
            //    占位就一直挂着「▍我 · 已插队，等当前任务完成」。
            if let idx = entries[sid]?.lastIndex(where: { $0.id.hasPrefix("local-") && Self.sameMessage($0.text, text) }) {
                var item = entries[sid]![idx]
                item.running = false
                item.queued = false
                // steering 也要清 —— 上一版只清了 queued，
                // 插队那条执行完之后「▍我 · 已插队，等当前任务完成」一直挂着
                // （用户实拍：标还在气泡里没删）。
                item.steering = false
                entries[sid]![idx] = item
                return
            }
            // ② 兜底：万一 local- 那条已经被别的路径消费掉（例如切会话重载），
            //    再用「文本相同 + 近距离」判断一次。
            let recent = entries[sid]?.suffix(3) ?? []
            let duplicated = recent.contains { item in
                item.kind == .user
                    && Self.sameMessage(item.text, text)
                    && abs(item.at.timeIntervalSinceNow) < 15
            }
            guard !duplicated else { return }
            // 帧时间而不是 Date()：回填时所有条目都用 Date() 会挤在同一毫秒，
            // 按 at 排序就退化成插入顺序（历史里提问/回答会错位）。
            // turn 也要带：0 会被排序推到最前面。
            append(sid, ChatEntry(id: UUID().uuidString, kind: .user, text: text, at: Self.frameDate(frame), turn: turn))

        default:
            break
        }
        stallWatcher.setMark("apply:done")
    }

    /// 轮询 ComfyUI 状态。实现搬到了 ComfyStore（它自己管 8 秒循环与去重），
    /// 这里只把「怎么取数据」注入进去 —— 因为只有 AppModel 持有 client。
    func startComfyPolling() {
        comfyStore.start { [weak self] in
            guard let client = self?.client else { return nil }
            return try? await client.comfyStatus()
        }
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
        // 同 id 就替换：历史回填与实时帧会给出同一个 id（如 sid#turn5），
        // 重复插入会让列表侧的去重/快照处理变复杂，也会在界面上显示两条「开始第 N 轮」。
        if let idx = entries[sessionId]?.firstIndex(where: { $0.id == item.id }) {
            entries[sessionId]?[idx] = item
            trimIfNeeded(sessionId)
            return
        }
        // ── 本轮内的顺序时钟 ───────────────────────────────────────────
        // 排序键是 (turn, at)。**同一个 turn 内，显示顺序必须等于插入顺序**：
        // 历史回放的帧时间和实时帧时间不可比（回放时 assistant 消息的时间戳
        // 往往晚于同一轮的工具帧），光靠帧时间会让同一轮里的条目互相插队 ——
        // 用户多次实拍：重新加载会话后「📄 输出文件」跑到正文上方。
        // 所以在唯一入口这里做单调递增：插入顺序即显示顺序。
        let clockKey = "\(sessionId)#\(item.turn)"
        if let last = turnClock[clockKey] {
            if item.at <= last {
                item.at = last.addingTimeInterval(0.001)
            }
            turnClock[clockKey] = item.at
        } else {
            turnClock[clockKey] = item.at
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
    /// 每个会话保留的最大条目数。
    ///
    /// 原来是 80 —— 而 loadOlder 一次就往头部插 300 帧（约 40~90 条），
    /// 插进去立刻又被 trimIfNeeded 从头部裁掉，等于白拉。
    /// 现在放到 300：初始 400 帧约合 100 条消息，加上一两次上拉正好够，
    /// 超出 340（cap + trimSlack）才开始裁头部。
    private static let maxEntriesPerSession = 300
    /// 满 cap 之后不要每条都裁：裁一次是 O(n) 的全量 filter，而流式输出时
    /// 每个 delta 都会走一遍 append —— 等于每帧一次 220 元素的复制。
    /// 留一截余量（cap + 40）再裁，裁剪次数降到 1/40，内存上限仍然是硬的。
    private static let trimSlack = 40

    /// 一页最多多少帧（初始加载 / 上拉各一个）。
    ///
    /// **单位是帧，不是消息**，一条消息约 3~8 帧。实测：
    /// - 400 帧（≈50~120 条）一次灌进列表，上划明显卡顿（用户实拍）
    /// - 300 帧同样能感觉到顿
    /// - 200 / 120 顺，代价是多拉一次
    /// 这里做成硬上限：调用方传多大都钳住，避免「把容量调大」再把卡顿调回来。
    static let historyPageLimit = 200
    static let olderPageLimit = 120

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
    /// 把本轮的思考/工具调用折成一行，返回折叠了几步（0 表示没折）。
    /// 返回步数是为了让「本轮结束」那一行能带上它 —— 用户要求
    /// 「本轮步数位置改成和本轮同时一起」，即合并成一条系统行。
    @discardableResult
    private func foldSteps(_ sessionId: String, turn: Int) -> Int {
        guard var list = entries[sessionId] else { return 0 }
        let processKinds: Set<ChatEntry.Kind> = [.thinking, .toolCall]
        let stepIndexes = list.indices.filter {
            processKinds.contains(list[$0].kind) && list[$0].turn == turn
        }
        guard stepIndexes.count >= 3, let firstIdx = stepIndexes.first else { return 0 }

        let foldedEntries = stepIndexes.map { list[$0] }
        let fold = ChatEntry(
            id: "\(sessionId)#fold\(turn)",
            kind: .collapsedSteps,
            text: "本轮过程 · \(foldedEntries.count) 步",
            detail: nil,
            // 折叠块要留在「第一次出现的过程条目」那个时间点上，
            // 否则按 at 排序时会跑到本轮正文后面去。
            at: foldedEntries.first?.at ?? Date(),
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
        return foldedEntries.count
    }

    private func upsertStreaming(_ sessionId: String, id: String, kind: ChatEntry.Kind, delta: String, header: String, turn: Int = 0, at: Date = Date()) {
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
            at: at,
            running: true,
            turn: turn
        ))
    }

    /// 判断两条用户消息是不是同一条（用于替换本地乐观插入的占位）。
    ///
    /// 实现搬到 Core/BubbleIds.swift（纯 Foundation，本机可编译可测）。
    static func sameMessage(_ a: String, _ b: String) -> Bool {
        BubbleIds.sameMessage(a, b)
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

    /// - Parameter localEcho: 是否本地乐观插入。
    ///   排队时不插 —— 和电脑端一致：排队只在队列里显示，等真正开始执行才进对话。
    func send(text: String, mode: SendMode? = nil, localEcho: Bool = true) async {
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
        // local- 前缀标记「这条是我本地乐观插入的」：服务端回显时要替换它，
        // 而不是再插一条。靠 id 前缀识别比靠「文本 + 15 秒时间窗」可靠 ——
        // 排队场景下服务端可能要等几十秒才回显，时间窗一过就变成两条重复。
        //
        // 排队时不插：电脑端排队也不进对话框（只在队列里），
        // 手机上做本地插入会造成「手机有、电脑没有」的差异（用户反馈）。
        if localEcho {
            append(sid, ChatEntry(id: "local-\(UUID().uuidString)", kind: .user, text: trimmed, at: Date(), queued: true))
        }
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
    /// 「上拉加载更早」的状态：已加载条数 / 是否还有更早 / 是否正在加载
    @Published private(set) var olderHasMore = false
    @Published private(set) var olderLoading = false
    private var olderBefore: [String: Int] = [:]

    /// 加载更早的消息（QQ 式上拉）。
    /// 服务端按 before（已加载条数，从尾部往前数）分页返回。
    // 300 帧在上划明显卡顿，收到 120。宁可多拉两次，也要手感顺。
    func loadOlder(_ sessionId: String, limit: Int = 120) async {
        guard let client, !sessionId.isEmpty, !olderLoading else { return }
        // 同样钳住：上拉一页最多 olderPageLimit 帧（≈30~40 条），
        // 否则一次往头部插太多，滚动会顿（用户实拍：容量调大后上划卡顿）。
        let page = BubbleIds.pageSize(limit, cap: Self.olderPageLimit)
        olderLoading = true
        defer { olderLoading = false }
        // 用服务端给的 nextBefore，**不能**用条目数 ——
        // 一个条目可能由多个帧合成，两个数字对不上会导致重复拉取
        // （用户实拍：同一条消息被插了三次）。
        //
        // 游标只在 loadHistory 里记录。如果这次会话没走过 loadHistory
        // （比如内容是从别处恢复的），olderBefore 就是空的 ——
        // 之前直接 return，表现就是「往上拉完全没反应」。
        // 现在先补一次完整加载拿到游标，再继续。
        var cursor = olderBefore[sessionId]
        if cursor == nil {
            // 只为拿游标 —— **不能**在这里调 loadHistory。
            //
            // loadHistory 会把 entries 整个重置成「最近 200 帧」再回放。
            // 一长轮次（工具调用多、回答长）的帧数轻松上百，200 帧只覆盖到
            // 这一轮的后半段 —— 于是「开始第 N 轮」「我的提问」「本轮结束」
            // 这些行被整段截掉。用户实拍：上拉到顶再跳回底部，中间内容缺了。
            // 这里只要 nextBefore，读一次不落盘。
            if let raw = try? await client.transcript(sessionId: sessionId, limit: page),
               let next = (raw["nextBefore"] as? NSNumber)?.intValue {
                olderBefore[sessionId] = next
                cursor = next
            }
            if cursor == nil { trace("older-cursor-missing sid=\(sessionId.suffix(6))") }
        }
        guard let before = cursor else {
            trace("older-no-cursor sid=\(sessionId.suffix(6))")
            return
        }
        do {
            let raw = try await client.transcript(sessionId: sessionId, limit: page, before: before)
            guard let frames = raw["frames"] as? [[String: Any]], !frames.isEmpty else {
                trace("older-empty hasMore=\(raw["hasMore"] ?? "?")")
                olderHasMore = false
                return
            }
            trace("older-frames=\(frames.count) page=\(page) hasMore=\(raw["hasMore"] ?? "?")")
            olderHasMore = (raw["hasMore"] as? Bool) ?? false
            if let next = (raw["nextBefore"] as? NSNumber)?.intValue {
                olderBefore[sessionId] = next
            }
            // 历史帧按顺序应用，插到已有条目的**前面**。
            // 不能「清空 → apply → 拼回去」：apply 里带 foldSteps / syncCurrentEntries
            // 等副作用，而且一旦 before 算错就会把已加载的帧再插一遍
            // （用户实拍：同一条消息出现三次）。
            let existing = entriesStorage[sessionId] ?? []
            let existingIds = Set(existing.map(\.id))
            // 回放这一页帧时：不再逐帧通知界面、也不逐帧裁。
            // 120 帧 × 每帧 append → markCurrentDirty / trimIfNeeded，
            // 上拉时会连续触发好几次全量 sync（用户反馈「上划手感怪」）。
            // 和 loadHistory 用同一套批量写，收尾统一刷新一次。
            beginBatch()
            suppressTrim = true
            entriesStorage[sessionId] = []
            for frame in frames {
                let seq = (frame["seq"] as? NSNumber)?.intValue ?? 0
                apply(seq: seq, frame: frame, isHistory: true)
            }
            suppressTrim = false
            // 只保留「已有条目里没有的」新条目，按 id 去重兜底
            // 只保留已有条目里没有的（按 id）；但 id 可能变 ——
            // 用户刚发的消息本地是 local-xxx，服务端回显时换成正式 id，
            // 这时按 id 去重会漏掉，那条会被当成「历史」插到最前面，
            // 表现为「回答先于提问出现」（用户实拍）。
            //
            // 所以再做一次按文本的去重，最后**按 turn 排序**收口：
            // 顺序由服务端轮次号决定，不依赖拼接顺序。
            let existingTextTurns = Set(existing.map { "\($0.turn)|\($0.text.prefix(40))" })
            let fresh = (entriesStorage[sessionId] ?? []).filter { item in
                if existingIds.contains(item.id) { return false }
                let key = "\(item.turn)|\(item.text.prefix(40))"
                return !existingTextTurns.contains(key)
            }
            var merged = fresh + existing
            merged.sort { a, b in
                if a.turn != b.turn { return a.turn < b.turn }
                return a.at < b.at
            }
            entriesStorage[sessionId] = merged
            // 观察点：合并后条目反而变少，说明这一页把已有内容覆盖掉了
            // （历史上的「跳到底部内容缺失」就是这类）。
            if merged.count < existing.count {
                trace("older.shrink from=\(existing.count) to=\(merged.count) page=\(frames.count)")
            }
            trimIfNeeded(sessionId)
            // 这一页里攒下的产物提示就地落位（老轮次的 turn.end 往往不在本页）。
            // append 会对同一 turn 做单调时钟，所以它们仍落在各自那一轮的末尾。
            // except：正在跑的那一轮不提前落位（它自己的 turn.end 会处理）。
            flushFileHints(sessionId, except: currentTurn[sessionId])
            endBatch()
        } catch {
            trace("older-failed=\(error.localizedDescription.prefix(40))")
        }
    }

    // limit 的单位是**帧**，不是消息。一条消息约 3~8 帧。
    // 400 帧（约 50~120 条）在上划时会出现可感知的卡顿 —— 用户反馈后收紧到 200。
    // 少一点但更顺，往上拉一次就能补上。
    func loadHistory(_ sessionId: String, limit: Int = 200) async {
        guard let client, !sessionId.isEmpty else { return }
        // 硬上限：一页帧数一旦调大，就是「一次性往列表头插上百条」，
        // UICollectionView 的 diff + 高度重算全压在主线程（用户实拍：调大后上划卡顿）。
        // 参数可以随便传，这里一律钳住，避免再回到那次卡顿。
        let page = BubbleIds.pageSize(limit, cap: Self.historyPageLimit)
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
                    raw = try await client.transcript(sessionId: sessionId, limit: page)
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
            // 记下「下次往更早拉」的游标，以及还有没有更早的
            if let next = (raw["nextBefore"] as? NSNumber)?.intValue {
                olderBefore[sessionId] = next
            }
            olderHasMore = (raw["hasMore"] as? Bool) ?? false
            let started = CFAbsoluteTimeGetCurrent()
            var worstChunkMs = 0
            var chunkStart = started
            // 整段批量写，期间不发变更通知：几百帧就是几百次写入，
            // 逐次通知会让 ChatView 重建几百遍，切会话时手感发钝就是这个原因。
            beginBatch()
            suppressTrim = true          // 逐条裁是 O(n²)：回填期间关掉，收尾统一裁一次
            // 回填前先留住已有条目：**不能直接清空**。
            // 这一页只有最近 200 帧，长轮次（工具多、回答长）的帧数轻松上百，
            // 200 帧常常只覆盖到当前轮的后半段 —— 直接清空会把
            // 「开始第 N 轮 / 我的提问 / 本轮结束」整段抹掉。
            // 用户实拍：上拉到顶再跳回底部，中间内容缺了。
            // 现在改成「重放这一页 → 与已有条目合并」，重复 apply 也不会丢内容。
            let existingBefore = entriesStorage[sessionId] ?? []
            entries[sessionId] = []
            // 从头重放，段落号也跟着从头数（否则回填出来的 id 会带上一轮的段号）
            answerSegment[sessionId] = 0
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
            // 与已有条目合并（按 id 去重，已有优先：它可能带着更完整的状态）
            if !existingBefore.isEmpty, let replayed = entriesStorage[sessionId] {
                let liveIds = Set(existingBefore.map(\.id))
                let kept = replayed.filter { !liveIds.contains($0.id) }
                var merged = existingBefore + kept
                merged.sort { a, b in
                    if a.turn != b.turn { return a.turn < b.turn }
                    return a.at < b.at
                }
                entriesStorage[sessionId] = merged
            }
            trimIfNeeded(sessionId)
            // 历史回放里攒下的产物提示就地落位（同一 turn 内顺序由 append 保证）。
            flushFileHints(sessionId, except: currentTurn[sessionId])
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
            chat.bumpHistoryVersion()
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
        // 会话内容清空时，相关状态一起清 —— 否则重建历史时 turnClock 还停在旧值，
        // 新插入的条目会被顶到很后面；pending 里的提示也会跑到下一次 turn.end 去。
        resetTurnState(sessionId)
    }

    /// 清掉某个会话的「本轮时钟 + 攒着的产物提示」
    private func resetTurnState(_ sessionId: String) {
        turnClock = turnClock.filter { !$0.key.hasPrefix("\(sessionId)#") }
        pendingFileHints[sessionId] = nil
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
    /// 钱包相关 4 个字段搬到 WalletStore（它们只在设置页用，
    /// 不该参与 ChatView 的全量通知）。
    let walletStore = WalletStore()

    func loadBalance() async {
        guard let client else { return }
        walletStore.markLoading()
        do {
            let raw = try await client.balance()
            walletStore.apply(raw)
        } catch {
            walletStore.markFailed(error.localizedDescription)
        }
    }

    // MARK: - 队列写操作（编辑 / 删除 / 插队）
    //
    // 参数照 DSH 的 zod schema：updateQueue({ sessionId, itemId, action: {kind, content} })
    // itemId 用队列项的 id（agent/inbox/spliced 事件里 inserted[i].id）。

    func editQueued(itemId: String, newText: String) async -> String? {
        guard let client, let sid = selectedSessionId else { return "未连接" }
        guard chat.queue.contains(where: { $0.id == itemId }) else {
            return "这条已经不在队列里了"
        }
        do {
            _ = try await client.updateQueue(sessionId: sid, itemId: itemId, kind: "edit", text: newText)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeQueued(itemId: String) async -> String? {
        guard let client, let sid = selectedSessionId else { return "未连接" }
        guard chat.queue.contains(where: { $0.id == itemId }) else {
            return "这条已经不在队列里了"
        }
        do {
            _ = try await client.updateQueue(sessionId: sid, itemId: itemId, kind: "remove")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func steerQueued(itemId: String) async -> String? {
        guard let client, let sid = selectedSessionId else { return "未连接" }
        guard let item = chat.queue.first(where: { $0.id == itemId }) else {
            return "这条已经不在队列里了"
        }
        do {
            _ = try await client.updateQueue(sessionId: sid, itemId: itemId, kind: "steer")
            // 插队成功后立刻本地插一条占位。
            //
            // 为什么需要：插队会让这条从 next-turn 队列移除，但 DSH 要先把
            // 手头的小任务做完才真正执行 —— 这期间它「队列里没有了、对话框里
            // 也还没出现」，看起来像消息消失了（用户反馈）。
            // 电脑端会给它挂一个「未执行」的标记，这里用同样的思路：
            // 先插一条 pending 条目，等服务端回显时按 local- 前缀替换掉。
            append(sid, ChatEntry(
                id: "local-\(UUID().uuidString)",
                kind: .user,
                text: item.text,
                at: Date(),
                queued: true,
                steering: true
            ))
            return nil
        } catch {
            return error.localizedDescription
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
        chat.entries
    }

    // MARK: - 文件




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

    /// 下载文件内容。
    ///
    /// `preview: true` 时**电脑侧先压缩再传**（Pillow 缩放到 `maxWidth`，见 bridge/index.js
    /// 的 imagePreview）。聊天里看图只要几百像素，用 preview 能把传输量从几十 MB
    /// 降到几百 KB，并省掉手机端解码大图的内存峰值。
    func download(
        path: String,
        chunkSize: Int = 1024 * 1024,
        preview: Bool = false,
        maxWidth: Int? = nil,
        onProgress: ((Int64, Int64) -> Void)? = nil
    ) async throws -> Data {
        guard let client else { throw BridgeServerError(status: 0, code: "offline", message: "未连接") }
        if preview {
            // 预览图由电脑侧一次性生成，不必分块
            return try await client.readFile(
                path: path,
                offset: 0,
                limit: 8 * 1024 * 1024,
                preview: true,
                maxWidth: maxWidth
            )
        }

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

