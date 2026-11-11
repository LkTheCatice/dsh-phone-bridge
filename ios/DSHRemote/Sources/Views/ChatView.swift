import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    /// 上传进度（已完成张数, 总张数），nil 表示没在上传
    @State private var uploadProgress: (done: Int, total: Int)?
    @State private var sending = false
    @FocusState private var focused: Bool

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var uploading = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var showingModels = false
    @State private var showingSessions = false
    @State private var clearing = false
    /// 是否已经滚到（或接近）底部；false 时才显示「跳到最下」
    @State private var atBottom = true
    /// 在底部之外时收到了新内容，挂一个「新消息」提示等你点
    @State private var hasNewBelow = false

    private static let bottomAnchor = "__chat_bottom__"

    private var entries: [ChatEntry] { model.entriesForSelection() }

    private var currentSession: SessionRow? {
        guard let id = model.selectedSessionId else { return nil }
        return model.sessions.first { $0.id == id }
    }

    private var title: String {
        if let s = currentSession { return s.displayTitle }
        return model.selectedSessionId.map { "会话 \($0.suffix(8))" } ?? "新会话"
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if entries.isEmpty { emptyState }
                        ForEach(entries) { entry in
                            // 和上一条隔了 5 分钟以上才打时间戳（由 AppModel 填 timeLabel）
                            if let label = entry.timeLabel {
                                Text(label)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 2)
                            }
                            ChatBubble(entry: entry).id(entry.id)
                        }
                        // 底部哨兵：在视口里说明已经到底了，滚出去才显示「跳到最下」。
                        // 比「条目数 > N 就常驻」准，也不会挡住刚滚到底时的最后一条。
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchor)
                            .onAppear {
                                atBottom = true
                                hasNewBelow = false
                            }
                            .onDisappear { atBottom = false }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                // 已经在底部才跟着滚；往上翻的时候不准把人拽下去，只挂个「新消息」提示
                .onChange(of: entries.count) { _ in
                    if atBottom {
                        scrollToEnd(proxy)
                    } else {
                        hasNewBelow = true
                    }
                }
                .onChange(of: entries.last?.text) { _ in
                    if atBottom { scrollToEnd(proxy) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasNewBelow {
                        // 有新内容但你在上面看旧记录 → 只提示，不抢滚动位置
                        Button {
                            hasNewBelow = false
                            scrollToEnd(proxy)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 11, weight: .bold))
                                Text("新消息")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                            .shadow(radius: 2, y: 1)
                        }
                        .padding(.trailing, 14)
                        .padding(.bottom, 10)
                    } else if !atBottom && entries.count > 3 {
                        // 单纯往上翻（没新内容）时给个回底箭头
                        Button {
                            atBottom = true
                            scrollToEnd(proxy)
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 30))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.accentColor, Color(.systemBackground))
                                .shadow(radius: 2, y: 1)
                        }
                        .padding(.trailing, 14)
                        .padding(.bottom, 10)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
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
                            renameText = currentSession?.displayTitle ?? ""
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
                ToolbarItem(placement: .topBarTrailing) {
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
                            Circle().fill(comfyColor).frame(width: 7, height: 7)
                            Text(comfyShort)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // 连接状态用 wifi 图标，和右边 ComfyUI 的圆点区分开
                    Image(systemName: connectionIcon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(statusColor)
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
        }
    }

    private var comfyColor: Color {
        if !model.comfy.online { return .gray }
        return model.comfy.generating ? .orange : .green
    }

    private var comfyShort: String {
        if !model.comfy.online { return "离线" }
        if model.comfy.generating {
            return model.comfy.pending > 0 ? "生图+\(model.comfy.pending)" : "生图"
        }
        return "空闲"
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

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = entries.last else { return }
        atBottom = true
        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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
            if uploading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(uploadText).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
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
                    // photosPicker(isPresented:) 修饰符，这里只放一个开关按钮
                    Button { showPhotos = true } label: {
                        Label("图片", systemImage: "photo")
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
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            handleFile(result)
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 9, matching: .images)
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        // 切换会话时回填历史：之前只显示「连上之后收到的事件」，旧对话是空的
        .onChange(of: model.selectedSessionId) { sessionId in
            guard let sessionId else { return }
            // 草稿按会话存：切过去要把那一格的内容取回来
            draft = model.drafts[model.draftKey(sessionId)] ?? ""
            Task { await model.loadHistory(sessionId) }
        }
    }

    private func submit() {
        let text = draft
        draft = ""
        // 草稿按会话存，发完要清掉对应那一格
        model.drafts[model.draftKey(model.selectedSessionId)] = ""
        // 自己发的消息一定要跟着滚到底，别让「不打断」规则把自己挡住
        atBottom = true
        hasNewBelow = false
        focused = false
        sending = true
        Task {
            await model.send(text: text)
            sending = false
        }
    }

    // MARK: - 附件

    /// 一次可以选多张（最多 9 张），逐张上传后把路径都写进输入框
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
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let stamp = Int(Date().timeIntervalSince1970)
                let name = "image-\(stamp)-\(index).jpg"
                let remote = try await model.uploadAttachment(data, filename: name)
                appendPath(remote)
                uploadProgress = (index + 1, items.count)
            } catch {
                model.showToast("第 \(index + 1) 张上传失败：\(error.localizedDescription)")
                uploadProgress = (index + 1, items.count)
            }
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
                    appendPath(remote)
                } catch {
                    model.lastError = "上传失败：\(error.localizedDescription)"
                }
                uploading = false
            }
        }
    }

    /// 把已上传文件的远端路径塞进输入框，模型据此读取
    private func appendPath(_ remote: String) {
        if draft.isEmpty {
            draft = "[附件] \(remote)\n"
        } else {
            draft += "\n[附件] \(remote)\n"
        }
    }
}
