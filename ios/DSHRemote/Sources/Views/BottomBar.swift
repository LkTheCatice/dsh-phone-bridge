import SwiftUI

/// 底部栏：左边两行状态，右边两个页签按钮（同一行，状态上下排列）。
///
/// **架构约定**：它不是"页面外面再加一条"，而是**每个页面自己的最底一行**。
/// 之前把它当 MainView 的 safeAreaInset 挂上去，和 ChatView 自己的
/// composer safeAreaInset 叠在一起 —— 两层 inset 的绘制顺序由系统决定，
/// 结果状态行压到了输入框上、+ 号被挤到左边（用户实拍"乱完了"）。
/// 现在：ChatView / SettingsView 各自在页面内部放这一行，全局只有一个底部 inset。
///
/// 两行状态点都用 6pt —— 之前 6pt 连接点 + 7pt 画图点大小不一，很显眼。
struct BottomBar: View {
    @Binding var selection: Int

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusStack()
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                tabButton(0, L("对话", "Chat"), "bubble.left.and.bubble.right")
                tabButton(1, L("设置", "Settings"), "gearshape")
            }
            .padding(3)
            .background(.thinMaterial, in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 62, height: 36)
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
        case .connected: return L("已连接", "Connected")
        case .connecting: return L("连接中", "Connecting")
        case .failed: return L("连接失败", "Failed")
        case .disconnected: return L("未连接", "Offline")
        }
    }

    private var comfyColor: Color {
        if !comfy.status.online { return .gray }
        return comfy.status.generating ? .orange : .green
    }

    /// 必须带「画图」前缀：光写「空闲/离线」会和上面的连接状态看混
    private var comfyText: String {
        if !comfy.status.online { return L("画图离线", "Image offline") }
        if comfy.status.generating {
            return comfy.status.pending > 0
                ? L("画图中 \(comfy.status.pending)", "Image busy (\(comfy.status.pending))")
                : L("画图中", "Image busy")
        }
        return L("画图空闲", "Image idle")
    }
}
