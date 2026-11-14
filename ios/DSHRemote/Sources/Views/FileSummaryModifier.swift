import SwiftUI

/// 把「全部产物 → 点一个 → 打开文件」这条 sheet 链收进一个 modifier。
///
/// 为什么要单独拆出来：ChatView 的主 body 已经挂了十几个 modifier，
/// 再往里塞一个带闭包的 sheet，Swift 的类型推断会超时
/// （CI 报 "unable to type-check this expression in reasonable time"，
/// 指向的正是 `.sheet(item: $editorImage)` 那一行 —— 被前面新增的 sheet 拖累）。
struct FileSummaryModifier: ViewModifier {
    @Binding var entry: ChatEntry?
    let onPick: (ChatEntry) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $entry) { summary in
            FileSummarySheet(files: summary.folded, onPick: onPick)
        }
    }
}
