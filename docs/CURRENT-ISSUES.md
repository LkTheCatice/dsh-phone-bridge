# 当前问题清单（换工作流前的交接）

> 时间：2026-11-12 23:00 左右
> 手机上装的包：`69762a2.46`（22:54 构建成功）
> 之后又有两个提交没打包，见下文。

---

## 一、等你验证的（已在代码里，但没装机）

这两个提交 **`d3b1dd5` / `c477d83` 只提交了、没构建**：

| 提交 | 改动 | 你要看什么 |
|---|---|---|
| `d3b1dd5` | 余额按 currency 去重 | 是不是只剩一行 |
| `d3b1dd5` | 加载收紧 200/120 帧 | 上划还卡不卡 |
| `d3b1dd5` | 桥：过滤后台命令回显 | **要重启 DSH** 才生效，App 不用重装 |
| `c477d83` | 插队标记执行后清除 | 「已插队，等当前任务完成」会不会消失 |

**上一版修了但你没确认的**（在 `69762a2.46` 里）：

- 余额两位小数 —— 你反馈**还是两行**，但那版的对 key 用的是 `isBonus+currency`，根因在 `d3b1dd5` 才修
- 上划加载 —— 你反馈**卡顿**，那是 400/300 帧太大，`d3b1dd5` 收到 200/120

---

## 二、没查明白的

### 1. 「我的回答在手机端消失」

我发的某条回答（讲余额/卡顿那次）在手机上整条不见了。

**已排除**：
- `TEXT_LIMIT` 是 32KB，那条远没到
- `assistant.delta` 分支正常走 `clip(text, TEXT_LIMIT)`

**可能**：
- 被 `foldSteps` 折进「▸ 本轮过程」了（点开能展开，不是真消失）
- 或者渲染层问题（`NSAttributedString` 生成了空内容）

**需要**：确认是哪一条、点「本轮过程」能不能展开。

### 2. `mark=body` 仍有 1.2~1.8 秒停顿

拆了三个 store（Chat / Comfy / Wallet），`AppModel` 还有 23 个 `@Published`。
继续拆的方向：`ConnectionStore`（phase / pairing / serverInfo / lastError）、
`SettingsStore`（exp* / sendMode / richTextEnabled）。

**注意**：拆的时候必须检查**所有订阅者都注入了** `environmentObject`，
否则点进去直接闪退（`WalletStore` 那次就是这样，编译期查不出来）。

### 3. 余额能不能真拿到数字

`getBalance(client)` 已补 client 参数（version / locale / timezoneOffsetSeconds），
但**没确认是否真的返回数字**。如果 DSH 还有别的初始化依赖，就维持
「已登录（凭据已存储）+ 用量页链接」的兜底显示。

### 4. 视频封面 `poster` 从未触发

代码在（ffmpeg 抽帧），日志里一次都没出现过 —— 因为一直没滑到视频消息。
不是 bug，是没测到。

---

## 三、构建渠道的现状（这是换工作流的主要原因）

### GitHub Actions：目前不可用

| 环节 | 状态 |
|---|---|
| 页面 | 私有仓库，需登录 |
| 日志 | **BlobNotFound**（存储侧丢了） |
| artifacts | 0 个 |
| annotations | API 404（网页能看） |

**网页上的注解说明了真正原因**：

```
❌ The job was not acquired by Runner of type hosted even after multiple attempts
ℹ️ Due to capacity constraints, jobs targeting macOS arm64 runners 
   may experience longer queue times.        （重复 3 次）
❌ Internal server error. Correlation ID: 0d68f616-...
```

→ **macOS runner 容量不足，反复分配失败，最后取消**。不是额度、不是代码。

### Codemagic：能成功，但排队不可控

| 时间 | 等待 | 结果 |
|---|---|---|
| 下午几次 | 2~5 分钟 | 成功，13~20 分钟跑完 |
| 21:42 | 40 分钟没开始（取消） | — |
| 22:29 | ~25 分钟 | **成功**（`69762a2.46`） |

**它的失败日志是可用的**（artefact 里有 `errors.txt`），不像 GitHub 那套会丢 blob。

### 已改

`on: push` → `workflow_dispatch` 只手动触发 + `concurrency` 防堆叠。
以后 push 不会再偷偷烧 GitHub 的 macOS 额度。

---

## 四、建议的新工作流

### 构建

1. **只走 Codemagic**，GitHub Actions 完全不用
2. **改完一次性提交**，不要每改一处就 push（减少触发次数）
3. 触发后**等 3 分钟看有没有开始跑**；超过 15 分钟没动就取消重试
4. 构建前先跑本地检查（见下）

### 本地检查（提交前必做）

```powershell
cd phone-dsh\tools\selftest
.\run.ps1                                    # 188 项断言
swiftc -parse <每个 .swift 文件>              # 语法
```

**纯数据模型还能做真实类型检查**（这次新摸索出来的，很有用）：

```powershell
# 抽出 ChatEntry / SessionRow 等纯数据模型 + 写探针真实调用构造点
swiftc -typecheck models_only.swift probe.swift
```

需要 UIKit 的那部分（ChatList / ChatView / MarkdownNS）本地无解，
只能靠 CI —— 所以**一次改动越小越好**。

### 验证节奏

- **一次只改一类**，改完看到数字/现象变化才算修对
- 手机装完先看 `bridge.log` 里的 `build=`，确认版本对不对（别猜）
- 遇到「方法加了但没生效」，**先确认调用点是否真的改了** ——
  我今天在 `formatMoney`、`walletUsageUrl`、`steering` 上连犯三次同样的错

---

## 五、TODO 里还剩什么

| 量级 | 项目 |
|---|---|
| 中 | 消息长按菜单（复制/引用/重发） |
| 中 | 手机上管设备（`/admin/devices*` 要先解决鉴权） |
| 小 | 从相册直接粘贴图片 |
| 小 | 会话列表相对时间缓存（`cwdName` 已预计算） |
| 小 | 输入框多行展开 |
| 小 | 图片缓存落盘（现在只有内存 LRU，重启后全重下） |
| 小 | 免费签名 7 天过期提醒 |
| 等 key | Bark 完成通知（`notify.kind/server/key` 三项全空） |

**模型推理强度已经做完了**（`Models.swift` 的 `ReasoningEffort` +
`ModelPickerSheet` 的 `EffortPickerSheet`），TODO 里那条可以划掉。
