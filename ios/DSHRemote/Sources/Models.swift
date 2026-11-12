import Foundation

struct SessionRow: Identifiable, Hashable {
    let id: String
    var title: String?
    var cwd: String?
    var running: Bool
    /// 服务端给的最后活动时间（毫秒时间戳）
    var updatedAt: Double?

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return String(id.suffix(8))
    }

    /// 「2 分钟前」这类相对时间
    var relativeTime: String {
        guard let updatedAt else { return "" }
        let date = Date(timeIntervalSince1970: updatedAt / 1000)
        let diff = Date().timeIntervalSince(date)
        if diff < 0 { return "刚刚" }
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60)) 分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600)) 小时前" }
        if diff < 86400 * 30 { return "\(Int(diff / 86400)) 天前" }
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func parse(_ dict: [String: Any]) -> SessionRow? {
        guard let id = dict["id"] as? String ?? dict["sessionId"] as? String, !id.isEmpty else {
            return nil
        }
        let stamp = (dict["updatedAt"] as? NSNumber)?.doubleValue
        return SessionRow(
            id: id,
            title: dict["title"] as? String,
            cwd: dict["cwd"] as? String,
            running: (dict["running"] as? Bool) ?? false,
            updatedAt: stamp
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
    /// 时间标签：只有和上一条隔了 5 分钟以上才填，nil 表示不显示
    var timeLabel: String? = nil
    /// 工具行的一行摘要（收到帧时算好；放 View 里现算会让滚动变卡）
    var summary: String? = nil
}

extension ChatEntry {
    /// 手写 Hashable：默认合成会把 `folded: [ChatEntry]` 整棵树递归比较，
    /// SwiftUI 做 diff 时非常贵。只比真正影响显示的那几个字段。
    static func == (lhs: ChatEntry, rhs: ChatEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.text == rhs.text
            && lhs.running == rhs.running
            && lhs.ok == rhs.ok
            && lhs.detail == rhs.detail
            && lhs.summary == rhs.summary
            && lhs.timeLabel == rhs.timeLabel
            && lhs.folded.count == rhs.folded.count
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(text)
        hasher.combine(running)
        hasher.combine(ok)
    }
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

/// 推理强度档位
struct ReasoningEffort: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String?
}

struct ModelOption: Identifiable, Hashable {
    let id: String
    let name: String
    let provider: String
    let providerName: String
    /// 该模型支持的推理档位；空表示不支持
    var efforts: [ReasoningEffort] = []
    /// 当前选中的档位（nil = 用模型默认）
    var effort: String?
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

