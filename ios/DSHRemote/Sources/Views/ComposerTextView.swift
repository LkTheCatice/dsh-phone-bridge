import SwiftUI
import UIKit

/// 消息输入框：自己包 `UITextView`，不用 SwiftUI 的 `TextField`。
///
/// **为什么换掉 `TextField`**：
/// 用户实测「呼出键盘后，第一个字母不进拼音」。机理是：
/// 点输入框 → 键盘弹出 → `safeAreaInset` 高度变化 → composer 重新布局
/// → SwiftUI 在布局变化中重建底层 `UITextField` → 重建那一瞬间到达的按键被丢掉。
/// 之后布局稳定，后续字母就正常 —— 完全吻合"只有第一个字母丢"的现象。
///
/// `UITextView` 由我们自己持有实例，键盘动画、布局变化都不会重建它，
/// 输入法（marked text）的组合态因此不会被中断。
///
/// 另外这里显式保护 `markedTextRange`：中文输入法正在拼写时，
/// `updateUIView` 绝对不能去改 `text`，否则组合态会被打断。
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    /// 是否第一响应者。用 FocusState 的投影类型，才能直接接 `$focused`
    var focused: FocusState<Bool>.Binding
    /// 内容高度变化（用于让外层按 1~5 行自适应）
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: 17)
        view.backgroundColor = .clear
        view.isScrollEnabled = false          // 高度由内容决定，超过上限由外层限高
        view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        view.textContainer.lineFragmentPadding = 0
        view.keyboardDismissMode = .interactive
        view.returnKeyType = .default
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.text = text

        // 让高度变化能回调（首次也要报一次）
        context.coordinator.textView = view
        DispatchQueue.main.async {
            context.coordinator.reportHeight()
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self

        // 中文输入法组合中：**不要碰 text**，否则会把拼音组合态打断
        let composing = view.markedTextRange != nil
        if !composing, view.text != text {
            view.text = text
            context.coordinator.reportHeight()
        }

        // focus 同步（键盘出现/消失时 SwiftUI 不会重建这个 view，所以是安全的）
        if focused.wrappedValue, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !focused.wrappedValue, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        weak var textView: UITextView?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ view: UITextView) {
            // 组合中也同步给外面（让发送按钮的禁用状态跟随），但绝不回写 text
            parent.text = view.text
            reportHeight()
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            if !parent.focused.wrappedValue { parent.focused.wrappedValue = true }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            if parent.focused.wrappedValue { parent.focused.wrappedValue = false }
        }

        func reportHeight() {
            guard let view = textView else { return }
            let height = view.sizeThatFits(
                CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)
            ).height
            parent.onHeightChange(height)
        }
    }
}
