import SwiftUI

/// 选择当前会话使用的模型。
/// 模型列表来自服务端 `/v1/models`（即 DSH 的 modelCatalog），选中后走 `selectModel` 真正改到会话上。
struct ModelPickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var applying: String?

    var body: some View {
        NavigationStack {
            List {
                if model.selectedSessionId == nil {
                    Section {
                        Text("先选一个会话，再切换模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.modelGroups.isEmpty {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text("读取模型列表…").font(.caption)
                        }
                    }
                }

                ForEach(model.modelGroups) { group in
                    Section(group.name) {
                        ForEach(group.models) { option in
                            Button {
                                Task { await apply(option) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(option.name)
                                        Text(option.id)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if applying == option.id {
                                        ProgressView().controlSize(.mini)
                                    } else if model.currentModel?.id == option.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.loadModels() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func apply(_ option: ModelOption) async {
        applying = option.id
        await model.selectModel(option)
        applying = nil
        if model.currentModel?.id == option.id {
            dismiss()
        }
    }
}
