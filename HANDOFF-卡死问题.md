# DSH Helm — 卡死问题排查总结

> 交接给另一个工作流。写的都是实测数据，不是推测。

---

## 一、项目背景

- **客户端**：iOS App，SwiftUI，`D:\Documents\deepseek-harness\default-workspace\phone-dsh\ios\DSHRemote\Sources\`
- **服务端**：Node 插件（cordis），`...\phone-dsh\bridge\`
- **作用**：手机通过端到端加密通道遥控电脑上的 DeepSeek Harness，收发消息、看执行过程、传文件
- **构建**：GitHub Actions（macos-latest）→ 产出 unsigned IPA → Sideloadly 装到 iPhone
- **日志**：`D:\Documents\deepseek-harness\dsh-phone-bridge\bridge.log`（JSONL）

---

## 二、核心症状

**App 卡死。** 具体表现：

- 点「发送」瞬间界面完全冻结
- 刚输入的文字不渲染出来（数据层已插入，视觉上没出现）
- 触控完全失效，无法滚动、无法打字
- 有时候恢复，有时候一直卡着

**伴随症状**：打开 App 后第一次在输入框打字，第一个拼音字母丢失。

---

## 三、已排除的嫌疑（都有实测数据）

### 1. 网络 / 服务端 —— 正常

服务端日志显示 `POST /v1/task` **16~42ms 就返回 200**，不是慢。

### 2. 数据层 —— 正常

在 `send()` 各步骤打了时间戳（通过 `pingDiagnostic` 发到服务端日志）：

```
s0-trim=0ms      去空格
s1-busy=0ms      置忙标志
s2-append=0ms    插入消息到数组
s3-task=42ms     网络请求
s5-refresh=0ms   刷新会话列表
s9-total=42ms    总计
```

**所有步骤都是 0~42ms。** 数据层不是瓶颈。

### 3. 列表规模 —— 已缓解但非主因

单会话条目上限从 600 降到 220。起作用但不是根因（卡死时列表只有 3 条也能复现）。

---

## 四、找到的四条循环（都是同一个模式：`@State` 在回调里被改）

**模式**：`@State` 一赋值 → SwiftUI 重算 body → body 重算所触发的回调又赋值 → 无限循环 → 主线程队列被灌满 → 彻底卡死。

### 循环 1：ScrollViewAccessor 重试任务堆积

```swift
// 文件：Sources/Views/ScrollViewAccessor.swift
func updateUIView(_ uiView: UIView, context: Context) {
    resolve(uiView)
    for delay in [0.15, 0.5, 1.2] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { resolve(uiView) }
    }
}

private func resolve(_ uiView: UIView) {
    guard let scroll = uiView.enclosingScrollView() else { return }
    DispatchQueue.main.async { onResolve(scroll) }   // ← 改 @State
}
```

`updateUIView` 每次 body 重算都会跑，每次都排 3 个任务，任务里又改 `@State`。

**已尝试的修复**：
- 第一次用 `Coordinator` 加标志 → **无效**，因为 `onResolve` 闭包每次 body 重算都是新值，SwiftUI 判定 representable 变了会重建 Coordinator，标志归零
- 第二次用 `static var` 跨实例标志 → 这一步执行后，看门狗开始能记录 `stall=`，说明**主线程不再被完全锁死**

### 循环 2：isClamping

```swift
// 文件：Sources/Views/ChatView.swift
@State private var isClamping = false

.onPreferenceChange(BottomYKey.self) { maxY in
    if !isClamping, ... {
        isClamping = true                                    // ← @State
        scroll.setContentOffset(...)                         // 又触发 onPreferenceChange
        DispatchQueue.main.async { isClamping = false }      // ← 再改一次
    }
}
```

**修复**：移到 `JumpButtonState`（引用类型的普通属性，非 `@Published`），改名 `clamping`。

### 循环 3：lastFollowAt

```swift
@State private var lastFollowAt = Date.distantPast

.onChange(of: model.streamTick) { _ in
    guard now.timeIntervalSince(lastFollowAt) > 0.15 else { return }
    lastFollowAt = now      // ← @State，触发 body 重算
    scrollToEnd(proxy)
}
```

**修复**：同样移到 `JumpButtonState.lastFollowAt`。

### 循环 4：uiScrollView

```swift
@State private var uiScrollView: UIScrollView?

ScrollViewAccessor { scroll in
    if let scroll, jump.scrollView !== scroll {
        jump.scrollView = scroll    // ← 赋值 @State → 重算 → updateUIView
    }
}
```

**修复**：移到 `JumpButtonState.scrollView`（`weak`，非 `@Published`）。

---

## 五、另一处真实性能问题（非死锁）

**历史回填占主线程 1 秒**。实测：

```
23:34:11.305  GET /v1/transcript → 服务端 25ms
23:34:13.164  stall=1032ms          ← 客户端用了 1 秒
```

`loadHistory()` 在 `beginBatch/endBatch` 里逐帧 `apply()`，几百帧的 JSON 解析全在主线程。服务端 25ms 返回，客户端处理要 1 秒。

**尚未修复**。建议方案：批处理里每 N 帧 `await Task.yield()` 让出主线程，或把纯解析部分移出 `@MainActor`。

---

## 六、诊断方法（可复用）

### 1. 主线程看门狗

```swift
// AppModel.startWatchdog() —— 现在每 2 秒落一行窗口统计
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    let gapMs = Int((now - lastHeartbeat) * 1000)
    if gapMs > 120 { stallCount += 1; worstGapMs = max(worstGapMs, gapMs) }
    // 每 8 拍（2 秒）
    pingDiagnostic("wd gap>120ms:\(stalls) max:\(worst)ms body:\(bodies)/2s pref:\(prefs)/2s")
}
```

| 字段 | 含义 |
|---|---|
| `gap>120ms:N` | 这 2 秒内主线程停顿超过 120ms 的次数 |
| `max:Xms` | 其中最长的一次 |
| `body:N/2s` | ChatView 的 `body` 求值次数（> 30/2s 就是每帧重算） |
| `pref:N/2s` | `onPreferenceChange` 触发次数（布局回调频率） |

**判读**：
- 一行 `wd` 都不出现 → 主线程被完全锁死，Timer 都停跑（真死锁）
- `gap>120ms:0`、body 也低 → 主线程干净，卡不在渲染侧
- 一堆 `gap` + 很高的 `body` → **失效风暴**：每次状态写入都让整棵树重算并重新布局
- `body` 不高但 `max` 很大 → 单次阻塞操作（回填、解析、同步 IO）

> 为什么把阈值从 1 秒改成 120ms：旧阈值下 2200 行日志里只有孤零零一条
> `stall=1032ms`。100~900ms 的抖动**从来没被量到**，「有时候卡一下」在旧数据里是隐形的。

### 2. 分步打点

在 `send()` 里 7 个位置打时间戳，发到 `/v1/health?d=...`，服务端落进 `bridge.log`。直接看出哪一步耗时。

### 3. 打点读取

```powershell
$log = "D:\Documents\deepseek-harness\dsh-phone-bridge\bridge.log"
Get-Content $log -Tail 400 | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } |
    Where-Object { $_.step -eq "diag" } | Select-Object -Last 20 |
    ForEach-Object { "$([datetime]$_.at)  $($_.d)" }
```

---

## 七、⭐ 当前代码状态：**半改，未编译**

> **⚠️ 这一节写的是接手前的状态，已过时。当前状态与结论见文末 §十二。**

这是最重要的一条，接手前必须先处理。

最近一轮尝试「彻底移除 UIKit 滚动」，改到一半停了。**已写入但未验证**的改动：

| 文件 | 改动 |
|---|---|
| `ChatView.swift` | 移除了 `ScrollViewAccessor` 探针 |
| `ChatView.swift` | 移除了 `onPreferenceChange` 里的越界 clamp |
| `ChatView.swift` | `scrollToEnd` / `jumpToBottom` 改成纯 SwiftUI `proxy.scrollTo` |
| `ChatView.swift` | 删除了 `confirmBottomThenUnfreeze` 整段 |

**残留引用未清理**（会编译报错或行为不一致）：

- `ChatView.swift:31` 注释里提到 `jump.scrollView`，但探针已删
- `AppModel.swift` 里 `freezeContent()` / `unfreezeContent()` / `isContentFrozen` 还在，但已无调用方
- `JumpButtonState` 里的 `scrollView` / `clamping` / `lastFollowAt` 已无人使用
- `ScrollViewAccessor.swift` 文件整体已无引用（可删除或保留）
- `ScrollViewAccessor.swift` 里的 `bottomOffsetY` / `stopDeceleration` / `scrollToBottomAnimated` 扩展也无引用

**最后一个成功构建的 commit**：`1b493cb`（2,431 KB IPA，含 static 标志修复 + 三处 @State 迁移）

**之后未提交的改动**：只有上面这批「简化滚动」的半成品，**在工作区里，没 commit**

---

## 八、建议的下一步（三个方向）

### 方向 A：完成简化（我原本在做的）

清掉残留引用，编译验证。**完全放弃 UIKit 滚动操作**，只用：

```swift
proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
```

**优点**：结构最简单，理论上不可能再有「读布局→写偏移→触发布局」的环
**代价**：惯性滚动中点击跳转按钮可能不灵敏（SwiftUI 的 scrollTo 会被减速动画覆盖，这是当初绕道 UIKit 的原因）

### 方向 B：回到 1b493cb，只修历史回填

`1b493cb` 是看门狗能记录 stall 的版本（死锁已解除）。只处理剩下的「历史回填占 1 秒」：

```swift
// loadHistory 的 apply 循环里
for (index, frame) in frames.enumerated() {
    apply(seq: index, frame: frame)
    if index % 40 == 0 { await Task.yield() }
}
```

### 方向 C：重构列表渲染

真正的问题是 `ChatView` 结构太深（`NavigationStack > GeometryReader > ScrollViewReader > VStack > ScrollView > LazyVStack > ForEach > ChatBubble`），任何状态变化都可能触发多层重算。

考虑：
- 把 `composer` 从 `ChatView.body` 里拆成独立 View（现在它是计算属性）
- 把滚动相关的 `onChange` / `onPreferenceChange` 收敛到单一入口
- 评估是否真的需要 `GeometryReader`（它会让整个子树在尺寸变化时重算）

---

## 九、踩过的坑（避免重复）

| 坑 | 教训 |
|---|---|
| `@State` 存在回调里被改的值 | 一律放进引用类型的普通属性 |
| `Coordinator` 放防重入标志 | 闭包变化会重建它，标志失效 → 用 `static` |
| `ScrollViewAccessor` 挂 `.background` | 不在 ScrollView 子视图链上，`enclosingScrollView()` 找不到 |
| 在跟随路径里 `layoutIfNeeded()` | 会打破 `LazyVStack` 的懒加载，几百条一次性布局 |
| `NSRegularExpression(pattern:)` 每帧调用 | 必须先编译成 `static let`，否则每次渲染重新编译 |
| 每次渲染都全文正则扫描 | 用 `MediaRefCache` 按文本缓存结果 |
| `scrollTo(anchor: .bottom)` 在内容末尾 | 会算偏，滚到「最新消息下面」的空白里（当初绕道 UIKit 的原因之一） |
| 消息显示两遍 | `send()` 本地乐观插入 + 服务端回显再插一次，要按「15 秒内同文本」去重 |

---

## 十、关键文件清单

```
ios/DSHRemote/Sources/
├── Views/
│   ├── ChatView.swift           ← 主战场，滚动/输入/列表都在这
│   ├── ChatBubble.swift         ← 已加 Equatable
│   ├── JumpButtonLayer.swift    ← JumpButtonState 里存运行时状态
│   ├── ScrollViewAccessor.swift ← 探针，当前已无引用
│   ├── RemoteImage.swift        ← 正则 static 缓存 + MediaRefCache
│   ├── RemoteMedia.swift        ← 视频/音频播放
│   └── MainView.swift           ← 看门狗启动点
├── Store/
│   └── AppModel.swift           ← send() 打点、loadHistory、refreshSessions
└── Net/
    └── BridgeClient.swift

bridge/
├── index.js                     ← /v1/health?d= 诊断通道
└── lib/events.js                ← 系统注入过滤
```

---

## 十一、如果继续诊断需要什么

建议在接手前先拿到这些东西：

1. **卡死时是「完全无响应」还是「能滚动但不能点」** —— 区分死锁和渲染阻塞
2. **卡死持续多久** —— 1 秒内 / 2-3 秒 / 一直不恢复
3. **是否和特定操作绑定** —— 只有发送时？滚动时？切换会话时？
4. **日志里有没有 `stall=`** —— 有说明 Timer 活着，没有说明彻底死锁

有了这四条，能大幅缩小范围。

---

## 十二、⭐ 本次接手：决策、改动、验证（2026-11-11 晚）

### 12.1 决策：选方向 A（完成简化），不回退 1b493cb

判据全部来自日志，不是偏好：

| 证据 | 说明 |
|---|---|
| `1b493cb` 已包含 4 条环的全部修复，**仍然卡** | 回退等于把一个已知还有问题的版本当基线 |
| 旧日志里 `tap:` 同一 payload 连发 10 次（18:52:51.316 → 52.666，间隔 ~200ms） | 这就是 `ScrollViewAccessor` 的 0.15/0.5/1.2 重试任务在跑，UIKit 探针这套机制**本身**会自喂 |
| 整套 UIKit 滚动只换来两件事：惯性中点击能跳、越界 clamp | 都是体验优化，而它带来的环已经让 App 卡死过 |
| `follow=0ms`（23:16~23:34 共 4 次） | 跟随路径**本身不花时间**，成本在下游布局，没被打点覆盖 |

所以：**彻底放弃 UIKit 滚动，只留 `proxy.scrollTo`**，然后把省下来的预算花在真正被量化的问题上。

### 12.2 本次改了什么

| 文件 | 改动 | 依据 |
|---|---|---|
| `Views/ScrollViewAccessor.swift` | **删除**（连同 `bottomOffsetY` / `stopDeceleration` / `scrollToBottomAnimated` 扩展） | 已无任何引用 |
| `Views/JumpButtonLayer.swift` | 删掉 `clamping` / `scrollView` 两个死属性 | clamp 路径已删，无人读 |
| `Views/ChatView.swift` | 删 `lastPhoneSendAt`（只写不读的 @State，每次发送白触发一次全量重算） | grep 只有声明与赋值 |
| `Views/ChatView.swift` | `scrollToEnd` / `jumpToBottom` / `onChange` / `onPreferenceChange` 里所有 `@Published` 写入**加等值判断** | `@Published` 赋同值也发 `objectWillChange`，而 ChatView 观察着 `jump`，等于每个 delta 白重算一次 |
| `Store/AppModel.swift` | 删掉 `freezeContent` / `unfreezeContent` / `isContentFrozen` / `frozenFrames` 及 `apply` 里的冻结分支 | 调用方随 UIKit 滚动一起删了 |
| `Store/AppModel.swift` | `loadHistory` **每 40 帧 `await Task.yield()`**，并回填期间关掉逐条裁剪、收尾裁一次 | 实测 1 秒全耗在这圈 `apply` 上；逐条裁剪还是 O(n²) |
| `Store/AppModel.swift` | `trimIfNeeded` 加 slack（cap+40 才裁） | 流式输出每个 delta 都走 `append` → 每帧一次 220 元素 filter |
| `Store/AppModel.swift` | 看门狗改成 120ms 阈值 + 每 2 秒一行 `wd`（含 body/pref 频率） | 旧阈值看不见 100~900ms 的抖动 |
| `Views/ChatView.swift` | `body` 里 `recordBodyEval()`；`onPreferenceChange` 里 `recordPrefEvent()` | 这两个数决定「失效风暴」还是「单次阻塞」 |
| `Views/ChatView.swift` | `submit()` 加 `render=` 打点（两跳 async 后测主线程何时空闲） | `s2-append=0ms` 说明数组插入不花时间，成本在插入后的渲染 |

### 12.3 验证协议（每次改动都照这个走）

**① 编译**：本机没有 macOS/Swift 工具链，编译只能在 CI 上做。推上去触发 `.github/workflows/ios.yml`，或本地 Mac 跑：

```powershell
cd ios\DSHRemote
xcodegen generate
xcodebuild -project DSHRemote.xcodeproj -scheme DSHRemote -configuration Release `
  -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

**② 装到手机后跑三个动作**（每个动作之间等 5 秒，方便在日志里切段落）：
1. 冷启动进 App
2. 切换一次会话（触发历史回填）
3. 发一条消息

**③ 读日志**（只要 `diag` 行）：

```powershell
$log = "D:\Documents\deepseek-harness\dsh-phone-bridge\bridge.log"
Get-Content $log -Tail 600 | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } |
  Where-Object { $_.step -eq "diag" } |
  ForEach-Object { $t=[datetime]$_.at; "{0}  {1}" -f $t.ToLocalTime().ToString('HH:mm:ss.fff'), $_.d }
```

**④ 看四个数**：

| 数 | 改之前 | 改之后应当是 |
|---|---|---|
| `hist ... worstChunk` | 一口气跑完，`stall=1032ms` | 每片 < 150ms，`total` 可以仍接近 1 秒 |
| `gap>120ms` | （旧阈值下看不到） | 回填期间应明显减少 |
| `body:N/2s` | （没有这个数） | 空闲时应接近 0；流式输出时约等于帧率 |
| `render=Xms` | （没有这个数） | < 100ms；若几百毫秒 → 主线程被渲染占住，问题在视图树 |

**⑤ 归属规则**：一次只改一组，跑完记下四个数再改下一组。数字没动就是没修对，不要叠加改动。

### 12.4 还没证明、下一步要量的

1. **「点发送瞬间冻结」在旧日志里根本没被量到**（唯一一条 stall 是回填）。`render=` 和 `wd` 就是为它加的。
2. 若 `render` 大而 `body` 不高 → 单条气泡首次渲染贵（`MarkdownText` / `RemoteImage` / `.textSelection`）。
3. 若 `body` 很高（> 30/2s）→ 失效风暴仍在：下一步把 `composer` 拆成独立 View，让输入框不再随列表重算（方向 C 的第一步，只动结构不动逻辑）。
4. 若一条 `wd` 都不来 + 界面冻住 → 真死锁，回到「主线程队列被灌满」的假设，重点查 `DispatchQueue.main.async` 的自我重排。

---

## 十三、⭐ 真凶抓到并修掉（2026-11-12 凌晨，commit 待补）

### 13.1 决定性证据

日志（`ee0c01e` 那版，每拍 0.25 秒上报回调活动）：

```
23:58:21.335  act b=2 p=75 f=0 last=pref     ← p ≈ 300 次/秒
23:58:30.007  act b=0 p=72 f=0 last=pref     ← p ≈ 288 次/秒
23:58:33.550  wd over>120ms:4 max:2824ms     ← 卡死 2.8 秒
```

`p` = `onPreferenceChange` 触发次数，`b` = `ChatView.body` 求值次数。

**p 冲到 200~300 次/秒，b 几乎为 0** —— 布局回调在自己喂自己，而 body 一次都没重算。
所以不是「写状态引起重算」那一类环（那类 b 会跟着涨），而是 **preference 机制本身自激**。

用户侧症状完全对得上：**打字时卡死、光标还在闪、App 内触控全失**。

### 13.2 机制

原实现在列表末尾放了一个哨兵，用 GeometryReader 上报它在命名坐标系里的位置：

```swift
Color.clear.frame(height: 1).id(bottomAnchor)
    .background(
        GeometryReader { geo in
            Color.clear.preference(key: BottomYKey.self,
                                   value: geo.frame(in: .named(scrollSpace)).maxY)
        }
    )
// 配合 .coordinateSpace(name: scrollSpace) 与 .onPreferenceChange(BottomYKey.self) { ... }
```

`GeometryReader` 为了算出「相对命名坐标系的坐标」必须在布局阶段反向请求布局，
而命名坐标系又依赖布局 —— 自己喂自己。输入框是 `TextField(axis: .vertical)`，
打字时高度一变、键盘一动就把它点着，于是每帧跑好几轮，主线程再也出不来。

> 注意：光标还在闪并不能证明主线程活着 —— 插入符闪烁由 Core Animation 维持。

### 13.3 修法

删掉 `BottomYKey` / `.coordinateSpace` / `.onPreferenceChange` 整条链，
「是否在底部」改由**手指手势**推断（零布局读取）：

```swift
.simultaneousGesture(
    DragGesture(minimumDistance: 12).onChanged { value in
        if value.translation.height > 12 {          // 往回看历史
            if jump.atBottom { jump.atBottom = false }
        } else if value.translation.height < -40 {  // 明显在往新消息方向滚
            if !jump.atBottom { jump.atBottom = true }
            if jump.hasNewBelow { jump.hasNewBelow = false }
        }
    }
)
```

配套：`jumpToBottom()` 里恢复 `atBottom = true`（否则点了按钮按钮还在），
`GeometryReader { outer in ... }` 改成 `_`（只为撑满高度，不再取视口尺寸）。

### 13.4 怎么确认修好了

复现同样的操作（**打字**、发消息、滚动），看日志：

| 观察点 | 修之前 | 修之后应当是 |
|---|---|---|
| `wd over>120ms` | `max:2824ms`、`1578ms`、`878ms` | 不再出现（或只偶尔一两百 ms） |
| `act b=` | 0~6 次/拍 | 空闲接近 0，流式时约等于帧率 |
| `act` 里的 `p` 字段 | 200~300 次/秒 | **该字段已删**（对应的机制不存在了） |
| `render=` | 113ms | < 100ms |

### 13.5 学到的（补进坑表）

| 坑 | 教训 |
|---|---|
| 在布局阶段读 `geo.frame(in: .named(...))` 再喂 preference | 命名坐标系本身依赖布局 → 自激。底部判定改用**手势**或 iOS 17+ 的 `scrollPosition` |
| 看门狗用 `gap > 阈值` 判卡顿 | `gap` 恒等于 Timer 周期，直接比绝对值必然误判，要比 `gap - 周期` |
| 主线程忙循环时的「光标还在闪」 | 光标闪烁是 CA 层的事，**不能**据此判断主线程活着 |
| 两秒汇总式的看门狗 | 死锁后什么都留不下来；必须有每拍（0.25s）就发的「遗言」 |

---

## 十四、版本考古：卡顿是从哪一版开始激增的（2026-11-12）

翻开发工作流的历史会话（`~/.dsh/sessions/…default-workspace…/session-90948fe0`，24.6 MB）
里的用户原话，按时间排，再与 git log 对照，能确定**问题不是一次性引入的 bug，
而是一条越修越坏的改造链**。

### 14.1 用户抱怨时间轴

| 时间 | 用户原话 |
|---|---|
| 11-11 16:40 | 还是没有显示而且**出现点击卡顿** |
| 17:04 | **图片消息传完后软件失去触控且卡死** |
| 17:22 | 切换会话「点不开」；惯性滑动中点跳转没反应 |
| 18:32 | 软件直接卡死 |
| 19:06 | 跳转没问题了，但是**现在卡** |
| 22:52–23:34 | 连续 9 次「发出消息一瞬间卡死 / 秒卡 / 又卡死」 |

### 14.2 对应的 commit 链（危险动作全部发生在「跟随」路径上）

```
17:31 40537a1 按钮挂到输入栏层
17:35 668fa8a composer 改成 ScrollView 的兄弟视图
17:40 994f6b8 跳到底之前先终止当前滚动
18:03 f9e3818 ← 分水岭：改为直接操作 UIScrollView（惯性中点按钮无效）
18:21 f6a7484 bottomOffsetY 公式多算 inset
18:24 b559aee isScrollEnabled 硬停减速
18:27 21f7876 定位后补几帧校准        ← 校准循环
18:32 65dde6b 卡死 —— 多帧校准与自动跟随互相触发   ← 已自认成环
18:44 4af797b 跟随补 layoutIfNeeded   ← 跟随路径强制全量布局
18:52 f3e398a 跳转改用 scrollRectToVisible
19:03 df89ab5 冻结内容→算高度→跳→解冻  ← 再加一层状态机
19:07 9fe0103 卡顿 —— clamp 自触发循环 + 跟随高频强制布局  ← 又一次自认成环
19:15 38901f1 自动跟随失效 —— 恢复 scrollToEnd 里的 layoutIfNeeded  ← 把刚删的加回来
```

到 19:15，**同一条每秒执行十几次的路径上**同时挂着：
强制布局、多次校准、越界夹取、冻结/解冻状态机。之后的所有「又卡死」都是它的表现。

### 14.3 结论（写下来避免重犯）

1. **滚动/跟随路径不允许出现「读布局 → 写状态/写偏移 → 触发布局」**。
   一次都不行，因为它每秒跑十几次，任何一次成环都会把主线程占满。
2. **不要为了「惯性中按钮点得动」这类体验细节去接管 UIScrollView**。
   代价是把整条渲染链交给自己维护，而这条链上的坑（校准、夹取、冻结）没有尽头。
   宁可接受「惯性中点按钮偶尔不灵」。
3. 判断「是否在底部」不要读布局：用**手势方向**推断（下拖 = 在看历史，
   上拖 = 想回底部），零布局读取，结构上不可能成环。
4. 主线程上的成本必须设上限：排版（CoreText）、正则、解析都要有字数阈值，
   超长内容默认折叠/截断，让用户点开再看。
5. 跨线程共享可变状态必须加锁 —— 特别是 `String`（引用计数类型），
   主线程写、后台读会随机 EXC_BAD_ACCESS 闪退。

### 14.4 当前状态（截至 bb3d613）

- 已有链全部拆除：`ScrollViewAccessor`、`freezeContent/unfreezeContent`、
  `BottomYKey`/`coordinateSpace`/`onPreferenceChange`、`layoutIfNeeded` 全部不在代码里
- 跟随 = `proxy.scrollTo(bottomAnchor)`；判底 = 手势
- markdown 解析在后台队列；长文本有 2000/4000/20000 字上限
- 观测：主线程看门狗（`wd over>`）+ 后台 StallWatcher（`STUCK … mark=`）
  卡死期间也能出证据


---

## 十五、当时最贵的一层：嵌套横向 ScrollView 的测量成本（2026-11-12 00:50，705ede1）

> 这一节写的是当时的判断。之后又暴露出三层（见 §十六），所以标题从「最终根因」改掉了 ——
> 卡顿是**分层掩盖**的，修掉一层，下一层才露出来。

### 15.1 决定性对比

| 版本 | 冷启动后最长停顿 | STUCK 条数 | 说明 |
|---|---|---|---|
| `9848edb.121` | 29824ms（另有 36632ms） | 63 | 已用 defaultScrollAnchor，os=26.6 |
| `705ede1.122` | **722ms** | **1** | 去掉嵌套横向 ScrollView |

### 15.2 根因

`MarkdownText` 里**每个代码块、每张表格都套了一层 `ScrollView(.horizontal)`**。
纵向 `LazyVStack` 做测量时，嵌套滚动容器要求完整布局 ——
一条消息里几个代码块就是几个滚动容器，20 条一起测量就是几十秒。

它伪装成「body 太慢」，实际是**测量**太慢；而三种滚动方式
（`proxy.scrollTo` / UIKit `setContentOffset` / `defaultScrollAnchor`）
**都会触发这个测量**，所以之前删哪条滚动路径都没用 —— 这就是连续十几轮
改错方向的原因。

### 15.3 修法

- 代码块：去掉 `ScrollView(.horizontal)`，改 `Text(...).fixedSize(horizontal: false, vertical: true)` 折行
- 表格：去掉横滑，直接用 `Grid`
- 未展开的消息预览 2000 → 600 字；主动展开封顶 8000 字
- 单会话条目上限 220 → 80

### 15.4 新增的取证能力（这次靠它收口）

- `build=<sha>.<run> os=<major>.<minor>`：每次连接上报，杜绝「不知道装的是哪版」
- 后台线程 `StallWatcher`：主线程卡住时仍能上报 `STUCK <ms> mark=<x>`，
  并按拍刷新（此前所有观测都挂在主线程，卡死期间零日志）
- 气泡级 mark：`b:ans` / `b:tool` / `b:think` / `b:user` / `b:fold` / `b:sys`，以及 `md`

### 15.5 仍未处理的次要项

- 单次会话刷新（`/v1/sessions` 偶发 800ms+）之后会连带一次 700ms 级的 ChatView 重算：
  `@EnvironmentObject` 会订阅整个 AppModel 的 `objectWillChange`，任何 `@Published`
  变化都会让 ChatView 重算一次。要根治需把 `sessions` 拆成独立 ObservableObject 或
  改成按需传递，收益是这 700ms，不是卡死级问题。
- 诊断打点目前在正常使用时仍偏密（`act` 每 0.25 秒一条），日志增长快。


---

## 十六、通宵踩坑总表（2026-11-12 01:55）

> 这一夜从「点发送卡死」查到「回车卡死」，先后挖出 **8 层**，
> 每一层都真实、都被实测数字钉住，但**每一层都不是全部**。
> 下面按「症状 → 当时看到的证据 → 真正的原因 → 修法」固化，
> 目的是别再从头走一遍。

### 16.1 卡死分层史（同一台机器、同一晚，最长停顿）

| 版本 | 最长停顿 | 当时最贵的一层 | mark |
|---|---|---|---|
| `1b493cb` | 死锁（Timer 停跑） | UIKit `ScrollViewAccessor` 重试风暴 + 四处 @State 环 | 无 |
| `26997be` | 1.0s→ 仍卡 | 底部判定 `GeometryReader`+`preference` 自激（300 次/秒） | `p=` |
| `d557047` | 21.6s | markdown 解析在主线程 | `body` |
| `65ed5ce` | 11.2s | 超长文本整段 `Text` 排版 | `body` |
| `9848edb` | 29.8s | `proxy.scrollTo` 强制全量测量 | `scroll` |
| `705ede1` | 0.7s | 嵌套横向 `ScrollView` 测量 | `b:tool` |
| `aa7516e` | 22s | 每个气泡各挂 `.sheet`（40 个宿主） | `body` |
| `deb7cbc` | 1.2s | `defaultScrollAnchor` 每帧重新锚定 | `body` |
| `68585f0` | 21s | `blocks` 未就绪时排整条原文 | `md` |
| `73813ca` | 1.76s | `DragGesture.onChanged` 每帧写 @State | `body` |
| `9f85a4e` | 待测 | `Block` 没有 Equatable → @State 赋值自激 | `body` |

### 16.2 SwiftUI 状态坑（**每一条都在真机上炸过**）

| 坑 | 为什么致命 | 正确做法 |
|---|---|---|
| `@State` 存**不可比较**的类型（如未声明 `Equatable` 的 enum） | SwiftUI 认为每次赋值都变了 → 无限重算 | `@State` 的类型必须 `Equatable`，并在赋值前比较 |
| 在**每帧回调**里写 `@State`/`@Published`（`DragGesture.onChanged`、`onPreferenceChange`、`updateUIView`） | 每帧一次全树重算，队列追不上 | 只在 `onEnded` / 值翻转时写；或用 `onScrollGeometryChange` 这类"只在变化时回调"的 API |
| 用 `GeometryReader` + `PreferenceKey` 上报滚动位置，再据此写状态 | 算相对坐标要反向请求布局 → 自激（实测 300 次/秒） | 位置判定用手势或 `onScrollGeometryChange`，**不读布局** |
| `@Published` 赋同值 | 一样发 `objectWillChange`，白重算 | 赋值前 guard（`if x != new`） |
| `@EnvironmentObject` 订阅**整个**对象 | 任何无关 `@Published` 变化都让大视图重算（实测 700ms） | 把高频/无关状态拆进独立 `ObservableObject`（如 `SessionListStore`） |
| 每个列表项各挂一个 `.sheet` | 每个都是 presentation 宿主（40 个直接卡死） | sheet 收到父层用一次，子项通过环境里的 presenter 触发 |

### 16.3 SwiftUI 布局/渲染成本坑

| 坑 | 代价 | 正确做法 |
|---|---|---|
| 纵向 `LazyVStack` 里嵌 `ScrollView(.horizontal)`（代码块/表格） | 测量要完整布局，20 条 = 30 秒 | 折行 / `Grid`，不嵌滚动容器 |
| `AttributedString(markdown:)` 每次求值都算 | 单次 ~100ms × 段落数 × 每秒十几次 | 按原文缓存 + 后台预解析 |
| `blocks` 未就绪时渲染 `Text(raw)` 整条回答 | 每次重算排全文（21 秒） | 占位 `"…"`，解析好再换 |
| `.lineLimit(1)` 以为能省排版 | **不减成本**，Text 仍排全文 | 渲染前截断字符串 |
| 长文本进列表（工具详情几万字符） | 每次布局重排 | 移到 sheet，列表只放短摘要 |
| 单会话条目无上限 | 布局成本随条目数增长 | 硬上限（现在 10 条可见，更早折叠） |
| 三种"贴底"写法都会触发全量测量 | `scrollTo` / `setContentOffset` / `defaultScrollAnchor` | 跟随节流 ≥500ms；不要每帧贴底 |

### 16.4 观测方法坑（**先有观测，才有方向**）

| 坑 | 后果 | 正确做法 |
|---|---|---|
| 所有打点都挂在主线程 Timer 上 | 卡死期间零日志，完全瞎 | 后台线程 `StallWatcher`：心跳 0.1s，>0.7s 就上报 `STUCK <ms> mark=` |
| 看门狗用 `gap > 阈值` 判卡顿 | `gap` 恒等于 Timer 周期，每拍都误报 | 比较 `gap - 周期`（`over`） |
| 只有粗粒度 mark（`body`/`scroll`） | `body` 涵盖整个布局阶段，等于没说 | 分到气泡类型 `b:tool` / `b:ans`，以及 `md`、`apply:<帧类型>`、`img:*` |
| 不知道手机上装的是哪一版 | 连续几轮把已修的问题当新问题查 | Info.plist 注入 `MARKETING_VERSION=<sha>` + `CURRENT_VERSION=<run>`，连上就报 `build=xxx.132 os=26.6` |
| 只看"卡了多久" | 分不清"单次慢"和"重算风暴" | 心跳带计数：`hb body= bubble= follow= send=`（bubble≫body=风暴；都低但 worst 高=单次慢） |

### 16.5 工程流程坑

| 坑 | 教训 |
|---|---|
| 没确认版本就开始改 | 每轮先看 `build=`；没有它就先加它 |
| 一次改 3-5 处 | 症状会换地方，无法归因；一次一组 |
| 用"真凶/最终根因"描述中间层 | 会造成误判和返工；只说"当前最贵的一层是多少 ms" |
| 拿"光标还在闪"判断主线程活着 | 插入符由 Core Animation 维持，**与主线程无关** |
| 直接解压正在写入的会话 `.jsonl.zstd` 做分析 | 虽然只读，但对活跃文件做解析没必要，且容易引出读写竞态误判（`SessionFormatError`）。要考古走 bridge 接口 |
| 把 `loadHistory` 的一次失败当真 | `/v1/transcript` 走内存快照，写者更新到一半会瞬时校验失败；应重试 2-3 次 |

### 16.6 当前状态与后续

**已稳**（`9f85a4e` 之前实测：最长 1.2s，发送 `render≈75ms`/`s9≈240ms`）：
- 发送 / 打字 / 上划的手势坑已修
- 会话列表与聊天树解耦；未选中会话不加载内容但保留运行态与未读提示

**待办**：
1. 首次布局 ~1.2s（`composer` 改 `safeAreaInset` 或继续拆子视图）
2. `comfy` 从 AppModel 拆出（每 8 秒一次状态轮询会让 ChatView 重算）
3. 运行日志：手机本地滚动日志 → 攒够走 bridge 上传 → `logDir` 可配 → 传完删本地
