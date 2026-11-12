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
        // 内边距直接采用原 TextField 的 padding(.horizontal 12 / .vertical 9)：
        // 外层不再叠加 padding，光标起点与 placeholder 才能对齐，
        // 单行高度也与旧样式一致（行高 ~20 + 上下 18 = 38）。
        // 上下对称：文字从顶部排，只有上下内边距相等时，光标才会在视觉上居中
        view.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view.textContainer.lineFragmentPadding = 0
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
        let coordinator = context.coordinator

        // ① 只在「外部主动设置」时写回文本。
        //    两个条件缺一不可：
        //    - 编辑中（有 marked text）绝对不碰，否则打断中文输入法的组合态
        //    - 外部值必须既不同于视图内容、又不同于 lastSyncedText，
        //      否则就是「用户刚打的字」被滞后的 @State 旧值覆盖（实测打不进去）
        let composing = view.markedTextRange != nil
        if !composing,
           view.text != text,
           text != coordinator.lastSyncedText {
            view.text = text
            coordinator.lastSyncedText = text
            coordinator.reportHeight()
        }

        // ② 只做 become，**从不 resign**。
        //    @FocusState 的双向同步有时序延迟：按键触发 body 重算时
        //    focused.wrappedValue 可能还是 false，走进"失焦"分支就会把键盘收掉
        //    —— 这正是"一按键输入框就往下掉"的真凶。
        if focused.wrappedValue, !view.isFirstResponder {
            view.becomeFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        weak var textView: UITextView?
        /// 最后一次由用户输入产生、并已同步给外部的文本。
        /// 用来区分「外部主动设置」与「用户正在输入」。
        var lastSyncedText: String = ""

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ view: UITextView) {
            // 组合中也同步给外面（让发送按钮的禁用状态跟随），但绝不回写 text
            lastSyncedText = view.text
            parent.text = view.text
            reportHeight()
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            if !parent.focused.wrappedValue { parent.focused.wrappedValue = true }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            if parent.focused.wrappedValue { parent.focused.wrappedValue = false }
        }

        /// 上次上报的高度。**只在真正变化时回调** —— 每输入一个字符都改
        /// inputHeight 会让 safeAreaInset 抖动，进而带动列表重排。
        private var lastReportedHeight: CGFloat = 0

        func reportHeight() {
            guard let view = textView else { return }
            let width = view.bounds.width
            guard width > 1 else { return }   // 还没布局，等下一次
            let height = view.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            guard abs(height - lastReportedHeight) >= 0.5 else { return }
            lastReportedHeight = height
            parent.onHeightChange(height)
        }
    }
}
