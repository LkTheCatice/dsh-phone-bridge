import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    /// 上传进度（已完成张数, 总张数），nil 表示没在上传
    @State private var uploadProgress: (done: Int, total: Int)?
    /// 已上传到电脑、等着随消息一起发出的附件（显示成 chip，不塞进输入框）
    @State private var attachments: [String] = []
    @State private var sending = false
    @FocusState private var focused: Bool

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var videoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showVideos = false
    @State private var importingAudio = false
    @State private var showFiles = false
    @State private var uploading = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var showingModels = false
    @State private var showingSessions = false
    @State private var clearing = false
    /// 跳到底按钮的状态单独持有：滚动时每帧都会更新它，
    /// 放在 @State 里会让整个 ChatView（含 ScrollView）跟着重建
    /// 用 @State 而不是 @StateObject 持有这个引用类型。
    ///
    /// 关键区别：**@StateObject 会让宿主视图订阅该对象**（哪怕 body 里一次都不读），
    /// 于是 jump.atBottom 每翻一次，整个 ChatView（composer、toolbar、列表）就重算一次。
    /// 而 onScrollGeometryChange 在布局变化时会翻转它 → 重算 → 布局 → 又翻转，
    /// 300ms 节流只是把环放慢；每次布局 > 300ms 时主线程永远饱和
    /// （实测回车卡 13297ms，mark=body）。
    /// @State 持有引用但**不订阅**，真正的观察者是 JumpButtonLayer（@ObservedObject）。
    @State private var jump = JumpButtonState()
    // 滚动全部交给 SwiftUI 原生 proxy.scrollTo，不再持有背后的 UIScrollView。
    // （探针那套「读 layout → setContentOffset → 再触发布局」已经整段删掉，
    // 它本身就是一条自激环，见 HANDOFF 里的循环 1。）
    // 注：这里原来还有个 lastPhoneSendAt（@State，只有写没有读）。
    // 每次发送都白触发一次 ChatView 全量重算，且判断逻辑早已不在，一并删掉。
    // 注意：节流时间戳和 clamp 防重入锁都放在 jump（JumpButtonState）里，
    // 不能用 @State —— 它们会在 body 重算触发的回调里被改，
    // 用 @State 就是「改状态 → 重算 → 回调 → 再改」的无限循环。
    /// 标注编辑器：待编辑的图与等待中的 continuation
    @State private var editorImage: UIImage?
    @State private var editorContinuation: CheckedContinuation<UIImage?, Never>?

    private static let bottomAnchor = "__chat_bottom__"

    /// 当前会话的条目。
    /// 读 model.currentEntries（@Published）而不是每次现查字典 ——
    /// 这样别的会话收到消息不会让这里重建、也不会误触发 onChange 的滚动。
    private var entries: [ChatEntry] { model.currentEntries }

    /// 一次最多渲染多少条。
    ///
    /// 这是硬兜底：布局成本随「条目数 × 每条文本量」增长，而 LazyVStack 在
    /// 首屏/跳转时会把可见范围整体测量一遍（真机实测 20 条就能卡 19 秒）。
    /// 把上限压到 40 条以后，再糟也有限；要看更早的点顶部那一行。
    @State private var visibleLimit = 10

    /// 每次 +1 就请求列表滚到底（由 ChatList 消费）
    @State private var scrollRequest = 0

    /// 当前展开的那一条消息（手风琴：只允许一条，避免同时渲染多份富文本）
    @State private var expandedEntryId: String?

    /// 工具详情弹窗（全列表共用一个，别在每个气泡上挂 sheet）
    @StateObject private var detailPresenter = ToolDetailPresenter()

    private var visibleEntries: [ChatEntry] {
        // 流式期间只留最后 4 条：渲染量恒定且极小，避免「每秒多次重排 × 富文本」饱和
        let limit = model.isStreaming ? 4 : visibleLimit
        return entries.count <= limit ? entries : Array(entries.suffix(limit))
    }

    /// 标题直接用 AppModel 里的标量：不要再读 model.sessions，
    /// 否则每次会话列表刷新（每条消息结束都刷）都会让整棵聊天树重算。
    private var title: String { model.currentSessionTitle }

    var body: some View {
        // 打点：body 求值频率。只累加整数、不发通知，不会反过来触发重算。
        // 看门狗每 2 秒把它和卡顿次数一起报出来 —— 判断「卡」到底是
        // 「树太大每帧重算」还是「某一次阻塞操作」，就靠这个数。
        let _ = model.recordBodyEval()
        NavigationStack {
            // 这里保留 GeometryReader 只为撑满可用高度（之前还兼职算视口高度给
            // preference 判定用，那套已经删了，别再把布局读数塞回来）
            GeometryReader { _ in
                ScrollViewReader { proxy in
                // 回退说明：试过把 composer 做成 ScrollView 的兄弟视图（VStack 并排），
                // 确实能脱离 UIScrollView 的手势树，但在 GeometryReader 里 VStack 会塌缩，
                // ScrollView 拿不到高度，整个聊天区空白。这里先回到 safeAreaInset 保证显示正常。
                // composer 用 safeAreaInset 挂在 ScrollView 上，**不再是 VStack 的兄弟**。
                //
                // 17:35 的 668fa8a 为了修「惯性中按钮点不动」，把 composer 挪成了兄弟视图；
                // 代价是从那以后输入框高度一变（打字换行、键盘、上传条、附件 chip、发送方式）
                // 就要整棵 VStack 重排 → ScrollView frame 变 → LazyVStack 全量重测。
                // 用户观察到的「某次功能更新后卡顿大量产生」正是它。
                // 现在改回 safeAreaInset：输入区高度变化只影响 inset，不牵动列表布局。
                // 代价：惯性滚动中点「跳到底」偶尔不灵（按钮在 ScrollView 的手势树里），
                // 但那是体验细节，不该用整页卡死来换。
                // ── 列表：UICollectionView + cell 复用（见 ChatList.swift）──
                // 换掉 LazyVStack 的原因：它没有 cell 复用，22 条消息滚动就能卡 13 秒。
                // 一条消息 = 一个 cell = 一个视图，滚动成本与消息总数无关。
                ChatList(
                    entries: visibleEntries,
                    isStreaming: model.isStreaming,
                    onBottomChanged: { bottom in
                        if jump.atBottom != bottom { jump.atBottom = bottom }
                        if bottom, jump.hasNewBelow { jump.hasNewBelow = false }
                    },
                    scrollRequest: scrollRequest,
                    onTapEntry: { id in
                        expandedEntryId = (expandedEntryId == id) ? nil : id
                    }
                )
                .onChange(of: model.streamTick) { _ in
                    if jump.atBottom {
                        // 跟随：只发一个「滚到底」请求，具体滚动由 collectionView 做
                        let now = Date()
                        guard now.timeIntervalSince(jump.lastFollowAt) > 0.5 else { return }
                        jump.lastFollowAt = now
                        guard !model.expNoAutoFollow else { return }
                        scrollRequest += 1
                    } else if !jump.hasNewBelow {
                        jump.hasNewBelow = true
                    }
                }
                .onChange(of: model.historyVersion) { _ in
                    if !jump.atBottom { jump.atBottom = true }
                    if jump.hasNewBelow { jump.hasNewBelow = false }
                    scrollRequest += 1
                }
                .onChange(of: scenePhase) { phase in
                    guard phase == .active, jump.atBottom else { return }
                    scrollRequest += 1
                }

                // 浮动按钮挂在 ScrollView 的 overlay 上、用 padding 定位：
                // - padding 让它留在 ScrollView 的 frame 内部，命中区真实存在
                //   （之前用 offset 把它推出 frame，视觉在、点不到）
                // - overlay 不参与滚动内容，也不占列表高度
                // - 位置在聊天区右下，离输入栏还有一段距离，不会压到发送键
                .overlay(alignment: .bottomTrailing) {
                    JumpButtonLayer(
                        state: jump,
                        entryCount: entries.count,
                        onTap: { jumpToBottom() }
                    )
                    .padding(.trailing, 14)
                    .padding(.bottom, 16)
                    // 这里刻意**不**读 jump 的显示状态。
                    // ChatView 持着 @StateObject jump，body 只要读它任何一个属性，
                    // 整个 ChatView（含 composer、toolbar）就会被订阅 ——
                    // atBottom 每翻一次就全树重算一次（实测 body=26 bubble=0 后卡 18 秒）。
                    // 显示与否交给 JumpButtonLayer 自己（它已 @ObservedObject）。
                }

                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .frame(maxWidth: .infinity, maxHeight: .infinity)   // 撑满 GeometryReader，否则 VStack 塌缩
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                handleFile(result)
            }
            // 音乐走文件选择器（相册里没有音频），视频走 PhotosPicker
            .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                handleFile(result)
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 9, matching: .images)
            .onChange(of: photoItems) { items in
                guard !items.isEmpty else { return }
                Task { await loadPhotos(items) }
            }
            .photosPicker(isPresented: $showVideos, selection: $videoItems, maxSelectionCount: 3, matching: .videos)
            .onChange(of: videoItems) { items in
                guard !items.isEmpty else { return }
                Task { await loadVideos(items) }
            }
            .sheet(item: $editorImage) { image in
                ImageEditorSheet(
                    image: image,
                    onCommit: { merged in
                        editorImage = nil
                        editorContinuation?.resume(returning: merged)
                        editorContinuation = nil
                    },
                    onCancel: {
                        editorImage = nil
                        editorContinuation?.resume(returning: nil)
                        editorContinuation = nil
                    }
                )
            }
            // 切换会话时回填历史：之前只显示「连上之后收到的事件」，旧对话是空的
            .onChange(of: model.selectedSessionId) { sessionId in
                guard let sessionId else { return }
                // 草稿按会话存：切过去要把那一格的内容取回来
                draft = model.drafts[model.draftKey(sessionId)] ?? ""
                Task { await model.loadHistory(sessionId) }
            }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // 键盘弹起时藏掉底部 Tab Bar：否则它被键盘盖住，三个按钮点不到
            .toolbar(focused ? .hidden : .visible, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // 会话列表放不进 Menu：UIMenu 只渲染简单的文本/图片组合，
                    // 双行布局（标题 + 状态时间）会被吞掉，只剩一个 ✓。改用 sheet。
                    Button {
                        showingSessions = true
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            renameText = model.currentSessionTitle
                            renaming = true
                        } label: {
                            Label("重命名当前对话", systemImage: "pencil")
                        }
                        Button {
                            if let id = model.selectedSessionId { Task { await model.archive(id) } }
                        } label: {
                            Label("归档当前对话", systemImage: "archivebox")
                        }
                        Divider()
                        Button {
                            showingModels = true
                        } label: {
                            Label(model.currentModel.map { "模型 · \($0.name)" } ?? "选择模型",
                                  systemImage: "cpu")
                        }
                        Divider()
                        Button(role: .destructive) {
                            clearing = true
                        } label: {
                            Label("清除本机记录", systemImage: "trash")
                        }
                        Button(role: .destructive) {
                            Task { await model.cancelCurrentTurn() }
                        } label: {
                            Label("停止本轮", systemImage: "stop.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                // ComfyUI 状态点单独成视图：它每 8 秒被轮询更新，
                // 直接在这里读 model.comfy 会让整个 ChatView（composer/toolbar/列表）跟着重算。
                ToolbarItem(placement: .topBarTrailing) {
                    ComfyBadge()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // 连接状态：正常时只留 wifi 图标（不占地方），
                    // 不正常时才补上文字 —— 免得和左边 ComfyUI 的「画图离线」看混
                    HStack(spacing: 3) {
                        Image(systemName: connectionIcon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(statusColor)
                        if model.phase != .connected {
                            Text(connectionShort)
                                .font(.system(size: 10))
                                .foregroundStyle(statusColor)
                        }
                    }
                }
            }
            .alert("重命名对话", isPresented: $renaming) {
                TextField("标题", text: $renameText)
                Button("保存") {
                    if let id = model.selectedSessionId {
                        Task { await model.rename(id, to: renameText) }
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $showingModels) {
                ModelPickerSheet()
                    .environmentObject(model)
            }
            .sheet(isPresented: $showingSessions) {
                SessionListSheet()
                    .environmentObject(model)
                    .environmentObject(model.sessionList)
                    .presentationDetents([.medium, .large])
            }
            .confirmationDialog("清除本机聊天记录", isPresented: $clearing, titleVisibility: .visible) {
                Button("保留最近 5 轮") {
                    if let id = model.selectedSessionId { model.clearEntries(id, keepTurns: 5) }
                }
                Button("全部清除", role: .destructive) {
                    if let id = model.selectedSessionId { model.clearEntries(id, keepTurns: nil) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只影响手机上显示的内容，电脑端的会话记录不受影响。")
            }
            }   // 关闭 GeometryReader
        }
        // 诊断开关：关掉所有气泡的文本选择（iOS 上由 UITextInteraction 实现，
        // 在 LazyVStack 里反复重排时是有代价的）
        .environment(\.noTextSelection, !model.expTextSelection)
        .environment(\.richTextEnabled, model.richTextEnabled)
        .environment(\.toolDetailPresenter, detailPresenter)
        .sheet(item: $detailPresenter.entry) { item in
            ToolDetailSheet(entry: item)
        }
    }



    /// 连接状态文案，和 ComfyUI 分开放
    private var connectionShort: String {
        switch model.phase {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .failed: return "连接失败"
        case .disconnected: return "未连接"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary)
            Text("发一句话，让电脑上的 DSH 去干").foregroundStyle(.secondary)
            Text("第一次发送会自动新建一个会话").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    /// 自动跟随：滚到内容末尾的哨兵。
    ///
    /// 刻意只用 SwiftUI 原生能力。
    /// 之前这里试过 UIScrollView.setContentOffset + layoutIfNeeded + 多次校准 +
    /// 冻结内容再解冻 —— 每一版都在「读布局 → 写偏移 → 触发布局」之间形成了
    /// 难以排查的环，最后表现为整个 App 卡死（连主线程 Timer 都停跑）。
    /// 原生 scrollTo 虽然偶尔差几像素，但不会把主线程拖住。
    private func scrollToEnd() {
        model.recordFollowEvent()
        if !jump.atBottom { jump.atBottom = true }
        if jump.hasNewBelow { jump.hasNewBelow = false }
        scrollRequest += 1
    }

    /// 「跳到最下」按钮：直接请求滚到底。
    /// 之前用 scrollDisabled 掐惯性（每次切换都让 ScrollView 重新布局），已移除。
    private func jumpToBottom() {
        model.recordFollowEvent()
        if !jump.atBottom { jump.atBottom = true }
        if jump.hasNewBelow { jump.hasNewBelow = false }
        scrollRequest += 1
    }

    /// 上传进度文案：单张只说「正在上传」，多张带上 2/5
    private var uploadText: String {
        guard let progress = uploadProgress, progress.total > 1 else {
            return "正在上传附件…"
        }
        return "正在上传 \(min(progress.done + 1, progress.total))/\(progress.total)"
    }

    private var statusColor: Color {
        switch model.phase {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var connectionIcon: String {
        switch model.phase {
        case .connected: return "wifi"
        case .connecting: return "wifi.exclamationmark"
        case .failed, .disconnected: return "wifi.slash"
        }
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(spacing: 0) {
            // 注意：这里刻意不用 `if ... { }` 增删视图。
            // SwiftUI 会在结构变化时重建整个子树，TextField 跟着重建，
            // 正在组合的拼音就被打断 —— 表现就是「选完图后第一个字母不进拼音」。
            // 改成恒定结构 + 用高度和透明度控制，视图树不变，输入法状态就不会丢。
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(uploadText).font(.caption).foregroundStyle(.secondary)
            }
            .frame(height: uploading ? 22 : 0)
            .opacity(uploading ? 1 : 0)
            .clipped()

            // 已上传待发送的附件：chip 列表，点 × 单独移除
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachments, id: \.self) { path in
                        HStack(spacing: 5) {
                            Image(systemName: "photo")
                                .font(.system(size: 11))
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Button {
                                attachments.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: attachments.isEmpty ? 0 : 44)
            .opacity(attachments.isEmpty ? 0 : 1)
            .clipped()
            // 发送方式：排队（等当前轮结束）/ 插队（打断当前轮）
            HStack(spacing: 8) {
                Picker("发送方式", selection: $model.sendMode) {
                    ForEach(SendMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 132)
                Text(model.sendMode.hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            HStack(alignment: .bottom, spacing: 8) {
                // 附件入口跟 QQ 一样放在输入框左边
                Menu {
                    // PhotosPicker 直接塞进 Menu 里不会触发选择器，必须用
                    // photosPicker(isPresented:) 修饰符，这里只放开关按钮
                    Button { showPhotos = true } label: {
                        Label("图片", systemImage: "photo")
                    }
                    Button { showVideos = true } label: {
                        Label("视频", systemImage: "video")
                    }
                    Button { importingAudio = true } label: {
                        Label("音乐", systemImage: "music.note")
                    }
                    Button { showFiles = true } label: {
                        Label("文件", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(uploading ? Color.secondary : Color.accentColor)
                }
                .disabled(uploading)

                TextField("让它跑点什么…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                    .focused($focused)

                Button(action: submit) {
                    Image(systemName: sending ? "hourglass" : "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }


    private func submit() {
        // 立刻打一条、不节流：确认「点击真的到达了 submit」，以及它到达之后
        // 主线程还能不能回到 runloop（有这条、后面却没有 render= 就是卡死在这中间）。
        model.markMain("submit")
        model.recordSubmitEvent()
        model.traceFollow("tap=send")
        let text = draft
        // 附件和文字合并成一条消息：附件路径放后面，文字保持原样在前面
        let attachmentLines = attachments.map { "[附件] \($0)" }.joined(separator: "\n")
        let payload = attachmentLines.isEmpty
            ? text
            : ([text, attachmentLines].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                .joined(separator: "\n")
        draft = ""
        attachments = []
        // 草稿按会话存，发完要清掉对应那一格
        model.drafts[model.draftKey(model.selectedSessionId)] = ""
        // 自己发的消息一定要跟着滚到底，别让「不打断」规则把自己挡住。
        // （原来这里还记一个 lastPhoneSendAt 给 onChange 做区分，那段逻辑已经没了，一并删掉）
        if !jump.atBottom { jump.atBottom = true }
        if jump.hasNewBelow { jump.hasNewBelow = false }
        focused = false
        sending = true
        let outgoing = payload
        // 「按下发送后，主线程多久才轮到下一个任务」。
        //
        // 为什么需要它：send() 里的分步打点永远是 0ms（s2-append=0ms），
        // 因为插入数组本身不花时间 —— 真实成本全在「插入之后那一次渲染与布局」，
        // 而那段没有任何打点覆盖。两跳 async 之后如果这个数变大，
        // 说明主线程确实被渲染占住了，而不是网络慢。
        let tSend = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                let ms = Int((CFAbsoluteTimeGetCurrent() - tSend) * 1000)
                model.traceFollow("render=\(ms)ms n=\(entries.count)")
            }
        }
        Task {
            await model.send(text: outgoing)
            sending = false
        }
    }

    // MARK: - 附件

    /// 一次可以选多张（最多 9 张），逐张压缩后上传，成功后挂成附件 chip
    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        uploading = true
        uploadProgress = (0, items.count)
        defer {
            uploading = false
            uploadProgress = nil
            photoItems = []
        }
        for (index, item) in items.enumerated() {
            do {
                guard let raw = try await item.loadTransferable(type: Data.self) else { continue }
                // 单张时给一次标注机会（可跳过）；多张直接走上传，免得连着弹九次编辑器
                var working = raw
                if items.count == 1,
                   let preview = UIImage(data: raw),
                   let annotated = await presentEditor(preview) {
                    working = annotated.jpegData(compressionQuality: 0.92) ?? raw
                }
                // 压缩必须离开主线程：1700 万像素的图光解码就是几十 MB，
                // 在主线程跑会把触控堵死（上传完就卡住就是这个原因）
                let data = await Task.detached(priority: .userInitiated) {
                    ImagePrep.compress(working)
                }.value
                let stamp = Int(Date().timeIntervalSince1970)
                let name = "image-\(stamp)-\(index).jpg"
                let remote = try await model.uploadAttachment(data, filename: name)
                attachments.append(remote)
                uploadProgress = (index + 1, items.count)
            } catch {
                model.showToast("第 \(index + 1) 张上传失败：\(error.localizedDescription)")
                uploadProgress = (index + 1, items.count)
            }
        }
    }

    /// 视频上传：不做压缩（重编码代价太高），直接原样传，
    /// 由电脑侧决定怎么处理。上限受 bridge 的 maxFileBytes 约束。
    private func loadVideos(_ items: [PhotosPickerItem]) async {
        uploading = true
        uploadProgress = (0, items.count)
        defer {
            uploading = false
            uploadProgress = nil
            videoItems = []
        }
        for (index, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let stamp = Int(Date().timeIntervalSince1970)
                // 保留原始扩展名，电脑侧靠它判断类型
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "mov"
                let name = "video-\(stamp)-\(index).\(ext)"
                let remote = try await model.uploadAttachment(data, filename: name)
                attachments.append(remote)
                uploadProgress = (index + 1, items.count)
            } catch {
                model.showToast("第 \(index + 1) 个视频上传失败：\(error.localizedDescription)")
                uploadProgress = (index + 1, items.count)
            }
        }
    }

    /// 弹出标注编辑器并等待结果；用户取消返回 nil（走原图）
    private func presentEditor(_ image: UIImage) async -> UIImage? {
        await withCheckedContinuation { continuation in
            editorContinuation = continuation
            editorImage = image
        }
    }

    private func handleFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.lastError = "选择文件失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.lastError = "读取本地文件失败"
                return
            }
            uploading = true
            Task {
                do {
                    let remote = try await model.uploadAttachment(data, filename: url.lastPathComponent)
                    attachments.append(remote)
                } catch {
                    model.showToast("上传失败：\(error.localizedDescription)")
                }
                uploading = false
            }
        }
    }
}


/// iOS 17 起用系统的「内容增长时保持贴底」代替手工 scrollTo。
///
/// 手工 `proxy.scrollTo(bottomAnchor)` 会让 LazyVStack 重新测量全部条目
/// （20 条 markdown 气泡 = 上百个 Text），真机实测一次 43 秒。
/// iOS 16 没有这个 API，只能退化为原路径。
struct BottomAnchorModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.defaultScrollAnchor(.bottom)
        } else {
            content
        }
    }
}


/// ComfyUI 状态点（含菜单）。
///
/// 单独成视图的原因：`comfy` 每 8 秒被轮询更新一次，如果直接在 ChatView.body
/// 里读它，ChatView 就会被订阅 —— 每 8 秒把 composer、toolbar、整个列表白重算一遍。
/// 抽出来之后只有这一个小徽标重算。
struct ComfyBadge: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            Label(model.comfy.label, systemImage: "flame")
            if let version = model.comfy.version {
                Text("ComfyUI v\(version)")
            }
            if !model.comfy.url.isEmpty {
                Text(model.comfy.url)
            }
            Button("刷新状态") { model.startComfyPolling() }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(short)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        if !model.comfy.online { return .gray }
        return model.comfy.generating ? .orange : .green
    }

    /// 必须带「画图」前缀：光写「离线」会和旁边的连接状态混在一起，
    /// 让人以为整个 App 掉线（其实只是画图服务没开）。
    private var short: String {
        if !model.comfy.online { return "画图离线" }
        if model.comfy.generating {
            return model.comfy.pending > 0 ? "画图中 \(model.comfy.pending)" : "画图中"
        }
        return "画图空闲"
    }
}

