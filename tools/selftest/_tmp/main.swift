import Foundation

let sample = """
| 能力 | 现在是 `UITextView` | 换 `UILabel` 后 |
|---|---|---|
| 长按选中**任意范围** | ✓ | ✗ |
| 双击选词 / 三击选段 | ✓ | ✗ |
"""

print("=== 有 inline code 的表头 ===")
for b in MarkdownParser.parse(sample) {
    switch b {
    case .table(let h, let r): print("  table: headers=\(h) rows=\(r.count)")
    case .paragraph(let t): print("  paragraph: \(t.prefix(50))")
    case .code(let c, _): print("  code: \(c.prefix(40))")
    default: print("  other: \(b)")
    }
}

let sample2 = """
| 能力 | 现在是 UITextView | 换 UILabel 后 |
|---|---|---|
| 长按 | ✓ | ✗ |
"""
print("=== 无 inline code 的表头 ===")
for b in MarkdownParser.parse(sample2) {
    switch b {
    case .table(let h, let r): print("  table: headers=\(h) rows=\(r.count)")
    case .paragraph(let t): print("  paragraph: \(t.prefix(50))")
    default: print("  other: \(b)")
    }
}