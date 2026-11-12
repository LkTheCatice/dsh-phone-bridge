import Foundation
import Combine

/// ComfyUI 状态（聊天页顶部那个状态点）。
///
/// 为什么单独拆：它每 8 秒被轮询更新一次，而 `ChatView` 用
/// `@EnvironmentObject var model: AppModel` 订阅的是**整个 AppModel** ——
/// AppModel 身上任何一个 `@Published` 变化都会让 ChatView 重算，
/// 哪怕 body 根本没读 comfy。
///
/// 实测依据：`hb body=` 在空闲时是 1-2，活跃时到 30；
/// 把高频状态搬出去是降低这个数的唯一办法（拆 ChatStore 时已验证）。
@MainActor
final class ComfyStore: ObservableObject {
    @Published private(set) var status = ComfyStatus()

    private var task: Task<Void, Never>?

    /// 开始轮询。`fetch` 由 AppModel 注入（它才有 BridgeClient）。
    func start(fetch: @escaping () async -> [String: Any]?) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let raw = await fetch() {
                    self?.apply(raw)
                }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func apply(_ raw: [String: Any]) {
        var next = ComfyStatus()
        next.online = (raw["online"] as? Bool) ?? false
        next.generating = (raw["generating"] as? Bool) ?? false
        next.running = (raw["running"] as? NSNumber)?.intValue ?? 0
        next.pending = (raw["pending"] as? NSNumber)?.intValue ?? 0
        next.version = raw["version"] as? String
        next.url = (raw["url"] as? String) ?? ""
        // 只在不相等时赋值，避免无意义通知
        if next != status { status = next }
    }
}
