# 工程约定（本项目的硬性规则）

> 起因：2026-11-12 通宵排查「发送/打字/滚动卡死」，用了 20 多个版本才定位到
> **不是某处慢，而是渲染结构选错了实现方式**。以下规则是为了不再重犯。

## 0. 最高优先：优先成熟的、适配度高的方案

**任何新功能，先问「这个场景在 iOS 上的标准做法是什么」，再动手。**

不要因为"SwiftUI 顺手"就用 SwiftUI 硬扛它不擅长的场景；也不要自创机制去绕系统行为。

具体到本项目已经踩过的坑：

| 场景 | ❌ 不要用 | ✅ 用成熟方案 |
|---|---|---|
| 长列表（聊天/文件/会话） | `SwiftUI LazyVStack`（无 cell 复用） | `UICollectionView`/`UITableView` + cell 复用 + diffable data source |
| 一条消息的富文本 | 拆成 N 个 `SwiftUI Text`（每 block 一个） | **一个** `UITextView`/`UILabel` + 一个 `NSAttributedString`（TextKit 排一次） |
| 输入区高度变化 | 与列表同一个 `VStack`（整表重排） | `.safeAreaInset(edge: .bottom)`，或独立于列表的容器 |
| 滚动到底 / 跟随 | 手工 `setContentOffset`、`layoutIfNeeded`、`isScrollEnabled` 掐惯性、preference 上报位置 | `scrollToItem(animated:)` + `scrollViewDidScroll` 判定 |
| 长文本渲染 | 一次排版几万字 | 截断 + 分段 + 按需展开（手风琴：同时只展开一条） |
| 高频状态 | 一个大 `ObservableObject` 被所有视图 `@EnvironmentObject` 订阅 | 拆小 store，视图只订阅自己要的那一个 |
| 跨线程共享 String | 直接读写 | 加锁（NSLock）或改整数编码，否则会随机 `EXC_BAD_ACCESS` |

## 1. 渲染结构的三条红线

1. **一条消息 = 一个视图**。不许因为"代码块/表格/列表"就拆成多个子视图。
2. **列表的滚动成本必须与消息总数无关**（靠 cell 复用，不靠"少加载"）。
3. **不许在 body / 每帧回调里做重活**：解析、正则、排版、JSON、加锁都要移到后台或加缓存。

## 2. 状态与更新

- `@State` 的类型必须 `Equatable`（否则赋值同值也会触发重算 → 自激）。
- `@StateObject` 会让**宿主视图**订阅该对象（与是否读属性无关）；只需要局部刷新时用 `@State` 持有引用 + 子视图 `@ObservedObject`。
- 每帧回调（`onChanged` / `onPreferenceChange` / `updateUIView`）里**不许写状态**；只在 `onEnded` 或值真正翻转时写。
- `@Published` 赋值前先比较，避免无意义通知。
- 不在布局阶段读布局（`GeometryReader` + `PreferenceKey` 上报滚动位置 = 自激，实测 300 次/秒）。

## 3. 本地验证（提交前必须做）

这台开发机是 Windows，没有 Xcode / iOS 模拟器。但 **Foundation 层可以在本地编译并运行**：

```powershell
cd phone-dsh\tools\selftest
.\run.ps1          # 87 项断言，全绿才算通过
```

- 测的是项目里的**真实文件**（`ios/DSHRemote/Sources/Core/MarkdownModel.swift`），不是副本
- 覆盖：解析器边界输入、解析分类、`NSRange` 多轮替换、按 id 去重、行内标记清理
- **改这些逻辑前先跑、改完再跑**；跑不过不许提交（今晚两次真机崩溃都在这一层）
- UIKit/SwiftUI 的行为本地测不了（cell 布局、body 求值频率、键盘），
  那部分要求：一次只改一处 + CI 编译通过 + 真机只看 `STUCK`/`hb` 两个数

**两个本地能做的补充检查**（省一轮往返）：

1. **语法检查全部文件**（不需要 SDK，能抓括号/拼写破损）：
   ```powershell
   swiftc -parse <每个 .swift 文件>
   ```
2. **符号引用交叉检查**：删文件/改类型后，`grep` 已删符号名，确认零引用；
   再从定义处确认被抽出的符号都还在。

**CI 状态可能滞后**：`gh run list` 显示 `queued` 时，`gh run download <id>` 可能已经能拿到
artifact —— **artifact 存在就等于构建成功**（失败的话该步骤不会产出）。
2026-11-12 就碰到过排队卡 45 分钟但产物早已生成的情况。

### 批量改代码时的一个坑（今天犯了三次）

用脚本按「起止标记」替换 `switch` 里的某个 `case` 时，很容易把 **`switch` 的收尾 `}` 一起吃掉**，
结果是后面所有类型都被吞进函数内部，报 `static methods may only be declared on a type`。

**规则**：脚本替换后必须做一次括号深度校对，再提交。

```python
depth = 0
for i, l in enumerate(lines, 1):
    depth += l.count("{") - l.count("}")
    if depth < 0: print("负深度于", i)      # 说明多吃了 }
print("最终深度:", depth)                    # 必须是 0
```

注意：这个粗算会把**注释和字符串里的 `{`** 算进去（`ToolSummary.swift` 就误报过），
所以「深度 0 + `swiftc -parse` 通过」两个条件都要满足才算过。

## 4. 观测与验证（改任何渲染相关代码都要按这个来）

- 连上电脑后第一行日志必须是 `build=<sha>.<run> os=<ver>` —— **不知道版本就没法归因**。
- 后台 `StallWatcher` 会报 `STUCK <ms> mark=<x>`；`mark` 指明主线程最后进入的路径。
- 心跳 `hb body= bubble= follow= send=`：
  - `bubble` 远大于 `body` → 重算风暴
  - 都低但 `worst` 高 → 单次成本高
- **一次只改一类**。改完必须看到数字变化，否则视为没修对。
- 记住：`mark` 只说明"最后进入哪里"，不说明"为什么慢"；能定因果的只有对照实验（同一设备、同一消息量、单一变量）。

## 5. 不做的事

- 不为修「惯性中按钮点不动」这类体验细节，去接管 `UIScrollView` 内部（17:35 那次结构改动导致后面所有卡死）。
- 不用降级（纯文本、限制条数）当最终方案 —— 只能是临时止血，且必须记 TODO。
- 不在用户可见的流程里留「半改未编译」状态；要么编译通过，要么回滚到 tag。

## 6. 回滚点

| tag | 说明 |
|---|---|
| `legacy-ok` | 2026-11-12 03:00 的可用版本（markdown 可关、纯文本默认、功能完整） |

## 7. 接口不确定就逆向，别猜（2026-11-12 的教训）

为了调通 DSH 的 `sessionController.updateQueue`，我**猜了七轮**参数形状：

```
第 1 轮  { target, start, removedCount, inserted }        → 失败
第 2 轮  加 kind: "splice" / "inbox" / "update"           → 失败
第 3 轮  加 op: "splice"                                   → 失败
第 4 轮  { sessionId, request: {...} }                     → 失败
第 5 轮  target 改成 { kind: "next-turn" } 对象            → 失败
```

每轮都报同一句：`Cannot read properties of undefined (reading 'kind')`。
中间还让用户重启了 DSH 五六次、点了十几次按钮。

**真相**：直接读 `app.asar` 里的 zod schema，3 分钟就看到：

```js
updateQueue({
  sessionId: string,
  itemId:    string,
  action: { kind: "edit", content: [{type:"text",text}] }
        | { kind: "remove" }
        | { kind: "steer" }
})
```

那个 `reading 'kind'` 就是在读 `action.kind` —— 我**从未传过 `action`**，
一直按事件里的 `{target,start,removedCount,inserted}` 在猜，
而那是**事件的结构**，不是 API 的参数。

### 规则

接口不确定时（DSH、任何打包过的依赖）：

1. **直接在包里搜符号名**。asar 是明文拼接，Python 二进制搜索即可定位：
   ```python
   data = open(asar, "rb").read()
   for m in re.finditer(b"updateQueue", data):
       print(data[m.start()-600:m.start()+900].decode("utf-8","ignore"))
   ```
2. 找到 **zod schema / 类型定义 / 函数体**，照着返回值写调用。
3. 只有在包是加密/混淆、且搜不到时才考虑试探，而且**一次只试一种**。

**成本对比**：猜测七轮 ≈ 两小时 + 用户十几次点击；读源码 3 分钟。

### 同类参照

- 余额接口 `getBalance()` 报 `reading 'version'` —— 也是靠 **stack 里的
  `platformClientHeaders（index.js:73）`** 一句话定位，而不是猜。
- 后续任何「方法存在但调用报 undefined」的情况，先看 **stack**，
  再进包里搜那个函数。
