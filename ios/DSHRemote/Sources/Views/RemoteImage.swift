import SwiftUI
import UIKit

/// 从文本里找出电脑上的图片路径，并通过桥把它们拉下来显示。
///
/// 为什么要在客户端解析：DSH 把生成的文件路径直接写进助手消息文本
/// （`![](...)` 或裸路径），服务端不做渲染约定，所以手机这边负责认出来。
enum ImageRef {
    private static let mdPattern = #"!\[[^\]]*\]\(\s*([^)]+?)\s*\)"#
    // 盘符 + 正斜杠（D:/...）也必须认：DSH 的 present 工具输出的正是这种形式，
    // 旧正则只写了 D:\ 于是把盘符吃掉，最后按当前盘解析成 C:\Documents\... 而 404。
    private static let barePattern = #"((?:[A-Za-z]:[\\/]|/)[^\s"'<>|\[\]]*?\.(?:png|jpe?g|gif|webp|bmp))"#

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]

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
    private var failed = Set<String>()

    func cached(_ path: String) -> UIImage? { cache[path] }
    func isFailed(_ path: String) -> Bool { failed.contains(path) }

    func load(path: String, model: AppModel) async -> UIImage? {
        if let hit = cache[path] { return hit }
        if failed.contains(path) { return nil }
        do {
            let data = try await model.download(path: path)
            guard let image = UIImage(data: data) else {
                failed.insert(path)
                return nil
            }
            cache[path] = image
            return image
        } catch {
            failed.insert(path)
            return nil
        }
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
                        ZStack {
                            Color.black.ignoresSafeArea()
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding(8)
                        }
                        .onTapGesture { shown = false }
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
