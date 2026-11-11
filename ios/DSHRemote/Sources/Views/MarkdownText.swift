import SwiftUI

/// 轻量 Markdown 渲染器。
///
/// 为什么不用 `AttributedString(markdown:)` 一把梭：它只处理**行内**格式
/// （粗体、斜体、代码、链接），完全不认表格、代码块、列表这些**块级**语法。
/// 而 DSH 的回答里表格非常常见（对比数据），所以块级必须自己拆。
///
/// 覆盖范围：标题 / 表格 / 代码块 / 无序列表 / 有序列表 / 引用 / 分隔线 / 段落的行内格式。
struct MarkdownText: View {
    let raw: String
    /// 解析结果。nil = 还没解析完，先显示纯文本。
    @State private var blocks: [Block]?

    init(raw: String) {
        self.raw = raw
        _blocks = State(initialValue: MarkdownCache.cached(raw))
    }

    var body: some View {
        stallWatcher.setMark("md")
        return VStack(alignment: .leading, spacing: 9) {
            if let blocks {
                // 用下标做 id，**不要**用 Block.id：divider 那条以前是
                // "d-\(UUID().uuidString)"，每次求值都变 → ForEach 认为整行是新元素，
                // 每帧销毁重建一遍，白烧主线程。
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            } else {
                // 首次渲染：主线程上**不做任何 markdown 解析**，先出纯文本，
                // 解析完成后自动换成排版好的版本。
                // 之前是 computed property 同步解析，一条超长回答（工具输出整段日志）
                // 就能把主线程按住好几秒 —— 主线程卡死时体感就是「界面冻住、触控失效」。
                Text(raw)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: raw) {
            if let cached = MarkdownCache.cached(raw) {
                blocks = cached
                return
            }
            blocks = nil
            let parsed = await MarkdownCache.blocksAsync(for: raw)
            blocks = parsed
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text)
                .font(.system(level <= 2 ? .title3 : .headline, weight: .semibold))
                .padding(.top, 2)

        case let .paragraph(text):
            inline(text)
                .font(.body)

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                inline(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case let .code(code, lang):
            VStack(alignment: .leading, spacing: 4) {
                if let lang, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                // ⚠️ 这里刻意**不用** ScrollView(.horizontal)。
                //
                // 嵌套的横向 ScrollView 在纵向 LazyVStack 里被测量时要求完整布局，
                // 一条消息里几个代码块就是几个滚动容器 —— 实测 20 条消息一次性
                // 测量要 30 秒（STUCK 29824ms mark=body）。改成直接换行：
                // 长行会折行、看着不如横滑，但测量成本是常数级。
                Text(clamped(code))
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .selectableText()
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

        case let .bullet(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(item).font(.body)
                    }
                }
            }

        case let .ordered(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        inline(item).font(.body)
                    }
                }
            }

        case .divider:
            Divider().padding(.vertical, 2)

        case let .table(headers, rows):
            table(headers: headers, rows: rows)
        }
    }

    /// 表格：同样不用横向 ScrollView（理由见代码块那段的注释），直接换行排布。
    /// 列多时会被压窄，但不会在测量阶段拖住主线程。
    private func table(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                if !headers.isEmpty {
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { col in
                            inline(col < headers.count ? headers[col] : "")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(minWidth: 54, alignment: .leading)
                        }
                    }
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { col in
                            inline(col < row.count ? row[col] : "")
                                .font(.system(size: 12))
                                .frame(minWidth: 54, alignment: .leading)
                        }
                    }
                    .background(index % 2 == 1 ? Color.secondary.opacity(0.05) : Color.clear)
                }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    /// 代码块/表格里的超长文本截断（排版在主线程，成本随字数线性涨）
    private func clamped(_ code: String) -> String {
        code.count > 4_000
            ? String(code.prefix(4_000)) + "\n…（其余 \(code.count - 4_000) 字已省略）"
            : code
    }

    /// 行内格式交给 AttributedString（它只认行内才是对的用法）
    ///
    /// ⚠️ 必须走缓存。`AttributedString(markdown:)` 每次调用都要重新做一遍
    /// 行内语法扫描，而 body 在流式输出时每 60ms 就重算一次 ——
    /// 15 条消息 × 每段一次 × 每秒十几次，主线程永远追不上，
    /// 表现就是「整个 App 卡住几十秒」（真机 STUCK 63 秒，mark=body）。
    private func inline(_ text: String) -> Text {
        // 长段落跳过行内解析：开销随长度线性涨，工具输出那种整段日志也没有行内格式可解
        if text.count > MarkdownCache.inlineMaxChars { return Text(text) }
        if let attributed = MarkdownCache.inline(text) {
            return Text(attributed)
        }
        return Text(text)
    }
}

enum Block: Identifiable {
    case heading(Int, String)
    case paragraph(String)
    case quote(String)
    case code(String, String?)
    case bullet([String])
    case ordered([String])
    case divider
    case table(headers: [String], rows: [[String]])

    var id: String {
        switch self {
        case let .heading(level, text): return "h\(level)-\(text)"
        case let .paragraph(text): return "p-\(text)"
        case let .quote(text): return "q-\(text)"
        case let .code(code, _): return "c-\(code)"
        case let .bullet(items): return "b-\(items.joined())"
        case let .ordered(items): return "o-\(items.joined())"
        case .divider: return "d-\(UUID().uuidString)"
        case let .table(headers, rows): return "t-\(headers.joined())-\(rows.count)"
        }
    }

    /// 需要做行内格式解析的文本片段（后台预解析用）
    var inlineTexts: [String] {
        switch self {
        case let .heading(_, text), let .paragraph(text), let .quote(text):
            return [text]
        case let .bullet(items), let .ordered(items):
            return items
        case let .table(headers, rows):
            return headers + rows.flatMap { $0 }
        case .code, .divider:
            return []
        }
    }
}

/// Markdown 解析结果缓存。
///
/// 现在有两个访问面：
/// - `cached(_:)` 只读缓存（主线程，命中就同步返回，滚动历史照样直接命中）
/// - `blocksAsync(for:)` 后台解析（首次解析，或流式输出时文本每次都变的情况）
///
/// 关键改动：解析**不再发生在主线程**。之前是 computed property 在 body 里同步解析，
/// 一条超长回答就能把主线程按住数秒。
enum MarkdownCache {
    private static let lock = NSLock()
    private static var storage: [String: [Block]] = [:]
    private static var order: [String] = []
    private static let capacity = 60
    private static let queue = DispatchQueue(label: "dsh.markdown.parse", qos: .userInitiated)

    /// 只读缓存，不触发解析
    static func cached(_ text: String) -> [Block]? {
        lock.lock()
        defer { lock.unlock() }
        return storage[text]
    }

    /// 后台解析并入缓存
    static func blocksAsync(for text: String) async -> [Block] {
        if let hit = cached(text) { return hit }
        // 超长文本直接当一段纯文本：几十万字符既没有 markdown 结构可读，
        // 解析代价也不值得付（典型来源：工具输出的整段日志）
        if text.count > 40_000 {
            let fallback: [Block] = [.paragraph(text)]
            store(text, fallback)
            return fallback
        }
        let parsed = await withCheckedContinuation { (continuation: CheckedContinuation<[Block], Never>) in
            queue.async {
                let blocks = MarkdownParser.parse(text)
                // 顺手把行内 AttributedString 也在后台算完。
                //
                // 为什么必须预解析：`AttributedString(markdown:)` 单次约 100ms，
                // 而 LazyVStack 首次布局会把所有条目测量一遍 ——
                // 19 条 × 每段一次 ≈ 95 次 ≈ 10 秒，全压在主线程上，
                // 表现为「装完第一次打开卡十几秒」（实测 STUCK 11215ms）。
                // 这里在后台把它们算好塞进缓存，主线程第一次取就是命中。
                for block in blocks {
                    for piece in block.inlineTexts where piece.count <= inlineMaxChars {
                        _ = inline(piece)
                    }
                }
                continuation.resume(returning: blocks)
            }
        }
        store(text, parsed)
        return parsed
    }

    private static func store(_ text: String, _ blocks: [Block]) {
        lock.lock()
        defer { lock.unlock() }
        storage[text] = blocks
        order.append(text)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    // MARK: - 行内 AttributedString 缓存
    //
    // 这是这一轮卡死的直接原因：`inline()` 每次都现算 `AttributedString(markdown:)`，
    // 而 body 在流式输出时每 60ms 重算一次 —— 一次重算要几秒（十几条消息 × 每段一次），
    // 于是队列越堆越长，主线程再也回不到空闲（真机 mark=body，STUCK 63 秒）。
    // 文本内容不变时结果必然不变，按原文缓存即可。

    private static var inlineStorage: [String: AttributedString] = [:]
    private static var inlineMiss: Set<String> = []
    private static var inlineOrder: [String] = []
    private static let inlineCapacity = 400
    /// 超过这个长度就不做行内解析（直接纯文本）：
    /// 单次解析耗时随字数增长，而这么长的一段基本都是工具输出，没有行内格式可解。
    static let inlineMaxChars = 800

    static func inline(_ text: String) -> AttributedString? {
        lock.lock()
        if let hit = inlineStorage[text] {
            lock.unlock()
            return hit
        }
        if inlineMiss.contains(text) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )

        lock.lock()
        defer { lock.unlock() }
        if let parsed {
            inlineStorage[text] = parsed
            inlineOrder.append(text)
            while inlineOrder.count > inlineCapacity, let oldest = inlineOrder.first {
                inlineOrder.removeFirst()
                inlineStorage.removeValue(forKey: oldest)
            }
        } else {
            // 解析失败也记住，别每次重算一遍注定失败的解析
            inlineMiss.insert(text)
        }
        return parsed
    }
}

enum MarkdownParser {
    static func parse(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [Block] = []
        var index = 0

        func trimmed(_ i: Int) -> String {
            lines[i].trimmingCharacters(in: .whitespaces)
        }

        while index < lines.count {
            let line = lines[index]
            let t = line.trimmingCharacters(in: .whitespaces)

            if t.isEmpty {
                index += 1
                continue
            }

            // 代码块
            if t.hasPrefix("```") {
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1 // 跳过结尾 ```
                blocks.append(.code(code.joined(separator: "\n"), lang.isEmpty ? nil : lang))
                continue
            }

            // 表格：当前行含 |，下一行是 |---| 分隔
            if t.contains("|"), index + 1 < lines.count, isSeparatorRow(trimmed(index + 1)) {
                let headers = parseRow(t)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    if !rowLine.contains("|") { break }
                    rows.append(parseRow(rowLine))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // 分隔线
            if t == "---" || t == "***" || t == "___" {
                blocks.append(.divider)
                index += 1
                continue
            }

            // 标题
            if t.hasPrefix("#") {
                var level = 0
                var body = t
                while body.hasPrefix("#"), level < 6 {
                    body.removeFirst()
                    level += 1
                }
                blocks.append(.heading(level, body.trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }

            // 引用
            if t.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let q = lines[index].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    quoteLines.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: " ")))
                continue
            }

            // 无序列表
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                var items: [String] = []
                while index < lines.count {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    guard item.hasPrefix("- ") || item.hasPrefix("* ") || item.hasPrefix("+ ") else { break }
                    items.append(String(item.dropFirst(2)))
                    index += 1
                }
                blocks.append(.bullet(items))
                continue
            }

            // 有序列表
            if let _ = t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                var items: [String] = []
                while index < lines.count {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let range = item.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) else { break }
                    items.append(String(item[range.upperBound...]))
                    index += 1
                }
                blocks.append(.ordered(items))
                continue
            }

            // 段落：把连续非空、且不像其它块起始的行合并
            var paragraph: [String] = [t]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || next.hasPrefix("```") || next.hasPrefix("#") || next.hasPrefix(">")
                    || next.hasPrefix("- ") || next.hasPrefix("* ") || next.hasPrefix("+ ")
                    || next == "---" || next.contains("|") {
                    break
                }
                paragraph.append(next)
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }

        return blocks
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        let stripped = line.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty
    }

    private static func parseRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
