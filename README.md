# 手机 → DSH 遥控端

iPhone 上发一句话，电脑上的 DeepSeek Harness 真的去跑（执行命令、改文件、调工具），思考与工具调用流式回到手机；要动手前在手机上点头或拒绝；文件可以双向传，内容端到端加密。

```
iPhone (SwiftUI)  ──HTTPS/Tailscale 或 局域网HTTP+E2EE──▶  PC 上的 dsh-phone-bridge 插件
                                                          └─▶ ctx.sessionController → 真实会话
```

## 现在什么状态

| 部分 | 状态 |
|---|---|
| PC 侧插件（`bridge/`） | ✅ 已在真实 DSH 里跑通：握手、加密请求、38 个真实会话、139 个真实事件帧、真实任务往返（`turn.start → assistant.delta "ok" → turn.end`） |
| iOS App（`ios/DSHRemote/`） | ✅ 已云编译通过（2026-11-10，GitHub Actions / `macos-latest`），产物 `dist/DSHRemote-unsigned.ipa`（256 KB），待装到手机 |
| 通知 | ✅ 代码就绪，接 Bark / ntfy，填 key 即用 |
| 文档 | ✅ 部署、侧载、协议三份 |

> CI 踩坑记录：`runs-on: macos-14` 在免费账户的私有仓库上会被解析成 `macos-14-arm64-us-xl` 并 2 秒直接拒绝；`macos-13` 已退役会永久排队；**用 `macos-latest`**。另外 git 走 HTTPS 要单独配代理（`git config http.proxy http://127.0.0.1:7892`），git 不读系统代理设置。

## 三步上手

**1. 电脑：装插件（要重启一次 DeepSeek Harness）**

```powershell
cd phone-dsh\bridge
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
# 想同时开局域网监听：在末尾加 -LanHost 192.168.1.23
```

`-ExecutionPolicy Bypass` 是必需的：本机执行策略禁止运行未签名脚本，直接 `.\install.ps1` 会被拦。

它会：复制插件 → 备份 `cordis.patch.yml` → 追加配置 → 打印配对串。然后**完全退出 DSH（托盘也退）再打开**，日志里出现 `[phone-bridge] 监听 127.0.0.1:8765` 就成功。

**2. 电脑：外网访问走 Tailscale（推荐）**

```powershell
tailscale serve --bg --https=443 8765
```

得到 `https://<机器名>.<tailnet>.ts.net` —— 真证书、WireGuard 加密，iOS 不用改 ATS。**不要把 8765 端口映射到公网。**

**3. 手机：装 App 后粘贴配对串**

```powershell
node bridge\bin\pairing.mjs 100.64.0.5 443   # 换成你的 tailscale 地址与端口
```

App → 配对 → 粘贴 `dshnb://pair?...` 整串 → 连接。

## 安全模型

用户的原始要求是「可能会传一些私密的文件」，所以默认值全部按最保守的来：

| 层面 | 做法 |
|---|---|
| **内容加密** | 每个请求体与响应体都是 `AES-256-GCM` 封包，**强制开启**（明文请求直接 401 `e2ee-required`）。局域网裸 HTTP 也读不到内容 |
| **密钥协商** | `X25519 ECDH → HKDF-SHA256`，salt 是配对 token，info 是协议版本；双向密钥分离（c2s / s2c） |
| **防重放** | AAD = `METHOD /path?canonicalQuery`，把密文绑死在端点上：把「读文件」的密文塞进「写文件」会直接解密失败 |
| **服务器身份** | 首次配对把服务器公钥指纹钉在手机上，之后指纹不一致就拒连（不静默接受） |
| **设备可见性** | 每台握手过的手机记入名单（最多 8 台，`pairing.mjs` 可列出），换机/重装不会卡死，但你能看见谁连过 |
| **网络边界** | 插件**只监听 loopback**，外网只能经 `tailscale serve`；局域网监听需显式传 `-LanHost`，且内容照样加密 |
| **文件边界** | 白名单根（会话 cwd + `roots` 配置），`realpath` 校验，符号链接逃逸、`..`、`\\?\`、NTFS 数据流、设备名全部拒绝；分块 1 MiB |
| **凭据落盘** | 手机私钥在 Keychain（`afterFirstUnlockThisDeviceOnly`，不进备份）；电脑侧 token 与私钥在 `%USERPROFILE%\.dsh\phone-bridge\` |
| **通知脱敏** | 只发「会话 xxxx · 状态」，不含文件内容、命令输出、模型回复 |
| **审批不卡死** | 手机在线才拦审批；90 秒没答就交回桌面端原流程，而不是让电脑干等 |

用 APNs 会需要付费开发者账号的 push entitlement，所以走 Bark/ntfy：电脑发一条短消息，通知与 App 版本解耦。

## 目录

```
phone-dsh/
├─ PLAN.md                  方案确认书（含实现期体检结论）
├─ bridge/                  PC 侧插件（零依赖 ESM，Node ≥ 20）
│  ├─ index.js              apply(ctx, config)：HTTP + 事件归一化 + 审批挂起
│  ├─ lib/{store,seal,fs-safe,events,notify}.js
│  ├─ bin/pairing.mjs       打印配对串 / 轮换 token / 看设备名单
│  ├─ bin/smoke.mjs         链路验收（可 --demo 自测）
│  ├─ install.ps1 / uninstall.ps1
│  └─ test/{seal,e2e}.test.mjs
├─ ios/DSHRemote/           SwiftUI App（XcodeGen 工程）
│  ├─ Sources/{Net,Store,Views}/
│  └─ project.yml
├─ .github/workflows/ios.yml  云编译 → 未签名 ipa
└─ docs/{部署,侧载,协议}.md
```

## 文件都在哪，能不能搬离 C 盘

能。这个项目对 C 盘的实际占用已经压到 **0 字节**。

| 内容 | 实际位置 | 说明 |
|---|---|---|
| 源码 | `D:\...\phone-dsh` | 本来就不在 C |
| 插件安装点 | `C:\Users\<你>\.dsh\profiles\desktop\node_modules\dsh-phone-bridge` | 路径必须是这里（cordis 从 profile 解析），但它是 **junction 链接**，实体在 D 盘 |
| 配对凭据 | `D:\Documents\deepseek-harness\dsh-phone-bridge\pair.json` | 由 `stateDir` 配置指过去 |
| 整个 `.dsh`（2.4 GB） | `C:\Users\<你>\.dsh` | 也能搬：设 `DSH_HOME` 即可，见下 |

装的时候默认就走链接，不复制：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -StateDir 'D:\dsh-phone-bridge'
```

不想要链接、就想复制一份（比如源码要挪走）：加 `-Link:$false`。卸载时 `uninstall.ps1` 只删链接本身，不会碰源码目录。

### 连整个 `.dsh` 一起搬（2.4 GB，可选）

`dsh-home-paths` 的解析优先级是：显式配置 > `$DSH_HOME` > `~/.dsh`，所以设环境变量就够。

```powershell
# 1. 先完全退出 DSH
# 2. 复制（约 2.4 GB，2 万多个文件，几分钟）
robocopy "$env:USERPROFILE\.dsh" "D:\dsh-home" /E /COPY:DAT /R:1 /W:1

# 3. 设用户级环境变量
setx DSH_HOME "D:\dsh-home"

# 4. 重开 DSH，确认 sessions / profiles / 登录态都在
```

回滚：`setx DSH_HOME ""` 然后重开，原 `C:\Users\<你>\.dsh` 还在原地（没删的前提下）。

**注意**：删掉状态目录会导致凭据被重新生成、手机端突然 401 —— 搬之前先备份 `pair.json`，或者搬完在电脑上跑一次 `pairing.mjs` 拿新串。

## 本机已验证的命令

```powershell
cd phone-dsh\bridge
node --test .\test\seal.test.mjs .\test\e2e.test.mjs   # 7 项通过
node .\bin\smoke.mjs --demo                           # 全链路通过
node .\bin\pairing.mjs --json                          # 打印真实配对串
```

## 已知限制

- 装插件必须重启 DSH 一次（cordis 插件的加载时机）
- iOS 免费签名 7 天过期，需重装；详见 [docs/侧载.md](docs/侧载.md)
- App 进后台后 SSE 会被系统挂起，靠 Bark 通知把你拉回来；前台重连会带 `since` 补上缺口
- `ask_user_question`（选项题）目前是 best-effort：答案以普通用户消息投递，精确的选项回填待联调
- 会话列表依赖 `ctx.sessionController.list()`；若某版本签名不同，会自动退化到 `ctx.agents.list()`
