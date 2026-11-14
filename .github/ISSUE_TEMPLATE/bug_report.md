## 上报问题前请先跑这两条

```powershell
cd <仓库根>
node tools\privacy-audit.mjs     # 隐私面
node tools\pentest.mjs --run     # 安全 19 项（会临时锁本机 60 秒，建议最后跑）
```

## 请附上这些信息

| 项 | 从哪看 |
|---|---|
| **版本号** | App → 设置 → 最底部 `build=xxxxxxx.N`；电脑端看 `bridge.log` 里的 `build=` |
| **哪一端出问题** | 手机 App / 电脑桥 / 构建流程 |
| **复现步骤** | 越具体越好（第几步、点了什么） |
| **现象** | 截图或录屏；卡顿请说明"大概几秒" |
| **电脑环境** | `powershell -File tools\preflight.ps1` 的输出（会自动隐去敏感路径） |

## 请不要贴这些

- `pair.json` 的内容（含 token 与私钥）
- `bridge.log` 原文（含你的目录结构）—— 先跑 `DSH_PHONE_LOG_MIN=1` 重启再复现
- 任何真实会话内容截图（要么打码，要么换成自己造的例子）

## 已知不是 bug 的

- **App 打不开 / 点图标闪退**：免费签名 7 天到期，覆盖安装即可，见 [docs/续签.md](docs/续签.md)
- **手机连不上**：换网络后 IP 变了；看桥日志里「局域网监听」那行，或重跑 `node bridge\bin\pairing.mjs`
- **宽表格被拆成多块**：气泡里放不下，点「查看完整表格」看原表
