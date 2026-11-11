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

    /// 先强制掐断惯性，再贴到底（按钮用）。
    ///
    /// 定位之后补一次「只修越界」的校正：
    /// 从很靠上的位置跳转时，LazyVStack 中间那段还没真正渲染，
    /// contentSize 是估算值、可能偏大 —— 按它跳就会越过底部露出空白。
    /// 所以落位后下一帧再量一次真实的 bottomOffsetY，超出才拉回来。
    ///
    /// 只修「超出」不修「差一点」，而且只跑一次：
    /// 之前做过多帧双向校准，会和自动跟随互相触发（高度变→跟随→校准→再变），
    /// 几秒把主线程打满直接卡死。
    func stopThenScrollToBottom() {
        // ① 系统级打断减速模拟
        let wasEnabled = isScrollEnabled
        isScrollEnabled = false
        isScrollEnabled = wasEnabled
        // ② 清掉残留的 offset 动画
        setContentOffset(contentOffset, animated: false)
        layer.removeAllAnimations()
        // ③ 布局稳定后一次性定位
        layoutIfNeeded()
        setContentOffset(CGPoint(x: contentOffset.x, y: bottomOffsetY), animated: false)
        // ④ 单次校正：两个方向都修 —— 只跑一次就不会循环。
        //    之前是「只修越界」，结果误差总是偏向「差一点没到底」，
        //    视觉上就是离底部留着一小段空隙。
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
