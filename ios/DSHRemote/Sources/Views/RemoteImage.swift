import ImageIO
import SwiftUI
import UIKit

/// 从文本里找出电脑上的图片路径，并通过桥把它们拉下来显示。
///
/// 为什么要在客户端解析：DSH 把生成的文件路径直接写进助手消息文本
/// （`![](...)` 或裸路径），服务端不做渲染约定，所以手机这边负责认出来。
enum ImageRef {
    /// 媒体类型：图片 / 视频 / 音频
    enum Kind {
        case image, video, audio
    }

    private static let mdPattern = #"!\[[^\]]*\]\(\s*([^)]+?)\s*\)"#
    // 盘符 + 正斜杠（D:/...）也必须认：DSH 的 present 工具输出的正是这种形式，
    // 旧正则只写了 D:\ 于是把盘符吃掉，最后按当前盘解析成 C:\Documents\... 而 404。
    private static let barePattern = #"((?:[A-Za-z]:[\\/]|/)[^\s"'<>|\[\]]*?\.(?:png|jpe?g|gif|webp|bmp))"#

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"]

    /// 按扩展名判断媒体类型
    static func kind(of path: String) -> Kind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        return nil
    }

    /// 从一段文本里挑出指定类型的路径
    static func mediaPaths(in text: String, kind wanted: Kind) -> [String] {
        allAbsolutePaths(in: text).filter { kind(of: $0) == wanted }
    }

    /// 扫出文本里所有「绝对路径 + 已知媒体扩展名」的字符串
    private static func allAbsolutePaths(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let extensions = imageExtensions.union(videoExtensions).union(audioExtensions)
        let pattern = #"((?:[A-Za-z]:[\\/]|/)[^\s"'<>|\[\]]*?\.[A-Za-z0-9]{2,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var found: [String] = []
        var seen = Set<String>()
        for match in regex.matches(in: text, range: range) {
            guard let pathRange = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[pathRange])
            let ext = (value as NSString).pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }
            guard seen.insert(value).inserted else { continue }
            found.append(value)
        }
        return found
    }

    /// 返回文本中出现的图片路径（去重、保序）
    static func paths(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var found: [String] = []
        var seen = Set<String>()

        func add(_ raw: String) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 去掉 file:// 前缀与首尾引号
            if value.hasPrefix("file://") { value = String(value.dropFirst(7)) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            guard !value.isEmpty else { return }
            let ext = (value as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { return }
            // 必须像绝对路径（D:\ / D:/ / 开头斜杠），避免把普通文件名当路径
            guard value.contains(":\\") || value.contains(":/") || value.hasPrefix("/") else { return }
            guard !seen.contains(value) else { return }
            seen.insert(value)
            found.append(value)
        }

        for pattern in [mdPattern, barePattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                let captureIndex = match.numberOfRanges > 1 ? 1 : 0
                guard let r = Range(match.range(at: captureIndex), in: text) else { continue }
                add(String(text[r]))
            }
        }
        return found
    }

    /// 生成给人看的文本：把 Markdown 图片语法换成短名字，避免一屏乱码
    static func cleaned(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: mdPattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "🖼 $1")
    }
}

/// 通过桥读取图片（分块加密下载），带内存缓存
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var cache = [String: UIImage]()
    /// 记录写入顺序，超过容量时按最久未用淘汰
    private var order: [String] = []
    private let capacity = 24
    private var failed = Set<String>()

    func cached(_ path: String) -> UIImage? { cache[path] }
    func isFailed(_ path: String) -> Bool { failed.contains(path) }

    func load(path: String, model: AppModel) async -> UIImage? {
        if let hit = cache[path] { return hit }
        if failed.contains(path) { return nil }
        do {
            let data = try await model.download(path: path)
            // 不能在主线程直接 UIImage(data:) —— 那是懒解码，真正解码发生在渲染时，
            // 一张 2835×6144 的图要 70MB，界面会直接卡住。
            // 这里在后台用 CGImageSource 只解码出一个够显示的缩略图。
            let image = await Task.detached(priority: .userInitiated) {
                Self.decodeThumbnail(data, maxPixel: 1600)
            }.value
            guard let image else {
                failed.insert(path)
                return nil
            }
            cache[path] = image
            order.removeAll { $0 == path }
            order.append(path)
            // 图片很占内存，缓存到 24 张就淘汰最旧的
            while order.count > capacity, let oldest = order.first {
                order.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            return image
        } catch {
            failed.insert(path)
            return nil
        }
    }

    /// 后台解码出缩略图（非隔离方法，随便哪个线程调）
    nonisolated static func decodeThumbnail(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: thumbnail)
        }
        return UIImage(data: data)
    }
}

struct RemoteImage: View {
    let path: String
    @EnvironmentObject private var model: AppModel
    @State private var image: UIImage?
    @State private var loading = true
    @State private var shown = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { shown = true }
                    .fullScreenCover(isPresented: $shown) {
                        ImageViewer(image: image, remotePath: path)
                    }
            } else if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("加载图片…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    Text("读不到这张图（路径可能不在电脑允许的目录里）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            loading = true
            image = await ImageCache.shared.load(path: path, model: model)
            loading = false
        }
    }
}

/// 全屏看图：双指缩放、双击放大、拖动平移，可存相册或分享。
struct ImageViewer: View {
    let image: UIImage
    let remotePath: String

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var savedToast: String?
    @State private var shareURL: URL?

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 8

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(maxScale, max(minScale * 0.6, lastScale * value))
                        }
                        .onEnded { _ in
                            lastScale = scale
                            if scale < minScale {
                                withAnimation { scale = minScale; offset = .zero; lastOffset = .zero }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1 else { return }
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in lastOffset = offset }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > 1.05 {
                            scale = 1; offset = .zero; lastOffset = .zero
                        } else {
                            scale = 3
                        }
                        lastScale = scale
                    }
                }

            VStack {
                HStack(spacing: 22) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Spacer()

                    Button {
                        saveToPhotos()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 6) {
                    if let savedToast {
                        Text(savedToast)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Text(scale > 1.05 ? "双指缩放 · 拖动平移 · 双击还原" : "双指缩放 · 双击放大")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(remotePath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 24)
                }
                .padding(.bottom, 18)
            }
        }
        .statusBarHidden(true)
        .onAppear(perform: prepareShareFile)
    }

    private func prepareShareFile() {
        guard shareURL == nil else { return }
        let name = (remotePath as NSString).lastPathComponent
        let safe = name.isEmpty ? "image.png" : name
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        let data = image.pngData() ?? image.jpegData(compressionQuality: 0.95)
        guard let data else { return }
        try? data.write(to: url, options: .atomic)
        shareURL = url
    }

    private func saveToPhotos() {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        withAnimation { savedToast = "已保存到相册" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { savedToast = nil }
        }
    }
}
