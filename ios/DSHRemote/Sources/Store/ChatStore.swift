import Foundation
import Combine

/// 聊天数据：当前会话的条目 + 流式状态。
///
/// **为什么单独拆出来**：
/// `ChatView` 用 `@EnvironmentObject var model: AppModel` 时，订阅的是**整个 AppModel** ——
/// 只要它身上任何一个 `@Published` 变化， body 就重算，哪怕 body 根本没读那个字段。
///
/// 实测：空闲时 `hb body=1`（10 秒 1 次），流式输出时 `hb body=30`（3 次/秒）。
/// 3 次/秒正好对上流式的 350ms 节流 —— 说明 `streamTick` / `currentEntries`
/// 每次更新都把 composer、toolbar、整个列表白算一遍。
///
/// 把流式相关的四个状态搬到这里之后，ChatView 只额外订阅这个小对象，
/// AppModel 身上剩下的都是低频字段（comfy 8 秒、会话列表 2 秒、草稿在输入时）。
@MainActor
final class ChatStore: ObservableObject {
    /// 当前会话的条目（列表的唯一数据源）
    @Published private(set) var entries: [ChatEntry] = []
    /// 流式心跳：每收到一批 delta 就 +1，用来驱动「跟随到底」
    @Published private(set) var tick: Int = 0
    /// 当前会话是否正在生成
    @Published private(set) var streaming: Bool = false
    /// 历史重建计数：回填完成后 +1，ChatView 靠它把列表贴回底部
    @Published private(set) var historyVersion: Int = 0

    /// 排队中的消息（电脑端发起的也在这里）。
    /// 数据来自桥转发的 queue.changed 帧，由 agent/inbox/spliced 事件翻译而来：
    ///   排队(next-turn + items) → 追加；移除(removed>0, 无 items) → 删除；
    ///   改内容(removed>0 + items) → 替换；插队(next-step) → 移出队列。
    @Published private(set) var queue: [QueueItem] = []

    /// 只在不相等时赋值，避免无意义通知。
    ///
    /// 这里用**快速指纹**而不是整数组比较：
    /// `entries != next` 是 O(n)（每条还要比几个 String），
    /// 而 tick 在流式输出时每秒十几次 —— 会话加载到 600 条以后
    /// 光这个比较就是明显开销（用户问「翻得越上越占性能吗」，
    /// 渲染不占，但这条比较会）。
    ///
    /// 指纹 = count + 首条 id + 末条 id + 末条文本长度。
    /// 流式追加必然改变末条长度；上拉插入必然改变首条 id；
    /// 两者都不变时，内容不足以变化到需要重绘。
    func setEntries(_ next: [ChatEntry]) {
        guard !isSame(entries, next) else { return }
        entries = next
    }

    private func isSame(_ a: [ChatEntry], _ b: [ChatEntry]) -> Bool {
        guard a.count == b.count else { return false }
        guard let aFirst = a.first, let bFirst = b.first,
              let aLast = a.last, let bLast = b.last else {
            return a.isEmpty && b.isEmpty
        }
        return aFirst.id == bFirst.id
            && aLast.id == bLast.id
            && aLast.text.count == bLast.text.count
    }

    func bumpTick() {
        tick &+= 1
    }

    func setStreaming(_ value: Bool) {
        guard streaming != value else { return }
        streaming = value
    }

    /// 「请滚到底」令牌：外部（例如开屏动画结束时）只 +1，
    /// ChatView 观察到就发一次滚动请求。
    /// 这样"开屏撤场后再贴底"由事件驱动，不依赖"内容恰好又 apply 了一次"。
    @Published private(set) var scrollToBottomToken: Int = 0

    func requestScrollToBottom() {
        scrollToBottomToken &+= 1
    }

    func bumpHistoryVersion() {
        historyVersion &+= 1
    }

    /// 应用一次队列变更（语义见 queue 属性注释）
    func applyQueueChange(target: String, start: Int, removed: Int, items: [QueueItem]) {
        switch target {
        case "next-turn":
            if removed > 0 {
                let lo = max(0, min(start, queue.count))
                let hi = max(lo, min(lo + removed, queue.count))
                if hi > lo { queue.removeSubrange(lo..<hi) }
            }
            if !items.isEmpty {
                let at = max(0, min(start, queue.count))
                queue.insert(contentsOf: items, at: at)
            }
        case "next-step":
            // 插队：这条不再排队，从队列里摘掉
            for item in items {
                queue.removeAll { $0.rpcId == item.rpcId || $0.id == item.id }
            }
        default:
            break
        }
    }

    func clearQueue() {
        if !queue.isEmpty { queue = [] }
    }
}

/// 队列里的一条待执行消息
struct QueueItem: Identifiable, Hashable {
    let id: String
    let rpcId: String
    let text: String
}
