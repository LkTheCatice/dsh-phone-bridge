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
    enum Mode {
        case compact      // 列表：表格截断以保滚动性能
        case full         // 详情页：完整渲染
        case tablesOnly   // 详情页：只渲染表格（用户点「看完整版」通常只想看表）
    }

    private static let cache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 120                 // 最多 120 条消息的富文本
        c.totalCostLimit = 40 * 1024 * 1024 // 合计不超过 40MB
        return c
    }()

    private static func cachePrefix(_ mode: Mode) -> String {
        switch mode {
        case .compact: return "compact|"
        case .full: return "full|"
        case .tablesOnly: return "tables|"
        }
    }

    static func render(_ text: String, mode: Mode = .compact) -> NSAttributedString {
        let cacheKey = cachePrefix(mode) + text
        if let hit = cache.object(forKey: cacheKey as NSString) { return hit }
        let blocks = MarkdownCache.blocksSync(for: text)
        let built = build(blocks, mode: mode)
        // 缓存不可变副本：可变对象被别处改动会污染缓存
        let frozen = NSAttributedString(attributedString: built)
        // cost 用「字符数 × 8」近似 attributed string 的实际占用（字符 + 属性表）
        // 注意 key 必须和上面 get 用的是同一把（带 mode 前缀）：之前 set 用的是裸 text，
        // 于是每次渲染都 miss，等于没有缓存（长回答反复解析 + 反复排版）。
        cache.setObject(frozen, forKey: cacheKey as NSString, cost: max(1, frozen.length * 8))
        return frozen
    }

    static func build(_ blocks: [Block], mode: Mode = .compact) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let visible: [Block]
        if mode == .tablesOnly {
            visible = blocks.filter { if case .table = $0 { return true }; return false }
        } else {
            visible = blocks
        }
        if visible.isEmpty { return NSAttributedString(string: "（这条消息里没有表格）") }
        var tableIndex = 0
        for (index, block) in visible.enumerated() {
            // 段与段之间：用段落样式给「段后距」，而不是靠空行撑 ——
            // 空行会随字号放大成一大片空白，看起来又松又散（可读性下降的主因）。
            if index > 0 {
                out.append(NSAttributedString(string: "\n"))
            }
            // 详情页的「表格」视图只放表：一条回答里常有两三张表，
            // 原来首尾相接，表头直接顶到上一张表的最后一行下面，看着像同一张表
            // （用户实拍：左边还冒出一截短横线，分不清是分隔还是新表的表头线）。
            if mode == .tablesOnly, case .table = block {
                tableIndex += 1
                if tableIndex > 1 {
                    out.append(NSAttributedString(
                        string: "\n▦ 第 \(tableIndex) 张表\n",
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                            .foregroundColor: UIColor.secondaryLabel,
                            .paragraphStyle: Self.style(spacingAfter: 4, spacingBefore: 8, lineSpacing: 1),
                        ]
                    ))
                }
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
            // 代码块：等宽 + 整块底色，**不许出现「一行一个灰胶囊」**
            //
            // 用户实拍过的三种坏样子：
            //  ① `lineSpacing > 0` → 底色按行绘制，被行距切成一条条
            //  ② `lineHeightMultiple` → 即使 lineSpacing=0，行高被撑大后底色只覆盖
            //     字形带（glyph band），行与行之间照样留白，看起来像每行一个灰胶囊
            //  ③ 不给行尾补空格 → 每行底色只画到该行最后一个字符，右边缘参差不齐
            // 现在的做法：行高用默认值（不撑）+ 每行按显示宽度补空格到统一宽度
            // （等宽字体下宽度可精确计算），底色于是连成一整块规整矩形。
            let style = Self.style(
                spacingAfter: 6, spacingBefore: before, lineSpacing: 0,
                headIndent: 8, tailIndent: -8
            )
            // 气泡里一行大约放得下 46 个半角字符；详情页外层有横向滚动，可以放宽。
            // 超长行仍在本行末尾截断成 …（详情页能横向拖看全文）。
            style.lineBreakMode = .byTruncatingTail
            let maxChars = mode == .compact ? 46 : 96
            let rawLines = clampCode(code).components(separatedBy: "\n")
            let target = min(maxChars, rawLines.map { Self.displayWidth($0) }.max() ?? 0)
            // 每行前面补一个空格当内边距，尾部补到统一宽度：
            // 等宽字体下宽度可精确计算，底色于是连成一整块矩形。
            let padded = rawLines.map { line -> String in
                let width = Self.displayWidth(line)
                let body = " " + line
                guard target > width else { return body }
                return body + String(repeating: " ", count: target - width)
            }.joined(separator: "\n")

            // 整体外框：TextKit 没有边框 API（NSTextTable 是 AppKit 专属），
            // 所以用同一套等宽字符画上下两条「─」，底色当填充 ——
            // 视觉上就是一整块带框的代码区（用户要求「再加一个整体外框」）。
            let ruleWidth = max(8, target + 3)
            let rule = String(repeating: "─", count: ruleWidth)
            let out = NSMutableAttributedString()
            if let lang, !lang.isEmpty {
                out.append(NSAttributedString(
                    string: lang + "\n",
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                        .foregroundColor: UIColor.tertiaryLabel,
                        .paragraphStyle: style,
                    ]
                ))
            }
            let mono = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let fill = UIColor.secondarySystemFill
            // 上边框
            out.append(NSAttributedString(
                string: rule + "\n",
                attributes: [
                    .font: mono,
                    .foregroundColor: UIColor.tertiaryLabel,
                    .backgroundColor: fill,
                    .paragraphStyle: style,
                ]
            ))
            // 正文（每行已带左侧内边距 + 尾部对齐）
            out.append(NSAttributedString(
                string: padded.joined(separator: "\n"),
                attributes: [
                    .font: mono,
                    .foregroundColor: UIColor.label,
                    .backgroundColor: fill,
                    .paragraphStyle: style,
                ]
            ))
            // 下边框
            out.append(NSAttributedString(
                string: "\n" + rule,
                attributes: [
                    .font: mono,
                    .foregroundColor: UIColor.tertiaryLabel,
                    .backgroundColor: fill,
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
            // 表格一律用 **tabStops 做列对齐**（等宽字体 + 按显示宽度算停靠点）。
            //
            // 走过的错路：
            // 1. 「│ 分隔的对齐文本行」→ 长内容撑乱整行
            // 2. 「卡片式（每行拆 2~3 段）」→ 可读但段落数翻倍，STUCK 1→65 条、725ms→6965ms
            // 3. 「卡片式用在详情页」→ ▸ 标题缺换行，和「列名：」粘在一起（用户实拍）
            //
            // 现在列表与详情页共用同一套 tabStops 实现，只有预算不同：
            // 列表收紧（10 行 / 5 列 / 46 字符宽）保滚动性能；
            // 详情页放宽（200 行 / 8 列 / 90 字符宽 + 更小字号）看完整内容。
            let isFull = (mode != .compact)   // full 与 tablesOnly 都按完整宽度渲染
            let rowLimit = isFull ? 200 : 10
            let columnLimit = isFull ? 8 : 5
            // 详情页总预算放大到 900：外层是横向 ScrollView，
            // 宽度不够时用户能左右拖，没必要为了「塞进屏幕」而压缩内容。
            let availableChars = isFull ? 900 : 46
            let charWidth: CGFloat = isFull ? 6.4 : 7.2
            let fontSize: CGFloat = isFull ? 10 : 11.5

            let maxColumns = max(headers.count, rows.map(\.count).max() ?? 0)
            guard maxColumns > 0 else { return NSAttributedString() }
            let columnCount = min(maxColumns, columnLimit)
            let hiddenColumns = maxColumns - columnCount

            let displayWidth = Self.displayWidth

            let shownRows = Array(rows.prefix(rowLimit))
            let gutterChars = 2
            let gutterTotal = (columnCount - 1) * gutterChars
            let contentBudget = max(8, availableChars - gutterTotal)

            // 任一单元格被截断 → 需要给「点开看完整版」的入口
            var didTruncateCells = false

            func clampCell(_ s: String, maxWidth: Int) -> String {
                let stripped = InlineParser.stripResidual(s)
                if displayWidth(stripped) <= maxWidth { return stripped }
                didTruncateCells = true
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

            let allRows = [headers] + shownRows
            var natural = [Int](repeating: 0, count: columnCount)
            for row in allRows {
                for (i, cell) in row.enumerated() where i < columnCount {
                    // 详情页放宽到 60：之前是 22，长说明（「每行 Date() + 格式化 + cwd 名称解析」
                    // 这类）会被直接截断，点开完整内容也只看得到开头（用户实拍确认）。
                    natural[i] = max(natural[i], displayWidth(clampCell(cell, maxWidth: isFull ? 60 : 16)))
                }
            }
            // 单列占比封顶：气泡里出现过 `%LOCALAPPDATA%\Programs\Swift\Platforms\6.4.2`
            // 这种超长首列，把「结果」整列挤到屏幕外面 —— 用户看到的就是
            // 左边一坨省略号 + 右边只剩半个字。封到一半宽度，配合下面按比例压缩，
            // 起码每列都能露出可读的一段。
            let columnShareCap = max(8, contentBudget / 2)
            for i in 0..<columnCount where natural[i] > columnShareCap {
                natural[i] = columnShareCap
            }
            let naturalTotal = natural.reduce(0, +)
            var columnWidths = natural
            if naturalTotal > contentBudget, naturalTotal > 0 {
                let scale = Double(contentBudget) / Double(naturalTotal)
                // 下限从 4 提到 8：太窄的列会被压成「一两字 + …」，
                // 看起来像排版坏了（用户实拍）。宁可整体变宽靠横向滚动看。
                columnWidths = natural.map { max(8, Int((Double($0) * scale).rounded(.down))) }
            }

            var stops: [NSTextTab] = []
            var location: CGFloat = 0
            for i in 1..<columnCount {
                location += CGFloat(columnWidths[i - 1] + gutterChars) * charWidth
                stops.append(NSTextTab(textAlignment: .left, location: location))
            }

            func makeRow(_ row: [String], isHeader: Bool) -> NSAttributedString {
                let style = NSMutableParagraphStyle()
                style.tabStops = stops
                // lineSpacing 必须 0：表格现在有整段底色（当边框用），
            // 行距一留空隙，底色就会被切成一条条（和代码块同一类问题）。
            // 行高改由 lineHeightMultiple 撑。
            style.lineSpacing = 0
            style.lineHeightMultiple = isHeader ? 1.42 : 1.36
                style.paragraphSpacing = isHeader ? 5 : 3
                let base = UIFont.monospacedSystemFont(ofSize: fontSize, weight: isHeader ? .semibold : .regular)
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
                // 表头分隔线：用一整行「─」而不是 .underlineStyle。
                // underlineStyle 是逐字符的，tabStops 留下的空白覆盖不到，
                // 看起来会断成几截（用户实拍）。
                // 「─」在等宽字体下宽度正好一个字符，按列宽总和铺满即可连续。
                let totalChars = columnWidths.reduce(0, +) + (columnCount - 1) * gutterChars
                let ruleStyle = NSMutableParagraphStyle()
                ruleStyle.tabStops = stops
                ruleStyle.lineSpacing = 0
                ruleStyle.lineHeightMultiple = 1.0
                ruleStyle.paragraphSpacing = isFull ? 6 : 3
                out.append(NSAttributedString(
                    string: String(repeating: "─", count: max(8, totalChars)) + "\n",
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                        .foregroundColor: UIColor.separator,
                        .paragraphStyle: ruleStyle,
                    ]
                ))
            }
            for (i, row) in shownRows.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 3)])) }
                out.append(makeRow(row, isHeader: false))
            }

            // 折叠提示只在列表（compact）里出现；详情页本身就是完整内容。
            // 注意：除了「行/列超限」，**单元格被压窄截断**也算被省略（用户实拍：
            // 4 列 8 行的表里 13.3… / 1.24… 被截断，却没有入口点开）。
            if !isFull, rows.count > rowLimit || hiddenColumns > 0 || didTruncateCells {
                var note = "\n"
                if hiddenColumns > 0 { note += "（还有 \(hiddenColumns) 列未显示）" }
                if rows.count > rowLimit { note += "… 还有 \(rows.count - rowLimit) 行未显示" }
                if hiddenColumns == 0, rows.count <= rowLimit, didTruncateCells {
                    note += "（部分单元格内容已省略）"
                }
                out.append(NSAttributedString(
                    string: note,
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 11),
                        .foregroundColor: UIColor.tertiaryLabel,
                        .paragraphStyle: Self.style(spacingAfter: 2, spacingBefore: 3, lineSpacing: 1),
                    ]
                ))
                if let url = URL(string: "dsh://detail") {
                    var hint = NSMutableAttributedString(
                        string: "▦ 表格已折叠 · 点按看完整版 ›",
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                            .foregroundColor: UIColor.tintColor,
                            .link: url,
                            .paragraphStyle: Self.style(spacingAfter: 2, spacingBefore: 1, lineSpacing: 1),
                        ]
                    )
                    out.append(hint)
                }
            }
            // 给表格加个框：TextKit 没有表格边框 API（NSTextTable 是 AppKit 专属），
            // 所以用整段底色模拟 —— 和代码块同一套做法。
            // 注意 lineSpacing 必须是 0，否则按行绘制的背景会被行距切成一条条。
            // 表头分隔线。
            //
            // 为什么不用底色：`.backgroundColor` 只能覆盖**字符**，
            // 而 tabStops 对齐产生的空白不属于任何字符 —— 底色会在行尾
            // 断掉一段（用户实拍「最上面一行的灰色少了一段」）。
            // 改成给表头文字加下划线，横跨整行的视觉效果靠它完成。

            return out
        }

    }

    /// 行内格式：用 `InlineParser` 的**分段结果**拼接属性。
    ///
    /// 全程只有 `append`，没有任何 `replaceCharacters(in:with:)` ——
    /// NSRange 只用于「已知长度」的切片，不会因为前一次替换而失效。
    /// 这就是「点开就闪退」那个越界问题的结构性解法（实现在 Core 层，已被 selftest 覆盖）。

    /// 把 markdown 里的地址变成可点的 URL。
    /// - 绝对地址（http/https/mailto 等）→ 直接用
    /// - 相对路径（phone-dsh/dist/x.ipa）→ 包成 dsh://path?p=<编码后的路径>，
    ///   由上层决定是提示还是跳到文件页；总比「染成蓝色却点不动」好
    /// 显示宽度：中文/全角算 2、其余算 1（等宽字体下才成立）
    static func displayWidth(_ s: String) -> Int {
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

    /// 详情页需要多宽才能把表格完整显示（不压缩）。
    /// 返回 nil 表示这条消息里没有需要横向放大的表格。
    static func requiredTableWidth(for text: String) -> CGFloat? {
        var widest: CGFloat = 0
        for block in MarkdownCache.blocksSync(for: text) {
            guard case let .table(headers, rows) = block else { continue }
            let columns = max(headers.count, rows.map(\.count).max() ?? 0)
            guard columns > 0 else { continue }
            var natural = [Int](repeating: 0, count: columns)
            for row in [headers] + rows {
                for (i, cell) in row.enumerated() where i < columns {
                    natural[i] = max(natural[i], displayWidth(InlineParser.stripResidual(cell)))
                }
            }
            let totalChars = natural.reduce(0, +) + (columns - 1) * 2
            // 详情页字号 10pt 等宽字体单个字符约 6.4pt
            let width = CGFloat(totalChars) * 6.4
            widest = max(widest, width)
        }
        return widest > 0 ? widest : nil
    }

    static func linkTarget(for raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // 只有**真的能打开**的才返回 URL（→ 才会染蓝 + 可点）：
        // - http / https / mailto 等带 scheme 的绝对地址
        // - dsh:// 内部路由
        // 相对路径（phone-dsh/dist/x.ipa、AGENTS.md 这类）一律返回 nil：
        // 手机上打不开，染蓝只会让人以为能点（用户反馈「只要是个路径都标蓝」）。
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        let allowed: Set<String> = ["http", "https", "mailto", "tel", "dsh"]
        guard allowed.contains(scheme) else { return nil }
        return url
    }

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
                // UITextView 对 .link 属性原生支持点击（isSelectable = true 即可）。
                //
                // ⚠️ 只有能构造成 URL 的才染色 + 加 .link：
                // 消息里常出现相对路径（如 phone-dsh/dist/x.ipa），
                // URL(string:) 对它返回 nil —— 以前照样染成蓝色，结果点了没反应（用户实拍）。
                // 现在构造失败就保持普通文字，不做「看着能点却点不动」的暗示。
                switch Self.linkTarget(for: url) {
                case .some(let target):
                    attributes[.foregroundColor] = UIColor.tintColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.link] = target
                case .none:
                    break
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
