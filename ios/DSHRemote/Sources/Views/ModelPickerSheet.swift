import SwiftUI

/// 选择当前会话使用的模型。
///
/// 模型列表来自 `/v1/models`（DSH 的 modelCatalog）。
/// 有的模型支持推理强度档位（`reasoning.efforts`），点进去会展开档位选择。
struct ModelPickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var applying: String?
    @State private var effortTarget: ModelOption?

    var body: some View {
        NavigationStack {
            List {
                if model.selectedSessionId == nil {
                    Section {
                        Text(L("先选一个会话，再切换模型", "Pick a chat first, then switch the model"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.modelGroups.isEmpty {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text(L("读取模型列表…", "Loading models…")).font(.caption)
                        }
                    }
                }

                ForEach(model.modelGroups) { group in
                    Section(group.name) {
                        ForEach(group.models) { option in
                            Button {
                                tap(option)
                            } label: {
                                row(option)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(L("选择模型", "Choose model"))
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.loadModels() }
            .sheet(item: $effortTarget) { target in
                EffortPickerSheet(target: target)
                    .environmentObject(model)
                    .presentationDetents([.height(340)])
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消", "Cancel")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ option: ModelOption) -> some View {
        let isCurrent = model.currentModel?.id == option.id && model.currentModel?.provider == option.provider
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(option.name)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text(option.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    // 有档位的模型标出来，说明还能再选一层
                    if !option.efforts.isEmpty {
                        Text("· \(effortLabel(option, isCurrent: isCurrent))")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            Spacer(minLength: 0)
            if applying == option.id {
                ProgressView().controlSize(.mini)
            } else if isCurrent {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            } else if !option.efforts.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func effortLabel(_ option: ModelOption, isCurrent: Bool) -> String {
        let selected = isCurrent ? (model.currentModel?.effort ?? option.effort) : option.effort
        if let selected, let match = option.efforts.first(where: { $0.id == selected }) {
            return match.name
        }
        return L("推理 \(option.efforts.count) 档", "\(option.efforts.count) levels")
    }

    /// 有档位的先选档位，没有再直接切
    private func tap(_ option: ModelOption) {
        if option.efforts.isEmpty {
            Task {
                applying = option.id
                await model.selectModel(option)
                applying = nil
                if model.currentModel?.id == option.id { dismiss() }
            }
            return
        }
        var target = option
        // 预填当前已选档位，避免每次都要重选
        if model.currentModel?.id == option.id, let current = model.currentModel?.effort {
            target.effort = current
        }
        effortTarget = target
    }
}

/// 推理强度档位选择
struct EffortPickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let target: ModelOption
    @State private var selected: String?
    @State private var applying = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(target.efforts) { effort in
                        Button {
                            selected = effort.id
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(effort.name).foregroundStyle(.primary)
                                    if let detail = effort.detail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                if selected == effort.id {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(L("\(target.name) · 推理强度", "\(target.name) · reasoning effort"))
                } footer: {
                    Text(L("档位越高思考越深、耗时越长。确定后会自动切换到这个模型。", "Higher effort means deeper thinking and longer runs. Confirming switches to this model."))
                        .font(.caption2)
                }
            }
            .navigationTitle(L("推理强度", "Reasoning effort"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            applying = true
                            var updated = target
                            updated.effort = selected
                            await model.selectModel(updated)
                            applying = false
                            dismiss()
                        }
                    } label: {
                        if applying { ProgressView().controlSize(.mini) } else { Text(L("确定", "OK")) }
                    }
                    .disabled(applying)
                }
            }
            .onAppear {
                selected = target.effort ?? model.currentModel?.effort
            }
        }
    }
}
