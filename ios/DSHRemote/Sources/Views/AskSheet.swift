import SwiftUI

/// 回答电脑端的提问（`ask_user_question`）。
///
/// 和「权限确认」不同：确认操作必须在电脑上做（那是安全决定），
/// 而提问只是要一段信息 —— 在手机上答最方便，所以这里做成可交互。
///
/// 支持：单选（点一个即选）、多选（可多选再提交）、附加自定义文字。
struct AskSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let ask: PendingAsk

    /// 每个问题已选的选项 label
    @State private var selected: [String: Set<String>] = [:]
    /// 每个问题的自定义答案
    @State private var custom: [String: String] = [:]
    @State private var sending = false

    var body: some View {
        NavigationStack {
            Form {
                ForEach(ask.questions) { question in
                    Section {
                        Text(question.text)
                            .font(.subheadline.weight(.medium))

                        if let detail = question.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(question.options, id: \.label) { option in
                            Button {
                                pick(question, option.label)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: mark(question, option.label))
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                        if let desc = option.description, !desc.isEmpty {
                                            Text(desc).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        TextField(L("其它（可空）", "Other (optional)"),
                                  text: Binding(
                                    get: { custom[question.id] ?? "" },
                                    set: { custom[question.id] = $0 }
                                  ),
                                  axis: .vertical)
                            .lineLimit(1...4)
                    } header: {
                        Text(question.header ?? L("问题", "Question"))
                    }
                }
            }
            .navigationTitle(L("电脑在等你回答", "The computer asks"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if sending { ProgressView().controlSize(.mini) }
                        else { Text(L("提交", "Send")) }
                    }
                    .disabled(sending || !canSubmit)
                }
            }
        }
        .interactiveDismissDisabled(sending)
    }

    // MARK: - 选择

    private func isOn(_ q: AskQuestion, _ label: String) -> Bool {
        selected[q.id]?.contains(label) ?? false
    }

    private func mark(_ q: AskQuestion, _ label: String) -> String {
        let on = isOn(q, label)
        if q.multiSelect { return on ? "checkmark.square.fill" : "square" }
        return on ? "largecircle.fill.circle" : "circle"
    }

    private func pick(_ q: AskQuestion, _ label: String) {
        var set = selected[q.id] ?? []
        if q.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        selected[q.id] = set
    }

    /// 每个问题至少给一个答案（选项或自定义文字）才能提交
    private var canSubmit: Bool {
        ask.questions.allSatisfy { q in
            !(selected[q.id] ?? []).isEmpty || !(custom[q.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func submit() async {
        sending = true
        defer { sending = false }
        let answers: [[String: Any]] = ask.questions.map { q in
            let picked = Array(selected[q.id] ?? [])
            let text = (custom[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var item: [String: Any] = ["id": q.id, "selected": picked]
            if !text.isEmpty { item["custom"] = text }
            return item
        }
        await model.answer(ask: ask, answers: answers)
        dismiss()
    }
}
