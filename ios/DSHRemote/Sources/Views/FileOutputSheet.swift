import SwiftUI
import UIKit

/// 产物文件的打开页：能预览的直接看，不能预览的给「下载/分享」。
///
/// 与「工具详情」的区别：那是给 log 用的，这是给**产物**用的 ——
/// 从 `📄/🖼/🎬 …` 卡片点进来的入口。
struct FileOutputSheet: View {
    let entry: ChatEntry
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var textBody: String?
    @State private var loading = false
    @State private var error: String?
    @State private var shareURL: URL?
    @State private var showShare = false
    /// 正在转发到别的会话
    @State private var showForward = false
    /// 标注（PencilKit 画布）：先把原图拉下来，再进编辑器
    @State private var annotateImage: UIImage?
    @State private var annotating = false

    private var path: String { entry.detail ?? "" }
    private var kind: FileKind { FileKind(path: path) }
    private var name: String { AppModel.fileName(path) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header

                    switch kind {
                    case .image:
                        RemoteImage(path: path)
                    case .video:
                        RemoteVideo(path: path)
                    case .audio:
                        RemoteAudio(path: path)
                    case .text:
                        textPreview
                    default:
                        Text(L("这类文件不能在手机上直接看，点右上「下载」取回，或在电脑上打开。", "This file can't be previewed on the phone. Tap Download, or open it on the computer."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    }
                    pathRow
                }
                .padding(14)
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("关闭", "Close")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await download() }
                    } label: {
                        if loading { ProgressView().controlSize(.mini) } else { Text(L("下载", "Download")) }
                    }
                    .disabled(loading)
                }
                // 标注：图片才有。以前画笔只能从"附件"进，产物图片进不去
                if kind == .image {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await openAnnotate() }
                        } label: {
                            if annotating {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "pencil.tip.crop.circle")
                            }
                        }
                        .disabled(annotating)
                    }
                }
                // 转发：只发路径引用，不传文件本体 ——
                // 手机打不开的类型（dmg/exe/7z…）也能转，且不耗流量。
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showForward = true
                    } label: {
                        Image(systemName: "paperplane")
                    }
                    .disabled(path.isEmpty)
                }
            }
            .sheet(item: $annotateImage) { image in
                ImageEditorSheet(
                    image: image,
                    onCommit: { merged in
                        annotateImage = nil
                        saveAnnotated(merged)
                    },
                    onCancel: { annotateImage = nil }
                )
            }
            .sheet(isPresented: $showForward) {
                ForwardSessionSheet(path: path)
                    .environmentObject(model)
            }
            .sheet(isPresented: $showShare) {
                if let shareURL { ActivityView(items: [shareURL]) }
            }
            .task { await loadIfNeeded() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(kind.icon).font(.system(size: 15))
            Text(name).font(.system(size: 13, weight: .medium)).lineLimit(2)
            Spacer(minLength: 0)
            Text(kind.tag)
                .font(.system(size: 11))
                .foregroundStyle(kind.canPreview ? Color.accentColor : Color.secondary)
        }
    }

    @ViewBuilder
    private var textPreview: some View {
        if let textBody {
            Text(textBody)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else if loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L("读取中…", "Loading…")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var pathRow: some View {
        Text(path)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
    }

    private func loadIfNeeded() async {
        guard kind == .text, textBody == nil, !path.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            // 只取前 200KB 当预览：md/日志再长也不需要全量
            if let data = try? await model.download(path: path, onProgress: nil),
               data.count > 0 {
                let clipped = data.prefix(200 * 1024)
                textBody = String(data: clipped, encoding: .utf8)
                    ?? String(data: clipped, encoding: .isoLatin1)
                    ?? L("（无法按文本解析）", "(can't parse as text)")
            } else {
                error = L("读不到文件内容（可能不在电脑允许的目录里）", "Can't read the file (maybe outside the allowed folders)")
            }
        }
    }

    /// 拉一张 2048px 的图进标注器（和「看图」用的 900px 缩略图分开：
    /// 标注后的笔迹要压在更清晰的底图上，否则放大看全是糊的）
    private func openAnnotate() async {
        guard !annotating else { return }
        annotating = true
        defer { annotating = false }
        do {
            let data = try await model.download(path: path, preview: true, maxWidth: 2048)
            guard let image = UIImage(data: data) else {
                error = L("这张图读不出来", "Can't load this image")
                return
            }
            annotateImage = image
        } catch {
            self.error = L("取原图失败：\(error.localizedDescription)", "Failed to fetch the original: \(error.localizedDescription)")
        }
    }

    /// 标注完成：存相册（产物在电脑上，手机上最自然的去处就是相册）
    private func saveAnnotated(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        model.showToast(L("已存到相册", "Saved to Photos"))
    }

    private func download() async {
        loading = true
        defer { loading = false }
        do {
            let data = try await model.download(path: path)
            guard !data.isEmpty else { error = L("文件为空", "File is empty"); return }
            let dir = FileManager.default.temporaryDirectory
            let url = dir.appendingPathComponent(name.isEmpty ? "download.bin" : name)
            try data.write(to: url)
            shareURL = url
            showShare = true
        } catch {
            self.error = L("下载失败：\(error.localizedDescription)", "Download failed: \(error.localizedDescription)")
        }
    }
}
