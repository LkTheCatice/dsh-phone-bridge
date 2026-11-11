import SwiftUI
import UIKit

/// 拿到 SwiftUI ScrollView 背后的 UIScrollView。
///
/// 为什么需要它：`ScrollViewReader.scrollTo` 在惯性减速进行中会被滚动动画覆盖，
/// 点了等于没点（埋点实测：按钮 action 确实触发了，但画面不动）。
/// 只有直接操作 UIScrollView 才能真正掐断惯性。
struct ScrollViewAccessor: UIViewRepresentable {
    let onResolve: (UIScrollView?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 视图层级不是一次就绪的：刚进树时 superview 可能还没接上，
        // 所以分几个时间点重试，直到真的找到 UIScrollView。
        resolve(uiView)
        for delay in [0.15, 0.5, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                resolve(uiView)
            }
        }
    }

    private func resolve(_ uiView: UIView) {
        guard let scroll = uiView.enclosingScrollView() else { return }
        DispatchQueue.main.async { onResolve(scroll) }
    }
}

extension UIView {
    /// 向上遍历找到最近的 UIScrollView
    func enclosingScrollView() -> UIScrollView? {
        var node: UIView? = superview
        while let current = node {
            if let scroll = current as? UIScrollView { return scroll }
            node = current.superview
        }
        return nil
    }
}

extension UIScrollView {
    /// 先强制掐断惯性，再滚到底。
    ///
    /// 关键点：`setContentOffset(_:animated:)` 在减速动画进行时**不一定生效**，
    /// 必须先用一次 `animated: false` 的原地定位把 decelerating 状态打断；
    /// 第二步用 `UIView.animate` + `.beginFromCurrentState` 才可靠 ——
    /// 直接在 animate 外设 contentOffset 会被正在跑的动画盖掉。
    func stopThenScrollToBottom() {
        // ① 原地定位：终止减速动画
        setContentOffset(contentOffset, animated: false)
        // ② 算真正的底部
        let visibleHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
        let maxOffset = max(0, contentSize.height - visibleHeight + adjustedContentInset.bottom)
        guard maxOffset > 0 else { return }
        // ③ 动画滚过去
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.contentOffset = CGPoint(x: self.contentOffset.x, y: maxOffset)
        }
    }
}
