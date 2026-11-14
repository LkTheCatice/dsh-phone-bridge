# DSH Helm · 用 iPhone 遥控 DeepSeek Harness

> ⚠️ **先读 [安全须知与免责声明](docs/安全须知与免责声明.md)**。
> 这个工具会让 AI 在**你的电脑上真实执行操作**（跑命令、改文件、删文件），并传输你的私人会话。
> 三条红线：**不做公网端口映射**、**不泄露 `pair.json`**、**`roots` 不设成盘符根**。

手机发一句话，电脑上的 [DeepSeek Harness](https://github.com/deepseek-ai) 真的去跑，思考与工具调用流式回到手机；动手前你在手机上点头或拒绝；产物可直接在手机上看，也能转发给另一个会话继续做。

```
iPhone (SwiftUI)  ── 局域网 HTTP + 端到端加密 ──▶  PC 上的 dsh-phone-bridge 插件
      │                 （或 Tailscale 的 HTTPS）        └─▶ 真实会话：命令 / 文件 / 工具
      └─ 会话 · 过程 · 产物 · 审批
```

---

## 你需要什么

| | 要求 |
|---|---|
| 电脑 | Windows 10/11（macOS/Linux 未验证） |
| DSH | 桌面版，**至少启动过一次**（插件装在它的 profile 里） |
| Node | **24+**（桥用 `node:zlib` 的 zstd 读会话历史） |
| 手机 | iPhone，iOS 16+，需要侧载（免费签名 7 天有效） |
| 网络 | 手机和电脑**同一个局域网**；跨网用 Tailscale，别做端口映射 |

## 三步装上

### 1. 电脑：预检 + 装插件

```powershell
git clone https://github.com/<you>/dsh-phone-bridge && cd dsh-phone-bridge

# ① 先看环境缺什么（只读，不改任何东西）
powershell -ExecutionPolicy Bypass -File .\tools\preflight.ps1

# ② 装（默认建 junction，C 盘 0 字节；装完要重启 DSH）
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Roots "D:\work\output"
```

- `-Roots` 是**手机允许读写的目录**（可多个），不填就没法读写文件
- `-LanHost 192.168.1.23` 可固定内网 IP；**不填则自动探测**
- 其它参数：`-Port` / `-Profile` / `-StateDir` / `-Link:$false`

装完**完全退出 DSH（含托盘）再打开**，日志里应出现：

```
[phone-bridge] 监听 127.0.0.1:8765
[phone-bridge] 局域网监听 192.168.x.x:8765（自动探测，内容仍需 E2EE 解密）
```

### 2. 电脑：拿配对串

```powershell
node bridge\bin\pairing.mjs          # 自动用内网 IP；也可显式传 host port
```

输出一条 `dshnb://pair?host=...&port=...&token=...&fp=...`，等下贴到手机上。

### 3. 手机：装 App 再配对

App 需要侧载（未签名 IPA + 你自己的 Apple ID）。两种路径：

- **用现成 IPA**：从 [Releases](../../releases) 下载，用 [Sideloadly](https://sideloadly.io/) 安装
- **自己构建**：推到自己仓库，用 `codemagic.yaml`（免费额度够）跑一次「无签名 IPA」工作流

装好后打开 App → 粘贴第 2 步的整串 → 连接。详见 [docs/侧载.md](docs/侧载.md)。

---

## 它能做什么

| 能力 | 说明 |
|---|---|
| 远程下指令 | 手机发消息 → 电脑真实执行，过程流式回传 |
| 审批 | 工具调用前需你在手机上确认（可关，但默认开） |
| 产物 | 一轮产出的文件合成一张清单卡；图片/视频/音频可直接预览，其它可下载 |
| 转发 | 把产物**以路径引用**发给另一个会话继续处理（手机打不开的 dmg/exe 也能转） |
| 折叠 | 一轮结束把思考/工具调用收成一行，点开看全过程 |
| 通知 | 可选 Bark / ntfy，只发「会话 xxxx · 状态」，不含内容 |

## 安全模型（默认全最保守）

| 层面 | 做法 |
|---|---|
| 内容加密 | 每个请求/响应体 AES-256-GCM 封包，**强制**（明文请求直接 401） |
| 密钥协商 | X25519 ECDH → HKDF-SHA256，salt 是配对 token，双向密钥分离 |
| 防重放 | AAD 绑定 `METHOD /path?query`，跨端点重放会解密失败 |
| 服务器身份 | 首次配对钉住服务器公钥指纹，之后不一致就拒连 |
| 设备闸门 | 未批准的设备连 E2EE 都不建立（`/admin/devices` 可见、可拉黑） |
| 网络边界 | 默认只监听 loopback；局域网监听内容照样加密；`/admin` 只允许本机 |
| 文件边界 | 白名单根 + `realpath` 校验，`..`、符号链接逃逸、NTFS 数据流全部拒绝 |
| 凭据 | 手机私钥在 Keychain；电脑侧 `pair.json` 已收紧 ACL（当前用户 + SYSTEM） |

自测脚本：`node tools\pentest.mjs --run`（19 项）、`node tools\privacy-audit.mjs`。
最近一次结果见 [docs/安全测试-2026-11-14.md](docs/安全测试-2026-11-14.md)：**19/19 通过**。

## 目录

```
phone-dsh/
├─ install.ps1               一键安装（先跑预检，再调 bridge\install.ps1）
├─ bridge/                   PC 侧插件（零依赖 ESM）
│  ├─ index.js               apply(ctx, config)：HTTP + 事件归一化 + 审批挂起
│  ├─ lib/{store,seal,fs-safe,events,notify}.js
│  ├─ bin/{pairing,smoke,verify}.mjs
│  └─ install.ps1 / uninstall.ps1
├─ ios/DSHRemote/            SwiftUI App（XcodeGen 工程，project.yml）
├─ tools/
│  ├─ preflight.ps1          环境预检（只读）
│  ├─ pentest.mjs / privacy-audit.mjs   安全与隐私自测
│  └─ selftest/run.ps1       Foundation 层 188 项断言（需要 Swift 工具链，可选）
├─ docs/                     部署 · 侧载 · 协议 · 移植 · 安全须知
├─ codemagic.yaml            云构建未签名 IPA（给维护者/自建者用）
└─ dist/                     IPA 产物（不入库）
```

## 常见问题

**Q：手机连不上**
1. 手机和电脑在同一 WiFi 吗（有些路由器把 2.4G/5G 隔离）
2. 电脑防火墙是否拦了 Node（首次运行会弹窗，要允许专用网络）
3. 看 DSH 日志里「局域网监听」那行的 IP，与手机配对串里的 host 是否一致

**Q：重启后手机 401**
token 换了（`pairing.mjs --rotate` 或删过 `pair.json`）→ 重新配对。

**Q：App 打不开 / 闪退**
免费签名 7 天到期 → 用 Sideloadly 重签重装。

**Q：`roots` 该填什么**
填你希望手机能看到的目录（比如产物目录、项目目录），**不要填 `D:\`**。

**Q：能跨公网用吗**
用 Tailscale：`tailscale serve --bg --https=443 8765`，然后手机连 `https://<机器>.<tailnet>.ts.net`。
**不要**在路由器上做 8765 端口映射。

## 已知限制

- 装插件必须重启 DSH 一次（cordis 加载时机）
- 免费签名 7 天过期，需重装
- App 进后台 SSE 会被挂起，靠通知拉回；前台重连带 `since` 补缺口
- 会话日志（DSH 本体）只压缩不加密 —— 建议开 BitLocker
- `ask_user_question` 的选项回填仍是 best-effort

## 许可证

[MIT](LICENSE)。自用、修改、二次分发都可以，风险自担（见[安全须知](docs/安全须知与免责声明.md)）。
