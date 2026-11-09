import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    private var entries: [ChatEntry] { model.entriesForSelection() }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if entries.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary)
                                Text("发一句话，让电脑上的 DSH 去干")
                                    .foregroundStyle(.secondary)
                                Text("第一次发送会自动新建一个会话")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                        }
                        ForEach(entries) { entry in
                            ChatBubble(entry: entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .onChange(of: entries.count) { _ in
                    if let last = entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: entries.last?.text) { _ in
                    if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle(model.selectedSessionId.map { "会话 \($0.suffix(8))" } ?? "新会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
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
                        Button("停止当前轮次", role: .destructive) { Task { await model.cancelCurrentTurn() } }
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                        .padding(.trailing, 4)
                }
            }
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("让它跑点什么…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                .focused($focused)
                .onSubmit { submit() }

            Button(action: submit) {
                Image(systemName: sending ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func submit() {
        let text = draft
        draft = ""
        sending = true
        Task {
            await model.send(text: text)
            sending = false
        }
    }
}

struct ChatBubble: View {
    let entry: ChatEntry
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant:
            contentCard(icon: "sparkles", tint: .accentColor)
        case .thinking:
            contentCard(icon: "brain", tint: .purple)
        case .toolCall:
            toolCard(icon: "wrench.and.screwdriver", tint: .blue)
        case .toolResult:
            toolCard(icon: "checkmark.circle", tint: .teal)
        case .system:
            HStack(spacing: 6) {
                if entry.running { ProgressView().controlSize(.mini) }
                Text(entry.text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func contentCard(icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2).foregroundStyle(tint)
                Text(entry.kind == .thinking ? "思考" : "回答")
                    .font(.caption2)
                    .foregroundStyle(tint)
                if entry.running { ProgressView().controlSize(.mini) }
            }
            Text(entry.text)
                .font(.system(.body, design: entry.kind == .thinking ? .monospaced : .default))
                .foregroundStyle(entry.kind == .thinking ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func toolCard(icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2).foregroundStyle(tint)
                Text(entry.text).font(.system(.caption, design: .monospaced))
                if entry.running { ProgressView().controlSize(.mini) }
                Spacer()
                if let detail = entry.detail, !detail.isEmpty {
                    Button(expanded ? "收起" : "详情") { expanded.toggle() }
                        .font(.caption2)
                }
            }
            if expanded, let detail = entry.detail {
                ScrollView(.horizontal) {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                }
                .frame(maxHeight: 220)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
