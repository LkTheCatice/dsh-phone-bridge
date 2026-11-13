# 推送测试 · 2026-11-13 11:17

这条文件用来验证「文件产出提示」：

- 桥在 `tool/call` 时检测到 `file_path` 且扩展名属于产物类（md / docx / pptx / pdf / ipa / zip …）
- 就会多发一帧 `file.output`
- 手机上应出现一条灰色小字：`📄 输出文件 · PUSH-TEST.md`

如果手机上没看到，请把 `/v1/diag` 的 `frames` 里有没有 `file.output` 告诉我——
有帧没显示 = 手机端渲染问题；没帧 = 桥侧没识别到路径。
