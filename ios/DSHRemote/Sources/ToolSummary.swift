import Foundation

/// 把工具调用的 args 压成「一行人类可读的摘要」。
///
/// 关键点：`args` 在帧里常常是**一段 JSON 字符串**，不是对象 ——
/// 第一次 `JSONSerialization` 解析出来还是 String，必须再解一次才能拿到字典。
/// 之前漏了这一步，于是整段 JSON 被 `hasPrefix("{")` 拦掉，界面上什么都不显示。
///
/// 另外这个解析只在收到帧时做一次，结果存进 `ChatEntry.summary`；
/// 放在 View 的 computed property 里会让每帧重建都重解一遍 JSON，滚动就卡。
enum ToolSummary {
    /// 摘要候选字段，按优先级。`description` 最前 —— DSH 给每个工具调用
    /// 写的人类可读说明就在那儿，电脑端显示的就是它。
    private static let preferredKeys = ["description", "command", "query", "pattern", "prompt", "url", "target", "title", "name"]

    private static let pathKeys = ["file_path", "filePath", "path"]

    static func make(from raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // 最多剥三层「JSON 字符串套 JSON」的情况
        var value: Any = raw
        for _ in 0..<3 {
            guard let text = value as? String,
                  let data = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data, options: [])
            else { break }
            value = parsed
        }
        if let picked = pick(value) { return picked }
        // 实在解析不出来就显示原文（但只在它看起来不像 JSON 时）
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") {
                return clamp(trimmed)
            }
        }
        return nil
    }

    /// 从工具参数里找出所有图片路径（用于在工具行展开时显示缩略图）。
    ///
    /// DSH 运行时读取的图片（read_image 等）路径只出现在 args 里，
    /// 手机端不渲染就完全看不到 —— 而这些图往往正是「这一轮到底看了什么」的关键。
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"]

    static func imagePaths(from raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var value: Any = raw
        for _ in 0..<3 {
            guard let text = value as? String,
                  let data = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data, options: [])
            else { break }
            value = parsed
        }
        var found: [String] = []
        collectPaths(value, into: &found, depth: 0)
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    private static func collectPaths(_ value: Any, into found: inout [String], depth: Int) {
        guard depth < 4 else { return }
        if let text = value as? String {
            let ext = (text as NSString).pathExtension.lowercased()
            // 只看绝对路径 + 图片扩展名，别把普通文案误判成路径
            if imageExtensions.contains(ext), text.contains("/") || text.contains("\\") {
                found.append(text)
            }
            return
        }
        if let dict = value as? [String: Any] {
            for (_, v) in dict { collectPaths(v, into: &found, depth: depth + 1) }
            return
        }
        if let arr = value as? [Any] {
            for item in arr { collectPaths(item, into: &found, depth: depth + 1) }
        }
    }

    private static func pick(_ value: Any, depth: Int = 0) -> String? {
        guard depth < 3 else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : clamp(trimmed)
        }
        if let dict = value as? [String: Any] {
            // 1) description：和电脑端显示一致
            if let d = dict["description"] as? String {
                let t = d.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return clamp(t) }
            }
            // 2) 文件类：目录末两段/文件名:行号
            for key in pathKeys {
                if let p = dict[key] as? String, !p.isEmpty {
                    return shortPath(p, offset: (dict["offset"] as? NSNumber)?.intValue)
                }
            }
            // 3) 其余白名单。刻意不遍历所有 key —— 那样会抓到工具结果里的文案
            for key in preferredKeys {
                if let v = dict[key], let s = pick(v, depth: depth + 1) { return s }
            }
            return nil
        }
        if let arr = value as? [Any] {
            for item in arr {
                if let s = pick(item, depth: depth + 1) { return s }
            }
        }
        return nil
    }

    /// `D:\a\b\ChatView.swift` + offset 39 → `b/ChatView.swift:39`
    private static func shortPath(_ path: String, offset: Int?) -> String {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        let tail = parts.suffix(2).joined(separator: "/")
        let base = tail.isEmpty ? path : tail
        if let offset, offset > 0 { return "\(base):\(offset)" }
        return base
    }

    /// 命令可能很长：只留第一行，超长截断
    private static func clamp(_ text: String) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 64 ? String(trimmed.prefix(64)) + "…" : trimmed
    }
}
