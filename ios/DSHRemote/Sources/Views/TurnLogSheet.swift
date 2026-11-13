import SwiftUI

/// 「本轮过程」页：一轮里被折叠的思考/工具行，按顺序列出，每行可再点开看详情。
///
/// 为什么是独立一页，而不是把文本塞进详情弹窗：
/// · 现在的 `collapsedContent` 把每步的原始结果（可达 8k 字符）平铺渲染，
///   20 步就是 20 段长文本 —— 打开一次要 300~800ms，而且找不到东西
/// · 独立一页后，主列表**一行都不变**（不插 cell、不重排、不测量），
///   开销只发生在打开时，且列表行只排短文本
///
/// 详情复用 `ToolDetailContent`（和「点工具行」看到的是同一份视图），
/// 所以参数/结果/读过的图片在两处表现完全一致。
struct TurnLogSheet: View {
    let entry: ChatEntry

    @Environment(\.dismiss) private var dismiss

    private var steps: [ChatEntry] { entry.folded }

    private var toolCount: Int { steps.filter { $0.kind == .toolCall }.count }
    private var thinkCount: Int { steps.filter { $0.kind == .thinking }.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Label("第 \(entry.turn) 轮", systemImage: "number")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if thinkCount > 0 {
                            Text("思考 \(thinkCount)")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        if toolCount > 0 {
                            Text("工具 \(toolCount)")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section {
                    if steps.isEmpty {
                        Text("这一轮没有记录到过程条目")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            NavigationLink(value: step) {
                                row(index: index + 1, step: step)
                            }
                        }
                    }
                } header: {
                    Text("过程 · \(steps.count) 步")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("本轮过程")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ChatEntry.self) { step in
                ToolDetailContent(entry: step)
                    .navigationTitle(step.kind == .thinking ? "思考详情" : "步骤详情")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func row(index: Int, step: ChatEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)

            Image(systemName: step.kind == .thinking ? "brain" : "wrench.and.screwdriver")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.kind == .thinking ? "思考" : step.text)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let summary = step.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if step.running {
                ProgressView().controlSize(.mini)
            } else if let ok = step.ok {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(ok ? Color.green : Color.red)
            }
        }
        .padding(.vertical, 2)
    }
}
