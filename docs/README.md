# 文档索引

## 给使用者

| 文档 | 什么时候看 |
|---|---|
| [安全须知与免责声明](安全须知与免责声明.md) | **装之前必读**：红线、已知限制、免责 |
| [部署](部署.md) | 从零装一台新电脑（含 Tailscale 跨网） |
| [侧载](侧载.md) | 把 IPA 装到 iPhone（Sideloadly） |
| [AltStore](altstore.md) | 用本仓库的应用源安装，并自动续签（推荐） |
| [续签](续签.md) | 7 天签名到期怎么办 |
| [移植](移植.md) | 换电脑 / 换手机 / 给别人用 |
| [对比-串流](对比-串流.md) | 和远程桌面 / 串流工具的区别与取舍 |
| [协议](协议.md) | HTTP 接口、E2EE 握手、帧格式 |

## 给维护者 / 贡献者

| 文档 | 说明 |
|---|---|
| [安全测试-2026-11-14](安全测试-2026-11-14.md) | 安全 + 隐私自测报告（19 项，含修复结论） |
| [交付清单](交付清单.md) | 开源转交自检：克隆即用、Release、App 与配套的配合点 |

## 自测脚本

```powershell
powershell -File tools\preflight.ps1     # 环境预检（只读）
powershell -File tools\selftest\run.ps1  # Foundation 层 188 项断言（需 Swift，可选）
node tools\pentest.mjs --run             # 安全 19 项
node tools\privacy-audit.mjs             # 隐私面
```

> `pentest` 的限速用例会把本机 IP 拉黑 60 秒 —— 它排在最后，跑完稍等再做别的本机请求。
