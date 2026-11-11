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

    /// 先强制掐断惯性，再动画滚到底（按钮用）。
    ///
    /// 三步：
    /// ① `animated: false` 的原地定位 —— 真正终止减速动画
    /// ② `layoutIfNeeded()` 让 contentSize 追到最新
    /// ③ `UIView.animate` + `.beginFromCurrentState` 滚过去，
    ///    completion 里再校准一次 —— 万一被手指或残余惯性打断，也能精确到位
    func stopThenScrollToBottom() {
        setContentOffset(contentOffset, animated: false)
        layoutIfNeeded()
        let target = bottomOffsetY
        guard contentSize.height > bounds.height else {
            setContentOffset(CGPoint(x: contentOffset.x, y: target), animated: false)
            return
        }
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.contentOffset = CGPoint(x: self.contentOffset.x, y: target)
        } completion: { _ in
            // 兜底校准：被惯性或手指打断时，最终值可能差一点
            self.setContentOffset(CGPoint(x: self.contentOffset.x, y: target), animated: false)
        }
    }
}
