import Foundation

struct SessionRow: Identifiable, Hashable {
    let id: String
    var title: String?
    var cwd: String?
    var running: Bool
    /// 服务端给的最后活动时间（毫秒时间戳）
    var updatedAt: Double?
    /// 是否已收藏（桥存在 stateDir/favorites.json）
    var favorite: Bool = false
    /// 收藏时间（毫秒），用于"收藏"筛选里按收藏先后排
    var favoriteAt: Double? = nil

    /// cwd 的最后一段目录名。
    /// 预计算并随 SessionRow 一起构造 —— UI 里每行都调
    /// `URL(fileURLWithPath:).lastPathComponent` 是白开销（60 行就是 60 次解析）。
    var cwdName: String? = nil

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return String(id.suffix(8))
    }

    /// 「2 分钟前」这类相对时间
    /// 预先算好的相对时间（在解析时算一次）。
    ///
    /// 以前这里是**计算属性**：列表 60 行、每次 body 重算都会跑一遍
    /// `Date()` + 字符串插值，滚动时是纯浪费。现在由 `parse` 填好。
    var timeLabel: String = ""

    /// 计算相对时间的纯函数（解析时调用一次，UI 直接读 `timeLabel`）
    static func makeTimeLabel(from updatedMs: Double?, now: Date = Date()) -> String {
        guard let updatedMs else { return "" }
        let date = Date(timeIntervalSince1970: updatedMs / 1000)
        let diff = now.timeIntervalSince(date)
        if diff < 0 { return L("刚刚", "just now") }
        if diff < 60 { return L("刚刚", "just now") }
        if diff < 3600 {
            return L("\(Int(diff / 60)) 分钟前", "\(Int(diff / 60)) min ago")
        }
        if diff < 86400 {
            return L("\(Int(diff / 3600)) 小时前", "\(Int(diff / 3600)) h ago")
        }
        if diff < 86400 * 30 {
            return L("\(Int(diff / 86400)) 天前", "\(Int(diff / 86400)) d ago")
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func parse(_ dict: [String: Any]) -> SessionRow? {
        guard let id = dict["id"] as? String ?? dict["sessionId"] as? String, !id.isEmpty else {
            return nil
        }
        let stamp = (dict["updatedAt"] as? NSNumber)?.doubleValue
        let cwd = dict["cwd"] as? String
        var row = SessionRow(
            id: id,
            title: dict["title"] as? String,
            cwd: cwd,
            running: (dict["running"] as? Bool) ?? false,
            updatedAt: stamp,
            // 预计算：UI 每行都要用，别在 body 里解析 URL
            cwdName: cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        )
        row.favorite = (dict["favorite"] as? Bool) ?? false
        row.favoriteAt = (dict["favoriteAt"] as? NSNumber)?.doubleValue
        row.timeLabel = SessionRow.makeTimeLabel(from: row.updatedAt)
        return row
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
/// 一条待用户回答的提问（对应桥的 `ask.asked` 帧）。
///
/// 和「权限确认」不同：确认操作必须在电脑上做（涉及安全决定），
/// 而**提问**只是要一段信息，手机上答最方便 —— 所以这个做成了可交互卡片。
struct AskQuestion: Identifiable, Hashable {
    struct Option: Hashable {
        let label: String
        let description: String?
    }

    let id: String
    let text: String
    var header: String?
    var detail: String?
    var options: [Option] = []
    var multiSelect: Bool = false
}

struct PendingAsk: Identifiable, Hashable {
    let id: String          // 桥给的 ask id
    let sessionId: String
    var questions: [AskQuestion]
}

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
        /// 产物行（「📄 输出文件 · xxx」）。**独立一种 kind**：
        /// 它是带底色的卡片，用真正的 UIView 画（FileChipView），
        /// 而不是靠 NSAttributedString 的段落间距/行高去凑 ——
        /// 那套凑法试三版都没能把文字在卡片里对齐（用户三次实拍）。
        /// 架构上这样也更对：卡片是布局元素，不是文本。
        case fileOutput
        /// 一轮产出的**汇总清单卡**（多行、每行可点）
        case fileSummary
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
    /// 轮内序号：同 turn、同 at 时的稳定次序（0 = 普通帧，900 = 产物卡片，1000 = 结束行）。
    /// 排序键是 (turn, at, order, id)，全部来自帧数据 ——
    /// 所以同一份历史无论何时回放、从哪一页开始装，顺序都一样。
    var order: Int = 0
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
    /// 这条 system 行要用"警告色"（橙）显示。
    /// 目前只有一种用途：**电脑在等你确认某个操作** ——
    /// 手机上不做确认按钮（容易点错，也绕过了电脑端的策略），
    /// 只提示用户去电脑上处理。
    var warning: Bool = false
    /// 工具行的一行摘要（收到帧时算好；放 View 里现算会让滚动变卡）
    var summary: String? = nil
}

extension ChatEntry {
    /// 手写 Hashable：默认合成会把 `folded: [ChatEntry]` 整棵树递归比较，
    /// SwiftUI 做 diff 时非常贵。只比真正影响显示的那几个字段。
    static func == (lhs: ChatEntry, rhs: ChatEntry) -> Bool {
        lhs.id == rhs.id && lhs.order == rhs.order
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
        if !online { return L("ComfyUI 离线", "ComfyUI offline") }
        if generating {
            return pending > 0 ? L("生图中 · 队列 \(pending)", "Image busy · \(pending) queued") : L("生图中", "Image busy")
        }
        return pending > 0 ? L("空闲 · 队列 \(pending)", "Idle · \(pending) queued") : L("空闲", "Idle")
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
        case .queue: return L("排队", "Queued")
        case .steer: return L("插队", "Jump")
        }
    }

    var hint: String {
        switch self {
        case .queue: return L("等当前这轮跑完再处理", "Runs after the current turn")
        case .steer: return L("立刻打断当前这轮", "Interrupts the current turn")
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

