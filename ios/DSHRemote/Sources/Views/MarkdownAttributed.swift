import SwiftUI

/// 把 markdown 块合成**一个** AttributedString，用单个 Text 渲染。
///
/// 为什么不再用「每个 block 一个 Text」：
/// 一条长回答常被拆成几十个 block（代码块、表格、列表各一个），
/// SwiftUI 里每个 block 都是一个独立视图节点，而 LazyVStack 没有 cell 复用
/// —— 20 条消息就是上百个节点参与测量，中文 CoreText 排版又贵，
/// 滚动/流式一叠加就卡死几十秒（实测 mark=md 19594ms）。
///
/// 反观 QQ 那类实现：UITableView 的 cell 复用 + UITextView 整条消息一次排版。
/// 这里用「一个 AttributedString + 一个 Text」逼近同样的效果：
/// 节点数从 N 降到 1，样式仍然保留（字号、粗细、等宽、缩进、背景色、前缀）。
enum MarkdownAttributed {

    static func build(_ blocks: [Block]) -> AttributedString {
        var out = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                out += AttributedString("\n")
                // 段落之间留白（用换行 + 行高控制，比 VStack spacing 便宜）
                if case .code = block {} else {
                    out += AttributedString("\n")
                }
            }
            out += render(block)
        }
        return out
    }

    private static func render(_ block: Block) -> AttributedString {
        switch block {
        case let .heading(level, text):
            var s = inline(text)
            s.font = .system(size: level <= 2 ? 20 : 17, weight: .semibold)
            return s

        case let .paragraph(text):
            var s = inline(text)
            s.font = .system(size: 15)
            return s

        case let .quote(text):
            var s = inline(text)
            s.font = .system(size: 14)
            s.foregroundColor = .secondary
            // 引用用「左边距 + 竖线感」表达：正文前加两个全角空格
            return prepend("▍ ", to: s)

        case let .code(code, lang):
            var s = AttributedString()
            if let lang, !lang.isEmpty {
                var tag = AttributedString(lang + "\n")
                tag.font = .system(size: 10, design: .monospaced)
                tag.foregroundColor = .secondary
                s += tag
            }
            var body = AttributedString(clampCode(code))
            body.font = .system(size: 12, design: .monospaced)
            // 代码块背景：NSAttributedString 会按字符着色，视觉上接近「块」
            body.backgroundColor = Color.secondary.opacity(0.12)
            s += body
            return s

        case let .bullet(items):
            var s = AttributedString()
            for (i, item) in items.enumerated() {
                if i > 0 { s += AttributedString("\n") }
                var line = inline(item)
                line.font = .system(size: 15)
                s += prepend("• ", to: line)
            }
            return s

        case let .ordered(items):
            var s = AttributedString()
            for (i, item) in items.enumerated() {
                if i > 0 { s += AttributedString("\n") }
                var line = inline(item)
                line.font = .system(size: 15)
                s += prepend("\(i + 1). ", to: line)
            }
            return s

        case .divider:
            var s = AttributedString("────────")
            s.foregroundColor = .tertiary
            return s

        case let .table(headers, rows):
            // 表格降级成「对齐的文本行」：仍然可读，且不需要 Grid 的布局成本
            var s = AttributedString()
            if !headers.isEmpty {
                var head = AttributedString(headers.joined(separator: "  |  ") + "\n")
                head.font = .system(size: 12, weight: .semibold)
                s += head
                var rule = AttributedString(String(repeating: "─", count: max(8, headers.count * 6)) + "\n")
                rule.foregroundColor = .tertiary
                s += rule
            }
            for (i, row) in rows.enumerated() {
                if i > 0 { s += AttributedString("\n") }
                var line = AttributedString(row.joined(separator: "  |  "))
                line.font = .system(size: 12)
                s += line
            }
            return s
        }
    }

    /// 行内格式（粗体/斜体/行内代码）—— 走已有的缓存，避免重复解析
    private static func inline(_ text: String) -> AttributedString {
        if text.count > MarkdownCache.inlineMaxChars {
            var s = AttributedString(text)
            s.font = .system(size: 15)
            return s
        }
        if let cached = MarkdownCache.inline(text) {
            return cached
        }
        return AttributedString(text)
    }

    private static func prepend(_ prefix: String, to text: AttributedString) -> AttributedString {
        var p = AttributedString(prefix)
        p.foregroundColor = .secondary
        return p + text
    }

    /// 代码块截断：超长代码只保留前 4000 字符（排版成本随字数线性涨）
    private static func clampCode(_ code: String) -> String {
        code.count > 4_000
            ? String(code.prefix(4_000)) + "\n…（其余 \(code.count - 4_000) 字已省略）"
            : code
    }
}
