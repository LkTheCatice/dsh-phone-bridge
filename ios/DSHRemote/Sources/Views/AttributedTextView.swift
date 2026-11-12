import SwiftUI
import UIKit

/// 只读的富文本视图（UITextView 包装），用于详情页。
///
/// **为什么不用 SwiftUI 的 `Text(AttributedString(...))`**：
/// 实测点开详情页一片空白 —— SwiftUI 的 `Text` 不支持 `NSParagraphStyle.tabStops`
/// （表格列对齐就靠它），遇到这类属性整段渲染失败。
/// 走 UIKit 的 `UITextView` 才能完整支持 TextKit 的段落属性。
struct AttributedTextView: UIViewRepresentable {
    let content: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isScrollEnabled = false          // 高度交给外层 ScrollView
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.attributedText = content
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.attributedText != content {
            view.attributedText = content
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        // 让 SwiftUI 按内容给出高度：宽度用提议值，高度用 UITextView 自算
        let width = proposal.width ?? UIScreen.main.bounds.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}
