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

    var body: some View {
        NavigationStack {
            ToolDetailContent(entry: entry)
                .navigationTitle(L("工具详情", "Tool details"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("关闭", "Close")) { dismiss() }
                    }
                }
        }
    }
}

/// 工具详情的**内容**（参数 / 结果 / 它读过的图）。
///
/// 抽出来是为了两处共用，而不是复制一份：
///   · 直接点工具行 → ToolDetailSheet（sheet）
///   · 在「本轮过程」页里点某一步 → 同一份内容（push 进导航栈）
/// 复制两份的话，将来改图片展示/截断策略必然漏改一处。
struct ToolDetailContent: View {
    let entry: ChatEntry

    private static let limit = 8_000

    private var shown: String {
        guard let detail = entry.detail else { return "" }
        if detail.count <= Self.limit { return detail }
        return String(detail.prefix(Self.limit)) + L("\n…（其余 \(detail.count - Self.limit) 字已省略）", "\n… (\(detail.count - Self.limit) more characters omitted)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.text)
                    .font(.system(size: 13, weight: .medium))
                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if entry.detail == nil || entry.detail?.isEmpty == true {
                    Text(L("这一步没有可查看的输出", "No output to show for this step"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(shown)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .selectableText()
                }

                // 工具读过的图：只在前 20000 字里找（正则扫全文在主线程很贵）
                let images = ToolSummary.imagePaths(from: String((entry.detail ?? "").prefix(20_000)))
                ForEach(images, id: \.self) { path in
                    RemoteImage(path: path)
                }
            }
            .padding(14)
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
