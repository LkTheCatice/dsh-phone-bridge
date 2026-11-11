import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmingForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    LabeledContent("状态") {
                        Text(statusText).foregroundStyle(statusColor)
                    }
                    if let pairing = model.pairing {
                        LabeledContent("地址", value: pairing.displayName)
                        LabeledContent("通道", value: pairing.useTLS ? "HTTPS（Tailscale）" : "HTTP + 端到端加密")
                        LabeledContent("服务器", value: model.serverInfo.isEmpty ? "未知" : model.serverInfo)
                    }
                    LabeledContent("事件序号", value: String(model.lastSeq))
                    Button("重新连接") { Task { await model.connect() } }
                }

                // 主因（布局回调自激）已按真机日志修掉，这两个开关留着当逃生阀：
                // 万一某台机器上还抖，可以关掉它们把范围缩小。
                Section {
                    Toggle("禁用文本选择", isOn: $model.expNoTextSelection)
                    Toggle("禁用自动跟随滚动", isOn: $model.expNoAutoFollow)
                    HStack {
                        Button("全部开启") {
                            model.expNoTextSelection = true
                            model.expNoAutoFollow = true
                        }
                        Spacer()
                        Button("全部关闭") {
                            model.expNoTextSelection = false
                            model.expNoAutoFollow = false
                        }
                    }
                    .font(.caption)
                } header: {
                    Text("诊断实验")
                } footer: {
                    Text("① 文本选择：气泡里的文字选择由 UITextInteraction 实现，在 LazyVStack 里反复重排时有代价。② 自动跟随：每次内容变化都 scrollTo。\n默认都关闭（= 正常行为）。改完开关回聊天页生效。")
                        .font(.caption2)
                }

                if let pairing = model.pairing, !pairing.fingerprint.isEmpty {
                    Section("电脑公钥指纹") {
                        Text(pairing.fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text("首次配对时记录；之后若电脑换了密钥，连接会被拒绝而不是静默接受。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if model.wallets.isEmpty {
                        HStack(spacing: 8) {
                            if model.walletsStatus == "loading" {
                                ProgressView().controlSize(.mini)
                                Text("读取中…").font(.caption).foregroundStyle(.secondary)
                            } else if model.walletsStatus == "unavailable" || model.walletsStatus == "idle" {
                                Text("这台电脑没启用账号服务").font(.caption).foregroundStyle(.secondary)
                            } else if model.walletsStatus == "not-signed-in" {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("电脑上的 DSH 还没登录 DeepSeek 账号").font(.caption)
                                    Text("登录后回来点「刷新余额」").font(.caption2).foregroundStyle(.secondary)
                                }
                            } else if model.walletsStatus == "failed" {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("读取失败").font(.caption)
                                    if let detail = model.walletsDetail, !detail.isEmpty {
                                        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                }
                            } else {
                                Text("没有可显示的余额").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        ForEach(model.wallets) { wallet in
                            LabeledContent(
                                wallet.isBonus ? "赠送额度（\(wallet.currency)）" : "余额（\(wallet.currency)）"
                            ) {
                                Text(wallet.balance)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                    Button("刷新余额") { Task { await model.loadBalance() } }
                } header: {
                    Text("账户余额")
                } footer: {
                    Text("由电脑端向 DeepSeek 查询，手机上不保存任何 API 凭据。")
                        .font(.caption2)
                }

                Section("允许的文件根目录") {
                    if model.roots.isEmpty {
                        Text("尚未获取").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.roots, id: \.self) { root in
                            Text(root).font(.system(.caption, design: .monospaced))
                        }
                    }
                    Text("要加目录，改电脑上的 cordis.patch.yml → phone-bridge → roots，然后重启。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("加密") {
                    Text("传输层：每个请求体用 AES-256-GCM 加密，AAD 绑定方法与路径，重放到别的端点会解密失败。")
                        .font(.caption)
                    Text("密钥协商：X25519 ECDH → HKDF-SHA256，salt 是配对 token，双向密钥分离。")
                        .font(.caption)
                    Text("私钥存在本机 Keychain（afterFirstUnlockThisDeviceOnly），不进备份、不跨设备。")
                        .font(.caption)
                }

                Section {
                    Button("忘记这台电脑", role: .destructive) { confirmingForget = true }
                } footer: {
                    Text("只清手机端的配对与设备私钥。电脑端还绑着旧公钥，重装后要连会在电脑上执行 /v1/admin/unpair 或重新跑 pairing.mjs --rotate。")
                        .font(.caption2)
                }
            }
            .navigationTitle("设置")
            .task {
                // 进设置页拉一次，不做轮询
                if model.walletsStatus == "idle" { await model.loadBalance() }
            }
            .refreshable { await model.loadBalance() }
            .confirmationDialog("确定要删除本地配对信息吗？", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("删除", role: .destructive) { model.forgetPairing() }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var statusText: String {
        switch model.phase {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .disconnected: return "未连接"
        case .failed(let reason): return "失败：\(reason)"
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
