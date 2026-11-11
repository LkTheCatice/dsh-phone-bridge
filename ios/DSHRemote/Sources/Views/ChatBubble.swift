import SwiftUI
struct ChatBubble: View {
    let entry: ChatEntry
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            }

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
                        .textSelection(.enabled)
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
        let imagePaths = ImageRef.paths(in: entry.text)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.caption2).foregroundStyle(Color.accentColor)
                Text("回答").font(.caption2).foregroundStyle(Color.accentColor)
                if entry.running { ProgressView().controlSize(.mini) }
            }
            MarkdownText(raw: ImageRef.cleaned(entry.text))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            ForEach(imagePaths, id: \.self) { path in
                RemoteImage(path: path)
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
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
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
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
