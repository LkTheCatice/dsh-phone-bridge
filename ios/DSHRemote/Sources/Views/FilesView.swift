import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: String = ""
    @State private var rows: [FsEntry] = []
    @State private var loading = false
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(path.isEmpty ? "（取第一个允许的根目录）" : path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if loading {
                    HStack { ProgressView(); Text("读取中…").font(.caption) }
                }

                Section("目录内容") {
                    ForEach(rows) { row in
                        Button {
                            if row.dir {
                                load(row.fullPath)
                            } else {
                                Task { await download(row) }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: row.dir ? "folder.fill" : "doc.text")
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
                                if !row.dir { Image(systemName: "arrow.down.circle").foregroundStyle(.secondary) }
                            }
                        }
                    }
                }

                if !path.isEmpty {
                    Section {
                        Button("返回上一级") {
                            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
                            if let idx = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
                                load(String(trimmed[trimmed.startIndex..<idx]))
                            }
                        }
                    }
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
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let target = dir.appendingPathComponent(row.name)
            try data.write(to: target, options: .atomic)
            message = "已保存 \(row.name)（\(data.count) 字节）到 App 文档目录"
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
