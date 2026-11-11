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

    /// 先强制掐断惯性，再滚到底（按钮用）。
    ///
    /// 定位方式用 `scrollRectToVisible`，而不是手算 contentOffset：
    /// 给它「内容最末尾的一个 1pt 矩形」，系统自己算该滚到哪 ——
    /// contentInset、safeArea、边界夹取都由它处理，不会像手算那样越界或留缝。
    ///
    /// 前置的三步是为了让它在惯性中也能生效：
    /// ① isScrollEnabled 关再开 —— 系统级打断减速模拟
    /// ② 原地 setContentOffset + 清 layer 动画 —— 清掉残留滚动状态
    /// ③ layoutIfNeeded —— 让 contentSize 追上最新内容
    ///
    /// 最后补一次单次校正：内容可能还在长（工具行追加、流式输出），
    /// 落位后下一帧再量一次真实的底部，差超过 1pt 就修正。
    /// 只跑一次且用户开始滑动就放弃 —— 多帧反复校准会和自动跟随互相触发，之前因此卡死过。
    func stopThenScrollToBottom() {
        let wasEnabled = isScrollEnabled
        isScrollEnabled = false
        isScrollEnabled = wasEnabled
        setContentOffset(contentOffset, animated: false)
        layer.removeAllAnimations()
        layoutIfNeeded()

        let tail = CGRect(x: 0, y: max(0, contentSize.height - 1), width: 1, height: 1)
        scrollRectToVisible(tail, animated: true)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.isDragging, !self.isDecelerating, !self.isTracking else { return }
            self.layoutIfNeeded()
            let exact = self.bottomOffsetY
            if abs(self.contentOffset.y - exact) > 1 {
                self.setContentOffset(CGPoint(x: self.contentOffset.x, y: exact), animated: false)
            }
        }
    }
}
