# 用 AltStore 装（自动续签，免每 7 天手动重装）

## AltStore 是什么

一个**开源的 iOS 侧载工具**，由 AltServer（电脑端后台服务）+ AltStore（手机 App）组成。

它的核心能力：
1. 用你**自己的免费 Apple ID** 给 IPA 签名并装到 iPhone 上（和 Sideloadly 一样）
2. **每 7 天自动重签一次** —— 只要手机和电脑在同一个 WiFi、AltServer 在后台跑着，
   你什么都不用做，App 不会因为签名过期而打不开
3. 可以订阅 **source（应用源）**：一个 JSON 描述"有哪些 App、从哪下载"，
   AltStore 里加了这个源，就能像商店一样装和更新

> 免费 Apple ID 仍然受苹果 7 天限制，AltStore 只是把"到期前重签"这件事自动化了。
> 想彻底摆脱，只能上付费开发者账号（证书 1 年）。

## 用本项目的源

仓库里已经写好源文件：[`altstore/source.json`](../altstore/source.json)

源地址（可直接粘到 AltStore）：

```
https://raw.githubusercontent.com/LkTheCatice/dsh-phone-bridge/main/altstore/source.json
```

步骤：

1. 电脑装 **AltServer**（<https://altstore.io/>），装完托盘常驻；iCloud 也要装（它依赖 Apple 账户组件）
2. 手机用数据线连一次电脑 → AltServer 托盘 → `Install AltStore` → 选你的 iPhone → 输入 Apple ID
3. 手机上：设置 → 通用 → VPN与设备管理 → 信任你的 Apple ID
4. 打开 AltStore → `Browse`（或 `Sources`）→ `+` → 粘贴上面的源地址
5. 在源里点 **DSH Helm** → 安装
6. 装完去电脑上装桥插件、重启 DSH、跑 `node bridge\bin\pairing.mjs` 拿配对串，粘到 App 里

之后只要「手机与电脑同 WiFi + AltServer 在跑」，每 7 天会自动续签。

## 为什么不做"内置重签"

考虑过把重签做进桥里（用户点一下就续 7 天），结论是**不做**：

- 需要用户的 **Apple ID 账号密码**，还要处理双重认证 —— 让一个开源 iOS 遥控器替你保管 Apple 账号，风险远大于收益
- 依赖苹果的私有接口（Anisette / 开发者门户签发证书），随时可能失效
- 已经成熟的方案（AltStore / SideStore / Sideloadly）在做同一件事，重复造轮子没有意义

所以我们做的是"**让它更容易被这些工具接管**"：
- App 自己读描述文件，在设置页显示「还剩 N 天」，并把到期时间报给电脑端面板
- 提供本仓库的 AltStore 源，装和更新都不用再传 IPA
- 文档写清"覆盖安装不丢配对"（Keychain 里的设备私钥不会被清）

## 常见坑

| 现象 | 原因 |
|---|---|
| 到点没自动续 | 手机没连同一 WiFi / AltServer 没开 / 低电量模式限制后台刷新 |
| 提示 "Could not find AltServer" | 路由器开了 AP 隔离，或防火墙拦了 mDNS（5353/UDP） |
| 续签成功但 App 打不开 | 证书信任掉了：设置 → 通用 → VPN与设备管理 → 重新信任 |
| 想换源里的版本但没更新 | AltStore 按 `versions[].version` 判断，源的 JSON 要跟着 Release 一起更新 |
