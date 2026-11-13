import UIKit

/// 给代码块 / 表格画**整块**底色的自定义布局管理器。
///
/// 为什么不用 `NSAttributedString.Key.backgroundColor`：
/// TextKit 按**字符范围**填色 —— 行尾空白、行间 leading、tabStops 留下的空档
/// 都不属于任何字符，所以底色会一段段断开、右边缘参差、行间留白缝。
/// 用户连拍三张截图指的都是这个问题（「还是有一些缝隙」「直接上完整底色」）。
///
/// 这里在**布局层面**画：把同一段（同一属性 run）里所有行片段的矩形并起来，
/// 画成一个圆角矩形 + 1px 描边。行间自然连续、宽度取行片段的并集（含缩进）。
/// 属性本身由 `BlockFillAttribute.key` 标记，未标记的文本完全不受影响。
enum BlockFillAttribute {
    static let key = NSAttributedString.Key("dshBlockFill")
    /// 描边颜色（可选）
    static let strokeKey = NSAttributedString.Key("dshBlockStroke")
}

final class BlockFillLayoutManager: NSLayoutManager {

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        // 先让 TextKit 画自己的（行内代码的底色、链接下划线等）
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(BlockFillAttribute.key, in: charRange, options: []) { value, range, _ in
            guard let color = value as? UIColor else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }

            // 把这个 run 的所有行片段并成一个矩形
            var union: CGRect = .null
            self.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                union = union.isNull ? rect : union.union(rect)
            }
            guard !union.isNull, union.height > 0 else { return }

            let target = CGRect(
                x: origin.x + union.minX,
                y: origin.y + union.minY,
                width: union.width,
                height: union.height
            )
            // insetBy 用**负值**才是向外扩：给文字和圆角边之间留 padding。
            // 之前是 dy: 1（往里收），字直接贴着上下边（用户实拍：上下边离字太近）。
            .insetBy(dx: -2, dy: -5)

            color.setFill()
            let path = UIBezierPath(roundedRect: target, cornerRadius: 8)
            path.fill()

            // 描边（同一 run 上给了 stroke 才画）
            if let stroke = storage.attribute(BlockFillAttribute.strokeKey, at: range.location, effectiveRange: nil) as? UIColor {
                stroke.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }
}
