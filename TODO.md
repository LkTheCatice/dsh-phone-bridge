# 待做清单

> 更新：2026-11-14 12:15
> 当前包：`64b86c7.134`
> 已落地：产物清单卡 · 文件/文本转发 · 长按菜单 · 会话内搜索 · 全屏写指令 · 「处理中」标记 ·
> 断帧提示 · 签名到期可见 · 入口合并 · 产物图片标注（画笔）· 图片缓存落盘 · 粘贴图片 ·
> 会话列表时间预计算 · 安全与隐私自测 19/19

---

## 一、剩下要做的

### A. 功能缺口

> 2026-11-14 二次核对，已实现并从待办移除：
> #2 图片编辑（画笔，PencilKit 画布早就有，本轮补了产物图片的入口）、
> #3 模型推理强度（ModelPickerSheet 展开档位）、
> #7 粘贴图片（「+」菜单读剪贴板）、
> #8 会话列表时间（改成解析时算好的 `timeLabel`）、
> #10 图片缓存落盘（`Caches/thumbs`）、
> #12 签名到期提醒（SigningInfo + 两端显示）。


| # | 项目 | 现状 / 卡点 | 量级 |
|---|---|---|---|
| 4 | **手机上管设备** | 拉黑/批准只在 DSH 设置页。`/admin/devices*` 是本机免 token 的，搬进 App 要先解决鉴权 | 中 |
| 5 | **Bark 完成通知** | `cordis.patch.yml` 的 `notify.kind / server / key` 三项全空，等 key | 小 |

### B. 体验优化（新的四条）

| # | 项目 | 现状 | 量级 |
|---|---|---|---|
| 16 | 导出对话 | 只能看，不能存成 Markdown / 文本分享 | 中 |
| 17 | 转发时自动附上下文 | 现在只有「来自哪个会话」，没有轮次/时间 | 小 |
| 18 | 产物清单卡按类型分组 | 图片/文档/安装包混排，8 行装不下更多信息 | 中 |
| 19 | 会话列表行缓存 | `cwd` 解析已在 store 侧，剩下滚动时的字符串拼接 | 小 |

### C. 稳定性 / 工程

| # | 项目 | 说明 | 量级 |
|---|---|---|---|
| 13 | Sideloadly 受系统代理影响 | 系统代理指向 `127.0.0.1:7892`，Clash 没开时直接 `ProxyError` | 环境问题 |
| 14 | `git push` 偶发静默失败 | 已改走 SSH（`ssh.github.com:443`）；推送后用 `rev-parse` 校验 | 环境问题 |

---

---

## 一·五、功能请求（2026-11-14 提出）

### 15. 产物文件「转发到另一个会话」 ✅ 已实现（2026-11-14）

> 实现说明：`/v1/session/forward` 同时支持 `path`（文件，走白名单校验）与 `text`（文本）；
> 手机端入口 = 长按任意消息 + 产物预览页右上纸飞机；3 秒幂等去重。
> 下面保留的是最初的需求描述，供追溯。

**动机**：DSH 里经常是多个会话分工，有时它们需要协作 ——
一个会话产出的文件（文档 / 图片 / 安装包 / 压缩包…）要交给另一个会话继续处理。
现在只能自己记路径、切会话、重新打字。

**入口**
- 产物文件打开页（`FileOutputSheet`）右上菜单：`转发到会话…`
- 产物卡片（`📄 输出文件 · xxx`）长按：同样的菜单（不进预览页也能转）
- **对手机不能预览 / 不能下载的类型同样可用** —— 这条最关键：`.dmg/.exe/.msi/.7z`
  之类手机根本打不开，但只要能引用路径就能转发

**交互**
1. 弹出会话选择器（当前工作区，排除当前会话，带搜索，显示最近活动时间）
2. 选中后可附一句说明（自由文本，可空）
3. 发送 → 目标会话里出现一条**用户消息**：
   ```text
   [转发] 来自「<源会话标题>」

   /abs/path/to/file.ipa

   <可选说明>
   ```
4. 默认消息体只放**路径引用**，不重传文件；需要模型直接处理时由用户补一句
   「把上面这个文件当输入」，或者选择器里勾选「附一句指令」

**为什么用路径引用而不是重传**
- DSH 与文件在同一台电脑上：路径对两个会话都有效，重传是纯浪费
- 大文件（ipa/dmg/视频）走手机中转会卡在 `maxFileBytes` 与移动网络
- 手机端也不需要先把文件下载下来才能转发（不可预览类型尤其重要）

**接口（桥）**
```http
POST /v1/session/forward
{ "fromSessionId": "...", "toSessionId": "...", "path": "D:/.../x.ipa", "note": "顺便看下这个包的 Info.plist" }
→ { "ok": true, "messageId": "..." }
```
- 复用 `/v1/answer` 的发送链路（`ctrl.create` 已有会话则跳过创建 → `send`）
- `path` 过 `safeFs` 白名单校验；不在白名单直接 400（提示哪个根可用）
- 幂等：同 `(toSessionId, path, note)` 3 秒内只发一次（防连点）

**手机端**
- `FileOutputSheet`：加 `转发`；`MessageCell` 的产物卡片：加长按菜单
- 新建 `ForwardSessionSheet`（会话列表 + 搜索 + 说明输入 + 「附指令」开关）
- 失败提示：目标会话不存在 / 路径不在白名单 / 未连接

**边界**
- 跨机器不支持（路径只在同一台电脑上有效）
- 转发的是**引用**：源文件被删/改名后目标会话里的路径会失效 —— 消息里带一句
  「（路径可能已失效）」的可行性留给实现时判断
- 不新建会话：只能转发到已存在的会话（新建走「新建对话」）

**量级**：中（桥 1 个接口 + 手机端 1 个 sheet + 2 处入口）

---

## 一·六、2026-11-14 完成（本轮）

| 项目 | 关键点 |
|---|---|
| **产物清单卡** | 一轮产出合成一张卡；8 行 + 「查看全部」（FileSummarySheet） |
| **转发（文件 / 文本）** | 长按任意消息 → 转发；产物转路径引用，文本转内容；桥端 `/v1/session/forward` 支持 `text` |
| **长按菜单** | 复制 / 引用到输入框 / 转发；UIContextMenuInteraction，不抢文本选择 |
| **会话内搜索** | 右上菜单「搜索消息」，命中片段 + 点击滚动定位（scrollToId） |
| **全屏写指令** | 输入框旁 ⤢，整屏 TextEditor 绑定同一 draft |
| **「处理中」标记** | turn.start 点亮本轮那条「我」，turn.end 撤销 |
| **断帧提示** | 帧缓冲 3000→12000；缺口发 `stream.gap`，手机显示"离线期间有 N 条未送达" |
| **签名到期可见** | 手机读 embedded.mobileprovision 报给电脑；两端都显示还剩几天 |
| **入口合并** | 重命名/归档只保留会话列表左滑；菜单项 6→4 |
| **安全/隐私** | 19 项自测全过；日志脱敏、限速分档、/admin 防 CSRF、pair.json 收紧 ACL |
| **开源准备** | preflight 预检、一键 install.ps1、LICENSE(MIT)、移植/续签/安全须知文档 |

---

## 二、建议的执行顺序（2026-11-14 更新）

现在只剩两条**需要外部输入**的，以及一批"想做得更好"的：

**等外部输入**
- **Bark / ntfy 通知**（#5）：桥端 `notify.js` 已就绪，只差你在
  `cordis.patch.yml` 里填 `notify.kind / server / key`；填完重启即用
- **手机上管设备**（#4）：`/admin/devices*` 是本机免 token 的，
  搬进 App 要先设计一套"手机端也能鉴权"的方案（否则等于把设备闸门开在 App 里）

**可以随时做（按性价比）**
1. 导出对话（Markdown / 文本，分享或存文件）
2. 转发时自动附上下文（来自哪个会话、第几轮）
3. 产物清单卡按类型分组
4. 会话列表行缓存（cwd 解析已在 store 侧，剩下的只是滚动时的格式化）

**大工程（各需一轮完整迭代）**
- 多会话并行视图（现在一次只能看一个）
- 真·推送（APNs 需要付费开发者账号的 push entitlement）

---

## 二·五、2026-11-12 当天完成

| 项目 | 关键点 |
|---|---|
| **排队消息管理** | 从 `app.asar` 的 zod schema 逆向出真实参数：`{sessionId, itemId, action:{kind:"edit"\|"remove"\|"steer"}}`。之前猜了七轮全失败，报错都是 `reading 'kind'`（缺 action） |
| **队列读取** | `agent/inbox/spliced` 事件 → 桥转成 `queue.changed` 帧 → ChatStore 自己维护队列（排队/移除/替换/插队） |
| **transcript 分页** | `/v1/transcript?before=N` + `hasMore`/`nextBefore`；手机端上拉 90pt 触发、按 id 去重、`performWithoutAnimation` 内补偿 offset |
| **余额** | `getBalance(client)` 少传 client（要 version/locale/timezoneOffsetSeconds），补上后用 getState 兜底；显示两位小数 + 去重 |
| **401 自动重新握手** | 桥重启后握手态丢失，`sendWithHeaders` 检测 `handshake-required` 自动握手重试一次 |
| **拆 store** | ChatStore / ComfyStore / WalletStore，`AppModel` 的 `@Published` 28 → 23 |
| **气泡** | 用户淡蓝按内容收缩靠右、助手淡灰；间距 8pt（之前两个 top 约束打架导致无效） |
| **代码块 / 表格排版** | 代码块 `lineSpacing` 0 + `lineHeightMultiple`（底色才连成块）；表格表头改用下划线（底色覆盖不到 tabStops 空白） |
| **启动加载历史** | 之前只在会话切换时加载，启动时 id 没变化就不加载 → 加 `.task` |
| **删「文件」页** | 只列目录不能预览，无意义；上传/接收能力保留 |

---

## 三、已完成（不用再动）

### 服务端

- 上传 403：fs-safe 向上找最近已存在祖先，自动建多级目录
- 冷会话历史：`/v1/transcript` 从磁盘日志重建
- 冷会话标题：三条路径（服务 / 事件 / 磁盘日志）
- **zstd 多 frame**：Electron 44 的 `zstdDecompressSync` 只解第一个 frame，890KB 日志只出 230 字符 → 按 magic number 手动切分
- runtime context 注入过滤
- 历史回填不再刷爆 `/v1/sessions`
- 归档会话：`/v1/sessions?archived=1`（`workspaceRegistry.archivedSessionIds`）
- 文件页：`/v1/fs/mkdir`、`/v1/fs/delete`（禁止删根目录）
- **日志重建护栏**：按 mtime 缓存 + 24MB 上限，避免单线程 Node 被同步解压堵死
- 新端点：`/v1/comfy`、`/v1/models`、`/v1/session/model`、`/v1/debug/title`、`/v1/balance`、`/admin/debug/env`
- 事件帧带 `at` 时间戳（历史轮次的用时才算得对）

### 客户端

**滚动与跳转**（这块花的时间最多）
- 惯性中点击失效 → 0×0 探针向上遍历 `superview` 拿到 `UIScrollView`（原来挂 `.background` 不在子视图链里，一直 `no-scrollview`）
- 跳转不准 → **冻结内容渲染**（`freezeContent`/`unfreezeContent` + 帧队列）→ 算准高度 → `scrollRectToVisible` → 解冻
- 卡顿 → clamp 加 `isClamping` 防重入锁
- 偶发越界 → 解冻后再夹一次边界（`foldSteps` 会让高度骤减）
- 滚动指示条抖动 → 直接隐藏，位置感交给按钮
- 电脑端发消息不再带动手机滚动；贴底时恢复自动跟随

**聊天渲染**
- 工具行摘要：`args` 是 JSON 字符串要剥两层；`description` 优先；`path` 显示成 `目录/文件:行号`
- 转圈位置：`.firstTextBaseline` → `.center` + Spacer
- Markdown 解析加缓存、流式期只渲染纯文本、`upsertStreaming` 就地改数组、`ChatEntry` 手写 `==`
- 图片压缩与显示改 `CGImageSource` 缩略图 + 后台线程（原来主线程解 1700 万像素直接卡死）
- 图片和文字一起发（chip 方案）

**会话与输入**
- 拼音首字母丢失：composer 不再 `if` 增删视图，改恒定结构
- 切会话发钝：`loadHistory` 整段 `beginBatch/endBatch`
- 会话列表：独立 sheet + 搜索 + 相对时间 + 状态 + 未读蓝点 + 左滑归档/重命名 + 已归档分区
- 草稿按会话保存、上传进度、错误 toast、消息时间戳、按 turn 边界裁剪

**设置与引导**
- 账户余额区块（主钱包 + 赠送额度，进页面拉一次 + 下拉刷新）
- 断线横幅（显示原因 + 重连按钮）
- 首次使用引导（三步说明）
- 设备指纹、加密说明、忘记电脑

**外观**
- 图标：C 方案（人物下沉、角标 660px 贴死右下角仅左上圆角）
- 改名 DSH Helm
