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

    /// 只在不相等时赋值，避免无意义通知（Equatable 比较，Array<ChatEntry> 的 == 已是轻量实现）
    func setEntries(_ next: [ChatEntry]) {
        guard entries != next else { return }
        entries = next
    }

    func bumpTick() {
        tick &+= 1
    }

    func setStreaming(_ value: Bool) {
        guard streaming != value else { return }
        streaming = value
    }

    func bumpHistoryVersion() {
        historyVersion &+= 1
    }
}
