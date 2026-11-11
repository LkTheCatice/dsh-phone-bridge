import SwiftUI

/// 会话列表。
///
/// 之前是塞在 `Menu` 里的，但 iOS 的 UIMenu 只渲染简单的文本/图片组合，
/// 我放的双行布局（标题 + 状态时间）会被整个吞掉 —— 菜单里只剩一个 ✓。
/// 所以改成独立 sheet：能放双行、能搜索、能长按操作。
struct SessionListSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var renaming: SessionRow?
    @State private var renameText = ""

    private var filtered: [SessionRow] {
        let keyword = search.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return model.sessions }
        return model.sessions.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(keyword)
                || $0.id.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task {
                            await model.newSession()
                            dismiss()
                        }
                    } label: {
                        Label("新建对话", systemImage: "square.and.pencil")
                    }
                }

                Section {
                    ForEach(filtered) { session in
                        Button {
                            model.selectedSessionId = session.id
                            model.markRead(session.id)
                            dismiss()
                        } label: {
                            row(session)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await model.archive(session.id, archived: true) }
                            } label: {
                                Label("归档", systemImage: "archivebox")
                            }
                            Button {
                                renameText = session.displayTitle
                                renaming = session
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text("会话 \(filtered.count)")
                }

                if filtered.isEmpty && !search.isEmpty {
                    Section {
                        Text("没有匹配的会话").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索会话标题")
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await model.refreshSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .alert("重命名会话", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("标题", text: $renameText)
                Button("保存") {
                    if let target = renaming {
                        Task { await model.rename(target.id, to: renameText) }
                    }
                    renaming = nil
                }
                Button("取消", role: .cancel) { renaming = nil }
            }
        }
    }

    @ViewBuilder
    private func row(_ session: SessionRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(subtitle(session))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if session.running {
                ProgressView().controlSize(.mini)
            } else if model.unreadSessions.contains(session.id) {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
            }
            if session.id == model.selectedSessionId {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func subtitle(_ session: SessionRow) -> String {
        var parts: [String] = []
        if session.running {
            parts.append("正在处理")
        } else if model.unreadSessions.contains(session.id) {
            parts.append("已完成")
        }
        if !session.relativeTime.isEmpty { parts.append(session.relativeTime) }
        if parts.isEmpty { parts.append(session.cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
