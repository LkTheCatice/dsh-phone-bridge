import SwiftUI

/// 把产物文件转发到另一个会话。
///
/// 只发**路径引用**：两端在同一台电脑上，目标会话拿到路径就能读；
/// 手机不能预览/下载的类型（dmg/exe/7z…）也能用这条路，还不耗流量。
struct ForwardSessionSheet: View {
    /// 要转发的文件路径（空表示转发文本）
    var path: String = ""
    /// 要转发的一段文本
    var text: String = ""

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionList: SessionListStore
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var note = ""
    @State private var attachCommand = true
    @State private var sendingTo: String?
    @State private var error: String?

    private var rows: [SessionRow] {
        let keyword = search.trimmingCharacters(in: .whitespaces)
        return sessionList.rows
            .filter { $0.id != model.selectedSessionId }
            .filter {
                keyword.isEmpty
                    || $0.displayTitle.localizedCaseInsensitiveContains(keyword)
                    || $0.id.localizedCaseInsensitiveContains(keyword)
            }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if path.isEmpty {
                        Text(text)
                            .font(.system(size: 13))
                            .lineLimit(6)
                    } else {
                        Text(AppModel.fileName(path))
                            .font(.system(size: 13, weight: .medium))
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(path.isEmpty ? L("要转发的文本", "Text to forward") : L("要转发的文件", "File to forward"))
                }

                Section {
                    TextField(L("说明（可空）", "Note (optional)"), text: $note, axis: .vertical)
                        .lineLimit(1...4)
                    Toggle(L("附一句执行指令", "Attach an instruction"), isOn: $attachCommand)
                } header: {
                    Text(L("附加内容", "Attached"))
                } footer: {
                    Text(attachCommand ? L("会附上：「请把上面这个文件作为输入继续处理。」", "Adds: “Use the file above as input and continue.”") : L("只发路径与说明。", "Sends only the path and note."))
                }

                Section {
                    if rows.isEmpty {
                        Text(L("没有其它会话可转发", "No other chats to forward to")).foregroundStyle(.secondary)
                    } else {
                        ForEach(rows) { row in
                            Button {
                                Task { await send(row) }
                            } label: {
                                rowLabel(row)
                            }
                            .buttonStyle(.plain)
                            .disabled(sendingTo != nil)
                        }
                    }
                } header: {
                    Text(L("发送到", "Send to"))
                }

                if let error {
                    Section { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: L("搜索会话", "Search sessions"))
            .navigationTitle(L("转发到会话", "Forward to chat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L("取消", "Cancel")) { dismiss() } }
            }
        }
    }

    /// 单行会话：标题 + 相对时间（没有就退化成 id 后 8 位）
    ///
    /// 单独成函数是有原因的：写在 ForEach 里那句
    /// `row.timeLabel.isEmpty ? row.id.suffix(8) : row.timeLabel`
    /// 把 String 和 Substring 混在一个三元里，Swift 的类型推断会直接超时
    /// （CI 报 "unable to type-check this expression in reasonable time"）。
    @ViewBuilder
    private func rowLabel(_ row: SessionRow) -> some View {
        let subtitle: String = row.timeLabel.isEmpty
            ? String(row.id.suffix(8))
            : row.timeLabel
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayTitle).font(.system(size: 14))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if sendingTo == row.id {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "paperplane")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func send(_ row: SessionRow) async {
        guard sendingTo == nil else { return }
        sendingTo = row.id
        error = nil
        defer { sendingTo = nil }
        do {
            try await model.forwardFile(
                path: path,
                text: text,
                to: row.id,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                attachCommand: attachCommand
            )
            dismiss()
        } catch {
            self.error = L("发送失败：\(error.localizedDescription)", "Send failed: \(error.localizedDescription)")
        }
    }
}
