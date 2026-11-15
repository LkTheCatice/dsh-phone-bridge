import SwiftUI

/// 一条消息里的所有附件（图片 / 视频 / 音频）。
///
/// 为什么媒体不进列表 cell：
/// - cell 里塞 SwiftUI 视图要 `UIHostingController`，复用时的生命周期很麻烦；
/// - 图片解码/视频封面都是重活，放进列表会把 cell 复用的收益吃掉。
///
/// 所以列表里只显示一行「📎 2 张图片 · 1 个视频」，点开才渲染。
/// 这样滚动成本与消息内容无关，媒体也仍然看得到。
struct AttachmentSheet: View {
    let entry: ChatEntry
    @Environment(\.dismiss) private var dismiss

    private var refs: MediaRefs { MediaRefCache.refs(for: entry.text) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(refs.images, id: \.self) { path in
                        VStack(alignment: .leading, spacing: 4) {
                            Text((path as NSString).lastPathComponent)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            RemoteImage(path: path)
                        }
                    }
                    ForEach(refs.videos, id: \.self) { path in
                        VStack(alignment: .leading, spacing: 4) {
                            Text((path as NSString).lastPathComponent)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            RemoteVideo(path: path)
                        }
                    }
                    ForEach(refs.audios, id: \.self) { path in
                        VStack(alignment: .leading, spacing: 4) {
                            Text((path as NSString).lastPathComponent)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            RemoteAudio(path: path)
                        }
                    }
                    if refs.isEmpty {
                        Text(L("这条消息没有可显示的附件", "No attachments to show here"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
            .navigationTitle(L("附件", "Attachments"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("关闭", "Close")) { dismiss() }
                }
            }
        }
    }
}
