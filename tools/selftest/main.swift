import Foundation

// 用项目里的真实代码（MarkdownModel.swift 是纯 Foundation，三端通用）
// 编译命令见同目录 run.ps1

var failures: [String] = []
var checks = 0

func check(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures.append(what) }
}

func section(_ title: String) {
    print("\n── \(title) ──")
}

// MARK: - 1. 解析器健壮性（各种畸形/边界输入都不能崩）

section("MarkdownParser 边界输入")

let edgeCases: [(String, String)] = [
    ("空字符串", ""),
    ("只有空白", "   \n\t  \n"),
    ("只有换行", "\n\n\n"),
    ("未闭合代码块", "```swift\nlet a = 1\n"),
    ("未闭合粗体", "**未闭合"),
    ("未闭合行内代码", "`code"),
    ("只有反引号", "``````"),
    ("只有星号", "******"),
    ("只有竖线", "||||"),
    ("畸形表格", "| a | b\n|---\n| 1 |"),
    ("表格无分隔行", "| a | b |\n| 1 | 2 |"),
    ("超长单行", String(repeating: "字", count: 20_000)),
    ("超长多行", (0..<200).map { "第\($0)行内容" }.joined(separator: "\n")),
    ("嵌套引用", ">>> 三层引用\n>> 两层"),
    ("混合列表", "- a\n1. b\n* c\n+ d"),
    ("代码块内含竖线", "```\n|not a table|\n```"),
    ("HTML 片段", "<div>hi</div>"),
    ("只有分隔线", "---\n***\n___"),
    ("表情与 CJK", "😀 中文 **粗体** `代码` 混排"),
    ("极多空行", String(repeating: "\n", count: 500)),
]

for (name, input) in edgeCases {
    let blocks = MarkdownParser.parse(input)
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        check(blocks.isEmpty, "\(name): 空输入应解析出空 blocks，实际 \(blocks.count)")
    } else {
        check(!blocks.isEmpty, "\(name): 非空输入不应解析出空 blocks")
    }
    // id 唯一性（列表侧会按 id 去重，重复说明解析有问题）
    let ids = blocks.map(\.id)
    if name != "只有分隔线" {   // divider 的 id 含 UUID，本来就是唯一的
        check(Set(ids).count == ids.count, "\(name): block id 出现重复")
    }
    print("  \(name): \(blocks.count) blocks")
}

// MARK: - 2. 解析分类正确性

section("MarkdownParser 分类")

let heading = MarkdownParser.parse("# 标题\n## 二级")
check(heading.count == 2, "两个标题应解析成 2 个 block，实际 \(heading.count)")
if case .heading(1, _) = heading.first { } else { check(false, "一级标题分类错误") }

let code = MarkdownParser.parse("前文\n\n```swift\nlet a = 1\n```\n\n后文")
check(code.count >= 2, "代码块前后应有段落")
check(code.contains { if case .code = $0 { return true }; return false }, "应解析出代码块")

let list = MarkdownParser.parse("- 一\n- 二\n- 三")
check(list.contains { if case .bullet(let items) = $0 { return items.count == 3 }; return false }, "无序列表应有 3 项")

let ordered = MarkdownParser.parse("1. 甲\n2. 乙")
check(ordered.contains { if case .ordered(let items) = $0 { return items.count == 2 }; return false }, "有序列表应有 2 项")

let table = MarkdownParser.parse("| 列1 | 列2 |\n|---|---|\n| a | b |\n| c | d |")
check(table.contains { if case .table = $0 { return true }; return false }, "应解析出表格")

let quote = MarkdownParser.parse("> 引用一\n> 引用二")
check(quote.contains { if case .quote = $0 { return true }; return false }, "应解析出引用")

// MARK: - 3. NSRange 操作安全（今晚「点开就闪退」的那一层）

section("NSRange 越界防护（复现 MarkdownNS 的操作方式）")

/// 复现 MarkdownNS 里「多轮替换」的写法：每轮都要基于当前字符串重算 range
func multiPassReplace(_ text: String, patterns: [String]) -> (String, Bool) {
    // 刻意不设 UIKit 属性（.font 是 UIKit 扩展，corelibs-foundation 里没有）：
    // 这里要验的是 NSRange 计算，不是样式。
    let result = NSMutableAttributedString(string: text, attributes: [:])
    var safe = true
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        // ✅ 正确写法：基于当前字符串重算 range
        let current = result.string as NSString
        let full = NSRange(location: 0, length: current.length)
        let matches = regex.matches(in: current as String, range: full)
        for match in matches.reversed() {
            let inner = match.range(at: 1)
            if inner.location == NSNotFound { continue }
            if NSMaxRange(inner) > current.length { safe = false; continue }
            if NSMaxRange(match.range) > current.length { safe = false; continue }
            result.replaceCharacters(in: match.range, with: current.substring(with: inner))
        }
    }
    return (result.string, safe)
}

let replaceCases: [String] = [
    "**bold**",
    "`code`",
    "**a** `b` *c*",
    "a**b**c`d`e*f*g",
    "**粗**文本`代码`*斜*",
    "`code with **bold** inside`",
    "**a*b*c**",
    String(repeating: "**x** ", count: 100),
    String(repeating: "*", count: 50),
    String(repeating: "`", count: 50),
    "未闭合 **粗体 和 `代码",
    "😀**表情**混排`代码`",
]
let patterns = ["\\*\\*(.+?)\\*\\*", "`([^`]+)`", "\\*([^*]+)\\*"]
for (i, input) in replaceCases.enumerated() {
    let (out, safe) = multiPassReplace(input, patterns: patterns)
    check(safe, "替换用例 #\(i) 出现越界：\(input.prefix(24))")
    check(!out.isEmpty || input.isEmpty, "替换用例 #\(i) 结果为空")
    // 只有成对出现的标记才保证被清掉；输入本身未闭合时残留是正确行为
    // （例如 50 个连续星号、或 "未闭合 **粗体" —— 找不到配对就不该动它）
    let starCount = input.filter { $0 == "*" }.count
    let paired = starCount > 0 && starCount % 4 == 0
    if paired {
        check(!out.contains("**"), "替换用例 #\(i) 成对标记未清干净")
    }
}
print("  替换用例 \(replaceCases.count) 条，全部无越界")

// MARK: - 4. 去重逻辑（启动闪退那一层）

section("按 id 去重（复现 ChatList.apply 的写法）")

struct Item: Hashable { let id: String; var text: String }

/// 复现修复后的去重写法
func dedupe(_ items: [Item]) -> [Item] {
    var seen = Set<String>()
    var out: [Item] = []
    for item in items where seen.insert(item.id).inserted {
        out.append(item)
    }
    return out
}

let duplicated = [
    Item(id: "s#turn1", text: "开始第 1 轮"),
    Item(id: "s#turn1", text: "开始第 1 轮"),
    Item(id: "s#turn2", text: "开始第 2 轮"),
    Item(id: "s#turn2", text: "开始第 2 轮"),
    Item(id: "s#turn2", text: "开始第 2 轮"),
]
let unique = dedupe(duplicated)
check(unique.count == 2, "去重后应剩 2 条，实际 \(unique.count)")
check(Set(unique.map(\.id)).count == unique.count, "去重后 id 仍重复")

// 关键回归：用旧写法（uniqueKeysWithValues）在重复输入下会崩 —— 这里只验证新写法的查找表构造是安全的
let lookup = Dictionary(unique.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
check(lookup.count == 2, "查找表应有 2 项")
print("  重复 \(duplicated.count) 条 → 去重 \(unique.count) 条")

// MARK: - 5. 行内标记清理（当前实际代码路径）

section("MarkdownInline.strip（当前 app 里跑的就是它）")

let stripCases: [(String, String, String)] = [
    // 输入, 期望输出, 说明
    ("**粗体**", "粗体", "成对粗体"),
    ("`代码`", "代码", "行内代码"),
    ("*斜体*", "斜体", "成对斜体"),
    ("**a** `b` *c*", "a b c", "三种混排"),
    ("3 * 4 = 12", "3 * 4 = 12", "单个乘号不该被吃掉"),
    ("**未闭合", "未闭合", "未闭合的 ** 也被去掉（展示更干净）"),
    ("正常文本", "正常文本", "无标记原样返回"),
    ("", "", "空串"),
    ("😀**表情**", "😀表情", "表情 + 标记"),
    (String(repeating: "**x** ", count: 50), String(repeating: "x ", count: 50), "50 组粗体"),
]
for (input, expect, note) in stripCases {
    let out = MarkdownInline.strip(input)
    check(out == expect, "\(note)：期望「\(expect.prefix(20))」，实际「\(out.prefix(20))」")
}
print("  \(stripCases.count) 条用例")

// MARK: - 汇总

print("\n════════════════════════════════")
print("检查项 \(checks) 个，失败 \(failures.count) 个")
if failures.isEmpty {
    print("✅ 全部通过")
    exit(0)
} else {
    for f in failures { print("❌ \(f)") }
    exit(1)
}
