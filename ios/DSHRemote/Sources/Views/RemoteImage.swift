import ImageIO
import SwiftUI
import UIKit

/// 从文本里找出电脑上的图片路径，并通过桥把它们拉下来显示。
///
/// 为什么要在客户端解析：DSH 把生成的文件路径直接写进助手消息文本
/// （`![](...)` 或裸路径），服务端不做渲染约定，所以手机这边负责认出来。
/// 兼容层：媒体扫描逻辑已迁到 Core/MediaRefScan.swift（纯 Foundation，可单测）。
/// 这里保留原有 API 名，避免改动各处调用点。
enum ImageRef {
    typealias Kind = MediaKind

    static func kind(of path: String) -> Kind? { MediaRefScan.kind(of: path) }
    static func mediaPaths(in text: String, kind wanted: Kind) -> [String] {
        MediaRefScan.mediaPaths(in: text, kind: wanted)
    }
    static func paths(in text: String) -> [String] { MediaRefScan.paths(in: text) }
    static func cleaned(_ text: String) -> String { MediaRefScan.cleaned(text) }
}

/// 通过桥读取图片（分块加密下载），带内存缓存
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var cache = [String: UIImage]()
    /// 记录写入顺序，超过容量时按最久未用淘汰
    private var order: [String] = []
    private let capacity = 24
    /// 下载/解码失败的路径。**必须设上限**：每张坏图都会记住一个 path，
    /// 长期使用（尤其目录里堆了损坏文件）会一路涨。
    private var failed = Set<String>()
    private let failedCapacity = 200

    func cached(_ path: String) -> UIImage? { cache[path] }

    /// 内存缓存淘汰（磁盘缓存命中后也要走一次，保持「最近用过的留在内存」）
    private func trimIfNeeded() {
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
    func isFailed(_ path: String) -> Bool { failed.contains(path) }

    /// 磁盘缓存目录（`Caches/thumbs`）：App 重启后不必重新下载
    private static let diskDir: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func diskKey(_ path: String) -> String {
        // 路径里的非法字符多，直接取稳定哈希做文件名
        let hash = path.utf8.reduce(UInt64(0xcbf1_9ce4_8422_2325)) { h, b in
            (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func diskLoad(_ path: String) -> UIImage? {
        guard let dir = diskDir else { return nil }
        let file = dir.appendingPathComponent(diskKey(path))
        guard let data = try? Data(contentsOf: file) else { return nil }
        return UIImage(data: data)
    }

    private static func diskSave(_ path: String, image: UIImage) {
        guard let dir = diskDir else { return }
        let file = dir.appendingPathComponent(diskKey(path))
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func load(path: String, model: AppModel) async -> UIImage? {
        if let hit = cache[path] { return hit }
        // 内存没命中先看磁盘 —— 这是「重启后全部重下」的根因
        if let disk = Self.diskLoad(path) {
            cache[path] = disk
            order.append(path)
            trimIfNeeded()
            return disk
        }
        if failed.contains(path) { return nil }
        model.markMain("img:download")
        do {
            // 让电脑端压好再传：列表里只需要 ~900px，比拉原图（动辄十几 MB）
            // 再本地解码便宜两个数量级；点开看大图时另有 2048 的预览路径。
            let data = try await model.download(path: path, preview: true, maxWidth: 900)
            // 不能在主线程直接 UIImage(data:) —— 那是懒解码，真正解码发生在渲染时，
            // 一张 2835×6144 的图要 70MB，界面会直接卡住。
            // 这里在后台用 CGImageSource 只解码出一个够显示的缩略图。
            model.markMain("img:decode")
            let image = await Task.detached(priority: .userInitiated) {
                Self.decodeThumbnail(data, maxPixel: 1600)
            }.value
            guard let image else {
                if failed.count >= failedCapacity { failed.removeAll(keepingCapacity: true) }
                failed.insert(path)
                return nil
            }
            cache[path] = image
            Self.diskSave(path, image: image)
            order.removeAll { $0 == path }
            order.append(path)
            // 图片很占内存，缓存到 24 张就淘汰最旧的
            while order.count > capacity, let oldest = order.first {
                order.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            return image
        } catch {
            if failed.count >= failedCapacity { failed.removeAll(keepingCapacity: true) }
            failed.insert(path)
            return nil
        }
    }

    /// 后台解码出缩略图（非隔离方法，随便哪个线程调）
    /// 注意：整段包在 `autoreleasepool` 里。
    ///
    /// 一张 2800×6000 的图解码过程中会产生大量临时对象（CGImage、中间位图、NSData 副本），
    /// 没有 autoreleasepool 的话它们要等整个 Task 结束才释放；连续解码几十张时
    /// 峰值会叠加到几百 MB。包一层能保证每次解码结束就还。
    nonisolated static func decodeThumbnail(_ data: Data, maxPixel: Int) -> UIImage? {
        autoreleasepool { decodeThumbnailInner(data, maxPixel: maxPixel) }
    }

    private nonisolated static func decodeThumbnailInner(_ data: Data, maxPixel: Int) -> UIImage? {
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
                    Text(L("加载图片…", "Loading image…")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    Text(L("读不到这张图（路径可能不在电脑允许的目录里）", "Can't load this image (path may be outside the allowed folders)"))
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
                .animation(Motion.enabled
                       ? .interactiveSpring(response: 0.28, dampingFraction: 0.82)
                       : nil,
                       value: scale)
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
            Text(scale > 1.05
                 ? L("双指缩放 · 拖动平移 · 双击还原", "Pinch to zoom · drag to pan · double-tap to reset")
                 : L("双指缩放 · 双击放大", "Pinch to zoom · double-tap to enlarge"))
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
