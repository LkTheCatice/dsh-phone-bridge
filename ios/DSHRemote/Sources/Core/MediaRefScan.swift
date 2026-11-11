import Foundation

// MARK: - 媒体路径扫描（纯 Foundation，无 UIKit 依赖）
//
// 从 Views/RemoteImage.swift 迁来：这部分只做正则扫描与缓存，
// 与 UIKit 无关。迁到 Core 后有两个好处：
// 1. **可测**：Windows 上能跑 selftest（畸形路径、超长文本、混合扩展名）；
// 2. **可复用**：UICollectionView 的 cell 也能用它判断「这条消息有没有附件」，
//    不必为了扫路径去依赖 SwiftUI。

enum MediaKind {
    case image, video, audio
}

enum MediaRefScan {
    /// 媒体类型：图片 / 视频 / 音频
    // 见文件末尾的 MediaMediaKind 定义（顶层，供 Core 与 iOS 共用）
    typealias Kind = MediaKind

    private static let mdPattern = #"!\[[^\]]*\]\(\s*([^)]+?)\s*\)"#
    // 盘符 + 正斜杠（D:/...）也必须认：DSH 的 present 工具输出的正是这种形式，
    // 旧正则只写了 D:\ 于是把盘符吃掉，最后按当前盘解析成 C:\Documents\... 而 404。
    private static let barePattern = #"((?:[A-Za-z]:[\\/]|/)[^\s"'<>|\[\]]*?\.(?:png|jpe?g|gif|webp|bmp))"#

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"]

    /// 按扩展名判断媒体类型
    static func kind(of path: String) -> MediaKind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        return nil
    }

    /// 从一段文本里挑出指定类型的路径
    static func mediaPaths(in text: String, kind wanted: MediaKind) -> [String] {
        allAbsolutePaths(in: text).filter { kind(of: $0) == wanted }
    }

    // 正则必须缓存成 static：每次调用都 NSRegularExpression(pattern:) 会重新编译，
    // 而 ChatBubble 每次 body 重建都会调这些函数 —— 一屏几十条消息乘上流式的
    // 每秒十几次刷新，就是主线程被正则编译拖死的直接原因。
    private static let mdRegex = try? NSRegularExpression(pattern: mdPattern, options: [.caseInsensitive])
    private static let bareRegex = try? NSRegularExpression(pattern: barePattern, options: [.caseInsensitive])
    private static let mediaRegex = try? NSRegularExpression(
        pattern: #"((?:[A-Za-z]:[\\/]|/)[^\s"'<>|\[\]]*?\.[A-Za-z0-9]{2,5})"#,
        options: [.caseInsensitive]
    )

    /// 扫出文本里所有「绝对路径 + 已知媒体扩展名」的字符串
    private static func allAbsolutePaths(in text: String) -> [String] {
        guard !text.isEmpty, let regex = mediaRegex else { return [] }
        let extensions = imageExtensions.union(videoExtensions).union(audioExtensions)
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

        for regex in [Self.mdRegex, Self.bareRegex].compactMap({ $0 }) {
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
        // 同上：超长文本跳过改写，别为一屏乱码付几万字符的正则替换
        if text.count > 20_000 { return text }
        guard let regex = Self.mdRegex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "🖼 $1")
    }
}

/// 一条消息里出现的媒体路径（图片 / 视频 / 音频）
struct MediaRefs {
    let images: [String]
    let videos: [String]
    let audios: [String]

    var isEmpty: Bool { images.isEmpty && videos.isEmpty && audios.isEmpty }
    static let empty = MediaRefs(images: [], videos: [], audios: [])
}

/// 媒体路径扫描结果缓存。
///
/// ChatBubble 每次 body 重建都会问「这段文本里有哪些图片/视频/音频」，
/// 而条目一多，body 每秒重建十几次 —— 不做缓存的话就是
/// 「每条消息 × 3 次全文正则扫描 × 每秒十几次」，主线程直接卡死。
/// 这里按文本缓存，同一条消息只在第一次渲染时扫一遍。
enum MediaRefCache {
    private static var storage: [String: MediaRefs] = [:]
    private static var order: [String] = []
    private static let capacity = 120

    static func refs(for text: String) -> MediaRefs {
        guard !text.isEmpty else { return .empty }
        // 超长文本不扫描：三趟全文正则的成本随长度线性涨，而工具输出那种
        // 几万字符的日志里几乎不可能真的有图片路径 —— 主线程不值得为它扫。
        if text.count > 20_000 { return .empty }
        if let hit = storage[text] { return hit }
        let computed = MediaRefs(
            images: MediaRefScan.paths(in: text),
            videos: MediaRefScan.mediaPaths(in: text, kind: .video),
            audios: MediaRefScan.mediaPaths(in: text, kind: .audio)
        )
        storage[text] = computed
        order.append(text)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
        return computed
    }
}
