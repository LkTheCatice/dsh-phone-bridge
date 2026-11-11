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

    static func == (lhs: ChatBubble, rhs: ChatBubble) -> Bool {
        lhs.entry == rhs.entry
    }

    var body: some View {
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
                    Text(entry.text)
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

    private var assistantBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.caption2).foregroundStyle(Color.accentColor)
                Text("回答").font(.caption2).foregroundStyle(Color.accentColor)
                if entry.running { ProgressView().controlSize(.mini) }
            }
            if entry.running {
                // 流式期间只渲染纯文本：跳过 Markdown 解析、跳过正则扫图、跳过字符串清洗。
                // 否则每来一个 delta 都要对全文跑一遍正则 + 解析，输入和滚动都会卡。
                Text(entry.text)
                    .selectableText()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let media = MediaRefCache.refs(for: entry.text)
                MarkdownText(raw: ImageRef.cleaned(entry.text))
                    .foregroundStyle(.primary)
                    .selectableText()
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
                    Button(expanded ? "收起" : "详情") { expanded.toggle() }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }

            if expanded, let detail = entry.detail {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .selectableText()
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                // 工具读过的图：DSH 运行时看的图片只出现在参数里，
                // 不渲染的话手机上完全看不到这一轮到底看了什么。
                ForEach(ToolSummary.imagePaths(from: detail), id: \.self) { path in                    RemoteImage(path: path)
                }
            }
        }
        .padding(.leading, 2)
    }

    /// 工具行摘要：已经在 AppModel 收到帧时算好（见 ToolSummary），这里直接读，
    /// 不在 View 里解析 JSON —— 否则几百条气泡每帧重建都重解一遍，滚动就卡。
    private var summary: String? {
        entry.summary
    }
}
