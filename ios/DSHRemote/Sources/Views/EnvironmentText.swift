import SwiftUI

// MARK: - 文本可选中开关（气泡里的文本选择）

private struct NoTextSelectionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var noTextSelection: Bool {
        get { self[NoTextSelectionKey.self] }
        set { self[NoTextSelectionKey.self] = newValue }
    }
}

private struct MaybeSelectableText: ViewModifier {
    @Environment(\.noTextSelection) private var disabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if disabled {
            content
        } else {
            content.textSelection(.enabled)
        }
    }
}

extension View {
    /// 等价于 `.textSelection(.enabled)`，但受设置页的「禁用文本选择」控制
    func selectableText() -> some View { modifier(MaybeSelectableText()) }
}
