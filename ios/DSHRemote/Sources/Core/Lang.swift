import Foundation
import SwiftUI

/// 语言选择：跟随系统 / 中文 / English。
///
/// 为什么用"中文原文当 key"而不是 `settings.signing.title` 这种键：
/// 这个项目 383 条中文串已经散在 30 个文件里，先立键表再迁移要来回对两遍；
/// 用原文当 key，改造一行就是一行，漏了也还是显示中文（不会变成 key 名）。
/// 代价是"改中文文案 = 要同步改英文"，所以约定：**中文文案定稿后才进 L()**。
enum AppLang: String, CaseIterable, Identifiable {
    case system, zh, en

    var id: String { rawValue }

    /// 语言名用各自语言书写，永远不翻译（切错了也能找回来）
    var label: String {
        switch self {
        case .system: return L("跟随系统", "Follow system")
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }
}

/// 极简 i18n：一个进程内单例 + 一个 `L()` 函数。
///
/// 切换语言时：
///   1. 写 UserDefaults
///   2. `langToken` +1（`@Published`，驱动 SwiftUI 重算）
///   3. 根视图挂 `.id(langToken)`，强制整棵树重建
///   4. UIKit 部分（ChatList）监听同一个通知，`reloadData()`
final class I18N: ObservableObject {
    static let shared = I18N()

    static let changed = Notification.Name("dsh.i18n.changed")
    private static let storeKey = "dsh.lang"

    @Published private(set) var selection: AppLang
    @Published private(set) var token: Int = 0

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storeKey) ?? AppLang.system.rawValue
        selection = AppLang(rawValue: raw) ?? .system
    }

    /// 真正生效的语言（system 会解析成 zh / en）
    var lang: AppLang {
        guard selection == .system else { return selection }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .zh : .en
    }

    var isEnglish: Bool { lang == .en }

    func set(_ next: AppLang) {
        guard next != selection else { return }
        selection = next
        UserDefaults.standard.set(next.rawValue, forKey: Self.storeKey)
        token &+= 1
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// 取当前语言的文案
    func t(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }
}

/// 全项目唯一的取词入口。
///
/// ```swift
/// Text(L("设置", "Settings"))
/// ```
/// 只用于**界面文案**；会话内容、文件路径、命令一律不经过这里。
func L(_ zh: String, _ en: String) -> String { I18N.shared.t(zh, en) }

/// 带参数的版本（顺序参数，够用且不用记格式符）
func L(_ zh: String, _ en: String, _ args: CVarArg...) -> String {
    let format = I18N.shared.t(zh, en)
    return args.isEmpty ? format : String(format: format, arguments: args)
}
