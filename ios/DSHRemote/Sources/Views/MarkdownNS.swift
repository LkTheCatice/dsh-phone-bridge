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
    /// 渲染模式：列表里用 compact（表格截断以保滚动性能），
    /// 详情页用 full（表格完整展开）。
    enum Mode { case compact, full }

    private static let cache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 120                 // 最多 120 条消息的富文本
        c.totalCostLimit = 40 * 1024 * 1024 // 合计不超过 40MB
        return c
    }()

    static func render(_ text: String, mode: Mode = .compact) -> NSAttributedString {
        let cacheKey = (mode == .full ? "full|" : "compact|") + text
        if let hit = cache.object(forKey: cacheKey as NSString) { return hit }
        let blocks = MarkdownCache.blocksSync(for: text)
        let built = build(blocks, mode: mode)
        // 缓存不可变副本：可变对象被别处改动会污染缓存
        let frozen = NSAttributedString(attributedString: built)
        // cost 用「字符数 × 8」近似 attributed string 的实际占用（字符 + 属性表）
        cache.setObject(frozen, forKey: text as NSString, cost: max(1, frozen.length * 8))
        return frozen
    }

    static func build(_ blocks: [Block], mode: Mode = .compact) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            // 段与段之间：用段落样式给「段后距」，而不是靠空行撑 ——
            // 空行会随字号放大成一大片空白，看起来又松又散（可读性下降的主因）。
            if index > 0 {
                out.append(NSAttributedString(string: "\n"))
            }
            out.append(renderBlock(block, isFirst: index == 0, mode: mode))
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

    private static func renderBlock(_ block: Block, isFirst: Bool = false, mode: Mode = .compact) -> NSAttributedString {
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
            // 表格：用 **tabStops 做真正的列对齐**。
            //
            // 走过的路：
            // 1. 「│ 分隔的对齐文本行」→ 长内容撑乱整行，列根本对不上
            // 2. 「卡片式：每行拆 2~3 段」→ 可读了，但段落数翻倍，
            //    实测 STUCK 从 1 条 725ms 涨到 65 条 6965ms
            // 3. 「一行一条用 ｜ 分隔」→ 便宜，但列仍不对齐（用户：不直观）
            //
            // 现在：等宽字体 + 按显示宽度算出的 tabStops + 每行用 \t 分隔。
            // 列是真的对齐了，段落数与普通文本相同（成本回到基线）。
            let maxColumns = max(headers.count, rows.map(\.count).max() ?? 0)
            guard maxColumns > 0 else { return NSAttributedString() }

            // 中文/全角算 2 个字符宽，其余算 1 —— 等宽字体下才能对齐
            func displayWidth(_ s: String) -> Int {
                s.unicodeScalars.reduce(0) { acc, u in
                    let wide = (u.value >= 0x1100 && u.value <= 0x115F)
                        || (u.value >= 0x2E80 && u.value <= 0xA4CF)
                        || (u.value >= 0xAC00 && u.value <= 0xD7A3)
                        || (u.value >= 0xF900 && u.value <= 0xFAFF)
                        || (u.value >= 0xFE30 && u.value <= 0xFE6F)
                        || (u.value >= 0xFF00 && u.value <= 0xFF60)
                        || (u.value >= 0xFFE0 && u.value <= 0xFFE6)
                    return acc + (wide ? 2 : 1)
                }
            }

            // full 模式（详情页）不截断：行列全展开，单元格不压缩
            if mode == .full {
                let out = NSMutableAttributedString()
                for (rowIndex, row) in rows.enumerated() {
                    let title = row.first ?? ""
                    if !title.isEmpty {
                        let head = NSMutableAttributedString(
                            string: "▸ ",
                            attributes: [
                                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                                .foregroundColor: UIColor.secondaryLabel,
                            ]
                        )
                        head.append(inline(title, base: .systemFont(ofSize: 13, weight: .semibold)))
                        head.addAttribute(
                            .paragraphStyle,
                            value: Self.style(spacingAfter: 2, spacingBefore: rowIndex == 0 ? before : 8, lineSpacing: 2, headIndent: 14, firstLineIndent: 2),
                            range: NSRange(location: 0, length: head.length)
                        )
                        out.append(head)
                    }
                    for column in 1..<max(row.count, 1) where column < row.count {
                        let name = column < headers.count ? headers[column] : "列\(column + 1)"
                        let line = NSMutableAttributedString(
                            string: "\(name)：",
                            attributes: [
                                .font: UIFont.systemFont(ofSize: 12),
                                .foregroundColor: UIColor.tertiaryLabel,
                            ]
                        )
                        line.append(inline(row[column], base: .systemFont(ofSize: 13)))
                        line.addAttribute(
                            .paragraphStyle,
                            value: Self.style(spacingAfter: 3, spacingBefore: 0, lineSpacing: 2, headIndent: 16, firstLineIndent: 16),
                            range: NSRange(location: 0, length: line.length)
                        )
                        out.append(line)
                        out.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 2)]))
                    }
                    out.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 4)]))
                }
                return out
            }

            let limit = 10
            let shownRows = Array(rows.prefix(limit))

            // 手机竖屏、11.5pt 等宽字体下大约能放 46 个字符宽。
            // **必须限总宽**：只限单格宽度的话，5 列 × 14 + 间距 ≈ 78 字符，
            // 超出的部分会被强行折行，竖线立刻错位（用户问的就是这个）。
            let availableChars = 46
            let gutterChars = 2
            let maxColumnsShown = 5
            let columnCount = min(maxColumns, maxColumnsShown)
            let hiddenColumns = maxColumns - columnCount
            let gutterTotal = (columnCount - 1) * gutterChars
            let contentBudget = max(8, availableChars - gutterTotal)

            func clampCell(_ s: String, maxWidth: Int) -> String {
                let stripped = InlineParser.stripResidual(s)
                if displayWidth(stripped) <= maxWidth { return stripped }
                var out = ""
                var w = 0
                for ch in stripped {
                    let cw = displayWidth(String(ch))
                    if w + cw > maxWidth - 1 { break }
                    out.append(ch)
                    w += cw
                }
                return out + "…"
            }

            // 第一遍：算每列的自然宽度（单列上限先放 16）
            let table = [headers] + shownRows
            var natural = [Int](repeating: 0, count: columnCount)
            for row in table {
                for (i, cell) in row.enumerated() where i < columnCount {
                    natural[i] = max(natural[i], displayWidth(clampCell(cell, maxWidth: 16)))
                }
            }

            // 第二遍：超宽就按比例压缩，内容短的列保持短，只压长的
            let naturalTotal = natural.reduce(0, +)
            var columnWidths = natural
            if naturalTotal > contentBudget, naturalTotal > 0 {
                let scale = Double(contentBudget) / Double(naturalTotal)
                columnWidths = natural.map { max(4, Int((Double($0) * scale).rounded(.down))) }
            }

            // 12pt 等宽字体单个字符约 7.2pt
            let charWidth: CGFloat = 7.2
            var stops: [NSTextTab] = []
            var location: CGFloat = 0
            for i in 1..<columnCount {
                location += CGFloat(columnWidths[i - 1] + gutterChars) * charWidth
                stops.append(NSTextTab(textAlignment: .left, location: location))
            }

            func makeRow(_ row: [String], isHeader: Bool) -> NSAttributedString {
                let style = NSMutableParagraphStyle()
                style.tabStops = stops
                style.lineSpacing = 3
                style.paragraphSpacing = isHeader ? 4 : 3
                style.headIndent = 0
                let base = UIFont.monospacedSystemFont(ofSize: 11.5, weight: isHeader ? .semibold : .regular)
                let line = NSMutableAttributedString()
                for column in 0..<columnCount {
                    if column > 0 {
                        line.append(NSAttributedString(string: "\t", attributes: [.font: base]))
                    }
                    let text = column < row.count ? clampCell(row[column], maxWidth: columnWidths[column]) : ""
                    line.append(NSAttributedString(string: text, attributes: [
                        .font: base,
                        .foregroundColor: isHeader ? UIColor.label : UIColor.secondaryLabel,
                    ]))
                }
                line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                return line
            }

            let out = NSMutableAttributedString()
            if !headers.isEmpty {
                out.append(makeRow(headers, isHeader: true))
                out.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 3)]))
            }
            for (i, row) in shownRows.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 3)])) }
                out.append(makeRow(row, isHeader: false))
            }
            if rows.count > limit {
                out.append(NSAttributedString(
                    string: "\n… 还有 \(rows.count - limit) 行未显示",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 11),
                        .foregroundColor: UIColor.tertiaryLabel,
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
