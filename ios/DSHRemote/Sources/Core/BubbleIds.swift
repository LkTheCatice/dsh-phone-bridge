import Foundation

/// 气泡 id 与分页参数的**纯逻辑**。
///
/// 为什么单独抽到这里：`AppModel` 整个文件依赖 SwiftUI/UIKit，Windows 上编不了，
/// 于是「气泡 id 怎么拼」「插队后的回答落在哪个气泡」「一页塞多少帧」这些最容易出错的
/// 判断只能靠 CI 兜。抽成只依赖 Foundation 的类型之后，本机 `swiftc` 就能编译 + 跑断言
/// （`tools/selftest/run-bubbleids.ps1`），不用等一次 macOS 构建。
enum BubbleIds {
    /// 一轮里第几段回答的正文气泡。
    ///
    /// 插队（steer）在 DSH 里是把消息塞进**当前轮的下一步**，插队那条的回答和本轮
    /// 前面的回答共用同一个 `turn`。早先 id 固定是 `sid#ans<turn>`，两段文本会被拼进
    /// **同一个**气泡 —— 而那个气泡在插队消息上方，表现就是「插队执行成功，但手机上看
    /// 不到它的输出」。加上段号后，插队回显（一条 `user.message`）把段号 +1，
    /// 后续 delta 落到新气泡里，自然排在插队消息下面。
    static func answer(_ sessionId: String, turn: Int, segment: Int) -> String {
        "\(sessionId)#ans\(turn)_\(segment)"
    }

    /// 思考块气泡。同样分段：否则插队后的思考会拼回插队消息上方的旧块。
    static func thinking(_ sessionId: String, turn: Int, segment: Int) -> String {
        "\(sessionId)#think\(turn)_\(segment)"
    }

    /// 一轮的开头系统行 / 结尾系统行 / 折叠块 / 工具行（这些不需要分段）
    static func turnRow(_ sessionId: String, turn: Int) -> String { "\(sessionId)#turn\(turn)" }
    static func endRow(_ sessionId: String, turn: Int) -> String { "\(sessionId)#end\(turn)" }
    static func folded(_ sessionId: String, turn: Int) -> String { "\(sessionId)#fold\(turn)" }
    static func tool(_ sessionId: String, callId: String) -> String { "\(sessionId)#tool\(callId)" }

    /// 判断两条用户消息是不是同一条（用于把本地乐观插入的占位替换成服务端回显）。
    ///
    /// 占位里存的是队列项原文，服务端回显可能多出 `[附件] …` 这类装饰，
    /// 直接 `==` 匹配不上 —— 结果占位永远挂着「▍我 · 已插队，等当前任务完成」。
    static func sameMessage(_ a: String, _ b: String) -> Bool {
        normalize(a) == normalize(b)
    }

    private static func normalize(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[附件]") }
            .joined(separator: " ")
    }

    /// 一页多少帧（帧 ≠ 条，一条消息约 3~8 帧）。
    ///
    /// 实测：400 帧（≈50~120 条）一次灌进列表，上划明显卡顿；300 帧也能感觉到顿；
    /// 200 / 120 顺。所以调用方传多大都钳到 `cap`，下限 `floor` 防止有人传 0/负数
    /// 把「上拉」变成永远拉不到东西。
    static func pageSize(_ requested: Int, cap: Int, floor: Int = 40) -> Int {
        max(floor, min(requested, cap))
    }
}
