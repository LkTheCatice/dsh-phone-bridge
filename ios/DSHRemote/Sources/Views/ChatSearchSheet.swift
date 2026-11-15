import SwiftUI

/// 会话内搜索：在**当前会话已加载的消息**里找，点结果直接跳过去。
///
/// 为什么不做全局搜索：消息全文在电脑上（`sessions/**/*.zstd`），
/// 手机上只有当前会话的内存副本。做全局搜索要新加一个桥接口 + 全文索引，
/// 收益不如"在当前会话里快速定位"来得直接 —— 先把最常用的那一步做掉。
struct ChatSearchSheet: View {
    let entries: [ChatEntry]
    let onPick: (ChatEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [ChatEntry] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyword.count >= 1 else { return [] }
        return entries
            .filter { $0.kind != .system || $0.text.contains(keyword) }
            .filter { $0.text.localizedCaseInsensitiveContains(keyword) || ($0.detail ?? "").localizedCaseInsensitiveContains(keyword) }
            .suffix(60)
            .reversed()
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
            Text(L("输入关键词，在当前会话里找（只搜已加载的消息）", "Type a keyword to search this chat (only what’s loaded so far)"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if results.isEmpty {
            Section { Text(L("没找到", "No matches")).foregroundStyle(.secondary) }
                } else {
                    Section(L("\(results.count) 条结果", "\(results.count) results")) {
                        ForEach(results) { entry in
                            Button {
                                onPick(entry)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(roleLabel(entry))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                    Text(snippet(entry.text))
                                        .font(.system(size: 13))
                                        .foregroundStyle(.primary)
                                        .lineLimit(3)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L("搜索本会话", "Search this chat"))
            .navigationTitle(L("搜索", "Search"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(L("关闭", "Close")) { dismiss() } }
            }
            .onAppear { focused = true }
        }
    }

    private func roleLabel(_ entry: ChatEntry) -> String {
        switch entry.kind {
        case .user: return L("我", "Me")
        case .assistant: return "AI"
        case .thinking: return L("思考", "Thinking")
        case .toolCall: return L("工具", "Tools")
        case .fileOutput, .fileSummary: return L("产物", "Artifacts")
        default: return L("系统", "System")
        }
    }

    /// 命中位置附近截一段，避免把整条长文都摊出来
    private func snippet(_ text: String) -> String {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty,
              let range = text.range(of: keyword, options: .caseInsensitive) else {
            return text
        }
        let start = text.index(range.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = start == text.startIndex ? "" : "…"
        let suffix = end == text.endIndex ? "" : "…"
        return prefix + text[start..<end] + suffix
    }
}
