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
