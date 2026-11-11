import SwiftUI

/// 文件页里点视频/音频时的预览：先能播、再决定存不存。
///
/// 之前点这类文件只会下载到 App 文档目录然后弹分享 ——
/// 手机上根本没地方直接播放，等于白下载一次。
struct MediaPreviewSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let entry: FsEntry

    @State private var saving = false
    @State private var message: String?
    @State private var shareItems: [Any] = []

    private var kind: ImageRef.Kind? { ImageRef.kind(of: entry.name) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if kind == .video {
                    RemoteVideo(path: entry.fullPath)
                        .padding(.horizontal, 12)
                } else {
                    RemoteAudio(path: entry.fullPath)
                        .padding(.horizontal, 12)
                }

                if let size = entry.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.top, 12)
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await saveToPhone() }
                    } label: {
                        if saving { ProgressView().controlSize(.mini) } else { Text("存到手机") }
                    }
                    .disabled(saving)
                }
            }
            .sheet(isPresented: Binding(
                get: { !shareItems.isEmpty },
                set: { if !$0 { shareItems = [] } }
            )) {
                ActivityView(items: shareItems)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    /// 下载到 App 文档目录，再弹系统分享（存到「文件」/ 相册 / AirDrop）
    private func saveToPhone() async {
        saving = true
        defer { saving = false }
        do {
            let data = try await model.download(path: entry.fullPath)
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let target = dir.appendingPathComponent(entry.name)
            try data.write(to: target, options: .atomic)
            message = "已保存到「文件」App → 我的 iPhone → DSH Helm"
            shareItems = [target]
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }
}
