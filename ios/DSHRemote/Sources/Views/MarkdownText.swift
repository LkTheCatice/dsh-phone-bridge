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

    private var blocks: [Block] { MarkdownCache.blocks(for: raw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks) { block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .selectableText()
                }
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

    /// 表格：横向可滚动，避免多列时把字挤成一列一列
    private func table(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
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
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    /// 行内格式交给 AttributedString（它只认行内才是对的用法）
    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
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
}

/// Markdown 解析结果缓存。
///
/// 之前 `blocks` 是 computed property，每次 body 求值都重新解析整段文本。
/// 流式输出时每秒触发几十次重建 —— 这是卡顿的主因之一。
/// 这里按原文做定长缓存，滚动历史、重复渲染都能直接命中。
/// 只在主线程（View body）里调用。
enum MarkdownCache {
    private static var storage: [String: [Block]] = [:]
    private static var order: [String] = []
    private static let capacity = 60

    static func blocks(for text: String) -> [Block] {
        if let hit = storage[text] { return hit }
        let parsed = MarkdownParser.parse(text)
        storage[text] = parsed
        order.append(text)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
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
