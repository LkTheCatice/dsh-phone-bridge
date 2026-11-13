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

    @State private var markScale: CGFloat = 0.86
    @State private var markOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var leaving = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Color.accentColor.opacity(0.10),
                    Color(uiColor: .systemBackground),
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
                .opacity(markOpacity)

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
                markOpacity = 1
            }
            withAnimation(.easeOut(duration: 0.30).delay(0.16)) {
                titleOpacity = 1
            }

            // 退场时机 = max(最短停留, 首屏就绪)，上限兜底：
            //   · 最短 1.2s：让开场本身看得完整
            //   · 就绪：历史回放完成（布局落定）
            //   · 上限 2.4s：万一网络慢，不能一直挡着界面
            let started = CFAbsoluteTimeGetCurrent()
            let minDwell: Double = 1.2
            let maxWait: Double = 2.4
            while CFAbsoluteTimeGetCurrent() - started < maxWait {
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                if elapsed >= minDwell, isReady() { break }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }

            withAnimation(.easeIn(duration: 0.30)) {
                leaving = true
            }
            try? await Task.sleep(nanoseconds: 320_000_000)
            onFinish()
        }
    }
}
