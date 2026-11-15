import Foundation
import SwiftUI

/// 外观主题：跟随系统 / 浅色 / 深色。
///
/// 界面里几乎没有写死的颜色（全是 `.label` / `.quaternary` / `.bar` 这类语义色），
/// 所以这里只要把 `colorScheme` 挂到根视图，整套跟着变，不需要逐页改。
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L("跟随系统", "Follow system")
        case .light: return L("浅色", "Light")
        case .dark: return L("深色", "Dark")
        }
    }

    /// nil = 不干预，交给系统
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

final class UITheme: ObservableObject {
    static let shared = UITheme()
    private static let storeKey = "dsh.theme"

    @Published private(set) var selection: AppTheme

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storeKey) ?? AppTheme.system.rawValue
        selection = AppTheme(rawValue: raw) ?? .system
    }

    func set(_ next: AppTheme) {
        guard next != selection else { return }
        selection = next
        UserDefaults.standard.set(next.rawValue, forKey: Self.storeKey)
    }
}
