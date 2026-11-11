import SwiftUI

// MARK: - 文本选择开关（诊断用）

/// 关掉所有 `.textSelection(.enabled)`。
///
/// 为什么做成开关：气泡里每段文字都挂了文本选择，而它在 iOS 上是由
/// UITextInteraction 撑起来的 —— 放进 LazyVStack、随着流式输出反复重排时，
/// 是有可能把主线程拖住甚至转不出来的。真机上用设置页的开关二分，比继续猜快。
private struct NoTextSelectionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var noTextSelection: Bool {
        get { self[NoTextSelectionKey.self] }
        set { self[NoTextSelectionKey.self] = newValue }
    }
}

private struct MaybeSelectableText: ViewModifier {
    @Environment(\.noTextSelection) private var disabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if disabled {
            content
        } else {
            content.textSelection(.enabled)
        }
    }
}

extension View {
    /// 等价于 `.textSelection(.enabled)`，但受设置页的「禁用文本选择」控制
    func selectableText() -> some View { modifier(MaybeSelectableText()) }
}

/// 一条聊天条目。
///
/// 显式实现 Equatable 并在调用处用 `.equatable()`：
/// ChatView 每次 body 重算（发消息、流式输出）都会重新求值 ForEach 里每个元素，
/// 几百条历史时这部分开销非常可观 —— 加 equatable 后内容没变的条目直接跳过。
struct ChatBubble: View, Equatable {
    let entry: ChatEntry
    @State private var expanded = false
    /// 工具详情 presenter（由 ChatView 统一持有，见文件末尾 ToolDetailPresenter）。
    /// 刻意**不**用 @EnvironmentObject：那会让每个气泡都订阅它，
    /// 而每个气泡各自挂 .sheet 更贵 —— 真机实测 40 个气泡各挂一个 sheet 直接卡死。
    @Environment(\.toolDetailPresenter) private var detailPresenter

    static func == (lhs: ChatBubble, rhs: ChatBubble) -> Bool {
        lhs.entry == rhs.entry
    }

    var body: some View {
        // 卡死取证：主线程最后在渲染哪一类气泡
        stallWatcher.setMark("b:\(kindName)")
        stallWatcher.tickBubble()
        return Group {
        switch entry.kind {
        case .user:
            // 用户消息也要解析媒体路径：自己发出去的图/视频/音频
            // 之前只渲染纯文本，于是上传完只看到一行「[附件] E:/...mp4」
            let userMedia = MediaRefCache.refs(for: entry.text)
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Spacer(minLength: 40)
                    Text(entry.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                }
                ForEach(userMedia.images, id: \.self) { path in
                    RemoteImage(path: path)
                }
                ForEach(userMedia.videos, id: \.self) { path in
                    RemoteVideo(path: path)
                }
                ForEach(userMedia.audios, id: \.self) { path in
                    RemoteAudio(path: path)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

        case .assistant:
            assistantBlock

        case .thinking:
            // 电脑端就是这样：一行灰字 + 一个"思考"小标签，不占卡片
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("思考")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    // 思考过程很容易上万字符：只排前面一段，别让一次思考把主线程按住
                    Text(entry.text.count > 500 ? String(entry.text.prefix(500)) + "\n…（思考内容过长，已截断）" : entry.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .selectableText()
                }
            }
            .padding(.leading, 2)

        case .toolCall:
            toolRow

        case .toolResult:
            EmptyView()   // 结果已合并进调用行

        case .collapsedSteps:
            foldedSteps

        case .system:
            HStack(spacing: 5) {
                if entry.running { ProgressView().controlSize(.mini) }
                Text(entry.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 2)
        }
        }
    }

    private var kindName: String {
        switch entry.kind {
        case .user: return "user"
        case .assistant: return "ans"
        case .thinking: return "think"
        case .toolCall: return "tool"
        case .toolResult: return "toolres"
        case .collapsedSteps: return "fold"
        case .system: return "sys"
        }
    }

    private var assistantBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.caption2).foregroundStyle(Color.accentColor)
                Text("回答").font(.caption2).foregroundStyle(Color.accentColor)
                if entry.running { ProgressView().controlSize(.mini) }
            }
            if entry.running {
                // 流式期间只渲染纯文本，而且**只渲染尾部**：排版在主线程，
                // 一条长回答干到几万字符时，排版本身就是秒级开销。
                // 正在输出时用户看的是最新几行，保留尾部 2000 字符足够。
                clampedPlain(tailOf: entry.text, limit: 800)
                    .selectableText()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let media = MediaRefCache.refs(for: entry.text)
                let cleaned = ImageRef.cleaned(entry.text)
                if !expanded, cleaned.count > Self.previewChars {
                    // 超长回答默认只排前 2000 字符：真机实测启动首次渲染历史
                    // 在这上面卡了 21.6 秒（STUCK 21639ms mark=body）。
                    // 把解析搬到后台不够，**CoreText 排版本身**也必须受控。
                    VStack(alignment: .leading, spacing: 6) {
                        MarkdownText(raw: String(cleaned.prefix(Self.previewChars)))
                            .foregroundStyle(.primary)
                        Button("展开全文（\(cleaned.count) 字）") { expanded = true }
                            .font(.system(size: 12))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                } else {
                    MarkdownText(raw: expanded ? String(cleaned.prefix(Self.expandedChars)) : cleaned)
                        .foregroundStyle(.primary)
                        .selectableText()
                    if expanded, cleaned.count > Self.expandedChars {
                        Text("（已截断，原文 \(cleaned.count) 字）")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                ForEach(media.images, id: \.self) { path in
                    RemoteImage(path: path)
                }
                // 视频 / 音频：同样从正文里挑出来，各自渲染播放器
                ForEach(media.videos, id: \.self) { path in
                    RemoteVideo(path: path)
                }
                ForEach(media.audios, id: \.self) { path in
                    RemoteAudio(path: path)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// 单条内容在主线程上允许排版的字数上限。
    /// 为什么要有：Text 的排版（CoreText）在主线程，几万字符就是几秒级。
    private static let previewChars = 600
    /// 主动展开后仍允许的上限，防止「展开」变成又一次 20 秒
    private static let expandedChars = 3_000

    /// 只渲染尾部的一段纯文本（流式输出用）
    @ViewBuilder
    private func clampedPlain(tailOf text: String, limit: Int) -> some View {
        if text.count <= limit {
            Text(text)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("（前面 \(text.count - limit) 字已省略）")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(String(text.suffix(limit)))
            }
        }
    }

    /// 一轮跑完后的过程折叠行：点一下才展开里面的思考与工具调用
    private var foldedSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(entry.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(entry.folded) { item in
                        ChatBubble(entry: item)
                    }
                }
                .padding(.leading, 12)
                .padding(.vertical, 2)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// `> 运行命令 · 摘要` —— 和电脑端一样紧凑的一行，需要时才展开
    private var toolRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 用 .center 而不是 .firstTextBaseline：ProgressView 没有文字基线，
            // baseline 对齐会让它往下沉，看着像漂在行外。
            HStack(spacing: 6) {
                Text(">")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Text(entry.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                if let summary, !summary.isEmpty {
                    Text("· \(summary)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                if entry.running {
                    ProgressView().controlSize(.mini)
                } else if let ok = entry.ok {
                    Text(ok ? "✓" : "✗")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ok ? Color.green : Color.red)
                }

                Spacer(minLength: 0)

                if entry.detail != nil {
                    Button("详情") { detailPresenter?.entry = entry }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }

            // 工具详情**不再内联进列表**。
            //
            // 之前是点开后在气泡里渲染 Text(detail)：工具参数动辄几万字符，
            // 一旦展开过，之后每次布局都要重新排版这段 —— 真机实测
            // 「点跳到底」卡死 19 秒（STUCK 19620ms mark=b:tool）。
            // 现在改成弹出 sheet：列表布局里永远不出现长文本。
        }
        .padding(.leading, 2)
    }

    /// 工具行摘要：已经在 AppModel 收到帧时算好（见 ToolSummary），这里直接读，
    /// 不在 View 里解析 JSON —— 否则几百条气泡每帧重建都重解一遍，滚动就卡。
    private var summary: String? {
        entry.summary
    }
}


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
