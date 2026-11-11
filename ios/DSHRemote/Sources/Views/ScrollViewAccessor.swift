import SwiftUI
import UIKit

/// 拿到 SwiftUI ScrollView 背后的 UIScrollView。
///
/// 为什么需要它：`ScrollViewReader.scrollTo` 在惯性滚动进行中会被滚动动画覆盖，
/// 点了等于没点（实测：按钮 action 确实触发了，但画面不动）。
/// 只有直接调 UIScrollView 的 `setContentOffset` 才能先掐掉惯性、再定位。
struct ScrollViewAccessor: UIViewRepresentable {
    let onResolve: (UIScrollView?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 视图刚进层级时 superview 还没接好，延一拍再往上找
        DispatchQueue.main.async {
            onResolve(uiView.enclosingScrollView())
        }
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
    /// 先掐断惯性，再平滑滚到底。
    ///
    /// 直接 `setContentOffset(animated:)` 在减速动画进行时不一定生效，
    /// 所以先来一次 `animated: false` 把 decelerating 状态打断。
    func stopThenScrollToBottom(animated: Bool = true) {
        // ① 停在当前位置：这一步会终止正在跑的减速动画
        setContentOffset(contentOffset, animated: false)
        // ② 算真正的底部
        let visibleHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
        let maxOffset = max(0, contentSize.height - visibleHeight + adjustedContentInset.bottom)
        setContentOffset(CGPoint(x: contentOffset.x, y: maxOffset), animated: animated)
    }
}
