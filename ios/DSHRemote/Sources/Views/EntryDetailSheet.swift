import SwiftUI

/// 单条消息的完整内容。
///
/// 三类条目分开处理（之前一律走 markdown 渲染，导致点开工具行只看到「运行命令」四个字）：
/// - 正文类（user / assistant / thinking / system）→ 完整 markdown 渲染，
///   表格不折叠不截断（列表里为滚动性能做了三层截断）
/// - 工具类（toolCall / toolResult）→ 动作名 + 摘要 + 完整详情（参数 / 输出）
/// - 折叠过程（collapsedSteps）→ 逐步展开这一轮里被收起来的每一步
///
/// 这里可以「慢」：一次只渲染一条，而且用户是主动点开等它的。
struct EntryDetailSheet: View {
    let entry: ChatEntry
    @Environment(\.dismiss) private var dismiss
    @State private var showRaw = false
    /// 有表格时默认只看表格（「看完整版」的目的通常是看表），可切到全文
    @State private var tablesOnly = true

    /// 表格需要的宽度（nil 表示不需要横向滚动）
    private var tableWidth: CGFloat? { MarkdownNS.requiredTableWidth(for: entry.text) }

    /// 这条消息里有没有表格
    private var hasTable: Bool {
        MarkdownCache.blocksSync(for: entry.text).contains {
            if case .table = $0 { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: tableWidth != nil) {
                    content
                        // 宽表按自然宽度渲染，外层横向拖动看全（用户建议）
                        .frame(width: tableWidth.map { max($0, UIScreen.main.bounds.width - 28) })
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isMarkdownKind {
                        HStack(spacing: 10) {
                            if hasTable, !showRaw {
                                Button(tablesOnly ? L("全文", "Full text") : L("表格", "Table")) { tablesOnly.toggle() }
                                    .font(.footnote)
                            }
                            Button(showRaw ? L("渲染", "Rendered") : L("原文", "Raw")) { showRaw.toggle() }
                                .font(.footnote)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("关闭", "Close")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
                VStack(alignment: .leading, spacing: 14) {
                    switch entry.kind {
                    case .toolCall, .toolResult:
                        toolContent
                    case .collapsedSteps:
                        collapsedContent
                    default:
                        markdownContent
                    }
                }
                .padding(14)
    }

    private var isMarkdownKind: Bool {
        switch entry.kind {
        case .toolCall, .toolResult, .collapsedSteps: return false
        default: return true
        }
    }

    private var title: String {
        switch entry.kind {
        case .toolCall, .toolResult: return "运行详情"
        case .collapsedSteps: return "本轮过程"
        default:
            if showRaw { return "原文" }
            return (hasTable && tablesOnly) ? "表格" : "完整内容"
        }
    }

    // MARK: - 正文

    @ViewBuilder
    private var markdownContent: some View {
        if showRaw {
            Text(entry.text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // 必须走 UITextView：SwiftUI 的 Text 不支持 NSParagraphStyle.tabStops
            // （表格列对齐靠它），渲染出来会是一片空白。
            AttributedTextView(
                content: MarkdownNS.render(
                    entry.text,
                    mode: (hasTable && tablesOnly) ? .tablesOnly : .full
                )
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 工具

    @ViewBuilder
    private var toolContent: some View {
        HStack(spacing: 6) {
            Text(entry.text)
                .font(.system(size: 15, weight: .semibold))
            if let ok = entry.ok {
                Text(ok ? L("成功", "OK") : L("失败", "Failed"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ok ? Color.green : Color.red)
            } else if entry.running {
                Text(L("进行中", "In progress"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }

        if let summary = entry.summary, !summary.isEmpty {
            labeled("摘要", summary)
        }
        if let detail = entry.detail, !detail.isEmpty {
            labeled("详情", detail, monospaced: true)
        }
        if entry.detail == nil, entry.summary == nil {
            Text(L("这一步没有更多信息", "No more details for this step"))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 折叠的一轮

    @ViewBuilder
    private var collapsedContent: some View {
        if entry.folded.isEmpty {
            Text(L("这一轮没有可展开的步骤", "No expandable steps in this turn"))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(entry.folded) { step in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(step.kind == .thinking ? L("思考", "Thinking") : step.text)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if let ok = step.ok {
                            Text(ok ? L("成功", "OK") : L("失败", "Failed"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(ok ? Color.green : Color.red)
                        }
                    }
                    if let summary = step.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let detail = step.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - 小组件

    private func labeled(_ name: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(monospaced
                      ? .system(size: 11, design: .monospaced)
                      : .system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
