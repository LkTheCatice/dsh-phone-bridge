import SwiftUI

/// 图片编辑 sheet 的封装。
///
/// 为什么要抽出来：ChatView 的 body 是一个超长 modifier 链，
/// 里面这个 `ImageEditorSheet` 带两个多语句闭包，Swift 对整条表达式做类型推断时
/// 直接超时（CI：ChatView.swift:331 unable to type-check ... in reasonable time）。
/// 抽成 modifier 之后，body 里只剩一行，推断成本回到正常。
struct ImageEditorModifier: ViewModifier {
    @Binding var image: UIImage?
    @Binding var editingIndex: Int?
    @Binding var continuation: CheckedContinuation<UIImage?, Never>?
    let onReplace: (Int, UIImage) async -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $image) { source in
            ImageEditorSheet(
                image: source,
                onCommit: { merged in commit(merged) },
                onCancel: { cancel() }
            )
        }
    }

    private func commit(_ merged: UIImage) {
        let index = editingIndex
        image = nil
        editingIndex = nil
        if let index {
            Task { await onReplace(index, merged) }
        } else {
            continuation?.resume(returning: merged)
        }
        continuation = nil
    }

    private func cancel() {
        image = nil
        editingIndex = nil
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
