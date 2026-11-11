import SwiftUI

/// 「跳到底 / 新消息」按钮的显示状态。
///
/// 单独抽成 ObservableObject 的原因：
/// 之前这些状态放在 ChatView 的 @State 里，滚动时 onPreferenceChange 每帧都会改它们，
/// 结果是整个 ChatView（含 ScrollView）跟着重建 —— 手指落下的那一刻按钮被重建，
/// 点击自然落空；滚动指示条也会因为内容重排而跳变。
/// 拆出来之后，状态变化只重建这一个按钮层。
final class JumpButtonState: ObservableObject {
    @Published var atBottom = true
    @Published var hasNewBelow = false

    /// 是否该显示按钮（用于外层占位高度判断）
    var needsLayer: Bool {
        hasNewBelow || !atBottom
    }
}

/// 浮动在输入栏上方的按钮层。
///
/// 注意：必须放在父视图 frame **内部**。之前用 overlay + offset(y: -54) 把它推到
/// composer 外面，视觉上看得见，但 SwiftUI 的 hit testing 会被父视图 bounds 裁掉 ——
/// 手指点了等于点在空气里，所以「惯性滚动时点没反应」一直修不掉。
struct JumpButtonLayer: View {
    @ObservedObject var state: JumpButtonState
    let entryCount: Int
    let onTap: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // 有新内容但你在上面看旧记录 → 只提示，不抢滚动位置
            Button(action: onTap) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                    Text("新消息")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
                .shadow(radius: 2, y: 1)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(state.hasNewBelow ? 1 : 0)
            .allowsHitTesting(state.hasNewBelow)

            // 单纯往上翻（没新内容）时给个回底箭头
            Button(action: onTap) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.accentColor, Color(.systemBackground))
                    .shadow(radius: 2, y: 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(!state.hasNewBelow && !state.atBottom && entryCount > 3 ? 1 : 0)
            .allowsHitTesting(!state.hasNewBelow && !state.atBottom && entryCount > 3)
        }
    }
}
