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
    private var failed = Set<String>()

    func cached(_ path: String) -> UIImage? { cache[path] }
    func isFailed(_ path: String) -> Bool { failed.contains(path) }

    func load(path: String, model: AppModel) async -> UIImage? {
        if let hit = cache[path] { return hit }
        if failed.contains(path) { return nil }
        model.markMain("img:download")
        do {
            let data = try await model.download(path: path)
            // 不能在主线程直接 UIImage(data:) —— 那是懒解码，真正解码发生在渲染时，
            // 一张 2835×6144 的图要 70MB，界面会直接卡住。
            // 这里在后台用 CGImageSource 只解码出一个够显示的缩略图。
            model.markMain("img:decode")
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
