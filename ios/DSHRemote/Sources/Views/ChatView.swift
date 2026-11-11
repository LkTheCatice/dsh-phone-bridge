import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var uploading = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var showingModels = false
    @State private var clearing = false

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
                            ChatBubble(entry: entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: entries.count) { _ in scrollToEnd(proxy) }
                .onChange(of: entries.last?.text) { _ in scrollToEnd(proxy) }
                .overlay(alignment: .bottomTrailing) {
                    // 长对话往上翻之后，一键回到底部
                    if entries.count > 8 {
                        Button {
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
                    Menu {
                        Button {
                            Task { await model.createNewSession() }
                        } label: {
                            Label("新建对话", systemImage: "square.and.pencil")
                        }
                        Divider()
                        ForEach(model.sessions) { session in
                            Button {
                                model.selectedSessionId = session.id
                            } label: {
                                Label(
                                    "\(session.running ? "● " : "")\(session.displayTitle)",
                                    systemImage: session.id == model.selectedSessionId ? "checkmark" : "bubble.left"
                                )
                            }
                        }
                        Divider()
                        Button("刷新列表") { Task { await model.refreshSessions() } }
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
                    Circle().fill(statusColor).frame(width: 9, height: 9)
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
        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private var statusColor: Color {
        switch model.phase {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(spacing: 0) {
            if uploading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在上传附件…").font(.caption).foregroundStyle(.secondary)
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
            Task { await model.loadHistory(sessionId) }
        }
    }

    private func submit() {
        let text = draft
        draft = ""
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
        defer {
            uploading = false
            photoItems = []
        }
        for (index, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let stamp = Int(Date().timeIntervalSince1970)
                let name = "image-\(stamp)-\(index).jpg"
                let remote = try await model.uploadAttachment(data, filename: name)
                appendPath(remote)
            } catch {
                model.lastError = "第 \(index + 1) 张上传失败：\(error.localizedDescription)"
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
