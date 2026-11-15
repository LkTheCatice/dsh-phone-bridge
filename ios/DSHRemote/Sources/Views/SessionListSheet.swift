import SwiftUI

/// 会话列表。
///
/// 之前是塞在 `Menu` 里的，但 iOS 的 UIMenu 只渲染简单的文本/图片组合，
/// 我放的双行布局（标题 + 状态时间）会被整个吞掉 —— 菜单里只剩一个 ✓。
/// 所以改成独立 sheet：能放双行、能搜索、能长按操作。
struct SessionListSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionList: SessionListStore
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    /// 只看收藏（顶部工具栏那颗星）
    @State private var favoritesOnly = false
    @State private var renaming: SessionRow?
    @State private var renameText = ""

    private var filtered: [SessionRow] {
        let keyword = search.trimmingCharacters(in: .whitespaces)
        var rows = sessionList.rows
        if favoritesOnly { rows = rows.filter { $0.favorite } }
        guard !keyword.isEmpty else { return rows }
        return rows.filter {
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
                            // 只有"选中项真的换成了一个新 id"才关面板；
                            // 建失败（未连接 / 服务端没回 id）就留在这里看错误。
                            let before = model.selectedSessionId
                            await model.newSession()
                            if model.selectedSessionId != before { dismiss() }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Label(L("新建对话", "New chat"), systemImage: "square.and.pencil")
                            Spacer(minLength: 0)
                            if model.isCreatingSession {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(model.isCreatingSession)
                }
                Section {
                } footer: {
                    Text(L("左滑会话可重命名或归档；右上角可搜索标题。", "Swipe a chat to rename or archive; search titles at the top right."))
                        .font(.caption2)
                }


                Section {
                    ForEach(filtered) { session in
                        Button {
                            model.selectedSessionId = session.id
                            model.markRead(session.id)
                            dismiss()
                        } label: {
                            // contentShape 撑满整行：.buttonStyle(.plain) 会把命中区缩到内容本身，
                            // 行里的 Spacer 不接收触摸 —— 那样只有正好点在文字上才生效。
                            HStack(spacing: 6) {
                                if session.favorite {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.yellow)
                                }
                                row(session)
                            }
                            .contentShape(Rectangle())
                        }
                        // 不加 .plain 的话 Button 会给整行套默认 tint，标题全变蓝
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            Button {
                                Task { await model.toggleFavorite(session.id) }
                            } label: {
                                Label(
                                    session.favorite ? L("取消收藏", "Unfavorite") : L("收藏", "Favorite"),
                                    systemImage: session.favorite ? "star.slash" : "star"
                                )
                            }
                            .tint(.yellow)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await model.archive(session.id, archived: true) }
                            } label: {
                                Label(L("归档", "Archive"), systemImage: "archivebox")
                            }
                            Button {
                                renameText = session.displayTitle
                                renaming = session
                            } label: {
                                Label(L("重命名", "Rename"), systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text(L("会话 \(filtered.count)", "Chats (\(filtered.count))"))
                }

                if filtered.isEmpty && (!search.isEmpty || favoritesOnly) {
                    Section {
                        Text(search.isEmpty
                             ? L("还没有收藏的会话", "No favorite chats yet")
                             : L("没有匹配的会话", "No matching chats"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 已归档：之前归档后就彻底消失、无处找回，现在能在这里恢复
                if !sessionList.archived.isEmpty {
                    Section {
                        ForEach(sessionList.archived) { session in
                            Button {
                                model.selectedSessionId = session.id
                                model.markRead(session.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.displayTitle)
                                            .lineLimit(1)
                                            .foregroundStyle(.secondary)
                                        Text(L("已归档 · \(session.timeLabel)", "Archived · \(session.timeLabel)"))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button {
                                    Task { await model.unarchive(session.id) }
                                } label: {
                                    Label(L("恢复", "Restore"), systemImage: "arrow.uturn.backward")
                                }
                                .tint(.accentColor)
                            }
                        }
                    } header: {
                        Text(L("已归档 \(sessionList.archived.count)", "Archived (\(sessionList.archived.count))"))
                    }
                }
            }
            .searchable(text: $search, prompt: L("搜索会话标题", "Search chat titles"))
            .navigationTitle(L("会话", "Chats"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("完成", "Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await model.refreshSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                // 收藏筛选：只留一颗星，点一下只显示已收藏
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        favoritesOnly.toggle()
                    } label: {
                        Image(systemName: favoritesOnly ? "star.fill" : "star")
                            .foregroundStyle(favoritesOnly ? Color.yellow : Color.accentColor)
                    }
                    .accessibilityLabel(L("只看收藏", "Favorites only"))
                }
            }
            .alert(L("重命名会话", "Rename chat"), isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField(L("标题", "Title"), text: $renameText)
                Button(L("保存", "Save")) {
                    if let target = renaming {
                        Task { await model.rename(target.id, to: renameText) }
                    }
                    renaming = nil
                }
                Button(L("取消", "Cancel"), role: .cancel) { renaming = nil }
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
            if session.running || sessionList.running.contains(session.id) {
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
        // 让整行（含 Spacer 和右侧空白）都能点，并把行高拉到 44pt 以上好点
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func subtitle(_ session: SessionRow) -> String {
        var parts: [String] = []
        if session.running || sessionList.running.contains(session.id) {
            parts.append(L("正在处理", "Working"))
        } else if model.unreadSessions.contains(session.id) {
            parts.append(L("已完成", "Done"))
        }
        if !session.timeLabel.isEmpty { parts.append(session.timeLabel) }
        if parts.isEmpty { parts.append(session.cwdName ?? session.cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
