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
        // 已经能拿到就直接交付，别排任何任务。
        if let scroll = uiView.enclosingScrollView() {
            if !Self.delivered {
                Self.delivered = true
                DispatchQueue.main.async { onResolve(scroll) }
            }
            return
        }

        // 还没接上视图层级时，只排一次重试。
        //
        // 用 static 而不是 Coordinator：onResolve 闭包每次 body 重算都是新值，
        // SwiftUI 判定 representable 变了会重建 Coordinator —— 标志跟着归零，
        // 于是「排任务 → 改 @State → body 重算 → 又排任务」的循环永远停不下来。
        // static 跨实例存在，才能真正只排一次。
        guard !Self.retryScheduled else { return }
        Self.retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak uiView] in
            guard let uiView, let scroll = uiView.enclosingScrollView() else { return }
            guard !Self.delivered else { return }
            Self.delivered = true
            onResolve(scroll)
        }
    }

    /// 是否已经交付过 UIScrollView（跨实例）
    private static var delivered = false
    /// 是否已经排过延迟重试（跨实例）
    private static var retryScheduled = false
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
    /// 当前内容底部的合法 contentOffset。
    ///
    /// 标准公式：contentSize.height - bounds.height + bottomInset
    /// 之前写成 `contentSize - (bounds - top - bottom) + bottom`，
    /// 等于多加了一个 top+bottom，会滚过头跑到「最新消息下面」的一片空白里。
    var bottomOffsetY: CGFloat {
        max(
            -adjustedContentInset.top,
            contentSize.height - bounds.height + adjustedContentInset.bottom
        )
    }

    /// 立刻贴到底（自动跟随用）。
    ///
    /// 必须先 `layoutIfNeeded()`：流式输出时最后一条的高度刚变，
    /// contentSize 还没重算，直接读会拿到旧值 —— 于是「跟随了但差一点没到底」，
    /// 底部判定失败，之后就再也不跟随了。
    func scrollToBottomInstant() {
        layoutIfNeeded()
        setContentOffset(CGPoint(x: contentOffset.x, y: bottomOffsetY), animated: false)
    }

    /// 只掐断惯性、让位置静止，不改位置。
    ///
    /// `isScrollEnabled` 关再开是系统级打断减速模拟的办法，
    /// 光靠 `setContentOffset(animated: false)` 在减速阶段不生效。
    func stopDeceleration() {
        let wasEnabled = isScrollEnabled
        isScrollEnabled = false
        isScrollEnabled = wasEnabled
        setContentOffset(contentOffset, animated: false)
        layer.removeAllAnimations()
    }

    /// 平滑滚到内容末尾。
    ///
    /// 用 `scrollRectToVisible` 而不是手算 contentOffset：
    /// 给系统一个「末尾 1pt 的矩形」，contentInset / safeArea / 边界夹取都由它处理，
    /// 不会像手算那样越界或留缝。
    func scrollToBottomAnimated() {
        layoutIfNeeded()
        let tail = CGRect(x: 0, y: max(0, contentSize.height - 1), width: 1, height: 1)
        scrollRectToVisible(tail, animated: true)
    }
}
