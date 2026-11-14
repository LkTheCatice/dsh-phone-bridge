# UI 复刻包（用于宣传片录制）

一个单文件网页，把手机端 DSH Helm 的界面与交互按真实数值复刻。
**所有尺寸/字号/颜色都取自 iOS 源码**，不要凭感觉改数值——改了就和真机对不上了。

```
docs/ui-demo/
├── index.html     ← 单文件复刻（无外部依赖，双击即可打开）
├── record.mjs     ← Playwright 录屏/截图脚本（可选）
└── README.md      ← 本文件
```

打开方式：浏览器直接打开 `index.html`；右侧面板可逐个触发场景。
加 `?autoplay=1` 会自动跑完整流程（约 9 秒），适合直接录屏。

---

## 一、设计令牌（与代码一一对应）

| 元素 | 数值 | 代码位置 |
|---|---|---|
| 系统背景 | `#FFFFFF` | `systemBackground` |
| 次级背景（AI 气泡） | `#F2F2F7` | `secondarySystemBackground` |
| 填充色（卡片） | `rgba(118,118,128,.12)` | `tertiarySystemFill` |
| 主题色 | `#0A84FF` | `accentColor` |
| 主文字 | `#000` | `label` |
| 次文字 | `rgba(60,60,67,.6)` | `secondaryLabel` |
| 三级文字 | `rgba(60,60,67,.3)` | `tertiaryLabel` |
| 用户气泡底色 | `rgba(10,132,255,.11)` | `tintColor.withAlphaComponent(0.11)` |
| 气泡圆角 | 14pt，内边距 左右 10 / 上下 6 | `MessageCell` init |
| 用户消息左边界 | 56pt | `leadingConstraint` |
| 正文 | 16pt，行高 1.5 | `MessageRender` default |
| 前缀（▍我 / ▍AI） | 12pt semibold，段后 7pt | `MessageRender.prefix` |
| log 行（工具/思考） | **等宽 12pt**，secondaryLabel，行首 `> ` | `.toolCall` / `.thinking` |
| 思考行行数 | 2 行，第 2 行放不下才省略 | `textContainer.maximumNumberOfLines = 2` |
| 思考显示内容 | 取**开头** 240 字 | `.thinking` 分支 |
| 卡片（产物/折叠） | 圆角 9，内边距 上下 8 / 左右 12，最小高 32，字 13 medium | `FileChipView` |
| 折叠卡片颜色 | 主题色 + `▸ 本轮过程 · N 步 ›` | `.collapsedSteps` |
| 产物卡片 | 正文色 + `📄 输出文件 · 文件名` | `.fileOutput` |
| 系统行（本轮结束等） | 10.5pt，secondaryLabel 55% | `.system` |
| 底部状态栏 | 两行，10.5pt，圆点 6pt | `BottomBar` |
| 页签按钮 | 58×36，胶囊；选中底色主题色 12% | `BottomBar.tabButton` |
| 开屏停留 | **2.3s**（上限 3.5s），淡出 0.5s | `LaunchOverlay` |
| 开屏图标 | 圆圈 96pt（主题色 14%），符号 38pt；第一帧就可见，仅 0.94→1 缩放 | `LaunchOverlay` |
| 本轮过程页 | `insetGrouped` 列表；行高≈44；序号等宽 11 三级灰 | `TurnLogSheet` |

字体：`-apple-system, "SF Pro Text", "PingFang SC"` ——
在 macOS 上完全等于真机；Windows 会回退到 Segoe UI / 微软雅黑，观感略硬，
若要 1:1，装 **SF Pro** 字体或直接在 Mac 上录。

---

## 二、导演 API（给脚本/另一个会话用）

页面里挂了全局 `Demo`，每个方法返回 Promise，按顺序 `await` 即得到稳定画面：

```js
await Demo.replayLaunch();            // 开屏 2.3s + 淡出 0.5s
await Demo.askUser('我看下今天的改动'); // 我发一条消息（右侧气泡）
await Demo.streamThinking();           // 思考行流式，两行截断
await Demo.streamTools();              // 工具行逐条出现
await Demo.streamAnswer();             // AI 回答（标题/代码块/表格块）
await Demo.finishTurn();               // 过程行收成 ▸ 本轮过程 · N 步 ›
await Demo.openTurnLog();              // 打开「本轮过程」页
await Demo.openStep(2);                // 点开第 2 步（带图的那一步）
Demo.closeDetail(); Demo.closeTurnLog();
await Demo.autoPlay(1);                // 一键跑完整流程（参数=倍速）
```

细节可覆盖：

```js
await Demo.replayLaunch({ dwell: 3000 });                       // 拉长停留
await Demo.streamTools([['读取','a.jpg'], ['运行命令','build']]); // 自定义行
await Demo.finishTurn({ steps: 12, seconds: '5 分 08 秒' });
await Demo.openStep(2, false);                                   // 不带图片的详情
```

---

## 三、录屏做法

### A. 直接用浏览器录（最快）
1. Chrome 打开 `index.html`，窗口缩放到 **200%**
2. 用 OBS「窗口采集」只框住手机那一块（393×852，200% 下是 786×1704）
3. 点右下「▶ 自动播完整流程」

### B. Playwright（推荐，画面稳定、可反复出片）
```bash
npm i -D playwright && npx playwright install chromium
node docs/ui-demo/record.mjs            # 输出 docs/ui-demo/out/*.webm 与关键帧 png
```

`record.mjs` 会把**手机框**（不是整页）单独录下来，
并按分镜在关键节点抓 png，方便后期贴字幕。

---

## 四、宣传片分镜建议（约 20 秒）

| 时间 | 画面 | 对应 API |
|---|---|---|
| 0.0–2.8s | 开屏：图标 + DSH Helm | `replayLaunch()` |
| 2.8–4.0s | 我在手机上发一句 | `askUser()` |
| 4.0–7.0s | 思考行出现（两行截断） | `streamThinking()` |
| 7.0–10.0s | 工具行一条条落下 | `streamTools()` |
| 10–14s | AI 回答 + 代码块/表格 | `streamAnswer()` |
| 14–16s | 收尾折叠成一张卡片 | `finishTurn()` |
| 16–18s | 点开「本轮过程」，逐条可点 | `openTurnLog()` |
| 18–20s | 点某一步 → 参数/结果/**它读过的图** | `openStep(2)` |

字幕文案可选（与代码事实一致）：
- 「过程不丢：结束后折成一行，随时回看每一步」
- 「它看过的图，点开就能看见」
- 「冷启动直接停在最新一条」

---

## 五、注意

- 这是**纯前端复刻**，不连后端、不发消息；只用来出画面。
- 别在画面里露出右侧控制面板（用 OBS 框选或 Playwright 的 `elementHandle.screenshot()`）。
- 真机截图的暗色模式未复刻（当前版本 App 跟随系统，但复刻包只有浅色）。
