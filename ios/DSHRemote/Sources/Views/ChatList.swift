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
    /// 点击「📎 附件」提示行（打开媒体面板）
    let onTapAttachments: (String) -> Void

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
        // ⚠️ 不能用 .interactive：每输入一个字符，输入框高度变化会让 safeAreaInset
        // 跟着变 → 列表调整 contentOffset → 触发滚动事件 → interactive 模式下
        // 键盘立刻开始收起（用户实测：按任意键输入框就被「下拉」）。
        // .onDrag 只在手指真正拖动列表时才收键盘。
        view.keyboardDismissMode = .onDrag
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
                    cell.configure(
                        entry,
                        streaming: self?.parent.isStreaming ?? false,
                        onTapAttachments: { [weak self] in
                            self?.parent.onTapAttachments(id)
                        }
                    )
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
    /// 「📎 2 张图片 · 1 个视频」提示行；无附件时高度为 0
    private let attachmentLabel = UILabel()
    private var onTapAttachments: (() -> Void)?
    /// 当前渲染的条目（高度缓存要按它生成 key）
    private var currentEntry: ChatEntry?

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.isEditable = false
        textView.isScrollEnabled = false          // 高度由内容决定，交给 cell
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        attachmentLabel.font = .systemFont(ofSize: 12)
        attachmentLabel.textColor = .secondaryLabel
        attachmentLabel.numberOfLines = 1
        attachmentLabel.isUserInteractionEnabled = true
        attachmentLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleTapAttachments))
        )

        let stack = UIStackView(arrangedSubviews: [textView, attachmentLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        textView.attributedText = nil
        currentEntry = nil
        attachmentLabel.text = nil
        attachmentLabel.isHidden = true
        onTapAttachments = nil
    }

    @objc private func handleTapAttachments() {
        onTapAttachments?()
    }

    func configure(_ entry: ChatEntry, streaming: Bool, onTapAttachments: (() -> Void)?) {
        currentEntry = entry
        textView.attributedText = MessageRender.attributed(entry)
        self.onTapAttachments = onTapAttachments

        // 附件提示：只在真的有媒体时占位（用 MediaRefScan，纯 Foundation，已单测）
        let refs = MediaRefCache.refs(for: entry.text)
        if refs.isEmpty {
            attachmentLabel.isHidden = true
            attachmentLabel.text = nil
        } else {
            var parts: [String] = []
            if !refs.images.isEmpty { parts.append("\(refs.images.count) 张图片") }
            if !refs.videos.isEmpty { parts.append("\(refs.videos.count) 个视频") }
            if !refs.audios.isEmpty { parts.append("\(refs.audios.count) 段音频") }
            attachmentLabel.text = "📎 " + parts.joined(separator: " · ") + "，点按查看"
            attachmentLabel.isHidden = false
        }

    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let width = layoutAttributes.size.width
        let key = cacheKey(for: layoutAttributes, width: width)
        if let key, let cached = Self.heightStorage[key], abs(cached.width - width) < 0.5 {
            var attributes = layoutAttributes
            attributes.size.height = cached.height
            return attributes
        }

        setNeedsLayout()
        layoutIfNeeded()
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let size = contentView.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let height = ceil(size.height)
        if let key { Self.store(key: key, height: height, width: width) }

        var attributes = layoutAttributes
        attributes.size.height = height
        return attributes
    }

    /// 高度缓存用「id + 内容长度 + 附件数」作 key：内容一变就不复用旧高度。
    /// 不用 attributed string 的 hash —— 那个在每个 cell 上算一次比测量还贵。
    private func cacheKey(for attributes: UICollectionViewLayoutAttributes, width: CGFloat) -> String? {
        guard let entry = currentEntry else { return nil }
        return "\(entry.id)|\(entry.text.count)|\(entry.summary?.count ?? 0)|\(Int(width))"
    }

    /// 高度缓存。**有上限**（LRU 600 条），避免长会话把内存吃满。
    private struct CachedHeight { let height: CGFloat; let width: CGFloat }
    private static var heightStorage: [String: CachedHeight] = [:]
    private static var heightOrder: [String] = []
    private static let heightCapacity = 600

    private static func store(key: String, height: CGFloat, width: CGFloat) {
        if heightStorage[key] == nil {
            heightOrder.append(key)
            if heightOrder.count > heightCapacity {
                let drop = heightOrder.removeFirst()
                heightStorage.removeValue(forKey: drop)
            }
        }
        heightStorage[key] = CachedHeight(height: height, width: width)
    }
}

// MARK: - 渲染（第一版：纯文本 + 角色区分）

enum MessageRender {
    static func attributed(_ entry: ChatEntry) -> NSAttributedString {
        let out = NSMutableAttributedString()

        // 角色前缀（一条小字），正文用 markdown 富文本
        if let prefix = prefix(for: entry) {
            let color: UIColor = (entry.kind == .user) ? .tintColor : .tertiaryLabel
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 2
            out.append(NSAttributedString(
                string: prefix,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                ]
            ))
        }

        let body: NSAttributedString
        switch entry.kind {
        case .assistant where !entry.running:
            // 完成态回答走 markdown → 单个 NSAttributedString（代码块/列表/引用都在里面）
            body = MarkdownNS.render(entry.text)
        case .thinking:
            body = NSAttributedString(
                string: entry.text,
                attributes: [
                    .font: UIFont.italicSystemFont(ofSize: 13),
                    .foregroundColor: UIColor.secondaryLabel,
                ]
            )
        case .toolCall:
            var text = entry.text
            if let summary = entry.summary, !summary.isEmpty { text += " · " + summary }
            body = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel,
                ]
            )
        case .system, .toolResult:
            body = NSAttributedString(
                string: entry.text,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11),
                    .foregroundColor: UIColor.tertiaryLabel,
                ]
            )
        default:
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            body = NSAttributedString(
                string: entry.text,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 16),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: paragraph,
                ]
            )
        }
        out.append(body)
        return out
    }

    private static func prefix(for entry: ChatEntry) -> String? {
        switch entry.kind {
        case .user: return "▍我\n"
        case .assistant: return entry.running ? "▍AI（正在生成）\n" : "▍AI\n"
        case .thinking: return "思考\n"
        case .toolCall: return "> "
        case .collapsedSteps: return "▸ "
        case .system, .toolResult: return nil
        }
    }
}
