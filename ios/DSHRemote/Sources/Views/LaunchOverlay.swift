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
            // 入场：0.35s 放大 + 淡入，然后停 0.45s，最后 0.35s 退场。
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                markScale = 1
                markOpacity = 1
            }
            withAnimation(.easeOut(duration: 0.30).delay(0.16)) {
                titleOpacity = 1
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            withAnimation(.easeIn(duration: 0.30)) {
                leaving = true
            }
            try? await Task.sleep(nanoseconds: 320_000_000)
            onFinish()
        }
    }
}
