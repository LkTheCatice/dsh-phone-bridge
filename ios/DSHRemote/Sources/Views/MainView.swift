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
            if let approval = model.pendingApprovals.first {
                ApprovalBanner(approval: approval)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.pendingApprovals.count)
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

struct ApprovalBanner: View {
    @EnvironmentObject private var model: AppModel
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
