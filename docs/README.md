# 文档索引

## 给使用者

| 文档 | 什么时候看 |
|---|---|
| [安全须知与免责声明](安全须知与免责声明.md) | **装之前必读**：红线、已知限制、免责 |
| [部署](部署.md) | 从零装一台新电脑（含 Tailscale 跨网） |
| [侧载](侧载.md) | 把 IPA 装到 iPhone（Sideloadly / AltStore） |
| [移植](移植.md) | 换电脑 / 换手机 / 开源后给别人用 |
| [交付清单](交付清单.md) | 开源转交自检：克隆即用、Release 可下载、App 与配套的配合点 |
| [续签](续签.md) | 7 天签名到期怎么办（同一 WiFi 自动续签的逐步操作 / 付费账号） |
| [协议](协议.md) | HTTP 接口、E2EE 握手、帧格式 |

## 给维护者

| 文档 | 说明 |
|---|---|
| [安全测试-2026-11-14](安全测试-2026-11-14.md) | 安全 + 隐私自测报告（含每轮修复结论） |
| [CURRENT-ISSUES](CURRENT-ISSUES.md) | 当前已知问题 |
| [ARCH-重构](ARCH-重构.md) | 渲染架构与踩坑史 |
| [FIXES-2026-11-13](FIXES-2026-11-13.md) | 某天的修复清单 |
| [STATUS-*](.) | 历史状态快照，仅供追溯 |
| [internal/](internal/) | 内部交接、方案确认书（含过程记录） |

## 自测脚本

```powershell
powershell -File tools\preflight.ps1     # 环境预检（只读）：Windows / Node / profile / 端口 / 内网 IP
powershell -File tools\selftest\run.ps1  # Foundation 层 188 项断言（需 Swift，可选）
node tools\pentest.mjs --run             # 安全 19 项（含 path 穿越 / 重放 / 限速）
node tools\privacy-audit.mjs             # 隐私面（匿名端点、日志内容、落盘形态）
```

> 跑 `pentest` 的限速用例会把本机 IP 拉黑 60 秒 —— 它排在最后，跑完稍等再做别的本机请求。
