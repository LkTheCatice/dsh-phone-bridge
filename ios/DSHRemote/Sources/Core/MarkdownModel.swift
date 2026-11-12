import Foundation

// MARK: - markdown 数据模型与解析（纯 Foundation，不依赖 SwiftUI/UIKit）
//
// 单独成文件的原因：
// 1. 分层：解析是纯逻辑，视图只负责画；
// 2. **可测**：这份文件不 import SwiftUI/UIKit，能在 macOS/Linux/Windows 的
//    Swift 工具链上直接编译跑测试 —— 今晚两次崩溃（重复 key、NSRange 越界）
//    都属于这一层，本来就该在提交前被本地测试拦住。
// 3. 三端共用：iOS 的 SwiftUI 视图与 Windows 侧的自测脚本用同一份代码。

enum Block: Identifiable, Equatable {
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

// MARK: - 行内富化：扫描式分段（零 NSRange 操作）

enum InlineStyle: Equatable {
    case plain
    case bold
    case italic
    case code
    /// 链接：文本 + 目标地址（渲染层设 NSAttributedString.Key.link，UITextView 原生可点）
    case link(String)
}

struct InlineSegment: Equatable {
    let text: String
    let style: InlineStyle
}

/// 行内标记 → 分段列表。
///
/// **为什么是「分段」而不是「原地替换」**：
/// 之前用 `NSMutableAttributedString.replaceCharacters(in:with:)` 做多轮替换，
/// 每轮都改变字符串长度，一旦沿用旧 `NSRange` 就越界崩溃（真机实测「点开就闪退」）。
/// 扫描式解析只读原字符串、只产出分段，长度计算永不失效 —— 从结构上消除越界。
///
/// 规则（刻意保守，宁可少解析也不要错）：
/// - `**x**` → bold；`` `x` `` → code；`*x*` → italic（不跨行）
/// - 未闭合、空内容、`****`、跨行的单个 `*` 一律按纯文本原样保留
/// - 不处理嵌套（`**a *b* c**` 里的 `*b*` 保持字面）
enum InlineParser {

    static func segments(_ text: String) -> [InlineSegment] {
        let chars = Array(text)
        var out: [InlineSegment] = []
        var buffer = ""
        var i = 0
        let n = chars.count

        func flush() {
            if !buffer.isEmpty {
                out.append(InlineSegment(text: buffer, style: .plain))
                buffer = ""
            }
        }

        while i < n {
            let c = chars[i]

            // ** 粗体 **
            if c == "*", i + 1 < n, chars[i + 1] == "*" {
                if let close = findClosing(chars, from: i + 2, marker: "*", doubled: true) {
                    let inner = String(chars[(i + 2)..<close])
                    if !inner.isEmpty {
                        flush()
                        out.append(InlineSegment(text: inner, style: .bold))
                        i = close + 2
                        continue
                    }
                }
                buffer.append("*")
                buffer.append("*")
                i += 2
                continue
            }

            // [文本](链接)
            if c == "[" {
                if let (label, url, next) = parseLink(chars, from: i) {
                    flush()
                    out.append(InlineSegment(text: label, style: .link(url)))
                    i = next
                    continue
                }
                buffer.append(c)
                i += 1
                continue
            }

            // ` 行内代码 `
            if c == "`" {
                if let close = findClosing(chars, from: i + 1, marker: "`", doubled: false) {
                    let inner = String(chars[(i + 1)..<close])
                    if !inner.isEmpty {
                        flush()
                        out.append(InlineSegment(text: inner, style: .code))
                        i = close + 1
                        continue
                    }
                }
                buffer.append("`")
                i += 1
                continue
            }

            // * 斜体 *（不跨行、不与其他 * 相邻）
            if c == "*" {
                let prevIsStar = i > 0 && chars[i - 1] == "*"
                let nextIsStar = i + 1 < n && chars[i + 1] == "*"
                if !prevIsStar, !nextIsStar,
                   let close = findClosing(chars, from: i + 1, marker: "*", doubled: false) {
                    let inner = String(chars[(i + 1)..<close])
                    if !inner.isEmpty, !inner.contains("\n") {
                        flush()
                        out.append(InlineSegment(text: inner, style: .italic))
                        i = close + 1
                        continue
                    }
                }
                buffer.append("*")
                i += 1
                continue
            }

            buffer.append(c)
            i += 1
        }
        flush()
        return out
    }

    /// 找配对的结束标记；遇到换行或找不到就返回 nil（保持字面）
    private static func findClosing(
        _ chars: [Character], from start: Int, marker: Character, doubled: Bool
    ) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == "\n" { return nil }   // 行内标记不跨行
            if chars[j] == marker {
                if doubled {
                    if j + 1 < chars.count, chars[j + 1] == marker { return j }
                } else {
                    // 单个标记：前一个字符不能是同一标记（避免吃掉 ** 的一半）
                    if j == 0 || chars[j - 1] != marker { return j }
                }
            }
            j += 1
        }
        return nil
    }

    /// 解析 `[文本](地址)`，返回 (文本, 地址, 下一个位置)。
    /// 找不到闭合括号就返回 nil（保持字面）。
    private static func parseLink(
        _ chars: [Character], from start: Int
    ) -> (String, String, Int)? {
        var j = start + 1
        var label = ""
        while j < chars.count, chars[j] != "]" {
            if chars[j] == "\n" { return nil }
            label.append(chars[j])
            j += 1
        }
        guard j + 1 < chars.count, chars[j] == "]", chars[j + 1] == "(" else { return nil }
        var k = j + 2
        var url = ""
        while k < chars.count, chars[k] != ")" {
            if chars[k] == "\n" { return nil }
            url.append(chars[k])
            k += 1
        }
        guard k < chars.count, chars[k] == ")" else { return nil }
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty, !trimmedURL.isEmpty else { return nil }
        return (trimmedLabel, trimmedURL, k + 1)
    }
}
