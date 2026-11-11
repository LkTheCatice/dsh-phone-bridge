import UIKit

/// markdown → 单个 `NSAttributedString`（给 `UITextView` 用）。
///
/// 为什么单独写一份 UIKit 版本：
/// SwiftUI 的 `AttributedString` 用的是 `Color`/`Font`，塞进 `UITextView` 会丢样式；
/// 而 `UITextView` 是这条渲染管道的核心（一条消息一个视图、TextKit 排一次、cell 复用）。
///
/// 设计取舍：
/// - 块级结构**不建视图**，全部压进一个 attributed string（红线段：一条消息一个视图）
/// - 代码块用等宽 + 背景色，列表加项目符号，引用加竖线前缀，表格降级成对齐文本
/// - 解析结果按原文缓存，滚动时命中缓存不再解析
enum MarkdownNS {

    private static let cache = NSCache<NSString, NSAttributedString>()

    static func render(_ text: String) -> NSAttributedString {
        if let hit = cache.object(forKey: text as NSString) { return hit }
        let blocks = MarkdownCache.blocksSync(for: text)
        let built = build(blocks)
        // 缓存不可变副本：可变对象被别处改动会污染缓存
        let frozen = NSAttributedString(attributedString: built)
        cache.setObject(frozen, forKey: text as NSString)
        return frozen
    }

    static func build(_ blocks: [Block]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                out.append(NSAttributedString(string: "\n"))
                if case .code = block {} else {
                    out.append(NSAttributedString(string: "\n"))
                }
            }
            out.append(renderBlock(block))
        }
        return out
    }

    // MARK: - 块级

    private static func renderBlock(_ block: Block) -> NSAttributedString {
        switch block {
        case let .heading(level, text):
            let size: CGFloat = level <= 2 ? 20 : 17
            return inline(text, base: .systemFont(ofSize: size, weight: .semibold))

        case let .paragraph(text):
            return inline(text, base: .systemFont(ofSize: 15))

        case let .quote(text):
            let body = inline(text, base: .systemFont(ofSize: 14))
            let out = NSMutableAttributedString(
                string: "▍ ",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: UIColor.tertiaryLabel,
                ]
            )
            out.append(body)
            out.addAttribute(
                .foregroundColor,
                value: UIColor.secondaryLabel,
                range: NSRange(location: 0, length: out.length)
            )
            return out

        case let .code(code, lang):
            let out = NSMutableAttributedString()
            if let lang, !lang.isEmpty {
                out.append(NSAttributedString(
                    string: lang + "\n",
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                        .foregroundColor: UIColor.tertiaryLabel,
                    ]
                ))
            }
            out.append(NSAttributedString(
                string: clampCode(code),
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: UIColor.label,
                    .backgroundColor: UIColor.secondarySystemFill,
                ]
            ))
            return out

        case let .bullet(items):
            let out = NSMutableAttributedString()
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: "\n")) }
                out.append(NSAttributedString(
                    string: "• ",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 15),
                        .foregroundColor: UIColor.secondaryLabel,
                    ]
                ))
                out.append(inline(item, base: .systemFont(ofSize: 15)))
            }
            return out

        case let .ordered(items):
            let out = NSMutableAttributedString()
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: "\n")) }
                out.append(NSAttributedString(
                    string: "\(i + 1). ",
                    attributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular),
                        .foregroundColor: UIColor.secondaryLabel,
                    ]
                ))
                out.append(inline(item, base: .systemFont(ofSize: 15)))
            }
            return out

        case .divider:
            return NSAttributedString(
                string: "────────",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12),
                    .foregroundColor: UIColor.tertiaryLabel,
                ]
            )

        case let .table(headers, rows):
            // 表格降级成「对齐文本行」：可读、不需要 Grid 布局
            let out = NSMutableAttributedString()
            if !headers.isEmpty {
                out.append(NSAttributedString(
                    string: headers.joined(separator: "  |  ") + "\n",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: UIColor.label,
                    ]
                ))
                out.append(NSAttributedString(
                    string: String(repeating: "─", count: max(8, headers.count * 6)) + "\n",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 10),
                        .foregroundColor: UIColor.tertiaryLabel,
                    ]
                ))
            }
            for (i, row) in rows.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: "\n")) }
                out.append(NSAttributedString(
                    string: row.joined(separator: "  |  "),
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 12),
                        .foregroundColor: UIColor.label,
                    ]
                ))
            }
            return out
        }
    }

    // MARK: - 行内（**粗体** / *斜体* / `代码`）

    private static func inline(_ text: String, base: UIFont) -> NSAttributedString {
        let cleaned = MarkdownInline.strip(text)
        return NSAttributedString(
            string: cleaned,
            attributes: [.font: base, .foregroundColor: UIColor.label]
        )
    }

    private static func clampCode(_ code: String) -> String {
        code.count > 4_000
            ? String(code.prefix(4_000)) + "\n…（其余 \(code.count - 4_000) 字已省略）"
            : code
    }
}
