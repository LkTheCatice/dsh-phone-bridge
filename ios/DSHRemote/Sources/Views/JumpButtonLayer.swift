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

    // MARK: - 只用于内部节流/防重入的状态
    //
    // 这些刻意不是 @Published，也绝不能用 ChatView 的 @State：
    // @State 一改就触发 body 重算，而它们正是在 body 重算触发的回调里被改的 ——
    // 「改状态 → 重算 → 回调 → 再改状态」立刻变成无限循环，主线程被占死，
    // 连刚发出的消息都渲染不出来（用户看到的就是「秒卡、消息不出现」）。
    // 放在引用类型的普通属性里，改了不通知任何人，循环天然断开。

    /// 自动跟随的节流时间戳
    var lastFollowAt = Date.distantPast
    /// 「是否在底部」翻转的节流时间戳（防止几何值在阈值边界抖动引发反复重算）

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
        content
            // 显隐与命中都在这里决定，不要上抛给父视图读 state ——
            // 父视图只要读一次，就会订阅整个 JumpButtonState。
            .opacity(state.needsLayer ? 1 : 0)
            .allowsHitTesting(state.needsLayer)
    }

    private var content: some View {
        ZStack(alignment: .bottomTrailing) {
            // 有新内容但你在上面看旧记录 → 只提示，不抢滚动位置
            Button(action: onTap) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                    Text(L("新消息", "New messages"))
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
