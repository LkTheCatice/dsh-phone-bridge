# 待做清单

> 更新：2026-11-12 23:15
> 当前包：2,542 KB（`8f29ab5`）
> 服务端已生效：冷会话历史/标题（zstd 多 frame）、runtime context 过滤、transcript、fs 多级目录、归档过滤、fs mkdir/delete、`/v1/balance`

---

## 一、剩下要做的

### A. 功能缺口

| # | 项目 | 现状 / 卡点 | 量级 |
|---|---|---|---|
| 2 | **图片编辑（画笔）** | 需要 PencilKit 画布 + 存取回相册的完整流程 | 大 |
| 3 | **模型推理强度** | `modelCatalog` 已返回 `reasoning.efforts`，UI 只在选模型，没展示档位 | 中 |
| 4 | **手机上管设备** | 拉黑/批准只在 DSH 设置页。`/admin/devices*` 是本机免 token 的，搬进 App 要先解决鉴权 | 中 |
| 5 | **Bark 完成通知** | `cordis.patch.yml` 的 `notify.kind / server / key` 三项全空，等 key | 小 |

### B. 体验优化

| # | 项目 | 现状 | 量级 |
|---|---|---|---|
| 6 | **消息长按菜单** | 无法复制 / 引用 / 重发，只能手动选文字 | 中 |
| 7 | 从相册直接粘贴图片 | 现在只能走 `+` | 小 |
| 8 | 会话列表相对时间每行现算 | `SessionListSheet` 每行 `Date()` + 格式化 + cwd 名称解析，60 行有开销 | 小 |
| 9 | 输入框支持多行展开 | 目前 `lineLimit(1...5)`，长文本编辑体验一般 | 小 |

### C. 稳定性 / 工程

| # | 项目 | 说明 | 量级 |
|---|---|---|---|
| 10 | **图片缓存只在内存** | App 重启后全部重新下载。可落盘到 Caches | 小 |
| 12 | **免费签名 7 天过期** | 到期必须重签重装，没有任何提醒 | 小 |
| 13 | Sideloadly 受系统代理影响 | 系统代理指向 `127.0.0.1:7892`，Clash 没开时直接 `ProxyError` | 环境问题 |
| 14 | `git push` 偶发静默失败 | 已改走 SSH（`ssh.github.com:443`）；推送后用 `rev-parse` 校验 | 环境问题 |

---

## 二、建议的执行顺序

**第二批（一次编译）**：1 号楼里的三件小活
- 模型推理强度（6 号位之前，纯 UI）
- 消息长按菜单
- 图片缓存落盘

**第三批**：transcript 分页 + 会话行缓存 + 相册粘贴

**单独排期**：排队消息管理、图片编辑（都是大工程，各需一轮完整迭代）

**等外部输入**：Bark key、手机上管设备的鉴权方案

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
