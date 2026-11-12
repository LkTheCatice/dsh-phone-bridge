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

    /// 富文本缓存。**必须设上限**：一条长回答的富文本可能几 MB，
    /// NSCache 不设限时只靠系统内存压力回收，长时间挂机会一路涨到上百 MB。
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 120                 // 最多 120 条消息的富文本
        c.totalCostLimit = 40 * 1024 * 1024 // 合计不超过 40MB
        return c
    }()

    static func render(_ text: String) -> NSAttributedString {
        if let hit = cache.object(forKey: text as NSString) { return hit }
        let blocks = MarkdownCache.blocksSync(for: text)
        let built = build(blocks)
        // 缓存不可变副本：可变对象被别处改动会污染缓存
        let frozen = NSAttributedString(attributedString: built)
        // cost 用「字符数 × 8」近似 attributed string 的实际占用（字符 + 属性表）
        cache.setObject(frozen, forKey: text as NSString, cost: max(1, frozen.length * 8))
        return frozen
    }

    static func build(_ blocks: [Block]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            // 段与段之间：用段落样式给「段后距」，而不是靠空行撑 ——
            // 空行会随字号放大成一大片空白，看起来又松又散（可读性下降的主因）。
            if index > 0 {
                out.append(NSAttributedString(string: "\n"))
            }
            out.append(renderBlock(block, isFirst: index == 0))
        }
        return out
    }

    /// 统一段落样式：行距 + 段后距 + 缩进
    /// 注意返回**可变**类型：调用方还要设 `tailIndent`（代码块左右缩进），
    /// 返回 `NSParagraphStyle` 会让它变成只读属性（CI 已抓到一次）。
    @discardableResult
    private static func style(
        spacingAfter: CGFloat = 8,
        spacingBefore: CGFloat = 0,
        lineSpacing: CGFloat = 3,
        headIndent: CGFloat = 0,
        firstLineIndent: CGFloat? = nil,
        tailIndent: CGFloat? = nil
    ) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        p.paragraphSpacing = spacingAfter
        p.paragraphSpacingBefore = spacingBefore
        p.headIndent = headIndent
        p.firstLineHeadIndent = firstLineIndent ?? headIndent
        if let tailIndent { p.tailIndent = tailIndent }
        return p
    }

    // MARK: - 块级

    private static func renderBlock(_ block: Block, isFirst: Bool = false) -> NSAttributedString {
        // 首段不需要「段前距」，否则顶部会空一块
        let before: CGFloat = isFirst ? 0 : 10

        switch block {
        case let .heading(level, text):
            // 标题：字号 + 段前距（让层级「立起来」，而不是靠空行）
            let size: CGFloat = level <= 2 ? 21 : 18
            let style = Self.style(
                spacingAfter: 6,
                spacingBefore: isFirst ? 0 : (level <= 2 ? 14 : 10),
                lineSpacing: 2
            )
            let out = NSMutableAttributedString(attributedString: inline(text, base: .systemFont(ofSize: size, weight: .semibold)))
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
            return out

        case let .paragraph(text):
            let out = NSMutableAttributedString(attributedString: inline(text, base: .systemFont(ofSize: 16)))
            out.addAttribute(
                .paragraphStyle,
                value: Self.style(spacingAfter: 2, spacingBefore: before, lineSpacing: 4),
                range: NSRange(location: 0, length: out.length)
            )
            return out

        case let .quote(text):
            // 引用：整体缩进 + 竖线 + 灰字
            let out = NSMutableAttributedString(
                string: "▍ ",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 15),
                    .foregroundColor: UIColor.tertiaryLabel,
                    .paragraphStyle: Self.style(spacingAfter: 2, spacingBefore: before, lineSpacing: 4, headIndent: 4, firstLineIndent: 4),
                ]
            )
            let body = NSMutableAttributedString(attributedString: inline(text, base: .systemFont(ofSize: 15)))
            body.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: NSRange(location: 0, length: body.length))
            body.addAttribute(
                .paragraphStyle,
                value: Self.style(spacingAfter: 2, spacingBefore: 0, lineSpacing: 4, headIndent: 18, firstLineIndent: 18),
                range: NSRange(location: 0, length: body.length)
            )
            out.append(body)
            return out

        case let .code(code, lang):
            // 代码块：左右缩进 + 等宽 + 底色 + 稍紧的行距
            let style = Self.style(
                spacingAfter: 2, spacingBefore: before, lineSpacing: 1.5,
                headIndent: 10, tailIndent: -10
            )
            let out = NSMutableAttributedString()
            if let lang, !lang.isEmpty {
                let tag = NSAttributedString(
                    string: lang + "\n",
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                        .foregroundColor: UIColor.tertiaryLabel,
                        .paragraphStyle: style,
                    ]
                )
                out.append(tag)
            }
            out.append(NSAttributedString(
                string: clampCode(code),
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                    .foregroundColor: UIColor.label,
                    .backgroundColor: UIColor.secondarySystemFill,
                    .paragraphStyle: style,
                ]
            ))
            return out

        case let .bullet(items):
            // 列表：悬挂缩进（换行时对齐文字，不对齐符号）
            let out = NSMutableAttributedString()
            for (i, item) in items.enumerated() {
                let style = Self.style(
                    spacingAfter: i == items.count - 1 ? 2 : 5,
                    spacingBefore: i == 0 ? before : 0,
                    lineSpacing: 4,
                    headIndent: 20,
                    firstLineIndent: 4
                )
                out.append(NSAttributedString(
                    string: "• ",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 16),
                        .foregroundColor: UIColor.secondaryLabel,
                        .paragraphStyle: style,
                    ]
                ))
                let body = NSMutableAttributedString(attributedString: inline(item, base: .systemFont(ofSize: 16)))
                body.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: body.length))
                out.append(body)
                if i < items.count - 1 { out.append(NSAttributedString(string: "\n")) }
            }
            return out

        case let .ordered(items):
            let out = NSMutableAttributedString()
            for (i, item) in items.enumerated() {
                let style = Self.style(
                    spacingAfter: i == items.count - 1 ? 2 : 5,
                    spacingBefore: i == 0 ? before : 0,
                    lineSpacing: 4,
                    headIndent: 24,
                    firstLineIndent: 4
                )
                out.append(NSAttributedString(
                    string: "\(i + 1). ",
                    attributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular),
                        .foregroundColor: UIColor.secondaryLabel,
                        .paragraphStyle: style,
                    ]
                ))
                let body = NSMutableAttributedString(attributedString: inline(item, base: .systemFont(ofSize: 16)))
                body.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: body.length))
                out.append(body)
                if i < items.count - 1 { out.append(NSAttributedString(string: "\n")) }
            }
            return out

        case .divider:
            return NSAttributedString(
                string: "────────",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12),
                    .foregroundColor: UIColor.tertiaryLabel,
                    .paragraphStyle: Self.style(spacingAfter: 2, spacingBefore: before, lineSpacing: 0),
                ]
            )

        case let .table(headers, rows):
            // 表格：**每行压成一个段落**（不是每个单元格一个段落）。
            //
            // 走过的两条错路：
            // 1. 「用 │ 分隔的对齐文本行」→ 长内容撑乱整行，窄屏不可读（用户实拍否决）
            // 2. 「卡片式：每行 = 标题段 + 每列一段」→ 可读了，但文本量翻几倍，
            //    实测 STUCK 从 1 条 725ms 涨到 65 条 6965ms（mark=body）
            // 现在折中：一行一条，用 — 和 ｜ 分隔，列名省略（表头已给出语义），
            // 段落数与普通文本相同，成本回到基线。
            let limit = 12
            let shown = rows.prefix(limit)
            var out = NSMutableAttributedString()

            for (i, row) in shown.enumerated() {
                var line = NSMutableAttributedString()
                let title = row.first ?? ""
                if !title.isEmpty {
                    line.append(NSAttributedString(
                        string: "▸ " + title,
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                            .foregroundColor: UIColor.label,
                        ]
                    ))
                }
                let rest = Array(row.dropFirst()).filter { !$0.isEmpty }
                for value in rest {
                    line.append(NSAttributedString(
                        string: "  ｜ ",
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 11),
                            .foregroundColor: UIColor.tertiaryLabel,
                        ]
                    ))
                    line.append(inline(value, base: .systemFont(ofSize: 13)))
                }
                line.addAttribute(
                    .paragraphStyle,
                    value: Self.style(
                        spacingAfter: 6,
                        spacingBefore: i == 0 ? before : 0,
                        lineSpacing: 3,
                        headIndent: 14,
                        firstLineIndent: 2
                    ),
                    range: NSRange(location: 0, length: line.length)
                )
                out.append(line)
                if i < shown.count - 1 {
                    out.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 2)]))
                }
            }
            if rows.count > limit {
                out.append(NSAttributedString(
                    string: "\n… 还有 \(rows.count - limit) 行未显示",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 11),
                        .foregroundColor: UIColor.tertiaryLabel,
                        .paragraphStyle: Self.style(spacingAfter: 2, spacingBefore: 2, lineSpacing: 0, headIndent: 14),
                    ]
                ))
            }
            return out
        }
    }

    /// 行内格式：用 `InlineParser` 的**分段结果**拼接属性。
    ///
    /// 全程只有 `append`，没有任何 `replaceCharacters(in:with:)` ——
    /// NSRange 只用于「已知长度」的切片，不会因为前一次替换而失效。
    /// 这就是「点开就闪退」那个越界问题的结构性解法（实现在 Core 层，已被 selftest 覆盖）。
    private static func inline(_ text: String, base: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for segment in InlineParser.segments(text) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: base,
                .foregroundColor: UIColor.label,
            ]
            switch segment.style {
            case .plain:
                break
            case .bold:
                attributes[.font] = UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
            case .italic:
                attributes[.font] = UIFont.italicSystemFont(ofSize: base.pointSize)
            case .code:
                attributes[.font] = UIFont.monospacedSystemFont(
                    ofSize: max(10, base.pointSize - 1), weight: .regular
                )
                attributes[.backgroundColor] = UIColor.secondarySystemFill
            case let .link(url):
                // UITextView 对 .link 属性原生支持点击（isSelectable = true 即可）
                attributes[.foregroundColor] = UIColor.tintColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if let target = URL(string: url) {
                    attributes[.link] = target
                }
            }
            out.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return out
    }

    private static func clampCode(_ code: String) -> String {
        code.count > 4_000
            ? String(code.prefix(4_000)) + "\n…（其余 \(code.count - 4_000) 字已省略）"
            : code
    }
}
