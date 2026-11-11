import Foundation

struct SessionRow: Identifiable, Hashable {
    let id: String
    var title: String?
    var cwd: String?
    var running: Bool

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return String(id.suffix(8))
    }

    static func parse(_ dict: [String: Any]) -> SessionRow? {
        guard let id = dict["id"] as? String ?? dict["sessionId"] as? String, !id.isEmpty else {
            return nil
        }
        return SessionRow(
            id: id,
            title: dict["title"] as? String,
            cwd: dict["cwd"] as? String,
            running: (dict["running"] as? Bool) ?? false
        )
    }
}

struct ApprovalRow: Identifiable, Hashable {
    let id: String
    var tool: String
    var reason: String
    var since: Date
    var deadline: Date?
}

/// 聊天条目：把流式帧压成可渲染的行。
struct ChatEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case user
        case assistant
        case thinking
        case toolCall
        case toolResult
        case system
        /// 一轮跑完后把该轮的思考/工具调用收成一行，点开才展开
        case collapsedSteps
    }

    let id: String
    var kind: Kind
    var text: String
    var detail: String?
    var at: Date
    var running: Bool = false
    /// 工具结果的成功/失败，nil 表示还没回来
    var ok: Bool? = nil
    /// 属于哪一轮，折叠时按它筛
    var turn: Int = 0
    /// collapsedSteps 里包着的原始条目
    var folded: [ChatEntry] = []
}

/// ComfyUI 的在线/生图状态
struct ComfyStatus: Equatable {
    var online = false
    var generating = false
    var running = 0
    var pending = 0
    var version: String?
    var url: String = ""

    var label: String {
        if !online { return "ComfyUI 离线" }
        if generating {
            return pending > 0 ? "生图中 · 队列 \(pending)" : "生图中"
        }
        return pending > 0 ? "空闲 · 队列 \(pending)" : "空闲"
    }
}

struct ModelOption: Identifiable, Hashable {
    let id: String
    let name: String
    let provider: String
    let providerName: String
}

struct ModelGroup: Identifiable, Hashable {
    let id: String
    let name: String
    var models: [ModelOption]
}

/// 发送方式：排队（等当前轮结束）或插队（打断当前轮）
enum SendMode: String, CaseIterable, Identifiable {
    case queue
    case steer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .queue: return "排队"
        case .steer: return "插队"
        }
    }

    var hint: String {
        switch self {
        case .queue: return "等当前这轮跑完再处理"
        case .steer: return "立刻打断当前这轮"
        }
    }
}

/// 从别的 App（微信/QQ/文件）用「用其他应用打开」递过来的文件
struct IncomingFile: Identifiable {
    let id = UUID()
    let name: String
    let data: Data

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    var isImage: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"].contains(ext)
    }
}

struct FsEntry: Identifiable, Hashable {
    let id: String
    var name: String
    var dir: Bool
    var size: Int?
    var fullPath: String

    static func parse(_ dict: [String: Any], parent: String) -> FsEntry? {
        guard let name = dict["name"] as? String else { return nil }
        let joined = parent.hasSuffix("/") || parent.hasSuffix("\\")
            ? parent + name
            : parent + "/" + name
        return FsEntry(
            id: joined,
            name: name,
            dir: (dict["dir"] as? Bool) ?? false,
            size: (dict["size"] as? NSNumber)?.intValue,
            fullPath: joined
        )
    }
}
