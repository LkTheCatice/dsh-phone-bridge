import Foundation

/// 与 Node 侧 `canonicalQuery` / `encodeURIComponent` 逐字节对齐的辅助。
///
/// AAD 必须两边算出完全一样的字符串，否则 AES-GCM 认证失败 —— 这是整个加密层
/// 最容易踩的坑，所以这里刻意手写而不是用 URLComponents（它对空格、加号、
/// 反斜杠的编码规则和 JS 不一致）。
enum JS {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )

    static func encodeURIComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// 按 key 升序；空数组返回 ""
    static func canonicalQuery(_ pairs: [(String, String)]) -> String {
        guard !pairs.isEmpty else { return "" }
        let sorted = pairs.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? false : lhs.0 < rhs.0
        }
        return sorted
            .map { "\(encodeURIComponent($0.0))=\(encodeURIComponent($0.1))" }
            .joined(separator: "&")
    }

    /// `${METHOD} ${PATH}?${query}`，无 query 时省略 `?`
    static func aad(method: String, path: String, query: [(String, String)]) -> String {
        let q = canonicalQuery(query)
        return q.isEmpty ? "\(method) \(path)" : "\(method) \(path)?\(q)"
    }

    /// 把已排序的 query 拼成真正请求用的查询串（与 AAD 同源，避免二次编码差异）
    static func queryString(_ pairs: [(String, String)]) -> String {
        canonicalQuery(pairs)
    }
}
