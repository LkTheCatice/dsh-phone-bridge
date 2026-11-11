import Foundation

// MARK: - markdown 解析缓存（纯 Foundation）

/// Markdown 解析结果缓存。
///
/// 现在有两个访问面：
/// - `cached(_:)` 只读缓存（主线程，命中就同步返回，滚动历史照样直接命中）
///
/// 关键改动：解析**不再发生在主线程**。之前是 computed property 在 body 里同步解析，
/// 一条超长回答就能把主线程按住数秒。
enum MarkdownCache {
    private static let lock = NSLock()
    private static var storage: [String: [Block]] = [:]
    private static var order: [String] = []
    private static let capacity = 60

    /// 只读缓存，不触发解析
    static func cached(_ text: String) -> [Block]? {
        lock.lock()
        defer { lock.unlock() }
        return storage[text]
    }

    /// 同步取（命中缓存直接返回，未命中就在当前线程解析一次）
    ///
    /// 给 `UITextView` 的 cell 配置用：一条消息只解析一次，
    /// 之后滚动命中 NSCache / 这里的 storage，不再解析。
    static func blocksSync(for text: String) -> [Block] {
        if let hit = cached(text) { return hit }
        let parsed = MarkdownParser.parse(text)
        store(text, parsed)
        return parsed
    }

    private static func store(_ text: String, _ blocks: [Block]) {
        lock.lock()
        defer { lock.unlock() }
        if storage[text] == nil { order.append(text) }   // 同一份文本只入队一次
        storage[text] = blocks
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    //
    // 而 body 在流式输出时每 60ms 重算一次 —— 一次重算要几秒（十几条消息 × 每段一次），
    // 于是队列越堆越长，主线程再也回不到空闲（真机 mark=body，STUCK 63 秒）。
    // 文本内容不变时结果必然不变，按原文缓存即可。

    /// 超过这个长度就不做行内解析（直接纯文本）：
    /// 单次解析耗时随字数增长，而这么长的一段基本都是工具输出，没有行内格式可解。

}
