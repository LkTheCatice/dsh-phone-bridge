import Foundation

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
    /// 这条是本地乐观插入、还没被服务端确认的消息（排队中）。
    /// 显示上要明确标出来，否则用户会以为它已经执行了。
    var queued: Bool = false
    /// 这条是「点了插队、DSH 还没轮到执行」的占位。
    /// 机队语义和排队不同：它不是等前面排完，而是等 DSH 收尾手头的小任务，
    /// 所以文案要分开（用户反馈：插队后消息两边都没有，像消失了）。
    var steering: Bool = false
    /// collapsedSteps 里包着的原始条目
    var folded: [ChatEntry] = []
    /// 时间标签：只有和上一条隔了 5 分钟以上才填，nil 表示不显示
    var timeLabel: String? = nil
    /// 工具行的一行摘要（收到帧时算好；放 View 里现算会让滚动变卡）
    var summary: String? = nil
}

struct SessionRow: Identifiable, Hashable {
    let id: String
    var title: String?
    var cwd: String?
    var running: Bool
    /// 服务端给的最后活动时间（毫秒时间戳）
    var updatedAt: Double?

    /// cwd 的最后一段目录名。
    /// 预计算并随 SessionRow 一起构造 —— UI 里每行都调
    /// `URL(fileURLWithPath:).lastPathComponent` 是白开销（60 行就是 60 次解析）。
    var cwdName: String? = nil

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
        let cwd = dict["cwd"] as? String
        return SessionRow(
            id: id,
            title: dict["title"] as? String,
            cwd: cwd,
            running: (dict["running"] as? Bool) ?? false,
            updatedAt: stamp,
            // 预计算：UI 每行都要用，别在 body 里解析 URL
            cwdName: cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        )
    }
}

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

struct ApprovalRow: Identifiable, Hashable {
    let id: String
    var tool: String
    var reason: String
    var since: Date
    var deadline: Date?
}
