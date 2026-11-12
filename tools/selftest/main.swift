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

// MARK: - 6. 行内富化（扫描式分段，替代 NSRange 替换）

section("InlineParser.segments")

/// 分段拼接后必须与原文去掉标记后一致 —— 这条断言能抓「吞字」类 bug
func joined(_ segs: [InlineSegment]) -> String { segs.map(\.text).joined() }

let inlineCases: [(String, String)] = [
    ("**粗体**", "粗体"),
    ("`代码`", "代码"),
    ("*斜体*", "斜体"),
    ("**a** `b` *c*", "a b c"),
    ("前**粗**后", "前粗后"),
    ("3 * 4 = 12", "3 * 4 = 12"),            // 孤立星号保持字面
    ("**未闭合", "**未闭合"),                 // 未闭合保持字面
    ("`未闭合", "`未闭合"),
    ("****", "****"),                        // 空内容不配对
    ("**跨\n行**", "**跨\n行**"),            // 行内标记不跨行
    ("😀**表情**", "😀表情"),
    ("", ""),
    ("正常文本", "正常文本"),
    ("**a**普通文字", "a普通文字"),
    ("`a`\n\n`b`", "a\n\nb"),               // 两段代码各自闭合
]

for (input, expect) in inlineCases {
    let segs = InlineParser.segments(input)
    let got = joined(segs)
    check(got == expect, "分段拼接不符：输入「\(input)」期望「\(expect)」实际「\(got)」")
    // 分段不得为空文本（否则 iOS 侧会 append 空串）
    check(segs.allSatisfy { !$0.text.isEmpty }, "出现空分段：输入「\(input)」")
}

// 样式判定
func styles(_ s: String) -> [InlineStyle] { InlineParser.segments(s).map(\.style) }
check(styles("**b**") == [.bold], "粗体样式识别失败")
check(styles("`c`") == [.code], "代码样式识别失败")
check(styles("*i*") == [.italic], "斜体样式识别失败")
check(styles("**b**`c`") == [.bold, .code], "相邻样式识别失败")
check(styles("普通") == [.plain], "纯文本样式识别失败")

// 压力：长文本 + 大量标记，检查不崩且长度守恒
var stress = ""
for i in 0..<300 { stress += (i % 3 == 0) ? "**粗** " : ((i % 3 == 1) ? "`码` " : "*斜* ") }
let stressSegs = InlineParser.segments(stress)
check(!stressSegs.isEmpty, "压力用例解析为空")
check(stressSegs.count >= 300, "压力用例分段数异常少：\(stressSegs.count)")
print("  \(inlineCases.count) 条用例 + 样式/压力断言")

// MARK: - 7. 媒体路径扫描（Core/MediaRefScan）

section("MediaRefScan 路径识别")

let mediaCases: [(String, String, Int, Int, Int)] = [
    // 文本, 说明, 期望图片数, 期望视频数, 期望音频数
    ("看这个 ![图](D:/a/b.png)", "markdown 图片", 1, 0, 0),
    ("D:\\AI\\out\\x.jpg", "Windows 反斜杠", 1, 0, 0),
    ("/home/u/v.mp4", "正斜杠视频", 0, 1, 0),
    ("音乐 /a/s.mp3 和图 /a/p.png", "混合", 1, 0, 1),
    ("没有路径的普通文字", "无路径", 0, 0, 0),
    ("a.png b.jpg c.gif", "相对路径不算", 0, 0, 0),
    ("[附件] E:/x/y.webp", "附件标记", 1, 0, 0),
    ("C:\\a\\b.mov", "反斜杠视频", 0, 1, 0),
    ("/a/b.flac", "音频 flac", 0, 0, 1),
    ("文件 /a/b.txt", "非媒体扩展名", 0, 0, 0),
]
for (text, note, imgs, vids, auds) in mediaCases {
    let refs = MediaRefCache.refs(for: text)
    check(refs.images.count == imgs, "\(note)：图片数期望 \(imgs) 实际 \(refs.images.count)")
    check(refs.videos.count == vids, "\(note)：视频数期望 \(vids) 实际 \(refs.videos.count)")
    check(refs.audios.count == auds, "\(note)：音频数期望 \(auds) 实际 \(refs.audios.count)")
}

// 超长文本守卫（避免正则扫几万字）
let longText = String(repeating: "填充文字 ", count: 4_000) + " /a/p.png"
let longRefs = MediaRefCache.refs(for: longText)
check(longRefs.isEmpty, "超长文本应跳过扫描（守卫失效，实际图片数 \(longRefs.images.count)）")

// 扩展名分类
check(MediaRefScan.kind(of: "a.PNG") == .image, "大写扩展名应识别为图片")
check(MediaRefScan.kind(of: "a.mp4") == .video, "mp4 应识别为视频")
check(MediaRefScan.kind(of: "a.weird") == nil, "未知扩展名应返回 nil")

// cleaned：markdown 图片语法换成短名
let cleanedText: String = MediaRefScan.cleaned("看 ![alt](D:/a/b.png) 这里")
check(!cleanedText.contains("!["), "cleaned 应去掉 markdown 图片语法")
print("  \(mediaCases.count) 条路径用例 + 超长守卫 + 分类/清理")

// MARK: - 8. 解析缓存（Core/MarkdownCache）

section("MarkdownCache")

let sample = "# 标题\n\n正文 **粗体** 和 `代码`\n\n```swift\nlet a = 1\n```"
let first = MarkdownCache.blocksSync(for: sample)
check(!first.isEmpty, "首次解析为空")
let second = MarkdownCache.blocksSync(for: sample)
check(first.count == second.count, "缓存命中后 block 数不一致")
check(first == second, "缓存命中后内容不一致")

// 不同文本不应互相污染
let other = "另一段 `x` 文本"
let otherBlocks = MarkdownCache.blocksSync(for: other)
check(otherBlocks != first, "不同文本解析结果被污染")

// 空串
let emptyBlocks = MarkdownCache.blocksSync(for: "")
check(emptyBlocks.isEmpty, "空串应得到空 block")

// 超大文本不应崩（有长度守卫）
let huge = String(repeating: "填充 **粗** `码` ", count: 1_500)
let hugeBlocks = MarkdownCache.blocksSync(for: huge)
check(!hugeBlocks.isEmpty, "超大文本解析为空")

print("  缓存命中/隔离/空串/超大 共 6 条断言")

// MARK: - 9. 真实消息回归（用户截图暴露的问题）

section("表格 + 行内粗体（截图里的实际内容）")

let realSample = """
## ⚠️ 这一版有个前提：**桥要重启才生效**

| 改之前 | 改之后 |
|---|---|
| 传输 | 原图**十几 MB**，1MB 分块拉 |
| 解码 | 手机解 2800×6000 |
"""
let realBlocks = MarkdownParser.parse(realSample)
var foundTable = false
var foundHeading = false
for b in realBlocks {
    if case .table = b { foundTable = true }
    if case .heading = b { foundHeading = true }
}
check(foundHeading, "标题未识别成 heading")
check(foundTable, "表格未识别成 table（截图里显示成了带 | 的纯文本）")

// 表格单元格里的行内标记必须被清理（截图里 **十几 MB** 的星号还在）
if case let .table(headers, rows) = realBlocks.first(where: { if case .table = $0 { return true }; return false }) ?? .divider {
    // 分工：MarkdownParser 只负责切分，**保留原始标记**；
    // 清理行内标记是渲染层（MarkdownNS → InlineParser）的职责。
    // 所以这里验证的是「渲染层拿到单元格内容后能清干净」，而不是要求 parser 输出无标记。
    let cells = headers + rows.flatMap { $0 }
    for cell in cells {
        let cleaned = InlineParser.segments(cell).map(\.text).joined()
        check(!cleaned.contains("**"), "InlineParser 未清掉单元格里的 **：\(cell)")
        check(!cleaned.contains("`"), "InlineParser 未清掉单元格里的反引号：\(cell)")
    }
    print("  表格 headers=\(headers.count) rows=\(rows.count)")
} else {
    print("  未取到表格，跳过单元格断言")
}

// 表格后面紧跟段落时也要正确切分
let tableThenText = """
| a | b |
|---|---|
| 1 | 2 |

后面一段普通文字
"""
let tt = MarkdownParser.parse(tableThenText)
check(tt.count >= 2, "表格+段落应至少 2 个 block，实际 \(tt.count)")

// MARK: - 10. 链接（用户截图：markdown 链接原样露出）

section("InlineParser 链接")

let linkCases: [(String, String)] = [
    ("[dist/DSHRemote.ipa](phone-dsh/dist/x.ipa)", "dist/DSHRemote.ipa"),
    ("见 [文档](https://example.com) 说明", "见 文档 说明"),
    ("[未闭合](没有右括号", "[未闭合](没有右括号"),   // 不完整就保持字面
    ("[只有标签]", "[只有标签]"),
    ("[](空标签)", "[](空标签)"),                     // 空标签不解析
    ("前[中](u)后", "前中后"),
    ("[多个](a)和[b](c)", "多个和b"),
]
for (input, expect) in linkCases {
    let got = InlineParser.segments(input).map(\.text).joined()
    check(got == expect, "链接用例：输入「\(input)」期望「\(expect)」实际「\(got)」")
}

// 样式判定：链接必须带出 url
let segs = InlineParser.segments("[文档](https://example.com/x)")
check(segs.count == 1, "单个链接应只有 1 段，实际 \(segs.count)")
if case let .link(url) = segs.first?.style {
    check(url == "https://example.com/x", "链接地址解析错误：\(url)")
} else {
    check(false, "链接未被识别成 .link 样式")
}
// 链接与其它样式混排
// 注意：标记之间的空格会成为独立的 plain 段，计数时要排除纯空白段
let mixed = InlineParser.segments("**粗** [链](u) `码`")
let meaningful = mixed.filter { seg in
    if case .plain = seg.style {
        return !seg.text.trimmingCharacters(in: .whitespaces).isEmpty
    }
    return true
}
check(meaningful.count == 3, "混排应有 3 个有效段，实际 \(meaningful.count)（总段数 \(mixed.count)）")
check(meaningful.contains { if case .link = $0.style { return true }; return false }, "混排里没有 link")
print("  \(linkCases.count) 条用例 + 样式/混排断言")

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
