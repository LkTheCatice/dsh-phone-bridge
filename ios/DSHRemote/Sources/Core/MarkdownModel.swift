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

// MARK: - 行内标记清理（纯字符串处理，无 UIKit 依赖 → 可单测）

enum MarkdownInline {
    /// 去掉行内标记符号（** / ` / 成对的 *），不做任何富化。
    ///
    /// 为什么只做"去标记"而不是"加属性"：
    /// 加属性需要多轮 `NSRange` 替换，而每轮替换都会改变字符串长度，
    /// 一旦沿用旧 range 就越界崩溃（真机实测「点开就闪退」）。
    /// 在没法本地跑 iOS 的情况下，先保证零越界；富化等块级稳定后再单独加。
    static func strip(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        // 单星号只在成对出现时才去掉，避免吃掉乘号之类的正常文本
        if s.filter({ $0 == "*" }).count % 2 == 0 {
            s = s.replacingOccurrences(of: "*", with: "")
        }
        return s
    }
}
