import SwiftUI
import UIKit

struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @State private var manual = false
    @State private var host = ""
    @State private var port = "8765"
    @State private var token = ""
    @State private var useTLS = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("在电脑上运行 `node bridge/bin/pairing.mjs`，把打印出来的 `dshnb://pair?...` 整串粘贴到这里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !manual {
                    Section("配对串") {
                        TextEditor(text: $text)
                            .frame(minHeight: 110)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("从剪贴板粘贴") {
                            if let s = UIPasteboard.general.string { text = s }
                        }
                    }
                } else {
                    Section("手动填写") {
                        TextField("主机（IP 或 xxx.ts.net）", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("端口", text: $port)
                            .keyboardType(.numberPad)
                        TextField("token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("使用 HTTPS（Tailscale 证书）", isOn: $useTLS)
                    }
                }

                Section {
                    Toggle("手动填写", isOn: $manual)
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            if working { ProgressView().padding(.trailing, 6) }
                            Text(working ? "连接中…" : "配对并连接")
                        }
                    }
                    .disabled(working || (manual ? (host.isEmpty || token.isEmpty) : text.isEmpty))
                }

                if case let .failed(reason) = model.phase {
                    Section("上次尝试失败") {
                        Text(reason).font(.footnote).foregroundStyle(.red)
                        Text("常见原因：电脑没重启过 DeepSeek Harness（插件未生效）、tailscale 没起来、token 已轮换。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("安全说明") {
                    Label("所有请求与响应都用 X25519 + AES-256-GCM 端到端加密，电脑上的明文 HTTP 也读不到内容。", systemImage: "lock.shield")
                        .font(.caption)
                    Label("首次配对会把电脑公钥指纹钉在这台手机上，之后指纹不一致会直接拒连。", systemImage: "checkmark.seal")
                        .font(.caption)
                    Label("外网访问请走 Tailscale（WireGuard 加密），不要把桥接端口映射到公网。", systemImage: "network")
                        .font(.caption)
                }
            }
            .navigationTitle("连接电脑")
        }
    }

    private func submit() async {
        working = true
        defer { working = false }
        if manual {
            await model.updatePairing(
                host: host.trimmingCharacters(in: .whitespaces),
                port: Int(port) ?? 8765,
                token: token.trimmingCharacters(in: .whitespaces),
                useTLS: useTLS
            )
        } else {
            await model.pair(uri: text)
        }
    }
}
