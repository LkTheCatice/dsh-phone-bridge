import SwiftUI

/// 全屏写长指令。
///
/// 为什么需要：输入框最高 140pt（约 5 行），写"给它一段完整需求"时看不到全貌，
/// 上下翻来翻去很容易漏掉半句。这里给一个整屏 TextEditor，
/// 内容直接绑到同一个 draft，点「完成」就落回输入框。
struct DraftEditorSheet: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(size: 16))
                .padding(.horizontal, 12)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .background(Color(.systemBackground))
                .navigationTitle(L("写指令", "Compose"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(L("清空", "Clear")) { text = "" }
                            .disabled(text.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("完成", "Done")) { dismiss() }.bold()
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 6) {
                        Text(L("\(text.count) 字", "\\(text.count) chars"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(L("换行用键盘回车；完成后回到输入框直接发送", "Press return for a new line; go back to the composer to send"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
                .onAppear { focused = true }
        }
    }
}
