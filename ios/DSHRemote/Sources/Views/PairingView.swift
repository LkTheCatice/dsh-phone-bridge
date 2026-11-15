import SwiftUI
import UIKit

/// 首次引导里的单步：序号圆圈 + 标题 + 说明
private struct OnboardingStep: View {
    let index: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

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
                // 首次使用引导：这个页面本身就是「还没配对」的状态，
                // 所以三步说明直接常驻在最上面，配对成功后整个页面就不见了。
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        OnboardingStep(
                            index: 1,
                            title: L("电脑上生成配对串", "Generate a pairing code on the computer"),
                            detail: L("在电脑打开终端，运行 node bridge/bin/pairing.mjs", "Open a terminal on the computer and run node bridge/bin/pairing.mjs")
                        )
                        OnboardingStep(
                            index: 2,
                            title: L("粘到下面", "Paste it below"),
                            detail: L("复制打印出的 dshnb://pair?... 整串，点「从剪贴板粘贴」", "Copy the whole dshnb://pair?... string, then tap Paste from clipboard")
                        )
                        OnboardingStep(
                            index: 3,
                            title: L("电脑上批准这台手机", "Approve this phone on the computer"),
                            detail: L("首次连接会出现在 DSH 的「设置 → 手机设备」，点允许即可", "The first connection shows up in DSH → Settings → Phone devices; tap Allow")
                        )
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(L("三步开始使用", "Three steps to start"))
                } footer: {
                    Text(L("全程端到端加密，配对串只在你和这台电脑之间使用。", "Everything is end-to-end encrypted; the pairing code only works between you and this computer."))
                        .font(.caption2)
                }

                if !manual {
                    Section(L("配对串", "Pairing code")) {
                        TextEditor(text: $text)
                            .frame(minHeight: 110)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(L("从剪贴板粘贴", "Paste from clipboard")) {
                            if let s = UIPasteboard.general.string { text = s }
                        }
                    }
                } else {
                    Section(L("手动填写", "Enter manually")) {
                        TextField(L("主机（IP 或 xxx.ts.net）", "Host (IP or xxx.ts.net)"), text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField(L("端口", "Port"), text: $port)
                            .keyboardType(.numberPad)
                        TextField("token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle(L("使用 HTTPS（Tailscale 证书）", "Use HTTPS (Tailscale certificate)"), isOn: $useTLS)
                    }
                }

                Section {
                    Toggle(L("手动填写", "Enter manually"), isOn: $manual)
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            if working { ProgressView().padding(.trailing, 6) }
                            Text(working ? L("连接中…", "Connecting…") : L("配对并连接", "Pair and connect"))
                        }
                    }
                    .disabled(working || (manual ? (host.isEmpty || token.isEmpty) : text.isEmpty))
                }

                if case let .failed(reason) = model.phase {
                    Section(L("上次尝试失败", "Last attempt failed")) {
                        Text(reason).font(.footnote).foregroundStyle(.red)
                        Text(L("常见原因：电脑没重启过 DeepSeek Harness（插件未生效）、tailscale 没起来、token 已轮换。", "Common causes: DSH wasn't restarted (plugin not loaded), Tailscale is down, or the token was rotated."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(L("安全说明", "Security")) {
                    Label(L("所有请求与响应都用 X25519 + AES-256-GCM 端到端加密，电脑上的明文 HTTP 也读不到内容。", "Every request and response is end-to-end encrypted with X25519 + AES-256-GCM — even plain HTTP on the computer reveals nothing."), systemImage: "lock.shield")
                        .font(.caption)
                    Label(L("首次配对会把电脑公钥指纹钉在这台手机上，之后指纹不一致会直接拒连。", "The first pairing pins the computer's key fingerprint on this phone; a mismatch is refused outright."), systemImage: "checkmark.seal")
                        .font(.caption)
                    Label(L("外网访问请走 Tailscale（WireGuard 加密），不要把桥接端口映射到公网。", "For remote access use Tailscale (WireGuard). Never expose the bridge port to the internet."), systemImage: "network")
                        .font(.caption)
                }
            }
            .navigationTitle(L("连接电脑", "Connect"))
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
