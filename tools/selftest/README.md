# 本地自测（Windows，无 Xcode 也能跑）

用途：在提交前验证**不依赖 UIKit/SwiftUI 的那一层逻辑** —— 今晚两次崩溃
（`Dictionary(uniqueKeysWithValues:)` 重复 key、`NSRange` 越界）都属于这一层，
本来就该在这里被拦住，而不是让用户在手机上撞。

## 用法

```powershell
cd phone-dsh\tools\selftest
.\run.ps1
```

成功时输出 `✅ 全部通过`，退出码 0；失败会列出每一项并退出码 1。

## 它测什么

| 分组 | 内容 |
|---|---|
| 解析器边界 | 空串/只有空白/未闭合代码块/未闭合粗体/畸形表格/超长单行/嵌套引用/极多空行… 都不许崩、不许解析出空块、block id 不许重复 |
| 解析分类 | 标题/代码块/列表/表格/引用 是否落到正确的 Block 类型 |
| NSRange 操作 | 复现 `MarkdownNS` 的多轮替换写法，验证每轮重算 range、无越界、无标记残留 |
| 去重逻辑 | 复现 `ChatList.apply` 的 id 去重，验证重复 id 不会进查找表 |

## 它测不到什么（必须在真机 / macOS 上验）

- `UICollectionView` / `UITextView` 的布局、复用、滚动行为
- SwiftUI 的 body 求值频率、`@StateObject` 订阅、`safeAreaInset` 高度变化
- 键盘、输入法、手势

所以 UIKit 层的改动仍然要求：**一次只改一处、CI 编译通过、真机上看 `STUCK`/`hb` 数字**。

## 前置条件

- Swift 工具链（`winget install Swift.Toolchain`），本机版本 6.4.2
- 脚本会自动定位 `swiftc.exe` 与 `swiftCore.dll`，无需手动设 PATH

## 编译的是哪份代码

`ios/DSHRemote/Sources/Core/MarkdownModel.swift` —— 项目里的**真实文件**，
不是测试副本。所以这里测过 = App 里跑的是同一份逻辑。
