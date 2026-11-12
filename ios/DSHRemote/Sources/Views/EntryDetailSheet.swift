import SwiftUI

/// 单条消息的完整内容（表格不折叠、不截断）。
///
/// 为什么需要它：
/// 列表里的表格为了保住滚动性能做了三层截断 ——
/// 最多 5 列、最多 10 行、超出总宽按比例压缩单元格。
/// 被截掉的内容不能就这么消失，所以点一下消息就能在这里看完整版。
///
/// 这里可以「慢」：一次只渲染一条，而且用户是主动点开等它的。
struct EntryDetailSheet: View {
    let entry: ChatEntry
    @Environment(\.dismiss) private var dismiss
    @State private var showRaw = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if showRaw {
                        Text(entry.text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // 完整渲染：表格按卡片式展开，不截行列
                        Text(MarkdownNS.render(entry.text, mode: .full))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
            .navigationTitle(showRaw ? "原文" : "完整内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(showRaw ? "渲染" : "原文") { showRaw.toggle() }
                        .font(.footnote)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
