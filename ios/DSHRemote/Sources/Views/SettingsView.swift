import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var wallet: WalletStore
    @ObservedObject private var lang = I18N.shared
    @ObservedObject private var theme = UITheme.shared
    @ObservedObject private var motion = UIMotion.shared
    /// 选了但还没确认的语言
    @State private var pendingLang: AppLang?
    @State private var confirmingForget = false

    var body: some View {
        NavigationStack {
            Form {
                // 外观：跟随系统 / 浅色 / 深色（界面全用语义色，切换即时生效）
                Section(L("外观", "Appearance")) {
                    Picker(L("主题", "Theme"), selection: Binding(
                        get: { theme.selection },
                        set: { theme.set($0) }
                    )) {
                        ForEach(AppTheme.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // 动效：效率 / 均衡 / 质量。影响所有过渡、材质与入场动作
                Section {
                    Picker(L("动效", "Motion"), selection: Binding(
                        get: { motion.level },
                        set: { motion.set($0) }
                    )) {
                        ForEach(MotionLevel.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(motion.reduceMotion
                         ? L("系统已开启「减弱动态效果」，这里按效率执行。",
                             "Reduce Motion is on in iOS, so Efficiency applies regardless.")
                         : motion.level.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(L("动效", "Motion"))
                }

                // 语言：跟随系统 / 中文 / English。
                // 选完先弹确认 —— 因为切换后要重启进程，不确认的话看起来像闪退。
                Section(L("语言", "Language")) {
                    Picker(L("界面语言", "Interface language"), selection: Binding(
                        get: { lang.selection },
                        set: { picked in
                            if picked == lang.selection {
                                return
                            }
                            pendingLang = picked
                        }
                    )) {
                        ForEach(AppLang.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    if lang.selection == .system {
                        Text(L("当前：", "Current: ") + (lang.isEnglish ? "English" : "简体中文"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(L("连接", "Connection")) {
                    LabeledContent(L("状态", "Status")) {
                        Text(statusText).foregroundStyle(statusColor)
                    }
                    if let pairing = model.pairing {
                        LabeledContent(L("地址", "Address"), value: pairing.displayName)
                        LabeledContent(L("通道", "Channel"), value: pairing.useTLS
                            ? L("HTTPS（Tailscale）", "HTTPS (Tailscale)")
                            : L("HTTP + 端到端加密", "HTTP + end-to-end encryption"))
                        LabeledContent(L("服务器", "Server"), value: model.serverInfo.isEmpty ? L("未知", "Unknown") : model.serverInfo)
                    }
                    LabeledContent(L("事件序号", "Event seq"), value: String(model.lastSeq))
                    Button(L("重新连接", "Reconnect")) { Task { await model.connect() } }
                }

                // 主因（布局回调自激）已按真机日志修掉，这两个开关留着当逃生阀：
                // 万一某台机器上还抖，可以关掉它们把范围缩小。
                Section {
                    Toggle(L("启用文本选择（关掉更省）", "Text selection (off is cheaper)"), isOn: $model.expTextSelection)
                    Toggle(L("渲染 markdown（关掉最省，但没代码块样式）", "Render markdown (off = fastest, no code styling)"), isOn: $model.richTextEnabled)
                    Toggle(L("禁用自动跟随滚动", "Disable auto-follow scroll"), isOn: $model.expNoAutoFollow)
                    HStack {
                        Button(L("全部开启", "Turn all on")) {
                            model.expTextSelection = false
                            model.expNoAutoFollow = true
                        }
                        Spacer()
                        Button(L("全部关闭", "Turn all off")) {
                            model.expTextSelection = true
                            model.expNoAutoFollow = false
                        }
                    }
                    .font(.caption)
                } header: {
                    Text(L("诊断实验", "Diagnostics"))
                } footer: {
                    Text(L("① 文本选择：气泡里的文字选择由 UITextInteraction 实现，在 LazyVStack 里反复重排时有代价。② 自动跟随：每次内容变化都 scrollTo。\n默认都关闭（= 正常行为）。改完开关回聊天页生效。", "① Text selection uses UITextInteraction inside bubbles, which costs on every re-layout. ② Auto-follow scrolls to bottom on every change.\nBoth default to off (= normal behaviour). Changes apply when you go back to the chat."))
                        .font(.caption2)
                }

                if let pairing = model.pairing, !pairing.fingerprint.isEmpty {
                    Section(L("电脑公钥指纹", "Computer fingerprint")) {
                        Text(pairing.fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text(L("首次配对时记录；之后若电脑换了密钥，连接会被拒绝而不是静默接受。", "Pinned at first pairing. If the computer's key changes later, the connection is refused instead of silently accepted."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if wallet.wallets.isEmpty {
                        HStack(spacing: 8) {
                            if wallet.status == "loading" {
                                ProgressView().controlSize(.mini)
                                Text(L("读取中…", "Loading…")).font(.caption).foregroundStyle(.secondary)
                            } else if wallet.status == "unavailable" || wallet.status == "idle" {
                                Text(L("这台电脑没启用账号服务", "This computer has no account service enabled")).font(.caption).foregroundStyle(.secondary)
                            } else if wallet.status == "not-signed-in" {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("电脑上的 DSH 还没登录 DeepSeek 账号", "DSH on the computer isn't signed in to DeepSeek")).font(.caption)
                                    Text(L("登录后回来点「刷新余额」", "Sign in, then tap Refresh balance")).font(.caption2).foregroundStyle(.secondary)
                                }
                            } else if wallet.status == "credential-stored" {
                                // 凭据在（已登录），但 DSH 的余额接口内部拿不到数字
                                // （platformClient 未初始化）。不谎报「没登录」，
                                // 而是给状态 + 网页查询入口。
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L("已登录（凭据已存储）", "Signed in (credentials stored)")).font(.caption)
                                    Text(L("这台 DSH 的余额接口暂时取不到数字", "Balance endpoint returned no number"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if let url = wallet.usageUrl, let dest = URL(string: url) {
                                        Link(L("打开 DeepSeek 用量页", "Open DeepSeek usage page"), destination: dest).font(.caption)
                                    }
                                }
                            } else if wallet.status == "failed" {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("读取失败", "Failed to load")).font(.caption)
                                    if let detail = wallet.detail, !detail.isEmpty {
                                        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                }
                            } else {
                                Text(L("没有可显示的余额", "No balance to show")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        ForEach(wallet.wallets) { wallet in
                            LabeledContent(
                                wallet.isBonus
                        ? L("赠送额度（\(wallet.currency)）", "Bonus credit (\(wallet.currency))")
                        : L("余额（\(wallet.currency)）", "Balance (\(wallet.currency))")
                            ) {
                                Text(wallet.balance)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                    Button(L("刷新余额", "Refresh balance")) { Task { await model.loadBalance() } }
                } header: {
                    Text(L("账户余额", "Account balance"))
                } footer: {
                    Text(L("由电脑端向 DeepSeek 查询，手机上不保存任何 API 凭据。", "The computer queries DeepSeek; no API credentials are stored on the phone."))
                        .font(.caption2)
                }

                Section(L("允许的文件根目录", "Allowed folders")) {
                    if model.roots.isEmpty {
                        Text(L("尚未获取", "Not loaded yet")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.roots, id: \.self) { root in
                            Text(root)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text(L("要加目录，改电脑上的 cordis.patch.yml → phone-bridge → roots，然后重启。", "To add folders, edit cordis.patch.yml → phone-bridge → roots on the computer, then restart."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section {
                    // 原来是 LabeledContent + trailing 对齐：一换行第二行就悬在右边，
                    // 英文下会变成 3–4 行右对齐（用户截图指出）。改成标题在上一行、说明在下。
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("签名有效期", "Certificate"))
                            .foregroundStyle(.primary)
                        Text(SigningInfo.summary)
                            .font(.callout)
                            .foregroundStyle(SigningInfo.shouldWarn ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    if SigningInfo.shouldWarn {
                        Text(L("免费签名只有 7 天。到期后 App 会直接打不开（不是崩溃，是系统拒绝启动）。用 Sideloadly 重新拖一次 IPA 即可，聊天记录与配对都还在。", "Free signing lasts 7 days. After that the app won't launch (the system refuses it, it doesn't crash). Reinstall the IPA with Sideloadly — chats and pairing stay."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text(L("安装与签名", "Install & signing"))
                } footer: {
                    Text(L("想不用每 7 天重装：① AltStore/SideStore 自动续签（同一 WiFi 下自动完成）② 付费开发者账号（证书 1 年）。详见 docs/续签.md", "To avoid reinstalling weekly: ① AltStore/SideStore re-signs automatically on the same Wi-Fi ② a paid developer account (1-year certificate). See docs/续签.md"))
                        .font(.caption2)
                }

                Section(L("加密", "Encryption")) {
                    Text(L("传输层：每个请求体用 AES-256-GCM 加密，AAD 绑定方法与路径，重放到别的端点会解密失败。", "Transport: every request body is AES-256-GCM, with method and path bound as AAD — replaying it against another endpoint fails."))
                        .font(.caption)
                    Text(L("密钥协商：X25519 ECDH → HKDF-SHA256，salt 是配对 token，双向密钥分离。", "Key agreement: X25519 ECDH → HKDF-SHA256, salted with the pairing token, separate keys per direction."))
                        .font(.caption)
                    Text(L("私钥存在本机 Keychain（afterFirstUnlockThisDeviceOnly），不进备份、不跨设备。", "Private key lives in the local Keychain (afterFirstUnlockThisDeviceOnly) — never backed up, never synced."))
                        .font(.caption)
                }

                Section {
                    Button(L("忘记这台电脑", "Forget this computer"), role: .destructive) { confirmingForget = true }
                } footer: {
                    Text(L("只清手机端的配对与设备私钥。电脑端还绑着旧公钥，重装后要连会在电脑上执行 /v1/admin/unpair 或重新跑 pairing.mjs --rotate。", "Clears the pairing and device key on the phone only. The computer still holds the old public key — run /v1/admin/unpair there, or pairing.mjs --rotate."))
                        .font(.caption2)
                }
            }
            .navigationTitle(L("设置", "Settings"))
            // 切语言要重启进程：先问一句，否则用户以为闪退
            .alert(L("切换语言需要重启", "Restart needed"),
                   isPresented: Binding(
                        get: { pendingLang != nil },
                        set: { if !$0 { pendingLang = nil } }
                   ),
                   presenting: pendingLang) { target in
                Button(L("取消", "Cancel"), role: .cancel) { pendingLang = nil }
                Button(L("切换并重启", "Switch and restart"), role: .destructive) {
                    let next = target
                    pendingLang = nil
                    lang.set(next)          // set() 内部会安排退出
                }
            } message: { _ in
                Text(L("为保证所有界面（含消息列表）都换到新语言，App 会关闭一次，重新打开后生效。",
                       "To make sure every screen (including the message list) switches, the app will close once — reopen it to apply."))
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                // 进设置页拉一次，不做轮询
                if wallet.status == "idle" { await model.loadBalance() }
            }
            .refreshable { await model.loadBalance() }
            .confirmationDialog(L("确定要删除本地配对信息吗？", "Delete the local pairing?"), isPresented: $confirmingForget, titleVisibility: .visible) {
                Button(L("删除", "Delete"), role: .destructive) { model.forgetPairing() }
                Button(L("取消", "Cancel"), role: .cancel) {}
            }
        }
    
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 设置页也要有底栏，否则切进来就回不到对话。
            // 注意：这是**页面内部**的 inset（不是容器级的），
            // 全局只有一个底部 inset，不会和 composer 打架。
            BottomBar(selection: $model.tab)
                .environmentObject(model)
                .environmentObject(model.comfyStore)
                .background(.bar)
        }
    }

    private var statusText: String {
        switch model.phase {
        case .connected: return L("已连接", "Connected")
        case .connecting: return L("连接中", "Connecting")
        case .disconnected: return L("未连接", "Offline")
        case .failed(let reason): return L("失败：\(reason)", "Failed: \(reason)")
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }
}
