import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    /// 冷启动动画：只放一次。
    /// MainView 在 App 生命周期里常驻，这个 @State 不会被重置 ——
    /// 所以从后台切回来时它已经是 false，动画不会再放（用户要求）。
    @State private var showLaunch = true


    var body: some View {
        // 保留 TabView（两个页面的状态都活着，切回来草稿/滚动位置不丢），
        // 但把**系统 tab bar 藏掉**，换成自己的底栏 ——
        // 系统那个是浮动胶囊，旁边没法摆状态信息，而用户要求
        // 「状态和两个按钮同一行、状态上下排列」。
        TabView(selection: $model.tab) {
            ChatView()
                // ChatStore 单独注入：ChatView 只对「条目 / 流式心跳」高频更新重算，
                // 不再因为 AppModel 上任何字段变化而整页重算
                .environmentObject(model.chat)
                .environmentObject(model.comfyStore)
                .environmentObject(model.walletStore)
                .tag(0)
                // ⚠️ 隐藏系统 tab bar 的修饰符必须挂在**子页面**上。
                // 挂在 TabView 上时 iOS 26 只隐藏了按钮，浮动胶囊的玻璃背景
                // 仍然留着 —— 界面上就是一个空胶囊（用户实拍）。
                .toolbar(.hidden, for: .tabBar)
            SettingsView()
                // SettingsView 订阅了 WalletStore（余额区），
                // 不注入就会在打开设置页时崩 —— 缺 @EnvironmentObject 是运行时崩溃。
                .environmentObject(model.walletStore)
                .tag(1)
                .toolbar(.hidden, for: .tabBar)
        }
        // 横幅交给独立子视图：MainView 包着 TabView，一旦在这里读 phase /
        // pendingApprovals / suppressDisconnect，任何一次变化都会让三个 tab 的
        // 内容跟着重算。BannerHost 自己订阅、自己重算，TabView 不受影响。
        .overlay(alignment: .top) {
            BannerHost()
        }
        .overlay {
            if showLaunch {
                LaunchOverlay(
                    onFinish: { showLaunch = false },
                    // 历史回放完成 → 首屏布局基本落定
                    isReady: { model.chat.historyVersion > 0 }
                )
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .onChange(of: scenePhase) { newPhase in
            // 从后台回来时恢复连接。
            // 原来这里是「无条件 reconnect()」，即使已连接也整条重连一遍；
            // 现在交给 handleScenePhase 按状态区分：
            //   已连接 → 只重启事件流（系统挂起过，旧流多半已死）
            //   断开/失败 → 才真的重连
            model.handleScenePhase(newPhase)
            if newPhase == .active {
                // 给 3 秒宽限，避免网络抖动时断线横幅闪一下
                model.beginReconnectGrace(seconds: 3)
            }
        }
        .task {
            if !model.isConnected { await model.connect() }
            // 主线程看门狗：卡死时能留下「卡了多久」的记录
            model.startWatchdog()
            // ComfyUI 状态每 8 秒刷一次（聊天页顶部的状态点）
            model.startComfyPolling()
            // 历史回填延后 400ms：启动瞬间要做连接、会话列表、Comfy 轮询、
            // 几百帧历史重建，全挤在一起会占住主线程 ——
            // 表现就是「刚打开软件时，输入框第一个字母不进拼音」。
            // 先让输入框能打字，历史晚一点到。
            try? await Task.sleep(nanoseconds: 400_000_000)
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

/// 顶部横幅宿主（断线提示 + 审批提示）。
///
/// 单独成视图的原因：MainView 里是 TabView，若在 MainView.body 读
/// `phase` / `pendingApprovals` / `suppressDisconnect`，这些状态一变
/// 三个 tab 的内容都会被重新求值。放在这里只重算这一小块。
struct BannerHost: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            // 断线提示：只有异常时才出现，正常不占位。
            // 回前台的头几秒跳过 —— 那时连接还没恢复，弹「未连接」是误报。
            // 用 showDisconnectBanner（1.5 秒防抖后的结果），
            // 不要直接判 phase —— 重连时它会在 failed/connected 之间反复跳。
            if model.showDisconnectBanner {
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
        .animation(.easeInOut(duration: 0.2), value: model.pendingApprovals.count)
        .animation(.easeInOut(duration: 0.2), value: model.showDisconnectBanner)
        .animation(.easeInOut(duration: 0.2), value: model.suppressDisconnect)
    }
}
