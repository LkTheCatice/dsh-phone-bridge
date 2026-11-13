import SwiftUI

/// 底部栏：左边两行状态，右边两个页签按钮（同一行，状态上下排列）。
///
/// 为什么自己做而不用系统 TabView 的 tab bar：
/// 系统 tab bar 在 iOS 26 是浮动胶囊，**没有位置可以摆放附加信息**，
/// 而用户要求"状态和两个按钮同一行、状态上下排列"。自己排一行最直接，
/// 也不用去猜系统胶囊的内边距。
///
/// 说明：两行状态点都用 6pt —— 之前一版是 6pt 连接点 + 7pt 画图点，
/// 大小不一在同一行里很显眼（用户实拍）。
struct BottomBar: View {
    @Binding var selection: Int

    /// 键盘弹起时整条让位（否则会浮在键盘上方，很怪）
    @State private var keyboardUp = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusStack()
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                tabButton(0, "对话", "bubble.left.and.bubble.right")
                tabButton(1, "设置", "gearshape")
            }
            .padding(4)
            .background(.thinMaterial, in: Capsule())
        }
        .padding(.horizontal, 12)
        .frame(height: keyboardUp ? 0 : 52)
        .opacity(keyboardUp ? 0 : 1)
        .clipped()
        .animation(.easeOut(duration: 0.18), value: keyboardUp)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
        }
    }

    private func tabButton(_ index: Int, _ title: String, _ icon: String) -> some View {
        Button {
            selection = index
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                Text(title)
                    .font(.system(size: 10))
            }
            .frame(width: 62, height: 40)
            .foregroundStyle(selection == index ? Color.accentColor : Color.secondary)
            .background(
                selection == index ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 两行状态：连接 / 画图。各自订阅，只让自己重算。
private struct StatusStack: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var comfy: ComfyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row(color: connectionColor, text: connectionText)
            row(color: comfyColor, text: comfyText)
        }
    }

    private func row(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var connectionColor: Color {
        switch model.phase {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var connectionText: String {
        switch model.phase {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .failed: return "连接失败"
        case .disconnected: return "未连接"
        }
    }

    private var comfyColor: Color {
        if !comfy.status.online { return .gray }
        return comfy.status.generating ? .orange : .green
    }

    /// 必须带「画图」前缀：光写「空闲/离线」会和上面的连接状态看混
    private var comfyText: String {
        if !comfy.status.online { return "画图离线" }
        if comfy.status.generating {
            return comfy.status.pending > 0 ? "画图中 \(comfy.status.pending)" : "画图中"
        }
        return "画图空闲"
    }
}
