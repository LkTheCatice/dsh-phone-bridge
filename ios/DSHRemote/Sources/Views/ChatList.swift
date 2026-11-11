import SwiftUI
import UIKit

/// 聊天列表：UICollectionView + cell 复用。
///
/// 为什么换掉 SwiftUI 的 `LazyVStack`：
/// - `LazyVStack` **没有 cell 复用**，视图是值类型，内容一变就重建子树；
///   22 条消息滚动就能卡 13 秒（实测）。
/// - `UICollectionView` 的 cell 会被复用，滚动成本与消息总数无关；
///   这是 QQ / 微信这类客户端的标准做法。
///
/// 一条消息 = 一个 cell = 一个视图，节点数从 N 降到 1。
struct ChatList: UIViewRepresentable {
    let entries: [ChatEntry]
    let isStreaming: Bool
    /// 用户是否在底部（滚动位置变化时回调）
    let onBottomChanged: (Bool) -> Void
    /// 需要「滚到底」时由外部改这个 token（每次变化触发一次滚动）
    let scrollRequest: Int
    /// 点击某条消息（用于展开/收起富文本）
    let onTapEntry: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewCompositionalLayout { _, environment in
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(80)
                )
            )
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(80)
                ),
                subitems: [item]
            )
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 10
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
            return section
        }

        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.contentInsetAdjustmentBehavior = .never
        view.register(MessageCell.self, forCellWithReuseIdentifier: MessageCell.reuseID)
        view.delegate = context.coordinator

        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(entries)
        context.coordinator.handleScrollRequest(scrollRequest)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate {
        var parent: ChatList
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<String, String>!
        private var lookup: [String: ChatEntry] = [:]
        private var lastScrollRequest = -1
        private var lastBottomValue: Bool?

        init(_ parent: ChatList) {
            self.parent = parent
        }

        func attach(_ view: UICollectionView) {
            collectionView = view
            dataSource = UICollectionViewDiffableDataSource<String, String>(collectionView: view) { [weak self] cv, indexPath, id in
                let cell = cv.dequeueReusableCell(withReuseIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
                if let entry = self?.lookup[id] {
                    cell.configure(entry, streaming: self?.parent.isStreaming ?? false)
                }
                return cell
            }
            view.dataSource = dataSource
        }

        /// 增量应用：Diffable 会自己算差异，只更新真正变化的 cell
        ///
        /// ⚠️ 必须去重：`Dictionary(uniqueKeysWithValues:)` 遇到重复 key 会直接
        /// fatal error，而启动时「历史回填」与「实时帧」会写进同一个
        /// `sid#turn5` 这样的 id（实测启动闪退一次）。快照同样不允许重复 item。
        func apply(_ entries: [ChatEntry]) {
            var seen = Set<String>()
            var unique: [ChatEntry] = []
            unique.reserveCapacity(entries.count)
            for entry in entries where seen.insert(entry.id).inserted {
                unique.append(entry)
            }
            lookup = Dictionary(unique.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            snapshot.appendSections(["main"])
            snapshot.appendItems(unique.map(\.id), toSection: "main")
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        func handleScrollRequest(_ token: Int) {
            guard token != lastScrollRequest else { return }
            lastScrollRequest = token
            scrollToBottom(animated: false)
        }

        func scrollToBottom(animated: Bool) {
            guard let cv = collectionView else { return }
            let items = dataSource.snapshot().itemIdentifiers.count
            guard items > 0 else { return }
            let target = IndexPath(item: items - 1, section: 0)
            // 防御：布局尚未完成时 scrollToItem 会抛异常
            guard cv.numberOfSections > 0,
                  cv.numberOfItems(inSection: 0) > target.item else { return }
            cv.scrollToItem(at: target, at: .bottom, animated: animated)
        }

        // MARK: UIScrollViewDelegate（通过 collectionView.delegate 转发）

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let height = scrollView.contentSize.height
            let offset = scrollView.contentOffset.y
            let viewport = scrollView.bounds.height
            guard height > viewport else { report(bottom: true); return }
            let distance = height - (offset + viewport)
            // 滞后：靠近底部 40pt 内算在底部，离开 200pt 才算离开
            if distance < 40 {
                report(bottom: true)
            } else if distance > 200 {
                report(bottom: false)
            }
        }

        private func report(bottom: Bool) {
            guard lastBottomValue != bottom else { return }
            lastBottomValue = bottom
            parent.onBottomChanged(bottom)
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
            guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
            parent.onTapEntry(id)
        }
    }
}

// MARK: - Cell

/// 一条消息一个 cell。第一版先用 UITextView 承载纯文本（富文本在下一阶段接上）。
final class MessageCell: UICollectionViewCell {
    static let reuseID = "MessageCell"

    private let textView = UITextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.isEditable = false
        textView.isScrollEnabled = false          // 高度由内容决定，交给 cell
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        textView.attributedText = nil
    }

    func configure(_ entry: ChatEntry, streaming: Bool) {
        textView.attributedText = MessageRender.attributed(entry)
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        setNeedsLayout()
        layoutIfNeeded()
        let width = layoutAttributes.size.width
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let size = contentView.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        var attributes = layoutAttributes
        attributes.size.height = ceil(size.height)
        return attributes
    }
}

// MARK: - 渲染（第一版：纯文本 + 角色区分）

enum MessageRender {
    static func attributed(_ entry: ChatEntry) -> NSAttributedString {
        let text = entry.text.isEmpty ? "（空）" : String(entry.text.prefix(4_000))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2

        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]

        switch entry.kind {
        case .user:
            attributes[.foregroundColor] = UIColor.label
        case .assistant:
            break
        case .thinking:
            attributes[.font] = UIFont.italicSystemFont(ofSize: 13)
            attributes[.foregroundColor] = UIColor.secondaryLabel
        case .toolCall:
            attributes[.font] = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            attributes[.foregroundColor] = UIColor.secondaryLabel
        case .collapsedSteps:
            attributes[.font] = UIFont.systemFont(ofSize: 12)
            attributes[.foregroundColor] = UIColor.tertiaryLabel
        case .system, .toolResult:
            attributes[.font] = UIFont.systemFont(ofSize: 11)
            attributes[.foregroundColor] = UIColor.tertiaryLabel
        }

        let body = NSMutableAttributedString(string: text, attributes: attributes)

        // 前缀标记，先代替原有气泡视觉
        let prefix: String
        switch entry.kind {
        case .user: prefix = "我："
        case .assistant: prefix = entry.running ? "AI（正在生成）" : "AI："
        case .thinking: prefix = "思考："
        case .toolCall: prefix = "> "
        case .collapsedSteps: prefix = "▸ "
        case .system: prefix = ""
        case .toolResult: prefix = ""
        }
        if !prefix.isEmpty {
            let head = NSAttributedString(string: prefix, attributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor.tertiaryLabel,
            ])
            body.insert(head, at: 0)
        }
        return body
    }
}
