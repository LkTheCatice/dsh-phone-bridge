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
    }

    let id: String
    var kind: Kind
    var text: String
    var detail: String?
    var at: Date
    var running: Bool = false
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
