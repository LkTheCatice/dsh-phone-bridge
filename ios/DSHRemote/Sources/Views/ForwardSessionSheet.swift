import SwiftUI

/// 把产物文件转发到另一个会话。
///
/// 只发**路径引用**：两端在同一台电脑上，目标会话拿到路径就能读；
/// 手机不能预览/下载的类型（dmg/exe/7z…）也能用这条路，还不耗流量。
struct ForwardSessionSheet: View {
    let path: String

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
                    Text(AppModel.fileName(path))
                        .font(.system(size: 13, weight: .medium))
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("要转发的文件")
                }

                Section {
                    TextField("说明（可空）", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                    Toggle("附一句执行指令", isOn: $attachCommand)
                } header: {
                    Text("附加内容")
                } footer: {
                    Text(attachCommand ? "会附上：「请把上面这个文件作为输入继续处理。」" : "只发路径与说明。")
                }

                Section {
                    if rows.isEmpty {
                        Text("没有其它会话可转发").foregroundStyle(.secondary)
                    } else {
                        ForEach(rows) { row in
                            Button {
                                Task { await send(row) }
                            } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.displayTitle).font(.system(size: 14))
                                        Text(row.relativeTime.isEmpty ? row.id.suffix(8) : row.relativeTime)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if sendingTo == row.id {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "paperplane").font(.system(size: 13))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(sendingTo != nil)
                        }
                    }
                } header: {
                    Text("发送到")
                }

                if let error {
                    Section { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索会话")
            .navigationTitle("转发到会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
            }
        }
    }

    private func send(_ row: SessionRow) async {
        guard sendingTo == nil else { return }
        sendingTo = row.id
        error = nil
        defer { sendingTo = nil }
        do {
            try await model.forwardFile(
                path: path,
                to: row.id,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                attachCommand: attachCommand
            )
            dismiss()
        } catch {
            self.error = "发送失败：\(error.localizedDescription)"
        }
    }
}
