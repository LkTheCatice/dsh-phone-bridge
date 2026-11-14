import SwiftUI

/// ChatView 上所有「弹出层」集中在这里。
///
/// 为什么合并：ChatView 的 body 已经是一条很长的 modifier 链，每多挂一个 `.sheet`
/// 就会让 Swift 对整个表达式做一次类型推断 —— 加两个就直接超时
/// （CI：ChatView.swift:326 unable to type-check ... in reasonable time）。
/// 把四个 sheet 收进一个 modifier，body 里只多一行。
struct ChatSheetsModifier: ViewModifier {
    @Binding var summaryEntry: ChatEntry?
    @Binding var forwardPath: String?
    @Binding var showDraftEditor: Bool
    @Binding var draft: String
    @Binding var editorImage: UIImage?
    @Binding var editingIndex: Int?
    @Binding var editorContinuation: CheckedContinuation<UIImage?, Never>?

    let onPickSummaryFile: (ChatEntry) -> Void
    let onReplaceAttachment: (Int, UIImage) async -> Void

    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $summaryEntry) { summary in
                FileSummarySheet(files: summary.folded, onPick: onPickSummaryFile)
            }
            .sheet(item: $forwardPath) { path in
                ForwardSessionSheet(path: path).environmentObject(model)
            }
            .sheet(isPresented: $showDraftEditor) {
                DraftEditorSheet(text: $draft)
            }
            .sheet(item: $editorImage) { source in
                ImageEditorSheet(
                    image: source,
                    onCommit: { merged in commitEditor(merged) },
                    onCancel: { cancelEditor() }
                )
            }
    }

    private func commitEditor(_ merged: UIImage) {
        let index = editingIndex
        editorImage = nil
        editingIndex = nil
        if let index {
            Task { await onReplaceAttachment(index, merged) }
        } else {
            editorContinuation?.resume(returning: merged)
        }
        editorContinuation = nil
    }

    private func cancelEditor() {
        editorImage = nil
        editingIndex = nil
        editorContinuation?.resume(returning: nil)
        editorContinuation = nil
    }
}
