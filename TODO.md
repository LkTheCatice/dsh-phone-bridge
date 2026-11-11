# 待办与优化清单

> 状态：等用户发「新图标 + 新软件名」后一起做，然后跑基础验证。

## 已修（不用再动）

| 项 | 修法 |
|---|---|
| `lastSeq` 未持久化 | 每 20 帧落 UserDefaults；`refresh()` 里检测服务端重启并归零 |
| `entries` 无上限 | 单会话超 600 条丢最老 |
| `ImageCache` 无上限 | 24 张 LRU 淘汰 |
| 长对话回不到底部 | 右下角浮动按钮（>8 条时出现） |
| 看图只能看不能存 | 双指缩放 1–8×、拖动平移、双击放大、存相册、系统分享 |
| 表格显示成管道符 | 自写 Markdown 渲染（表格/代码块/列表/引用） |
| 过程 log 堆叠 | 一轮结束把思考+工具调用折成「本轮过程 · N 步」 |
| 图片路径盘符被吃 | 正则支持 `D:/` 正斜杠形式 |
| 会话标题读不到 | 两条读取路径 + `/v1/debug/title` 诊断 + turn.end 后延迟 3 秒刷新 |
| `+` 里点图片没反应 | `PhotosPicker` 从 Menu 里挪出来，改 `photosPicker(isPresented:)` |

## 高优先（每天碍事，都是小改动）

- [ ] **1. 草稿按会话保存** —— 切会话时输入框内容会串。改法：`drafts: [String: String]`，切会话时换。
- [ ] **2. 会话列表加搜索** —— 40+ 会话只能手滚。改法：`.searchable`。
- [ ] **3. 断线横幅** —— 现在只有顶栏一个点变色。改法：顶部横幅「连接断开，重连中…」+ 手动重连。

## 中优先

- [ ] **4. 附件上传进度** —— 只有「正在上传…」。改法：分块循环里更新百分比。
- [ ] **5. 错误改 toast** —— alert 会打断操作。改法：顶部 toast，3 秒消失。
- [ ] **6. 消息时间戳** —— 间隔 >5 分钟时在气泡下显示相对时间。
- [ ] **7. 归档会话可见** —— 归档后会话直接消失。要服务端加「已归档列表」端点。
- [ ] **8. 模型推理强度** —— `modelCatalog` 已返回 `reasoning.efforts`，UI 没展示。

## 低优先

- [ ] 9. 文件页建目录 / 删除（服务端加 fs 端点）
- [ ] 10. 手机上管设备（拉黑/批准）—— 把 `/admin/devices` 搬进 App 设置页，要解决鉴权
- [ ] 11. 消息长按菜单（复制 / 引用 / 重发）
- [ ] 12. Bark 通知（等用户给 key）
- [ ] 13. 从相册直接粘贴图片
- [ ] 14. 首次使用引导

## 本轮要做（等用户提供素材）

- [x] **换 App 名称 → DSH Helm** —— 已改 `CFBundleDisplayName`（一行）。
      未动：`PRODUCT_NAME`（产物仍叫 DSHRemote，CI 路径不用改）、
      `PRODUCT_BUNDLE_IDENTIFIER`（`dev.yg.dshremote`，改了签名会变、手机上会当新 App）、
      Keychain service（`dev.yg.dshremote`，改了配对信息读不到）、工程名。
      → 结论：改名不会导致重新配对。
- [ ] **换 App 图标** —— 用户会发新图（需要抠图/裁切成 1024×1024 无 alpha）

## 改名的注意点（提前记下）

改名涉及四处，漏一处就会显示不一致：

1. `project.yml` → `info.properties.CFBundleDisplayName`（主屏显示名）
2. `project.yml` → `settings.base.PRODUCT_NAME`（产物名，会影响 ipa 内 .app 目录名）
3. 配对页/设置页里写死的「DSH 遥控」文案
4. `CFBundleDocumentTypes` 的 `CFBundleTypeName`（「用其他应用打开」列表里显示的名字）

Bundle ID 建议**不动**（`dev.yg.dshremote`）—— 改了签名会变，手机上会被当成新 App，配对信息丢失。
