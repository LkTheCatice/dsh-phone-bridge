import SwiftUI

/// 冷启动动画。
///
/// **只在冷启动放一次**：由 MainView 用一个 `@State` 控制，
/// 页面活着期间不会重置 —— 从后台切回来时 MainView 还在，所以不会再放
/// （用户明确要求：后台切回不用）。
///
/// 不做重活：一个渐变底 + 一个符号 + 一行字，纯 SwiftUI 动画，
/// 900ms 后淡出。放在最上层 overlay，不参与任何列表布局。
struct LaunchOverlay: View {
    /// 动画放完后由 MainView 清掉
    let onFinish: () -> Void
    /// 首屏是否已经就绪（历史回放完成 = 布局基本落定）。
    /// 之前固定 ~0.8s 就撤场，经常盖不住"内容还在排"的那一段，
    /// 用户要求：多留一点时间，刚好把页面布局走完。
    let isReady: () -> Bool

    // 图标**第一帧就可见**：之前 opacity 从 0 淡入，于是开头有一小段"什么都没有"，
    // 观感就是"系统白屏撤了、图标才姗姗出现"（用户实拍）。
    // 现在只做轻微缩放（0.94 → 1），不参与透明度渐入。
    @State private var markScale: CGFloat = 0.94
    @State private var titleOpacity: Double = 0
    @State private var leaving = false

    var body: some View {
        ZStack {
            // 先铺一层**实色**，再叠渐变：渐变用了带透明度的 accent，
            // 单靠它盖不住下面的半成品页面（截图上就是"整屏发虚、能看到对话页"）。
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color.clear,
                    Color.accentColor.opacity(0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 96, height: 96)
                        .scaleEffect(markScale)
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .scaleEffect(markScale)
                }

                VStack(spacing: 4) {
                    Text("DSH Helm")
                        .font(.system(size: 17, weight: .semibold))
                    Text("连接你的 DeepSeek Harness")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .opacity(titleOpacity)
            }
            .scaleEffect(leaving ? 1.06 : 1)
            .opacity(leaving ? 0 : 1)
        }
        .task {
            // 入场
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                markScale = 1
            }
            withAnimation(.easeOut(duration: 0.22).delay(0.06)) {
                titleOpacity = 1
            }

            // 退场时机 = max(最短停留, 首屏就绪)，上限兜底：
            //   · 最短 1.2s：让开场本身看得完整
            //   · 就绪：历史回放完成（布局落定）
            //   · 上限 2.4s：万一网络慢，不能一直挡着界面
            // 时间放宽：上一版 1.2s 撤场，元素刚显现就走了（用户实拍：
            // 「中间元素刚显现白屏就结束了」）。现在主体 ~0.4s 就位，
            // 至少停到 2.0s 才退场，给首屏布局留足时间。
            let started = CFAbsoluteTimeGetCurrent()
            // 用户定为 2.3s（观感确认过）；上限给 3.5s，仅用于等历史回放。
            let minDwell: Double = 2.3
            let maxWait: Double = 3.5
            while CFAbsoluteTimeGetCurrent() - started < maxWait {
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                if elapsed >= minDwell, isReady() { break }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }

            let dwellMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            withAnimation(.easeInOut(duration: 0.50)) {
                leaving = true
            }
            try? await Task.sleep(nanoseconds: 520_000_000)
            // 真机打点：停留时长 / 是否因为就绪而提前退场。
            // 有这个数就不用再"感觉太短"地反复调了。
            Diag.ping("launch dwell=\(dwellMs)ms ready=\(isReady() ? 1 : 0)")
            onFinish()
        }
    }
}
