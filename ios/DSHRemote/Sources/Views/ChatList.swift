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
    /// 滚到顶部附近时回调，加载更早的消息
    let onLoadOlder: () -> Void
    /// 点击某条消息（用于展开/收起富文本）
    let onTapEntry: (String) -> Void
    /// 点击「📎 附件」提示行（打开媒体面板）
    let onTapAttachments: (String) -> Void
    /// 点击消息里的链接（dsh:// 自定义 scheme 或普通 URL）
    let onOpenLink: (String, URL) -> Void

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
        // 隐藏滚动条：聊天流里它除了晃眼没别的用（用户要求）
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false

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
        /// 上一次 apply 的内容指纹：没变就整段跳过
        private var lastFingerprint = ""

        init(_ parent: ChatList) {
            self.parent = parent
        }

        func attach(_ view: UICollectionView) {
            collectionView = view
            dataSource = UICollectionViewDiffableDataSource<String, String>(collectionView: view) { [weak self] cv, indexPath, id in
                let cell = cv.dequeueReusableCell(withReuseIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
                if let entry = self?.lookup[id] {
                    let list = self?.parent.entries ?? []
                    let index = list.firstIndex { $0.id == id }
                    let previousKind = (index ?? 0) > 0 ? list[(index ?? 1) - 1].kind : nil
                    let isRoleChange = previousKind != nil && previousKind != entry.kind
                    cell.configure(
                        entry,
                        streaming: self?.parent.isStreaming ?? false,
                        onTapAttachments: { [weak self] in
                            self?.parent.onTapAttachments(id)
                        },
                        onOpenLink: { [weak self] url in
                            self?.parent.onOpenLink(id, url)
                        },
                        isRoleChange: isRoleChange
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
            // 快速指纹：没变就直接返回。
            //
            // 为什么必须加：updateUIView 在任何 SwiftUI 状态变化时都会调，
            // 而流式输出时 tick 每秒十几次 —— 每次都把 300 条重建 lookup、
            // 重新 appendItems、再让 diffable data source 做一次全量 diff。
            // 这是「消息越多越卡」的主因（md 和图片都只在可见 cell 上花时间）。
            let fp = fingerprint(entries)
            guard fp != lastFingerprint else { return }
            lastFingerprint = fp

            var seen = Set<String>()
            var unique: [ChatEntry] = []
            unique.reserveCapacity(entries.count)
            for entry in entries where seen.insert(entry.id).inserted {
                unique.append(entry)
            }

            // 判断这次是不是「在顶部插入了更早的消息」：
            // 首条 id 变了、而且这个 id 之前没见过 —— 那就是往头部插。
            let oldIds = Set(lookup.keys)
            let insertedAtTop: Bool = {
                guard let firstNew = unique.first?.id else { return false }
                return !oldIds.isEmpty && !oldIds.contains(firstNew)
            }()

            // 必须在 apply **之前**取值：apply 之后 contentSize 就是新的了
            let cv = collectionView
            let beforeHeight = cv?.contentSize.height ?? 0
            let beforeOffset = cv?.contentOffset.y ?? 0
            let wasAtTop = beforeOffset < 90

            lookup = Dictionary(unique.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            snapshot.appendSections(["main"])
            snapshot.appendItems(unique.map(\.id), toSection: "main")
            // 往头部插入后补偿偏移。
            //
            // 两个坑都要避开：
            //  ① 同步读 contentSize 时还是旧值 → delta = 0（第一次失败的原因）
            //  ② 放到 completion 里补偿 → apply 与补偿之间会有一帧显示错位
            //     （用户反馈「加载会突然闪一下」）
            // 所以整段放进 performWithoutAnimation，并在同一个块里
            // 强制 layoutIfNeeded 后立刻把偏移加回去 —— 没有中间帧。
            UIView.performWithoutAnimation {
                dataSource.apply(snapshot, animatingDifferences: false)
                guard insertedAtTop, let cv, beforeHeight > 0 else { return }
                cv.layoutIfNeeded()
                let delta = cv.contentSize.height - beforeHeight
                if delta > 1 {
                    cv.contentOffset.y = beforeOffset + delta
                    cv.layoutIfNeeded()
                }
            }
        }

        /// 内容指纹：count + 首末 id + 末条文本长度。
        /// 流式追加必然改末条长度；上拉插入必然改首条 id。
        private func fingerprint(_ entries: [ChatEntry]) -> String {
            guard let first = entries.first, let last = entries.last else {
                return "0"
            }
            return "\(entries.count)|\(first.id)|\(last.id)|\(last.text.count)"
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

        /// 顶部触发防抖：靠近才触发一次，离开后复位
        private var olderArmed = true

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let height = scrollView.contentSize.height
            let offset = scrollView.contentOffset.y
            let viewport = scrollView.bounds.height
            // 顶部 90pt 内触发；离开 200pt 后重新武装
            if offset < 90, olderArmed {
                olderArmed = false
                parent.onLoadOlder()
            } else if offset > 200 {
                olderArmed = true
            }
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

        // 不再实现 didSelectItemAt：它会抢走 UITextView 里的链接点击，
        // 导致「蓝色链接点不开」。点开详情改由 attributed string 里的
        // dsh://detail 链接触发（见 MessageRender）。
    }
}

// MARK: - Cell

/// 一条消息一个 cell。第一版先用 UITextView 承载纯文本（富文本在下一阶段接上）。
final class MessageCell: UICollectionViewCell, UITextViewDelegate {
    static let reuseID = "MessageCell"

    private let textView = UITextView()
    /// 「📎 2 张图片 · 1 个视频」提示行；无附件时高度为 0
    private let attachmentLabel = UILabel()
    /// 气泡背景：垫在文字下面，靠圆角 + 底色区分消息与消息之间
    /// （用户反馈「分割不是很明显」—— 之前只有 ▍我 / ▍AI 前缀）。
    private let bubble = UIView()
    private var bubbleTop: NSLayoutConstraint?
    private var bubbleBottom: NSLayoutConstraint?
    /// 气泡宽度：用户消息按内容收缩并靠右，助手消息铺满
    /// 气泡宽度 = stack 宽度 + 20（真正控宽，equalTo）
    private var bubbleWidth: NSLayoutConstraint?
    /// stack 尾部：两种布局都贴右
    private var stackTrailing: NSLayoutConstraint?
    /// stack 宽度：仅用户消息启用
    private var stackWidth: NSLayoutConstraint?
    /// stack leading：助手固定 0，用户改成 ≥56（可收缩）
    private var stackLeadingEq: NSLayoutConstraint?
    private var stackLeadingMin: NSLayoutConstraint?
    private var onTapAttachments: (() -> Void)?
    /// 点开链接 / 折叠提示（由 ChatView 决定行为）
    private var onOpenLink: ((URL) -> Void)?
    /// cell 顶部留白（角色切换时更大）
    private var topConstraint: NSLayoutConstraint?
    /// 内容块左边界：用户消息靠右（留出 56pt），其余贴左
    private var leadingConstraint: NSLayoutConstraint?
    private var stackTopSpacing: CGFloat = 8 {
        didSet { topConstraint?.constant = stackTopSpacing }
    }
    /// 当前渲染的条目（高度缓存要按它生成 key）
    private var currentEntry: ChatEntry?

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.delegate = self          // 链接点击必须由 delegate 处理
        textView.isEditable = false
        textView.isScrollEnabled = false          // 高度由内容决定，交给 cell
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        // 可点内容用强调色，和不可点的信息文字区分（用户建议）
        attachmentLabel.font = .systemFont(ofSize: 12)
        attachmentLabel.textColor = .tintColor
        attachmentLabel.numberOfLines = 1
        attachmentLabel.isUserInteractionEnabled = true
        attachmentLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleTapAttachments))
        )

        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 14
        bubble.layer.cornerCurve = .continuous
        bubble.backgroundColor = .clear
        contentView.addSubview(bubble)

        let stack = UIStackView(arrangedSubviews: [textView, attachmentLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        topConstraint = stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8)
        // 约束分两套，按消息角色切换：
        //   助手 → leading 固定 0 + trailing 固定（铺满）
        //   用户 → leading 改成 ≥56（可收缩）+ width 固定（按内容）+ trailing 固定（贴右）
        // 只保留 topConstraint 一个 top 约束。
        // 之前这里还有个 `stack.topAnchor == contentView.topAnchor`，
        // 两条约束打架，topConstraint 的 constant 完全不起作用 ——
        // 表现就是「两个气泡贴在一起，调间距没反应」（用户实拍）。
        // bottom 也从 -2 改成 -8：气泡往外扩 6pt，留 2pt 会被裁掉。
        NSLayoutConstraint.activate([
            topConstraint!,
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
        stackLeadingEq = stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        stackLeadingMin = stack.leadingAnchor.constraint(
            greaterThanOrEqualTo: contentView.leadingAnchor, constant: 56)
        stackTrailing = stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        stackWidth = stack.widthAnchor.constraint(equalToConstant: 0)
        stackLeadingEq?.isActive = true
        stackTrailing?.isActive = true
        stackLeadingMin?.isActive = false
        stackWidth?.isActive = false
        // 气泡比文字各方向外扩 10pt（左右）/ 6pt（上下）
        bubbleTop = bubble.topAnchor.constraint(equalTo: stack.topAnchor, constant: -6)
        bubbleBottom = bubble.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 6)
        NSLayoutConstraint.activate([
            bubbleTop!,
            bubbleBottom!,
            bubble.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: -10),
            bubble.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 10),
        ])
        bubbleWidth = bubble.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 20)
        bubbleWidth?.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        textView.attributedText = nil
        currentEntry = nil
        attachmentLabel.text = nil
        attachmentLabel.isHidden = true
        onTapAttachments = nil
        onOpenLink = nil
    }

    // MARK: - UITextViewDelegate（链接与自定义 scheme）

    func textView(
        _ textView: UITextView,
        shouldInteractWith URL: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        // 自定义 scheme 交给上层（dsh://detail 看完整版、dsh://attachments 看附件）
        if URL.scheme == "dsh" {
            onOpenLink?(URL)
            return false
        }
        // 普通链接走系统（Safari）
        return interaction != .invokeDefaultAction ? false : true
    }

    func textView(
        _ textView: UITextView,
        shouldInteractWith URL: URL,
        in characterRange: NSRange
    ) -> Bool {
        if URL.scheme == "dsh" {
            onOpenLink?(URL)
            return false
        }
        return true
    }

    @objc private func handleTapAttachments() {
        onTapAttachments?()
    }

    func configure(
        _ entry: ChatEntry,
        streaming: Bool,
        onTapAttachments: (() -> Void)?,
        onOpenLink: ((URL) -> Void)? = nil,
        isRoleChange: Bool = false
    ) {
        currentEntry = entry
        self.onOpenLink = onOpenLink
        // 角色切换（我→AI / AI→我）时上方多留一点，段落感更强
        stackTopSpacing = isRoleChange ? 14 : 4
        // 用户消息把内容块整体右移（不是文字缩进）：左边界 56pt，
        // 这样右边界贴着屏幕右边，看起来才像「我说的」，与微信/QQ 一致。
        leadingConstraint?.constant = (entry.kind == .user) ? 56 : 0
        textView.attributedText = MessageRender.attributed(entry)
        self.onTapAttachments = onTapAttachments

        // 气泡配色 + 布局：
        //   用户 → 淡主题色气泡，按内容收缩，整体靠右（文字在气泡内左对齐）
        //   助手 → 淡灰气泡，铺满整宽
        //   系统/工具 → 透明，不画气泡
        switch entry.kind {
        case .user:
            bubble.backgroundColor = UIColor.tintColor.withAlphaComponent(0.11)
            applyUserBubbleLayout(attributed: textView.attributedText, maxWidth: contentWidth)
        case .assistant:
            bubble.backgroundColor = UIColor.secondarySystemBackground
            applyFullWidthLayout()
        default:
            bubble.backgroundColor = .clear
            applyFullWidthLayout()
        }

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
            attachmentLabel.text = "📎 " + parts.joined(separator: " · ") + " · 点按查看 ›"
            // 用户消息整条靠右，附件提示行也要跟着靠右 ——
            // 它是独立的 UILabel，不受正文段落对齐影响（用户实拍：图片蓝链仍靠左）。
            attachmentLabel.textAlignment = (entry.kind == .user) ? .right : .natural
            attachmentLabel.isHidden = false
        }

    }

    /// cell 内容可用宽度。
    ///
    /// **不能直接用 contentView.bounds.width**：configure 发生在布局之前，
    /// 那时 bounds 还是 0，按 0 算出来的气泡宽度就是 0 —— 文字被裁掉，
    /// 表现就是「历史消息全看不见了」（用户实拍确认）。
    /// 所以先退回屏幕宽度兜底，等真正布局后 cell 会再走一次 configure。
    private var contentWidth: CGFloat {
        let w = contentView.bounds.width
        if w > 1 { return w }
        let screen = textView.window?.bounds.width ?? UIScreen.main.bounds.width
        return max(120, screen - 24)
    }

    private func applyFullWidthLayout() {
        stackLeadingMin?.isActive = false
        stackWidth?.isActive = false
        stackLeadingEq?.isActive = true
        textView.textAlignment = .natural
        // 助手气泡铺满：靠 leading/trailing 撑开，宽度约束让位
        bubbleWidth?.priority = .defaultLow
    }

    /// 用户气泡：按内容收缩（不短于 22%，不长于 78% 可用宽度），整体贴右。
    /// 上限用 78% 是为了留出左侧空白 —— 否则长消息气泡会一直伸到左边，
    /// 看起来反而像整块背景（用户反馈）。
    private func applyUserBubbleLayout(attributed: NSAttributedString?, maxWidth: CGFloat) {
        guard let attributed else { return }
        let upper = max(120, maxWidth * 0.78)
        let measured = attributed.boundingRect(
            with: CGSize(width: upper - 20, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).width
        // measured 为 0（宽度没算出来）时不能给 0 —— 那会让文字彻底消失。
        // 这种情况退回铺满，宁可不好看也不能看不见。
        guard measured > 1 else {
            stackLeadingMin?.isActive = false
            stackWidth?.isActive = false
            stackLeadingEq?.isActive = true
            textView.textAlignment = .natural
            bubbleWidth?.priority = .defaultLow
            return
        }
        let bubbleW = min(ceil(measured) + 20, upper)

        bubbleWidth?.priority = .required
        stackLeadingEq?.isActive = false
        stackLeadingMin?.isActive = true
        stackWidth?.isActive = true
        stackWidth?.constant = bubbleW - 20
        textView.textAlignment = .natural
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
            if entry.kind == .user { paragraph.alignment = .right }

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
            text += "  ›"   // 可点开的提示（颜色保持灰，避免整屏发蓝）
            body = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel,
                ]
            )
        case .system, .toolResult:
            // 系统行是背景信息，居中 + 更淡更小，让它退到正文之后
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            centered.paragraphSpacing = 4
            body = NSAttributedString(
                string: entry.text,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 10.5),
                    // 用 secondaryLabel 的 55% —— tertiaryLabel 在某些背景下
                    // 看起来偏深（用户反馈「仍是黑色字」），这档更轻。
                    .foregroundColor: UIColor.secondaryLabel.withAlphaComponent(0.55),
                    .paragraphStyle: centered,
                ]
            )
        default:
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            if entry.kind == .user {
                // 用户消息整段右对齐：本来就有 56pt 左缩进（块靠右），
                // 再把文字对齐到右边，短消息（「检测」「准备重启」这类）就会贴屏幕右侧，
                // 像聊天软件的气泡。用户消息通常很短，右对齐不会妨碍阅读。
                paragraph.alignment = .right
                paragraph.paragraphSpacing = 3
            }
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
        case .user:
            // 排队中：明确标出来。否则本地乐观插入的消息看起来和「已执行」一样，
            // 用户会以为它已经开始跑了（实测反馈）。
            return entry.queued ? "▍我 · 排队中\n" : "▍我\n"
        case .assistant: return entry.running ? "▍AI（正在生成）\n" : "▍AI\n"
        case .thinking: return "思考\n"
        case .toolCall: return "> "
        case .collapsedSteps: return "▸ "
        case .system, .toolResult: return nil
        }
    }
}
