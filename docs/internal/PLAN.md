# 手机 → DSH 遥控端 · 方案确认书 v1

**目标**：iPhone 上发指令 → PC 上的 DSH 真实执行（跑命令、改文件、调工具）→ 执行过程与结果流式回手机；支持手机端审批、文件双向传输、多会话；私密文件全程不出可信任边界。

**已确认的前提**（来自实测与你的选择）
- 路线 A：PC 侧是 **DSH 插件**（复用桌面端登录态、会话、工具、审批链路，不需要 API key）
- 手机侧是 **原生 SwiftUI App**
- 网络：**局域网直连 + Tailscale** 双路径
- iOS 工具链：**暂无 Mac / 无付费账号** → 交付源码 + GitHub Actions 云编译 + 侧载步骤，另给 PWA 备用通道
- 功能：流式结果（含思考与工具调用）、手机端审批与选项回答、文件双向加密传输、多会话切换与历史、完成通知

---

## 1. 架构

```
┌────────────────────────┐        HTTPS / WireGuard        ┌──────────────────────────────┐
│  iPhone · DSHRemote    │  ─────────────────────────────►  │  PC · DeepSeek Harness       │
│                        │                                  │                              │
│  SwiftUI               │   GET  /v1/stream  (SSE)         │  ┌────────────────────────┐  │
│  ├ 配对（二维码）       │ ◄─────────────────────────────   │  │ dsh-phone-bridge 插件  │  │
│  ├ 会话列表/历史        │                                  │  │  http(s).createServer  │  │
│  ├ 聊天（流式）         │   POST /v1/task                  │  │  Bearer + 可选 E2EE    │  │
│  ├ 审批 / 选项回答      │   POST /v1/approval              │  └───────┬────────────────┘  │
│  ├ 文件上传/下载        │   POST /v1/fs/write …            │          │ ctx.agents        │
│  └ 本地通知             │                                  │          │ session/event     │
└────────────────────────┘                                  │  ┌───────▼────────────────┐  │
                                                            │  │ 已有 Agent / Session   │  │
            两条链路：                                       │  │ 工具 · skills · 审批    │  │
            ① 局域网  https://192.168.x.x:8765 (自签+指纹)   │  └────────────────────────┘  │
            ② 外网    https://<host>.<tailnet>.ts.net        │       127.0.0.1:8765        │
                      (tailscale serve 反代 loopback)        │   ← tailscale serve 只反代  │
                                                            └──────────────────────────────┘
```

**为什么插件不能直接对公网监听**：插件只 bind `127.0.0.1`。外网访问一律经 `tailscale serve`（WireGuard 加密、证书由 Tailscale 签发，iOS 无需 ATS 例外）；局域网访问才由插件额外 bind 一个内网 IP，走自签证书 + 公钥指纹 pinning。这样插件永远没有"裸奔在公网"的配置项。

---

## 2. 接口契约（PC 侧插件）

统一前缀 `/v1`，鉴权 `Authorization: Bearer <token>`（`/stream` 允许 `?token=`）。

| 方法 | 路径 | 作用 | 说明 |
|---|---|---|---|
| GET | `/v1/health` | 存活探测 | 返回版本、pid、bind 列表、能力位 |
| GET | `/v1/state` | 会话与挂起状态 | `sessions[]`（id/title/cwd/running/updatedAt）、`pending.approvals[]`、`pending.questions[]` |
| POST | `/v1/handshake` | E2EE 握手 | `{v, clientPub}` → `{v, serverPub}`；后续请求可用 `X-Sealed: 1` |
| GET | `/v1/stream?since=<seq>` | 事件流（SSE） | 环形缓冲 2000 帧，断线按 `since` 续传 |
| POST | `/v1/task` | 投递任务 | `{sessionId?, text}` → `{ok, sessionId, queued}` |
| POST | `/v1/approval` | 审批决定 | `{id, decision:"allow"\|"deny", note?}` |
| POST | `/v1/answer` | 回答选项题 | `{id, answers:[...]}` |
| GET | `/v1/fs/list?path=` | 列目录 | 仅白名单根内 |
| GET | `/v1/fs/read?path=&offset=&limit=` | 分块下载 | 默认 1 MiB/块，上限 8 MiB |
| POST | `/v1/fs/write?path=&offset=` | 分块上传 | raw body；`offset=0` 且 `truncate=1` 时新建 |
| GET | `/v1/fs/stat?path=` | 文件元信息 | size / mtime / sha256(可选) |
| GET | `/v1/transcript?sessionId=&since=` | 历史 | 从 session 日志读，分页 |

### 事件归一化（DSH → 手机）

| DSH `session/event` | 手机帧 `type` | 载荷 |
|---|---|---|
| `turn/start` | `turn.start` | `{sessionId, turn}` |
| `assistant/message`（text_delta） | `assistant.delta` | `{text}` |
| （thinking_delta） | `assistant.thinking` | `{text}` |
| `tool/call` | `tool.call` | `{callId, name, args}`（args 截断 8 KiB） |
| `tool/result` | `tool.result` | `{callId, ok, preview}`（preview 截断 8 KiB） |
| `approval/asked` | `approval.asked` | `{id, tool, reason}` |
| `approval/decided` | `approval.decided` | `{id, decision}` |
| `ask_user_question` 调用 | `question.asked` | `{id, questions[]}` |
| `turn/end` | `turn.end` | `{turn, reason}` |
| — | `heartbeat` | 每 15 s，防 NAT 掉线 |

每帧带单调 `seq`，手机侧按 seq 去重；断线重连带 `since` 补齐。

---

## 3. 审批链路（关键设计）

插件的 `scope.on("approval/request", async (request, next) => …)` 是一个**可挂起的中间件**：

```
DSH 想执行敏感工具
   → 中间件被调用，返回一个 Promise（挂起，不立刻 next()）
   → 插件把 {id, tool, reason} 推给手机（approval.asked）
   → 手机弹窗，用户点「允许」→ POST /v1/approval {id, decision:"allow"}
   → 插件 resolve → await next() → DSH 继续执行
   → 超时（默认 120 s）或断连 → 自动 deny，并推 approval.decided
```

`ask_user_question` 走同一模式，回答通过 `agent.followup` 投递（实现期体检确切 payload）。

---

## 4. 安全模型

| 层 | 措施 |
|---|---|
| 传输 · 外网 | Tailscale（WireGuard）+ ts.net 真证书；插件只 bind loopback，公网看不到端口 |
| 传输 · 局域网 | 明文 HTTP + **强制应用层 E2EE**：每个请求/响应都是 AES-256-GCM 封包，抓包只能看到长度与时序。放弃自签 TLS——证书链解决不了"内容保密"，E2EE 才解决，而且不用装证书、不用管 7 天换签 |
| 鉴权 | 32 字节随机 Bearer token，配对时写入 Keychain；可轮换（旧 token 立即失效、已握手连接全部断开） |
| 密钥协商 | X25519 ECDH → HKDF-SHA256（salt = token，info = 协议版本），c2s / s2c 双向分离 |
| 防重放 | AAD = `METHOD PATH?canonicalQuery`，密文绑死端点：把"读文件"的密文塞进"写文件"直接解密失败；错误响应同样加密 |
| 服务器身份 | 首次配对把服务器公钥指纹钉在手机上，之后不一致直接拒连（不静默接受） |
| 设备可见性 | 握手过的手机记入名单（最多 8 台，可 `pairing.mjs` 列出、可清空）。不做"只准一台"的一票否决——那会让重装/换机卡死且没有恢复入口 |
| 文件边界 | 白名单根（`roots` + 启动目录），`realpath` 校验，拒绝 `..`、符号链接逃逸、`\\?\`、NTFS 数据流、Windows 设备名；分块 1 MiB，单文件上限可配 |
| 密钥落盘 | 电脑侧 `%USERPROFILE%\.dsh\phone-bridge\pair.json`（token + 服务器私钥 + 设备名单）；手机侧 Keychain `afterFirstUnlockThisDeviceOnly`，不进备份 |
| 通知 | **不用 APNs**（免费签名拿不到 push entitlement）。走 Bark / ntfy，正文只含会话短码与状态，绝不含文件内容或命令输出 |
| 审批不卡死 | 手机在线才拦审批；90 s 无应答自动交回桌面端原流程，绝不制造"电脑干等手机"的死锁 |

---

## 5. 端口与部署

```
插件配置（cordis.patch.yml）
  dsh-phone-bridge:
    port: 8765
    lanHost: 192.168.1.23     # 留空则只监听 loopback（纯 Tailscale 模式）
    tls: auto                 # auto | on | off
    e2ee: auto                # auto | on | off
    roots: []                 # 额外允许的目录
    notify: { kind: bark, key: "<你的 bark key>" }
```

三种使用姿势：

1. **外网（推荐）**：插件只监听 loopback → `tailscale serve --bg --https=443 8765` → 手机连 `https://<host>.<tailnet>.ts.net`
2. **家里局域网**：`lanHost` 填内网 IP → 手机连 `https://192.168.x.x:8765`（扫二维码自动 pin 证书）
3. **零安装应急**：`dsh web --host <内网IP> --tls-cert … --tls-key …` + Safari 加主屏（PWA 通道，先用着）

---

## 6. 交付物清单

```
phone-dsh/
├─ PLAN.md                      ← 本文件
├─ bridge/                      PC 侧 DSH 插件（零依赖 ESM）
│  ├─ package.json
│  ├─ index.js                  apply(ctx, config)：HTTP 服务 + 事件归一化 + 审批挂起
│  ├─ lib/store.js              token / X25519 / TLS 自签证书 生成与持久化
│  ├─ lib/seal.js               X25519 + HKDF + AES-256-GCM 封装
│  ├─ lib/fs-safe.js            白名单根 + 逃逸防护 + 分块读写
│  ├─ lib/notify.js             Bark / ntfy
│  └─ install.ps1               装进 desktop profile + 备份 + 重启提示
├─ ios/DSHRemote/               SwiftUI App（可直接云编译）
│  ├─ DSHRemoteApp.swift
│  ├─ Info.plist
│  ├─ Net/{Crypto,BridgeClient,SSEClient,Pinning}.swift
│  ├─ Store/{AppStore,Keychain,Models}.swift
│  └─ Views/{Pairing,SessionList,Chat,Approval,Files,Settings}.swift
├─ .github/workflows/ios.yml    云编译 → 未签名 .ipa 产物
└─ docs/
   ├─ 部署.md                   装插件 / tailscale serve / 重启 DSH
   ├─ 侧载.md                   Sideloadly + 免费 Apple ID（7 天重签）步骤
   └─ 协议.md                   接口与帧格式全表（给以后加 Android / 脚本用）
```

---

## 7. 里程碑与验收

| 里程碑 | 内容 | 验收方式 |
|---|---|---|
| M0 | 插件骨架 + token + `/health` `/state` | PC 上 `curl -H "Authorization: Bearer …" http://127.0.0.1:8765/v1/health` 返回 200 |
| M1 | `/task` 投递 + `/stream` 事件流 | 在 GUI 里发一句话给会话，手机端 `curl -N` 能看到 `assistant.delta` 与 `turn.end` |
| M2 | 审批挂起与放行 | 触发一次需要确认的操作，`/v1/approval` 放行后任务继续 |
| M3 | 文件双向 | 手机传 10 MiB 文件到 `cwd`，PC 侧 sha256 一致；反向下载一致 |
| M4 | 加密层 | `X-Sealed: 1` 请求正确解密；AAD 篡改被拒；无 TLS 时默认自动启用 |
| M5 | Swift App 全流程 | 配对 → 发任务 → 看流式 → 审批 → 传文件 → 切会话 |
| M6 | 云编译 + 侧载 + 通知 | Actions 出 ipa，Sideloadly 装上，任务完成手机收到 Bark |
| M7 | PWA 备用通道 | Safari 加主屏可发任务（`dsh web` 那套） |

---

## 8. 已知风险 / 实现期体检项

| # | 风险 | 应对 |
|---|---|---|
| 1 | ~~`ctx.agents` 是否有"新建会话"入口~~ **已核实：有** | 用 `ctx.sessionController`（见第 10 节），`/v1/task` 无 sessionId 时直接新建会话，不再需要"先让电脑开一个会话"的妥协 |
| 2 | `ask_user_question` 的回答 payload 未确认 | 读 `dsh-tool-ask-user` 源码确认结构，再定 `/v1/answer` 的 body |
| 3 | 装插件需**重启 DSH** | install.ps1 备份 `cordis.patch.yml`，重启后自检 `/health` |
| 4 | 免费签名 7 天过期 | 云编译 workflow 保留 artifact 30 天；文档给"每周重跑一次 workflow + 重装"的操作清单 |
| 5 | 手机后台被系统挂起，SSE 断 | 前台靠 SSE 续传 `since`；后台靠 Bark 通知拉回 App |
| 6 | 桌面端登录态过期 | `/v1/state` 暴露 `account` 健康位，App 直接显示"电脑端需重新登录" |

---

## 9. 需要你现在拍板的两处

1. **通知服务**：默认 Bark（国内直连、免费、可自建）。若你已有 ntfy 服务器我改成 ntfy。
2. **会话策略**：第一版若确认拿不到"新建会话"接口，就**复用 PC 上已打开的会话**（手机不能凭空开会话）。接受这个约束，还是让我花时间啃 `ctx.agents` 的新建路径？

确认这两点后我按 M0 → M7 顺序落代码，每个里程碑可独立验证。

---

## 10. 实现期体检结论（已核实，2026-11-09）

读了 `@deepseek-ai/dsh-api-session-controller/lib/index.js`（Host 侧 `ServerController`）与 `dsh-headless` 的 bundle 配置，以下从"待验证"变为"确定"：

**`ctx.sessionController` 是插件该用的正统入口**（不是 pet-bridge 里那个 `agent.followup` 的权宜写法）：

```js
// 新建会话 —— 实测签名（源码 755 行）
await ctx.sessionController.create({
  cwd,                    // 与 workspaceId 二选一
  sessionId?,             // 可复用空白会话
  agentPreset?,           // 缺省用运行配置的默认 preset
})                        // → { sessionId, agentPreset? }

// 投递任务（源码 925 行）
await ctx.sessionController.prompt(
  {
    sessionId,
    content: [{ type: "text", text }],
    requestId,            // 幂等键：重复 requestId 直接返回 accepted
    mode?,                // "steer" 走打断通道，缺省 followup 排队
  },
  { kind: "user-rpc", ... } // source，作为 user 消息来源写进日志
)                         // → { accepted: true }

// 其它可用：resume(sessionId) / fork({atSeq}) / rename / cancel / list / selectModel / attachment
```

`prompt()` 内部就是 `createUserMessage()` + `agent.followup(message)`，鉴权、附件准入、busy 判定、幂等全在里面 —— 手机端不需要自己拼消息结构。

**由此确定的映射**：
- `POST /v1/task` 带 `sessionId` → `prompt()`；不带 → `create()` 拿新 id 再 `prompt()`
- `requestId` 由手机端生成 UUID，重试不会重复插入消息（弱网必备）
- `mode: "steer"` 暴露成 App 里的「插话打断」按钮

**headless 路线（B）的结论也定死了**：`dsh-headless/cordis.patch.yml` 里 `credentials / authorization / deepseek-account` 三行是**显式 `disabled: true`**，注释写着"one-shot jobs use launch-time credentials"。所以 B 路线必须自备有效 `DEEPSEEK_API_KEY`，无法白嫖桌面登录态 —— 这也是当初不选 B 的硬理由，现在有源码佐证。

**仍未核实**（不阻塞 M0–M4，M2 前补）：`ask_user_question` 的答案 payload 结构，决定 `/v1/answer` 的 body 形状。

### 真机联调后修正（2026-11-10，插件已在真实 DSH 里跑起来）

`ctx.sessionController` 暴露的**不是** `SessionController` 类本身，而是 Typert Remote 门面。两者签名不同，这点很坑：

| 方法 | 门面实际签名 | 说明 |
|---|---|---|
| `create` | `create(request)` | 单参数，内部 `this.commands.create(request)` |
| `prompt` | `async prompt(request, signal)` | **第二参数是 AbortSignal，不是 source**；方法第一行就 `signal.throwIfAborted()`，source 由门面自己构造 `{kind:"user", rpcId:request.requestId}` |
| `list` | `async list(_request, signal)` | 返回 `{ items: [...] }`，同样需要 signal |
| `cancel` | `cancel(request)` | 单参数 |

第一版按 `prompt(request, source)` 调用，直接 500：`signal.throwIfAborted is not a function`。已改为统一传 `AbortSignal.timeout(...)`。

另外确认：Electron 里 `process.cwd()` 是 profile 目录，**不是**用户工作区。文件白名单根改为自动读 `$DSH_HOME/storages/workspace.json` 的 `tables.workspaces[*].path`。

真机已验证通过：插件在真实 DSH 中加载、双监听（loopback + `192.168.124.27`）、X25519 握手、AES-GCM 请求与响应、38–39 个真实会话列表、SSE 收到 139 个真实事件帧并正确解密归一化、越界路径 403、凭据迁移到 D 盘后 token 保持一致。
