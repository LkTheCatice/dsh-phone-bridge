import Foundation
import SwiftUI
import UIKit

/// 动效档位：效率 / 均衡 / 质量。
///
/// 这个 App 真正的开销不在渲染，而在**流式刷新时反复重排**：
/// 每一帧进来都要重算 attributed string 和高度缓存，动画叠上去会让主线程更忙。
/// 所以"效率"档的做法是：**关掉动画、去掉模糊材质、缩短过渡**，而不是减少功能。
///
/// 另外：系统开了「减弱动态效果」时，无论选哪档都按效率处理。
enum MotionLevel: String, CaseIterable, Identifiable {
    case efficiency, balanced, quality

    var id: String { rawValue }

    var label: String {
        switch self {
        case .efficiency: return L("效率", "Efficiency")
        case .balanced: return L("均衡", "Balanced")
        case .quality: return L("质量", "Quality")
        }
    }

    /// 设置页里的一行说明
    var summary: String {
        switch self {
        case .efficiency:
            return L("关闭过渡与模糊，列表插入、提示条、跳转都直接到位。最省电、最不容易卡。",
                     "No transitions or blur — inserts, toasts and jumps land instantly. Cheapest and smoothest on old devices.")
        case .balanced:
            return L("默认。保留必要的过渡（提示条、横幅），其它即时生效。",
                     "Default. Keeps the transitions that carry meaning (toasts, banners); everything else is instant.")
        case .quality:
            return L("过渡更从容：弹性回弹、轻微缩放、材质模糊。比均衡更「贵」一点。",
                     "More generous motion: springs, slight scale, blur materials. A bit more expensive than Balanced.")
        }
    }
}

final class UIMotion: ObservableObject {
    static let shared = UIMotion()
    private static let storeKey = "dsh.motion"

    @Published private(set) var level: MotionLevel
    @Published private(set) var reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storeKey) ?? MotionLevel.balanced.rawValue
        level = MotionLevel(rawValue: raw) ?? .balanced

        NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reduceMotion = UIAccessibility.isReduceMotionEnabled
        }
    }

    func set(_ next: MotionLevel) {
        guard next != level else { return }
        level = next
        UserDefaults.standard.set(next.rawValue, forKey: Self.storeKey)
    }

    /// 是否允许过渡动画
    var animationsEnabled: Bool {
        guard !reduceMotion else { return false }
        return level != .efficiency
    }

    /// 过渡时长系数：质量档略长，让动作"从容"一点
    var durationScale: Double {
        switch level {
        case .efficiency: return 0.6
        case .balanced: return 1.0
        case .quality: return 1.25
        }
    }

    /// 流式帧合并间隔（秒）。
    ///
    /// 真正的大头不在动画，而在**每一帧都重排一次 attributed string + 高度缓存**。
    /// 把进来的帧攒一小会儿再一次性应用，SwiftUI 只重绘一次：
    ///   效率 120ms（≈8 次/秒，肉眼够用，主线程压力降 ~8 倍）
    ///   均衡 33ms（≈30 次/秒）
    ///   质量 16ms（≈60 次/秒，最顺）
    var streamInterval: TimeInterval {
        guard !reduceMotion else { return 0.12 }
        switch level {
        case .efficiency: return 0.12
        case .balanced: return 0.033
        case .quality: return 0.016
        }
    }

    /// 是否用模糊材质（效率档换成实色，省 GPU）
    var usesMaterials: Bool { animationsEnabled }

    /// 统一取动画：效率档返回 nil = 直接到位
    func animation(_ base: Animation = .easeOut(duration: 0.22)) -> Animation? {
        animationsEnabled ? base : nil
    }

    /// 质量档用弹簧，其余用缓出
    func spring(_ response: Double = 0.32) -> Animation? {
        guard animationsEnabled else { return nil }
        return level == .quality
            ? .spring(response: response * durationScale, dampingFraction: 0.82)
            : .easeOut(duration: 0.2 * durationScale)
    }

    /// 过渡：效率档直接 identity（没有入场动画）。
    /// 参数用 AnyTransition 而不是泛型 Transition —— 泛型会让 `.move(edge:)`
    /// 解析到 iOS 17 才有的静态成员，在 iOS 16 上编译不过（CI 已踩）。
    func transition(_ t: AnyTransition) -> AnyTransition {
        animationsEnabled ? t : .identity
    }

    /// 材质：效率档回落成不透明色
    func material(_ material: Material, fallback: Color) -> AnyShapeStyle {
        usesMaterials ? AnyShapeStyle(material) : AnyShapeStyle(fallback)
    }
}

/// 便捷入口：`Motion.anim()` / `Motion.spring()` / `Motion.transition(_:)`
enum Motion {
    static var ui: UIMotion { .shared }

    static func anim(_ base: Animation = .easeOut(duration: 0.22)) -> Animation? {
        ui.animation(base)
    }

    static func spring(_ response: Double = 0.32) -> Animation? {
        ui.spring(response)
    }

    static func transition(_ t: AnyTransition) -> AnyTransition {
        ui.transition(t)
    }

    static func material(_ material: Material, fallback: Color) -> AnyShapeStyle {
        ui.material(material, fallback: fallback)
    }

    static var enabled: Bool { ui.animationsEnabled }
}
