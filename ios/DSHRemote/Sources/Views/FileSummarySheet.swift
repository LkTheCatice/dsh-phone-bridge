import SwiftUI

/// 「本轮产出」的全部文件（清单卡里点「还有 N 个」时打开）
///
/// 只做一件事：把这一轮的所有产物平铺出来，点谁开谁。
/// 为什么需要它：清单卡最多显示 5 行，超出的文件此前**没有任何入口**能打开
/// —— 用户只能看到"还有 3 个"，点不动。
struct FileSummarySheet: View {
    let files: [ChatEntry]
    let onPick: (ChatEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(files) { file in
                        Button {
                            onPick(file)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Text(FileKind(path: file.detail ?? "").icon)
                                    .font(.system(size: 15))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(AppModel.fileName(file.detail ?? ""))
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(file.detail ?? "")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                Text(FileKind(path: file.detail ?? "").tag)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("本轮产出 · \(files.count) 个")
                }
            }
            .navigationTitle("全部产物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
    }
}
