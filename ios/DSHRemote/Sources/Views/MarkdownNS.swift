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
            // 代码块：等宽 + **整块**底色（由 BlockFillLayoutManager 按行片段画）
            //
            // 走过的错路都在 `.backgroundColor` 上：它按字符填色，
            //  ① lineSpacing > 0 → 一条条断开
            //  ② lineHeightMultiple / 负 lineSpacing → 底色勉强连上，但行高被压，
            //     ASCII 图的框线和箭头会错位（用户实拍：图看着不对）
            //  ③ 行尾没字符 → 右边缘参差
            // 现在底色交给布局管理器画（见 BlockFillLayoutManager），
            // 这里只需要保证行高是**字体默认值**、文本宽度正常，ASCII 图才对得齐。
            // ⚠️ 关键：代码块的每一行都是一个「段落」（用 \n 分隔），
            // paragraphSpacing 是按段落生效的 —— 给 12 就等于**每行之间空 12pt**，
            // 于是 ASCII 图的竖线全被拉开、框看起来是断的（用户实拍）。
            // 这里行间必须是 0；上下留白只给「首行之前 / 末行之后」。
            let style = Self.style(
                spacingAfter: 0, spacingBefore: 0, lineSpacing: 0,
                headIndent: 8, tailIndent: -8
            )
            style.lineBreakMode = .byTruncatingTail
            let maxChars = mode == .compact ? 46 : 96
            let rawLines = clampCode(code).components(separatedBy: "\n")
            let truncated = rawLines.contains { Self.displayWidth($0) > maxChars }
            // 左侧一个空格当内边距；不再往行尾补空格（那是给 .backgroundColor 用的，
            // 现在也不该把空格塞进可复制的内容里）。
            let body = rawLines.map { " " + $0 }.joined(separator: "\n")

            // 字体：优先 Menlo。SF Mono 对制表框线（┌ ─ │ └ ▼）覆盖不全，
            // fallback 字宽不一致 → ASCII 图错位。
            let mono = UIFont(name: "Menlo", size: 12.5)
                ?? UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let fill = UIColor.secondarySystemFill

            // ── 内边距用**真实段落**实现（架构上唯一干净的做法）──────────────
            // 之前是在布局管理器里把矩形往外画（insetBy 负值）：padding 是画上去的，
            // 不是布局的一部分 —— 于是遇到相邻元素就必然重叠，只能靠调数字躲，
            // 补丁越打越多（用户连着三次实拍「碰到别的元素」）。
            // 现在整块 = [上空白段][语言标签][正文][下空白段]，四段同属一块底色：
            //   · padding 由空白段的高度提供（真布局），不会越界；
            //   · 块外间距由这两个空白段的段前/段后距提供（也是真布局）；
            //   · 底色矩形仍由布局管理器按片段并集画，但因为不再外扩，永远不会碰到别人。
            let padFont = UIFont.systemFont(ofSize: 5)
            let padTopStyle = Self.style(
                spacingAfter: 0, spacingBefore: max(before, 12),
                lineSpacing: 0, headIndent: 8, tailIndent: -8
            )
            let padBottomStyle = Self.style(
                spacingAfter: 14, spacingBefore: 0,
                lineSpacing: 0, headIndent: 8, tailIndent: -8
            )

            let out = NSMutableAttributedString()
            out.append(NSAttributedString(
                string: "\n",
                attributes: [.font: padFont, .paragraphStyle: padTopStyle]
            ))
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
            out.append(NSAttributedString(
                string: body,
                attributes: [
                    .font: mono,
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: style,
                ]
            ))
            // 下空白段：第一个 "\n" 只是给最后一行收尾，第二个才是独立的空段落
            // （少一个的话底边会被切掉 —— 和表格同一个坑）。
            out.append(NSAttributedString(
                string: "\n",
                attributes: [.font: UIFont.systemFont(ofSize: 3)]
            ))
            out.append(NSAttributedString(
                string: "\n",
                attributes: [.font: padFont, .paragraphStyle: padBottomStyle]
            ))

            // 整块底色 + 描边（一次画成一整块，行间不再有缝；不再向外扩）
            let blockRange = NSRange(location: 0, length: out.length)
            out.addAttribute(BlockFillAttribute.key, value: fill, range: blockRange)
            out.addAttribute(BlockFillAttribute.strokeKey, value: UIColor.separator, range: blockRange)
            // 有行被截断 → 给一个入口点开看整行（详情页 96 字符 + 横向滚动）。
            // 之前只有「…」没有任何办法看到后半句（用户实拍）。
            if truncated, mode == .compact, let url = URL(string: "dsh://detail") {
                out.append(NSAttributedString(
                    string: "\n",
                    attributes: [.font: UIFont.systemFont(ofSize: 4)]
                ))
                out.append(NSAttributedString(
                    string: L("▦ 代码已截断 · 点按看完整行 ›", "▦ Code truncated · tap for the full line ›"),
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: UIColor.tintColor,
                        .link: url,
                        .paragraphStyle: Self.style(spacingAfter: 2, spacingBefore: 0, lineSpacing: 1),
                    ]
                ))
            }
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
            // ── 窄气泡里先判断：这张表"根本塞不下"就别硬做表格 ─────────────
            //
            // 硬用 tabStops 对齐时，一旦是 3 列以上的中文表格，列宽会被压到 8 字符，
            // 每格都被迫换行 —— 最终看起来就是「几个词一堆堆在一起」，
            // 既不像表格也不像列表（用户实拍反馈）。
            // 这种时候降级成「一条记录一块」：首列加粗当小标题，
            // 其余列按「列名：值」排，读起来和表格等价，但不会再挤爆。
            if mode == .compact {
                let colCount = max(headers.count, rows.map(\.count).max() ?? 0)
                var widestCell = 0
                for row in rows.prefix(6) {
                    for cell in row { widestCell = max(widestCell, Self.displayWidth(InlineParser.stripResidual(cell))) }
                }
                let estimated = widestCell * max(1, colCount) + (colCount - 1) * 2
                let cannotFit = colCount >= 3 || estimated > 44
                if cannotFit {
                    let out = NSMutableAttributedString()
                    let indexFont = UIFont.systemFont(ofSize: 12, weight: .bold)
                    let nameFont = UIFont.systemFont(ofSize: 12, weight: .regular)
                    let valueFont = UIFont.systemFont(ofSize: 14, weight: .regular)
                    let shown = Array(rows.prefix(6))

                    // 版式（2026-11-14 重做）：
                    //   · 首列（序号/文件名）与第二列**同一行**，不再孤零零占一行
                    //   · 同一块的后续列缩进两格对齐在下面，和"序号"一起读成一条记录
                    //   · 块与块之间留 14pt，比块内行距大，视觉上分组清楚
                    //   · 末尾给一条可点的「查看完整表格」，走 dsh://detail（详情页只渲染表格）
                    for (r, row) in shown.enumerated() {
                        let head = row.first ?? ""
                        let second = row.count > 1 ? row[1] : ""

                        // 每条记录用「▍」起头（和消息前缀 ▍AI / ▍我 同一套视觉语言），
                        // 序号用次要灰、正文用 label —— 只靠留白和一条竖线分组，
                        // 不用底色也不用主题蓝（蓝在这里暗示"可点"，会误导）。
                        let title = NSMutableAttributedString()
                        title.append(NSAttributedString(string: "▍", attributes: [
                            .font: UIFont.systemFont(ofSize: 13, weight: .regular),
                            .foregroundColor: UIColor.tertiaryLabel,
                        ]))
                        if !head.isEmpty {
                            title.append(NSAttributedString(string: head + "  ", attributes: [
                                .font: indexFont,
                                .foregroundColor: UIColor.secondaryLabel,
                            ]))
                        }
                        if !second.isEmpty {
                            title.append(Self.inline(second, base: valueFont))
                        }
                        title.addAttribute(
                            .paragraphStyle,
                            value: Self.style(spacingAfter: 2, spacingBefore: r == 0 ? 0 : 13, lineSpacing: 2),
                            range: NSRange(location: 0, length: title.length)
                        )
                        out.append(title)
                        out.append(NSAttributedString(string: "\n"))

                        // 第三列起：缩进挂在同一条记录下面
                        for (c, cell) in row.enumerated() where c > 1 {
                            let name = c < headers.count ? headers[c] : ""
                            let line = NSMutableAttributedString(string: "　", attributes: [
                                .font: nameFont,
                            ])
                            if !name.isEmpty {
                                line.append(NSAttributedString(string: "\(name)：", attributes: [
                                    .font: nameFont,
                                    .foregroundColor: UIColor.secondaryLabel,
                                ]))
                            }
                            line.append(Self.inline(cell, base: valueFont))
                            line.addAttribute(
                                .paragraphStyle,
                                value: Self.style(
                                    spacingAfter: 0,
                                    lineSpacing: 2,
                                    headIndent: 22,
                                    firstLineIndent: 22
                                ),
                                range: NSRange(location: 0, length: line.length)
                            )
                            out.append(line)
                            out.append(NSAttributedString(string: "\n"))
                        }
                    }

                    // 截断（行数或被压缩的列）→ 给「查看完整表格」入口
                    // 只用本分支内可见的量：行数被截、或单元格宽度已经把列压扁过
                    let truncated = rows.count > shown.count || widestCell > 24
                    if truncated && mode == .compact, let url = URL(string: "dsh://detail") {
                        // 灰色 + 下划线表示可点：不再占用主题蓝（那是"主要操作"的颜色）
                        let hint = NSMutableAttributedString(string: "查看完整表格（\(rows.count) 行） ›", attributes: [
                            .font: UIFont.systemFont(ofSize: 12, weight: .regular),
                            .foregroundColor: UIColor.secondaryLabel,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .underlineColor: UIColor.tertiaryLabel,
                            .link: url,
                        ])
                        hint.addAttribute(
                            .paragraphStyle,
                            value: Self.style(spacingAfter: 0, spacingBefore: 10, lineSpacing: 0),
                            range: NSRange(location: 0, length: hint.length)
                        )
                        out.append(hint)
                        out.append(NSAttributedString(string: "\n"))
                    }
                    return out
                }
            }

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
            // 详情页放宽到 900 字符（外层横向滚动）；气泡里按实际宽度倒推：
            // 11pt 等宽字符约 6.6pt，可用宽度约 330pt → 50 个半角字符。
            // 之前是 46 字符 + 11.5pt（同样宽度但内容更少）。
            let availableChars = isFull ? 900 : 50
            let charWidth: CGFloat = isFull ? 6.4 : 6.6
            let fontSize: CGFloat = isFull ? 10 : 11

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
            // 测量时每格的截断上限：
            // 以前 compact 写死 16 —— 两列的表可用宽度只有 44 字符，却把每格先砍到 16，
            // 于是「8 帧（turn.start 1）」被切成「8 帧（turn.star…」，
            // 看起来既不整齐也没信息（用户实拍：表格又挤又丑）。
            // 现在按 contentBudget 量，宽度分配交给下面的按比例压缩 + 单列封顶。
            let cellMeasureCap = isFull ? 60 : contentBudget
            for row in allRows {
                for (i, cell) in row.enumerated() where i < columnCount {
                    natural[i] = max(natural[i], displayWidth(clampCell(cell, maxWidth: cellMeasureCap)))
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

            // 表格内边距：整块底色是贴着 container 画的，
            // 文字如果从 0 开始就直接压在圆角边上（用户实拍「贴边」）。
            // 用「行首补一个空格 + 所有 tab 停靠点整体右移一格」来留白 ——
            // 比 headIndent 可靠：tabStops 是按 container 原点算的，headIndent 不会带动它。
            let leadChars = 1
            var stops: [NSTextTab] = []
            var location = CGFloat(leadChars) * charWidth
            for i in 1..<columnCount {
                location += CGFloat(columnWidths[i - 1] + gutterChars) * charWidth
                stops.append(NSTextTab(textAlignment: .left, location: location))
            }

            func makeRow(_ row: [String], isHeader: Bool, isLast: Bool = false) -> NSAttributedString {
                let style = NSMutableParagraphStyle()
                style.tabStops = stops
                // lineSpacing 必须 0：底色是按行片段画的，行距会在片段之间留缝。
                style.lineSpacing = 0
                style.lineHeightMultiple = isHeader ? 1.42 : 1.36
                // 表格首行上方 / 末行下方各留一段：整块底色上下各外扩 4pt，
                // 没有这段就会顶到 AI 前缀或下一段正文（用户实拍「碰到外部元素」）。
                // 块外间距交给上下空白段；这里只保留表头与数据行之间的分隔
                style.paragraphSpacingBefore = 0
                style.paragraphSpacing = isHeader ? 8 : (isLast ? 0 : 4)
                let base = UIFont.monospacedSystemFont(ofSize: fontSize, weight: isHeader ? .semibold : .regular)
                let line = NSMutableAttributedString()
                // 行首留白（和 tabStops 的 leadChars 对应）
                line.append(NSAttributedString(
                    string: String(repeating: " ", count: leadChars),
                    attributes: [.font: base]
                ))
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
                // 行尾留白：不然最后一列直接顶到圆角边缘
                line.append(NSAttributedString(string: " ", attributes: [.font: base]))
                line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                return line
            }

            // 自适应排法：**3 列以上且按 tabStops 排会截断**时，改用「列名：值」卡片式。
            //
            // 为什么：气泡宽度只有 50 个半角字符，三列中文（每字 2 宽）几乎必然截断 ——
            // 用户看到的是一排省略号，信息反而丢了（实拍多次）。
            // 卡片式每行只放「列名 + 一个值」，可以换行，不丢内容；代价是行数变多。
            // 两列以内仍用 tabStops（那是最省高度的排法）。
            let wouldTruncate = allRows.contains { row in
                row.enumerated().contains { idx, cell in
                    idx < columnCount
                        && displayWidth(InlineParser.stripResidual(cell)) > columnWidths[idx]
                }
            }
            if !isFull, columnCount >= 3, wouldTruncate {
                let card = NSMutableAttributedString()
                let valueFont = UIFont.systemFont(ofSize: 13)
                let labelFont = UIFont.systemFont(ofSize: 11, weight: .medium)
                for (rowIndex, row) in shownRows.enumerated() {
                    if rowIndex > 0 {
                        card.append(NSAttributedString(
                            string: "\n",
                            attributes: [.font: UIFont.systemFont(ofSize: 7)]
                        ))
                    }
                    for column in 0..<columnCount where column < row.count {
                        let style = NSMutableParagraphStyle()
                        style.lineSpacing = 2
                        style.paragraphSpacing = 3
                        style.headIndent = 10        // 换行后悬挂缩进，读起来成块
                        style.firstLineHeadIndent = 0
                        style.lineBreakMode = .byWordWrapping
                        let label = column < headers.count ? headers[column] : ""
                        let line = NSMutableAttributedString()
                        if column == 0 {
                            line.append(NSAttributedString(
                                string: "· ",
                                attributes: [.font: valueFont, .foregroundColor: UIColor.tertiaryLabel]
                            ))
                        } else {
                            line.append(NSAttributedString(string: "  ", attributes: [.font: valueFont]))
                        }
                        line.append(NSAttributedString(
                            string: label + " ",
                            attributes: [.font: labelFont, .foregroundColor: UIColor.secondaryLabel]
                        ))
                        line.append(NSAttributedString(
                            string: InlineParser.stripResidual(row[column]),
                            attributes: [.font: valueFont, .foregroundColor: UIColor.label]
                        ))
                        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                        card.append(line)
                        card.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 2)]))
                    }
                }
                let range = NSRange(location: 0, length: card.length)
                if range.length > 0 {
                    card.addAttribute(BlockFillAttribute.key, value: UIColor.tertiarySystemFill, range: range)
                }
                if rows.count > rowLimit, let url = URL(string: "dsh://detail") {
                    card.append(NSAttributedString(
                        string: "\n▦ 还有 \(rows.count - rowLimit) 行 · 点按看完整版 ›",
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                            .foregroundColor: UIColor.tintColor,
                            .link: url,
                            .paragraphStyle: Self.style(spacingAfter: 2, spacingBefore: 4, lineSpacing: 1),
                        ]
                    ))
                }
                return card
            }

            let out = NSMutableAttributedString()
            // 上下空白段：表格的内边距和块外间距都由它们提供（真布局，不靠外扩矩形）。
            let tablePadFont = UIFont.systemFont(ofSize: 5)
            out.append(NSAttributedString(
                string: "\n",
                attributes: [
                    .font: tablePadFont,
                    .paragraphStyle: Self.style(spacingAfter: 0, spacingBefore: max(before, 12), lineSpacing: 0),
                ]
            ))
            if !headers.isEmpty {
                // 表头不再单独画「─」分隔线：
                // 那一行本身是**一个段落**，会挤在表头的视觉区域里，
                // 看起来就是「横线压在第一行」（用户实拍）。
                // 现在靠「表头加粗 + 表头下 8pt 段距」区分。
                out.append(makeRow(headers, isHeader: true))
            }
            for (i, row) in shownRows.enumerated() {
                // ⚠️ 每一行前面都要补 "\n"（包括第一行）。
                // makeRow 产出的行**不带换行**，以前靠表头下面那行「─」收尾，
                // 那行删掉之后第一行数据就接到了表头段里 ——
                // 用户实拍：表头那一行变成「调用 结果 write 晨报.docx」。
                out.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 3)]))
                out.append(makeRow(row, isHeader: false, isLast: i == shownRows.count - 1))
            }
            // 下空白段：先 "\n" 结束最后一行，再来一个 "\n" 才是**独立的空段落**
            // （只加一个 "\n" 只是给上一行收尾，不会产生高度 ——
            //  用户实拍：表格下边界被切掉）。
            out.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 3)]))
            out.append(NSAttributedString(
                string: "\n",
                attributes: [
                    .font: tablePadFont,
                    .paragraphStyle: Self.style(spacingAfter: 14, spacingBefore: 0, lineSpacing: 0),
                ]
            ))

            // 整表一块底色：由 BlockFillLayoutManager 按行片段并集画（含 tab 空档），
            // 不像 .backgroundColor 那样被列间距切成一段段。
            let tableRange = NSRange(location: 0, length: out.length)
            if tableRange.length > 0 {
                out.addAttribute(
                    BlockFillAttribute.key,
                    value: UIColor.tertiarySystemFill,
                    range: tableRange
                )
            }

            // 折叠提示只在列表（compact）里出现；详情页本身就是完整内容。
            // 注意：除了「行/列超限」，**单元格被压窄截断**也算被省略（用户实拍：
            // 4 列 8 行的表里 13.3… / 1.24… 被截断，却没有入口点开）。
            if !isFull, rows.count > rowLimit || hiddenColumns > 0 || didTruncateCells {
                // 说明 + 入口合成一行，别再分两行占高度（用户实拍觉得像乱码那一版）。
                var label = L("▦ 表格已折叠", "▦ Table collapsed")
                if hiddenColumns > 0 { label += "（还有 \(hiddenColumns) 列）" }
                if rows.count > rowLimit { label += "（还有 \(rows.count - rowLimit) 行）" }
                label += L(" · 点按看完整版 ›", " · tap for the full table ›")
                if let url = URL(string: "dsh://detail") {
                    out.append(NSAttributedString(
                        string: "\n" + label,
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                            .foregroundColor: UIColor.tintColor,
                            .link: url,
                            .paragraphStyle: Self.style(spacingAfter: 2, spacingBefore: 4, lineSpacing: 1),
                        ]
                    ))
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
