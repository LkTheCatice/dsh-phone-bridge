import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 包一层 UIActivityViewController：ShareLink 只能由用户点按钮触发，
/// 而这里的分享是「下载完成后自动弹出」，只能走程序化呈现。
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct FilesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: String = ""
    @State private var rows: [FsEntry] = []
    @State private var loading = false
    @State private var importing = false
    @State private var message: String?
    @State private var shareItems: [Any] = []

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp"]

    /// 文件夹优先，其余按首字母分组；非字母开头归到 #
    private var grouped: [(String, [FsEntry])] {
        let sorted = rows.sorted { lhs, rhs in
            if lhs.dir != rhs.dir { return lhs.dir }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let dict = Dictionary(grouping: sorted) { entry -> String in
            guard let first = entry.name.first else { return "#" }
            let upper = String(first).uppercased()
            return upper.range(of: "^[A-Z]$", options: .regularExpression) != nil ? upper : "#"
        }
        return dict.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }.map { ($0, dict[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        Text(path.isEmpty ? "（取第一个允许的根目录）" : path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if loading {
                        HStack { ProgressView(); Text("读取中…").font(.caption) }
                    }

                    ForEach(grouped, id: \.0) { letter, entries in
                        Section {
                            ForEach(entries) { row in
                                rowView(row)
                            }
                        } header: {
                            Text(letter)
                                .id(letter)
                        }
                    }

                    if !path.isEmpty {
                        Section {
                            Button("返回上一级") { goUp() }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay(alignment: .trailing) {
                    indexBar(proxy)
                }
            }
            .navigationTitle("文件")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { importing = true } label: { Label("上传到当前目录", systemImage: "arrow.up.doc") }
                        Button { load(path) } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .sheet(isPresented: Binding(
                get: { !shareItems.isEmpty },
                set: { if !$0 { shareItems = [] } }
            )) {
                ActivityView(items: shareItems)
                    .presentationDetents([.medium, .large])
            }
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.caption)
                        .padding(10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                }
            }
            .task { if rows.isEmpty { load("") } }
        }
    }

    @ViewBuilder
    private func rowView(_ row: FsEntry) -> some View {
        Button {
            if row.dir {
                load(row.fullPath)
            } else {
                Task { await download(row) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: row.dir ? "folder.fill" : iconFor(row.name))
                    .foregroundStyle(row.dir ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).lineLimit(1)
                    if let size = row.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !row.dir {
                    Image(systemName: isImage(row.name) ? "photo" : "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .id(row.id)
    }

    /// 右侧 A–Z 索引条：点一下就跳到那个分组
    @ViewBuilder
    private func indexBar(_ proxy: ScrollViewProxy) -> some View {
        let letters = grouped.map(\.0)
        if letters.count > 3 {
            VStack(spacing: 1) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18, height: 14)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                proxy.scrollTo(letter, anchor: .top)
                            }
                        }
                }
            }
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.trailing, 2)
        }
    }

    private func isImage(_ name: String) -> Bool {
        Self.imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private func iconFor(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp": return "photo"
        case "md", "txt", "log": return "doc.text"
        case "json", "yml", "yaml", "js", "ts", "py", "swift": return "chevron.left.forwardslash.chevron.right"
        case "zip", "7z", "rar", "tar", "gz": return "archivebox"
        case "mp4", "mov", "mkv", "webm": return "film"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    private func goUp() {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if let idx = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            load(String(trimmed[trimmed.startIndex..<idx]))
        }
    }

    private func load(_ target: String) {
        loading = true
        Task {
            do {
                let list = try await model.listFiles(path: target)
                rows = list
                if !target.isEmpty { path = target } else if let first = model.roots.first { path = first }
                message = "\(rows.count) 项"
            } catch {
                message = "读取失败：\(error.localizedDescription)"
            }
            loading = false
        }
    }

    private func download(_ row: FsEntry) async {
        do {
            let data = try await model.download(path: row.fullPath)
            // 图片直接进相册，别让用户再去分享面板里绕一圈
            if isImage(row.name), let image = UIImage(data: data) {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                message = "已存到相册：\(row.name)"
                return
            }
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let target = dir.appendingPathComponent(row.name)
            try data.write(to: target, options: .atomic)
            message = "已保存 \(row.name)（\(data.count) 字节）"
            shareItems = [target]
        } catch {
            message = "下载失败：\(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            message = "选择文件失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let base = path.isEmpty ? (model.roots.first ?? "") : path
                let sep = base.hasSuffix("/") || base.hasSuffix("\\") ? "" : "/"
                let remote = base + sep + url.lastPathComponent
                Task {
                    do {
                        try await model.upload(localData: data, remotePath: remote)
                        message = "已上传到 \(remote)"
                        load(path)
                    } catch {
                        message = "上传失败：\(error.localizedDescription)"
                    }
                }
            } catch {
                message = "读取本地文件失败：\(error.localizedDescription)"
            }
        }
    }
}
