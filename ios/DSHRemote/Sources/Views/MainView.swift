import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            ChatView()
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
            FilesView()
                .tabItem { Label("文件", systemImage: "folder") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                // 断线提示：只有异常时才出现，正常不占位
                if model.phase != .connected {
                    DisconnectBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let approval = model.pendingApprovals.first {
                    ApprovalBanner(approval: approval)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .animation(.easeInOut(duration: 0.2), value: model.pendingApprovals.count)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .task {
            if !model.isConnected { await model.connect() }
            // ComfyUI 状态每 8 秒刷一次（聊天页顶部的状态点）
            model.startComfyPolling()
            // 首次进入也回填一次历史；切换会话时由 ChatView 的 onChange 负责
            if let id = model.selectedSessionId {
                await model.loadHistory(id)
            }
        }
    }
}

/// 断线横幅：只在非 connected 状态出现，正常时不占位。
/// 之前只有顶栏 wifi 图标变色，断了自己不一定注意到，还会以为 DSH 没在干活。
struct DisconnectBanner: View {
    @EnvironmentObject private var model: AppModel
    @State private var reconnecting = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                Task {
                    reconnecting = true
                    await model.reconnect()
                    reconnecting = false
                }
            } label: {
                HStack(spacing: 4) {
                    if reconnecting { ProgressView().controlSize(.mini) }
                    Text("重连")
                }
            }
            .buttonStyle(.bordered)
            .disabled(reconnecting)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.35)))
    }

    private var icon: String {
        switch model.phase {
        case .connecting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "wifi.slash"
        }
    }

    private var tint: Color {
        switch model.phase {
        case .connecting: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }

    private var title: String {
        switch model.phase {
        case .connecting: return "正在连接电脑…"
        case .failed: return "连接失败"
        default: return "与电脑断开"
        }
    }

    private var detail: String {
        switch model.phase {
        case .connecting: return "同时尝试 Tailscale 和局域网"
        case .failed(let reason): return reason
        default: return "点「重连」立刻重试；也可以检查电脑上的 DSH 是否在跑"
        }
    }
}

struct ApprovalBanner: View {    @EnvironmentObject private var model: AppModel
    let approval: ApprovalRow
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                Text("电脑在等你确认：\(approval.tool)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            if !approval.reason.isEmpty {
                Text(approval.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    Task {
                        working = true
                        await model.decide(approval, allow: false)
                        working = false
                    }
                } label: {
                    Text("拒绝").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        working = true
                        await model.decide(approval, allow: true)
                        working = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        if working { ProgressView().controlSize(.mini) }
                        Text("允许").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(working)

            if let deadline = approval.deadline {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(deadline.timeIntervalSince(ctx.date)))
                    Text(left > 0 ? "\(left) 秒后自动交回电脑处理" : "已超时，交回电脑处理")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.orange.opacity(0.4)))
    }
}
