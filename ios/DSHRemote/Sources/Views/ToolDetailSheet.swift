import SwiftUI

// MARK: - 工具详情弹窗

/// 工具详情弹窗。
///
/// 详情（工具参数 / 结果预览）动辄几万字符 —— 在主列表里渲染它，
/// 每次布局都要重新排版，是「点跳到底卡 19 秒」的直接原因。
/// 单独放在 sheet 里：只有用户点开时排版一次，且不参与主列表布局。
/// 仍然按 8000 字截断，避免一次点开就排几十万字符。
struct ToolDetailSheet: View {
    let entry: ChatEntry
    @Environment(\.dismiss) private var dismiss

    private static let limit = 8_000

    private var shown: String {
        guard let detail = entry.detail else { return "" }
        if detail.count <= Self.limit { return detail }
        return String(detail.prefix(Self.limit)) + "\n…（其余 \(detail.count - Self.limit) 字已省略）"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(entry.text)
                        .font(.system(size: 13, weight: .medium))
                    if let summary = entry.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Text(shown)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .selectableText()

                    // 工具读过的图：只在前 20000 字里找（正则扫全文在主线程很贵）
                    let images = ToolSummary.imagePaths(from: String((entry.detail ?? "").prefix(20_000)))
                    ForEach(images, id: \.self) { path in
                        RemoteImage(path: path)
                    }
                }
                .padding(14)
            }
            .navigationTitle("工具详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

/// 工具详情弹窗的状态持有者（由 ChatView 用一个 .sheet 统一呈现）。
final class ToolDetailPresenter: ObservableObject {
    @Published var entry: ChatEntry?
}

private struct ToolDetailPresenterKey: EnvironmentKey {
    static let defaultValue: ToolDetailPresenter? = nil
}

extension EnvironmentValues {
    var toolDetailPresenter: ToolDetailPresenter? {
        get { self[ToolDetailPresenterKey.self] }
        set { self[ToolDetailPresenterKey.self] = newValue }
    }
}

private struct RichTextEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var richTextEnabled: Bool {
        get { self[RichTextEnabledKey.self] }
        set { self[RichTextEnabledKey.self] = newValue }
    }
}
