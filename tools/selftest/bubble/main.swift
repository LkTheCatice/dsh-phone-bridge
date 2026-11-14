// 本机（Windows + Swift toolchain）直接编译并跑断言：BubbleIds 只依赖 Foundation，
// 不需要 iOS SDK。用法：tools/selftest/run-bubbleids.ps1
//
// 文件名必须叫 main.swift：Swift 只允许在 main.swift 里写顶层语句。

var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: String) {
    checks += 1
    if !ok {
        failures += 1
        print("  ✗ \(what)")
    }
}

let sid = "session-abc"

// 1) 插队前后：同一轮的两段回答必须是两个 id（否则文本会被拼回上方的旧气泡）
let before = BubbleIds.answer(sid, turn: 269, segment: 0)
let after = BubbleIds.answer(sid, turn: 269, segment: 1)
check(before != after, "同一轮不同段必须不同 id")
check(before == "session-abc#ans269_0", "段 0 的 id 形状: \(before)")
check(after == "session-abc#ans269_1", "段 1 的 id 形状: \(after)")
check(BubbleIds.answer(sid, turn: 270, segment: 1) != after, "不同轮不撞 id")
check(BubbleIds.answer("session-xyz", turn: 269, segment: 1) != after, "不同会话不撞 id")
check(BubbleIds.thinking(sid, turn: 269, segment: 1) != after, "思考块与正文不撞 id")

// 2) 占位匹配：服务端回显多出 `[附件] …` 时也要认成同一条
let sent = "看一下这个\n[附件] D:/output/sample-01.jpg"
check(BubbleIds.sameMessage("报这个", sent), "占位(纯文本) 应匹配 回显(带附件)")
check(BubbleIds.sameMessage(sent, "报这个"), "顺序无关")
check(BubbleIds.sameMessage("  报这个  ", "报这个"), "首尾空白应忽略")
check(!BubbleIds.sameMessage("报这个", "报那个"), "内容不同不能匹配")
check(!BubbleIds.sameMessage("报这个", "报这个\n再补一句"), "多一句就不能算同一条")
check(BubbleIds.sameMessage("1、余额两行\n2、卡顿", "1、余额两行 2、卡顿"), "换行/空格归一化后相同")

// 3) 分页钳制：容量传多大都不会再回到那次卡顿
check(BubbleIds.pageSize(400, cap: 200) == 200, "400 帧应被钳到 200")
check(BubbleIds.pageSize(300, cap: 120) == 120, "300 帧应被钳到 120")
check(BubbleIds.pageSize(120, cap: 120) == 120, "刚好等于 cap 不动")
check(BubbleIds.pageSize(80, cap: 120) == 80, "小于 cap 尊重调用方")
check(BubbleIds.pageSize(0, cap: 120) == 40, "0 帧抬到下限 40")
check(BubbleIds.pageSize(-5, cap: 120) == 40, "负数抬到下限 40")

// 4) 队列项 vs 本地占位（「排队消息不该同时出现在对话里」的判据）
check(BubbleIds.matchesQueueItem("插队的标也还在气泡里没删", "插队的标也还在气泡里没删"), "完全一致要认")
check(BubbleIds.matchesQueueItem("报这个\n[附件] E:/x.jpg", "报这个"), "占位没有附件装饰也要认")
check(BubbleIds.matchesQueueItem("报这个", "报这个\n[附件] E:/x.jpg"), "反过来也要认")
let longQueued = String(repeating: "这是一条很长的排队消息，", count: 40)
let truncatedQueued = String(longQueued.prefix(400))
check(BubbleIds.matchesQueueItem(truncatedQueued, longQueued), "桥截断到 400 字也要对上")
check(!BubbleIds.matchesQueueItem("短", "短的"), "太短的前缀不许认（防误删）")
check(!BubbleIds.matchesQueueItem("第一条消息内容足够长了哦", "第二条消息内容也足够长了"), "不同内容不能认")
check(!BubbleIds.matchesQueueItem("", "任何东西"), "空队列项不能认")

print("BubbleIds: 检查 \(checks) 项，失败 \(failures) 项")
if failures > 0 {
    print("❌ 有断言失败")
    fatalError("BubbleIds 断言失败 \(failures) 项")
}
print("✅ 全部通过")
