import SwiftUI

/// 从微信 / QQ / 文件 App 递过来文件后，让用户挑一个会话发过去。
///
/// 为什么不做成 Share Extension：那需要 App Groups capability，
/// 而免费 Apple ID 签名拿不到它（Personal Team 不支持）。但「用其他应用打开」
/// 是 iOS 原生通道，微信里「更多 → 用其他应用打开」、QQ 里「其他应用打开」都能点，
/// 文件会直接进主 App，不需要任何特殊 entitlement。
struct IncomingFileSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionList: SessionListStore
    @Environment(\.dismiss) private var dismiss

    let file: IncomingFile

    @State private var target: String = "__new__"
    @State private var note: String = ""
    @State private var sending = false
    @State private var localError: String?

    private let newSessionTag = "__new__"

    var body: some View {
        NavigationStack {
            Form {
                Section(L("要发送的文件", "File to send")) {
                    LabeledContent(L("名称", "Name"), value: file.name)
                    LabeledContent(L("大小", "Size"), value: file.formattedSize)
                    if file.isImage {
                        LabeledContent(L("类型", "Type"), value: L("图片", "Photo"))
                    }
                }

                Section(L("发送到", "Send to")) {
                    Button {
                        target = newSessionTag
                    } label: {
                        HStack {
                            Label(L("新对话", "New chat"), systemImage: "square.and.pencil")
                            Spacer()
                            if target == newSessionTag { checkmark }
                        }
                    }

                    ForEach(sessionList.rows.prefix(30)) { session in
                        Button {
                            target = session.id
                        } label: {
                            HStack {
                                Label(
                                    "\(session.running ? "● " : "")\(session.displayTitle)",
                                    systemImage: "bubble.left"
                                )
                                Spacer()
                                if target == session.id { checkmark }
                            }
                        }
                    }
                }

                Section(L("附言（可选）", "Note (optional)")) {
                    TextField(L("想让 DSH 对它做点什么…", "What should DSH do with it…"), text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let localError {
                    Section {
                        Text(localError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L("转发到电脑", "Send to computer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消", "Cancel")) {
                        model.pendingIncoming = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if sending {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text(L("发送中", "Sending"))
                            }
                        } else {
                            Text(L("发送", "Send"))
                        }
                    }
                    .disabled(sending)
                }
            }
            .interactiveDismissDisabled(sending)
        }
    }

    private var checkmark: some View {
        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
    }

    private func submit() async {
        sending = true
        localError = nil
        defer { sending = false }
        do {
            let sessionId = target == newSessionTag ? nil : target
            try await model.sendIncoming(file, to: sessionId, note: note)
            model.pendingIncoming = nil
            dismiss()
        } catch {
            localError = L("发送失败：\(error.localizedDescription)", "Send failed: \\(error.localizedDescription)")
        }
    }
}
