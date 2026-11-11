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

    /// 从工具参数里挑一行最能说明问题的摘要。
    ///
    /// 参数不一定是扁平对象：有的工具是 `{"content":[{"type":"text","text":"…"}]}`，
    /// 有的直接是顶层数组。所以递归挑字段，绝不把整段 JSON 怼到界面上。
    private var summary: String? {
        guard let detail = entry.detail, !detail.isEmpty else { return nil }
        var candidate: String?
        if let data = detail.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: []) {
            candidate = Self.pickSummary(parsed)
        }
        if candidate == nil {
            candidate = detail
        }
        guard var text = candidate else { return nil }
        text = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("{"), !text.hasPrefix("[") else { return nil }
        return text.count > 72 ? String(text.prefix(72)) + "…" : text
    }

    private static func pickSummary(_ value: Any, depth: Int = 0) -> String? {
        guard depth < 3 else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : clamped(trimmed)
        }
        if let dict = value as? [String: Any] {
            // 1) description —— DSH 给每个工具调用写的人类可读说明，
            //    电脑端显示的就是这句。必须排第一，否则会掉到原始命令上。
            if let d = dict["description"] as? String {
                let t = d.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return clamped(t) }
            }
            // 2) 文件类：显示「目录末段/文件名:行号」，不要一长串绝对路径，更不要 offset 数字
            if let p = (dict["path"] ?? dict["file_path"] ?? dict["filePath"]) as? String, !p.isEmpty {
                return shortPath(p, offset: (dict["offset"] as? NSNumber)?.intValue)
            }
            // 3) 其余按语义挑（白名单）。这里刻意不再「遍历所有 key」——
            //    那样会抓到工具结果里的文字，之前在手机上显示成 "The file D:\..." 就是这么来的。
            let preferred = ["command", "query", "pattern", "prompt", "url", "target", "title", "name"]
            for key in preferred {
                if let v = dict[key], let s = pickSummary(v, depth: depth + 1) { return s }
            }
            return nil
        }
        if let arr = value as? [Any] {
            for item in arr {
                if let s = pickSummary(item, depth: depth + 1) { return s }
            }
        }
        return nil
    }

    /// `D:\a\b\ChatView.swift` + offset 39 → `b/ChatView.swift:39`
    private static func shortPath(_ path: String, offset: Int?) -> String {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        let tail = parts.suffix(2).joined(separator: "/")
        let base = tail.isEmpty ? path : tail
        if let offset, offset > 0 { return "\(base):\(offset)" }
        return base
    }

    /// 命令可能很长：只留第一行，超长截断，避免整行被省略号吃掉关键信息
    private static func clamped(_ text: String) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 64 ? String(trimmed.prefix(64)) + "…" : trimmed
    }
}
