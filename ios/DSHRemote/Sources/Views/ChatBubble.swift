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

    /// 从工具参数里挑一行最能说明问题的摘要
    private var summary: String? {
        guard let detail = entry.detail, !detail.isEmpty else { return nil }
        var candidate: String?
        if let data = detail.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["command", "path", "file_path", "filePath", "target", "pattern", "query", "prompt", "text", "description", "name"] {
                if let value = obj[key] as? String, !value.isEmpty {
                    candidate = value
                    break
                }
            }
            if candidate == nil {
                for (_, value) in obj {
                    if let s = value as? String, !s.isEmpty { candidate = s; break }
                }
            }
        } else {
            candidate = detail
        }
        guard var text = candidate else { return nil }
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.trimmingCharacters(in: .whitespaces)
        return text.count > 72 ? String(text.prefix(72)) + "…" : text
    }
}
