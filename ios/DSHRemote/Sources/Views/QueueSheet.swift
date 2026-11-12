import SwiftUI

/// 排队详情：把队列里的每一条单独列出来，支持编辑与插队。
///
/// 数据来源是 ChatStore.queue —— 它由桥转发的 queue.changed 帧维护，
/// 电脑端排的队也在里面（两边读同一份）。
///
/// 关于「编辑到一半队列变了」的处理（用户明确要求）：
/// 编辑的是队列里的**某一条**，用户可能在编辑期间：
///   · 那一条被执行了（被 DSH 取走）
///   · 那一条被别处取消了
///   · 队列插进了新的条目，位置全变了
/// 所以编辑/插队都按 **rpcId** 定位而不是按下标：
/// 提交时如果队列里已经找不到这个 rpcId，就明确告诉用户「这条已经不在队列里了」，
/// 而不是把改动套到别人的位置上。
struct QueueSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss

    /// 正在编辑的那一条（按 rpcId 记，不按下标）
    @State private var editing: QueueItem?
    @State private var draft: String = ""
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Group {
                if chat.queue.isEmpty {
                    // 不用 ContentUnavailableView：它要 iOS 17+，
                    // 而本项目部署目标更低（CI 直接报只读 API 不可用）。
                    VStack(spacing: 10) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                        Text("队列是空的")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("当前没有排队的消息。\n发送新消息时会自动排到队尾。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(Array(chat.queue.enumerated()), id: \.element.rpcId) { index, item in
                                row(index: index, item: item)
                            }
                        } header: {
                            Text("排队中 · \(chat.queue.count) 条")
                        } footer: {
                            Text("电脑端排的队也会出现在这里。点「插队」可以让它立刻执行。")
                        }
                    }
                }
            }
            .navigationTitle("排队")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.bar)
                }
            }
            .sheet(item: $editing) { item in
                editor(for: item)
            }
        }
    }

    @ViewBuilder
    private func row(index: Int, item: QueueItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                // 序号徽标：一眼看出排队次序
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle().fill(index == 0 ? Color.accentColor : Color.secondary.opacity(0.45))
                    )
                Text(item.text)
                    .font(.callout)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 18) {
                Button {
                    beginEdit(item)
                } label: {
                    Label("编辑", systemImage: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Button {
                    remove(item)
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red.opacity(0.85))
                .disabled(true)   // 写接口还没打通，先占位

                Button {
                    steer(item)
                } label: {
                    Label("插队", systemImage: "arrow.up.to.line")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(true)   // 写接口还没打通，先占位
            }
        }
        .padding(.vertical, 7)
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
                .padding(.vertical, 3)
        )
    }

    private func beginEdit(_ item: QueueItem) {
        // 编辑前记下 rpcId：队列随时会变，提交时要确认这条还在
        editing = item
        draft = item.text
        notice = nil
    }

    private func remove(_ item: QueueItem) {
        // 删除 = splice(target: next-turn, start: 该条位置, removedCount: 1, inserted: [])
        // 语义已经确认（事件里有 removedCount 字段），但还没有能调用的写接口。
        let stillThere = chat.queue.contains { $0.rpcId == item.rpcId }
        notice = stillThere ? "删除接口还在打通中" : "这条已经不在队列里了"
    }

    private func steer(_ item: QueueItem) {
        // 写入口未打通（DSH 的 splice 还没找到可调用的 API）
        notice = "插队接口还在打通中"
    }

    @ViewBuilder
    private func editor(for item: QueueItem) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("编辑排队中的消息")
                    .font(.headline)
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editing = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commitEdit(item) }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func commitEdit(_ item: QueueItem) {
        // 极端情况：编辑期间那一条已经被执行/取消 —— 队列里找不到同一个 rpcId。
        // 这时绝不能「按下标改」，否则会改到别人的那条上。
        let stillThere = chat.queue.contains { $0.rpcId == item.rpcId }
        guard stillThere else {
            notice = "这条已经不在队列里了（可能已经开始执行），改动没有保存"
            editing = nil
            return
        }
        notice = "编辑接口还在打通中"
        editing = nil
    }
}
