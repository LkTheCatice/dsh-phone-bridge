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
            // 行间距：从 10 收到 7。工具行本来就密（一轮里十几条），
            // 10pt 加上 cell 内部 4pt，读起来像散开的日志（用户反馈「行间距大了一点」）。
            section.interGroupSpacing = 7
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
        /// 上一次的快照 id 序列：用来识别「只有末条文本在长」这种最常见的流式更新
        private var lastIds: [String] = []
        /// 角色切换（我 ↔ AI）的条目 id，在 apply() 里一次算好
        private var roleChangeIds: Set<String> = []
        /// 手指还在拖：这时候往头部插内容会把列表在手指底下顶走
        private var isDragging = false
        /// 拖动期间被推迟的一次 apply（等松手再落地）
        private var deferredEntries: [ChatEntry]?
        /// apply 之后立刻读到的 contentSize.height，用来吸收「自适应高度二次收敛」
        private var appliedHeight: CGFloat = 0

        init(_ parent: ChatList) {
            self.parent = parent
        }

        func attach(_ view: UICollectionView) {
            collectionView = view
            dataSource = UICollectionViewDiffableDataSource<String, String>(collectionView: view) { [weak self] cv, indexPath, id in
                let cell = cv.dequeueReusableCell(withReuseIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
                if let entry = self?.lookup[id] {
                    // 角色切换（我 ↔ AI）只影响气泡留白。
                    //
                    // 以前是**每个 cell** 都拿 entries 做一次 firstIndex(where:) ——
                    // O(n) × 可见 cell 数 × 每次布局，300 条消息时就是几千次比较，
                    // 滚动（尤其上拉插入后整屏重排）会明显发涩。
                    // 现在在 apply() 里一次算好，这里只做 O(1) 查表。
                    let isRoleChange = self?.roleChangeIds.contains(id) ?? false
                    cell.configure(
                        entry,
                        streaming: self?.parent.isStreaming ?? false,
                        onTapAttachments: { [weak self] in
                            self?.parent.onTapAttachments(id)
                        },
                        onOpenLink: { [weak self] url in
                            self?.parent.onOpenLink(id, url)
                        },
                        onTapEntry: { [weak self] rowId in
                            self?.parent.onTapEntry(rowId)
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
            let applyStart = CFAbsoluteTimeGetCurrent()

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

            // 手指按着的时候**不**往头部插：往上拖到顶、触发加载，条目一到就
            // 在手指底下把内容顶走，手感就是「滑到一半被弹了一下」（用户反馈）。
            // 先记下来，松手/惯性结束时再落地（iOS 官方列表也是这个节奏）。
            if insertedAtTop, isDragging {
                deferredEntries = entries
                lastFingerprint = fp
                return
            }

            // 后台预渲染：真机上"上拉加载 120 帧卡 5 秒"的时间几乎全在
            // cell configure 里重新渲染 markdown；这里先把它挪到后台。
            MessageRender.prefetch(unique)

            // 角色切换一次算好，cell provider 只查表（O(1)）
            var changes = Set<String>()
            changes.reserveCapacity(unique.count / 4)
            if unique.count > 1 {
                for i in 1..<unique.count where unique[i].kind != unique[i - 1].kind {
                    changes.insert(unique[i].id)
                }
            }
            roleChangeIds = changes

            // 必须在 apply **之前**取值：apply 之后 contentSize 就是新的了
            let cv = collectionView
            let beforeHeight = cv?.contentSize.height ?? 0
            let beforeOffset = cv?.contentOffset.y ?? 0
            let wasAtTop = beforeOffset < 90

            latestEntries = unique
            lookup = Dictionary(unique.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

            // 流式最常见的形态：**只有末条的文本在变长**，id 序列完全没动。
            // 这种时候没必要重建整份 snapshot 再让 diffable 全量比一遍
            // （300 条时一次 apply 会把主线程压住几百毫秒，用户反馈上划/流式发涩）。
            // 只 reconfigure 末条，其余条目保持原样。
            let ids = unique.map(\.id)
            let tailOnly = !lastIds.isEmpty
                && ids.count == lastIds.count
                && ids.first == lastIds.first
                && ids.dropLast().elementsEqual(lastIds.dropLast())
            lastIds = ids
            if tailOnly, let cv, let tailId = ids.last {
                var current = dataSource.snapshot()
                if current.itemIdentifiers.contains(tailId) {
                    current.reconfigureItems([tailId])
                    UIView.performWithoutAnimation {
                        dataSource.apply(current, animatingDifferences: false)
                    }
                    appliedHeight = cv.contentSize.height
                    Diag.ping("apply-tail total=\(Int((CFAbsoluteTimeGetCurrent() - applyStart) * 1000))")
                    return
                }
            }

            // 头部插入且量大 → 先只插入后面的一部分，前面几帧逐批补。
            if insertedAtTop, stagedTopCount == 0 {
                let newLeading = unique.prefix { !oldIds.contains($0.id) }.count
                if newLeading > Self.insertChunk {
                    stagedTopCount = newLeading - Self.insertChunk
                }
            }
            let shown = stagedTopCount > 0 ? Array(unique.dropFirst(stagedTopCount)) : unique

            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            snapshot.appendSections(["main"])
            snapshot.appendItems(shown.map(\.id), toSection: "main")
            // 往头部插入后补偿偏移。
            //
            // 三个坑都要避开：
            //  ① 同步读 contentSize 时还是旧值 → delta = 0（第一次失败的原因）
            //  ② 放到 completion 里补偿 → apply 与补偿之间会有一帧显示错位
            //     （用户反馈「加载会突然闪一下」）
            //  ③ 布局用的是 `.estimated(80)`：apply 后的 contentSize 是**估算**的，
            //     自适应 cell 完成最终排版后还会再变一次 —— 只补偿一次，
            //     后续那次收敛会把内容再推一下，手感就是「顿一下 / 回弹一点」。
            // 所以：同步补偿一次（没有中间帧），下一个 runloop 再吸收二次收敛。
            let snapStart = CFAbsoluteTimeGetCurrent()
            UIView.performWithoutAnimation {
                dataSource.apply(snapshot, animatingDifferences: false)
                guard insertedAtTop, let cv, beforeHeight > 0 else {
                    appliedHeight = cv?.contentSize.height ?? 0
                    return
                }
                cv.layoutIfNeeded()
                let delta = cv.contentSize.height - beforeHeight
                if delta > 1 {
                    cv.contentOffset.y = beforeOffset + delta
                    cv.layoutIfNeeded()
                }
                appliedHeight = cv.contentSize.height
            }
            if pendingBottomScroll { attemptBottomScroll(animated: false) }
            if keepAtBottom, !pendingBottomScroll { silentBottomScroll() }
            Diag.ping("apply n=\(unique.count) top=\(insertedAtTop ? 1 : 0)"
                      + " snap=\(Int((CFAbsoluteTimeGetCurrent() - snapStart) * 1000))"
                      + " total=\(Int((CFAbsoluteTimeGetCurrent() - applyStart) * 1000))")
            // 还有暂缓的头部条目 → 下一帧再补一片（每次都带偏移补偿，
            // 用户当前看的内容不会被顶走）。
            if stagedTopCount > 0 {
                stagedTopCount = max(0, stagedTopCount - Self.insertChunk)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let all = self.latestEntries else { return }
                    self.lastFingerprint = ""
                    self.apply(all)
                }
            }
            guard insertedAtTop, let cv, beforeHeight > 0 else { return }
            // 二次收敛补偿：只在「用户没在拖/没在惯性」时做，否则会和手势打架
            DispatchQueue.main.async { [weak self] in
                guard let self, let cv = self.collectionView else { return }
                guard !cv.isTracking, !cv.isDecelerating else { return }
                let settled = cv.contentSize.height
                let drift = settled - self.appliedHeight
                if abs(drift) > 1 {
                    cv.contentOffset.y += drift
                    self.appliedHeight = settled
                }
            }
        }

        /// 分片插入：一次最多往列表里塞这么多条，剩下的下几帧补齐。
        ///
        /// 真机数据（.86/.88 打点）：apply 本身只要 2~44ms、测量 avg 0ms，
        /// 但每插入一页历史，主线程仍连续卡 3~5 秒 —— 因为 UIKit 在自适应用
        /// 估算高度时会**为每个新条目实例化 cell 并 configure**，
        /// 每次 configure 都要把整条 markdown 交给 TextKit 排一遍。
        /// 一次 40 条 = 40 次排版，全在主线程。
        /// 分片后每帧只排 8 条，中间让 runloop 喘一口，手感从"卡死"变成"顺畅地补上"。
        private static let insertChunk = 8
        /// 被暂缓插入的头部条目数（0 = 全部已插入）
        private var stagedTopCount = 0
        /// 最近一次收到的完整条目列表（分片补插时要用）
        private var latestEntries: [ChatEntry]?

        /// 拖动期间推迟的那次 apply，松手后补上
        private func flushDeferred() {
            guard let pending = deferredEntries else { return }
            deferredEntries = nil
            // 清掉指纹，否则 apply 会认为「没变」直接返回
            lastFingerprint = ""
            apply(pending)
        }

        /// 内容指纹：count + 首末 id + 末条文本长度。
        /// 流式追加必然改末条长度；上拉插入必然改首条 id。
        private func fingerprint(_ entries: [ChatEntry]) -> String {
            guard let first = entries.first, let last = entries.last else {
                return "0"
            }
            return "\(entries.count)|\(first.id)|\(last.id)|\(last.text.count)"
        }

        /// 待落实的「滚到底」请求。
        ///
        /// 冷启动时 `scrollRequest` 往往比数据先到：那一刻 items=0 或布局还没完成，
        /// 旧实现直接 return，**请求就这么丢了** —— 于是启动后停在顶部
        /// （用户实拍「启动软件时不在最下方」）。
        /// 现在挂起这个意图，等 apply 之后或下一帧再兑现。
        private var pendingBottomScroll = false
        private var pendingBottomTries = 0

        /// **持续贴底**：冷启动/自己发消息后置位，用户手动往上翻才清除。
        ///
        /// 一次性的 scrollToItem 不够：启动时内容会分好几批到达
        /// （历史回放 + 实时帧 + 自适应高度收敛），每次插入都把"底"往下推一屏，
        /// 于是最终停在离底部固定一段的位置（用户实拍：位置一致但不在最底下）。
        /// 只要这个标志还在，每次 apply 之后都会静默贴一次底，
        /// 直到用户真的往上划 —— 那才是他想要的位置。
        private var keepAtBottom = true

        func handleScrollRequest(_ token: Int) {
            guard token != lastScrollRequest else { return }
            lastScrollRequest = token
            keepAtBottom = true
            pendingBottomScroll = true
            pendingBottomTries = 0
            attemptBottomScroll(animated: false)
        }

        func scrollToBottom(animated: Bool) {
            keepAtBottom = true
            pendingBottomScroll = true
            pendingBottomTries = 0
            attemptBottomScroll(animated: animated)
        }

        /// 静默贴底：不触发动画、不改 lastScrollRequest，纯粹把位置压到底部。
        /// 内容还在长的时候用它，避免"来回跳"的观感。
        private func silentBottomScroll() {
            guard let cv = collectionView else { return }
            let items = dataSource.snapshot().itemIdentifiers.count
            guard items > 0, cv.numberOfSections > 0,
                  cv.numberOfItems(inSection: 0) >= items,
                  cv.contentSize.height > cv.bounds.height else { return }
            let maxY = max(0, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            if abs(cv.contentOffset.y - maxY) > 1 {
                cv.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
            }
        }

        /// 真正执行；数据没就绪就留到下一帧（最多 30 次，约 0.5 秒，够了）
        private func attemptBottomScroll(animated: Bool) {
            guard pendingBottomScroll, let cv = collectionView else { return }
            let items = dataSource.snapshot().itemIdentifiers.count
            let ready = items > 0
                && cv.numberOfSections > 0
                && cv.numberOfItems(inSection: 0) >= items
                && cv.bounds.height > 1
            guard ready else {
                pendingBottomTries += 1
                guard pendingBottomTries < 30 else {
                    pendingBottomScroll = false
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    self?.attemptBottomScroll(animated: animated)
                }
                return
            }
            cv.layoutIfNeeded()
            let target = IndexPath(item: items - 1, section: 0)
            cv.scrollToItem(at: target, at: .bottom, animated: animated)
            pendingBottomScroll = false
            // 自适应高度（.estimated）下第一次定位会差一点：
            // 下一个 runloop 再补一次无动画定位，避免"差半屏"。
            if !animated {
                DispatchQueue.main.async { [weak cv] in
                    guard let cv, cv.numberOfSections > 0,
                          cv.numberOfItems(inSection: 0) >= items else { return }
                    cv.scrollToItem(at: target, at: .bottom, animated: false)
                }
            }
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
            // 用户往上翻离开底部 → 取消持续贴底（否则会把他拽回去）
            let distanceToBottom = height - (offset + viewport)
            if distanceToBottom > 200 {
                keepAtBottom = false
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

        // 拖动状态：只用来决定「头部插入能不能现在落地」
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isDragging = true
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            isDragging = false
            if !decelerate { flushDeferred() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            flushDeferred()
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

    private let textView: UITextView = {
        // 代码块 / 表格的整块底色由 BlockFillLayoutManager 画（见那个文件）。
        // UITextView() 默认的布局管理器画不了「整块」，只能按字符填色。
        let storage = NSTextStorage()
        let layout = BlockFillLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        return UITextView(frame: .zero, textContainer: container)
    }()
    /// 「📎 2 张图片 · 1 个视频」提示行；无附件时高度为 0
    private let attachmentLabel = UILabel()
    /// 点整行（工具行）→ 打开工具详情。
    ///
    /// 之前**根本没有点击入口**：cell 只处理 `dsh://` 链接，
    /// `onTapEntry` 这个闭包从声明起就没被调用过 ——
    /// 所以"点工具行看它读过的图片"永远打不开（用户实拍：并不能）。
    var onTapEntry: ((String) -> Void)?

    /// 产物卡片（「📄 输出文件 · xxx」）。
    /// 用真视图而不是富文本：内外边距和垂直居中由约束保证，见 FileChipView 顶部注释。
    private let fileChip = FileChipView()
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

        let stack = UIStackView(arrangedSubviews: [fileChip, textView, attachmentLabel])
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

        // 卡片行（产物 / 折叠）自己接管点击：这两类 textView 是隐藏的，
        // 挂在 textView 上的手势收不到事件。
        let chipTap = UITapGestureRecognizer(target: self, action: #selector(handleRowTap))
        fileChip.addGestureRecognizer(chipTap)
        fileChip.isUserInteractionEnabled = true

        // 工具行整行可点：打开「工具详情」（含它读过的图片）。
        // 只对 .toolCall 生效 —— 其它行里的 dsh:// 链接靠 UITextView 自己的
        // delegate 处理，不要让一个手势去抢点击。
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleRowTap))
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)
    }

    @objc private func handleRowTap() {
        // 工具行 → 工具详情；折叠行（▸ 本轮过程 · N 步）→ 本轮过程页。
        // 只放 .toolCall 是不够的：折叠行同样需要入口，
        // 漏掉它就会出现「找不到本轮过程入口」（用户实拍）。
        guard let entry = currentEntry,
              entry.kind == .toolCall || entry.kind == .collapsedSteps
        else { return }
        onTapEntry?(entry.id)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        textView.attributedText = nil
        textView.isHidden = false
        currentEntry = nil
        attachmentLabel.text = nil
        attachmentLabel.isHidden = true
        // 产物卡片：复用前必须清空，否则会带着上一条的文件名（cell 复用的经典坑）
        fileChip.text = nil
        fileChip.isHidden = true
        onTapAttachments = nil
        onOpenLink = nil
        onTapEntry = nil
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
        onTapEntry: ((String) -> Void)? = nil,
        isRoleChange: Bool = false
    ) {
        currentEntry = entry
        self.onOpenLink = onOpenLink
        // 角色切换（我→AI / AI→我）时上方多留一点，段落感更强。
        // 工具行（运行命令 / 读取 / 写入…）属于「过程」，和上一行贴紧一点，
        // 否则一轮十几条读起来像散开的日志（用户反馈行距偏大）。
        switch entry.kind {
        case .toolCall, .collapsedSteps, .toolResult:
            stackTopSpacing = isRoleChange ? 12 : 2
        case .fileOutput:
            stackTopSpacing = isRoleChange ? 12 : 6
        default:
            stackTopSpacing = isRoleChange ? 14 : 4
        }
        // 用户消息把内容块整体右移（不是文字缩进）：左边界 56pt，
        // 这样右边界贴着屏幕右边，看起来才像「我说的」，与微信/QQ 一致。
        leadingConstraint?.constant = (entry.kind == .user) ? 56 : 0
        // 产物卡片 / 折叠行：这两类都**不用 textView**，交给 FileChipView
        // （真视图 + 约束）—— 文字的垂直居中、内边距都由约束保证。
        if entry.kind == .fileOutput {
            fileChip.isHidden = false
            fileChip.text = entry.text
            fileChip.textColor = .label
            textView.isHidden = true
            textView.attributedText = nil
        } else if entry.kind == .collapsedSteps {
            // 「▸ 本轮过程 · N 步」做成一张**有色卡片的行**：
            // 之前是 12pt 灰字，小、没颜色、看不出能点（用户实拍）。
            fileChip.isHidden = false
            fileChip.text = "▸ " + entry.text + "  ›"
            fileChip.textColor = .tintColor
            textView.isHidden = true
            textView.attributedText = nil
        } else {
            fileChip.isHidden = true
            fileChip.text = nil
            textView.isHidden = false
            textView.attributedText = MessageRender.attributed(entry)
        }
        self.onTapAttachments = onTapAttachments
        self.onTapEntry = onTapEntry
        // 思考行最多 6 行：TextKit 只排这么多，界面给个「大概在想什么」；
        // 其余行不限制（0 = 不限）。
        textView.textContainer.maximumNumberOfLines = (entry.kind == .thinking) ? 2 : 0

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
            var hit = layoutAttributes
            hit.size.height = cached.height
            return hit
        }

        let started = CFAbsoluteTimeGetCurrent()
        let height = measuredHeight(cellWidth: width)
        Self.noteMeasure(Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
        if let key { Self.store(key: key, height: height, width: width) }

        var attributes = layoutAttributes
        attributes.size.height = height
        return attributes
    }

    /// 直接算高度：**不再走 Auto Layout**。
    ///
    /// 旧实现是 setNeedsLayout() + layoutIfNeeded() 再 systemLayoutSizeFitting() ——
    /// 等于把整个 cell 的约束解两遍，长消息一次几百毫秒；真机 STUCK 数值
    /// （stalls.maxMs ≈ 9s、over1s ≈ 190）就是这条路径贡献的。
    ///
    /// 现在按布局常量做算术：cell 高度 = 顶部间距 + 内容高度 + 底部 8。
    /// 唯一需要排版引擎的是文本 —— 用 UITextView.sizeThatFits 量，
    /// 那是文本真正显示时用的同一套 TextKit 引擎，不会和最终布局不一致。
    private func measuredHeight(cellWidth: CGFloat) -> CGFloat {
        guard let entry = currentEntry else { return 44 }

        // 产物卡片：约束固定（上下各 8pt、最小高度 32pt）
        if entry.kind == .fileOutput {
            return stackTopSpacing + 32 + 8
        }

        // 用户消息整块右移 56pt；宽度已由 applyUserBubbleLayout 按内容算好
        let leadingInset: CGFloat = (entry.kind == .user) ? 56 : 0
        var contentWidth = cellWidth - leadingInset
        if entry.kind == .user, let fixed = stackWidth?.constant, fixed > 1 {
            contentWidth = min(contentWidth, fixed)
        }
        contentWidth = max(40, contentWidth)

        let textHeight: CGFloat
        if let attributed = textView.attributedText, attributed.length > 0 {
            textHeight = textView.sizeThatFits(
                CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
            ).height
        } else {
            textHeight = 0
        }

        var height = stackTopSpacing + textHeight + 8
        // 附件行：stack spacing 4 + 单行 12pt 字约 17pt
        if !attachmentLabel.isHidden { height += 4 + 17 }
        // 产物卡片：同一 stack 里，间距同上
        if !fileChip.isHidden { height += 4 + 32 }
        return ceil(height)
    }


    /// 高度缓存用「id + 内容长度 + 附件数」作 key：内容一变就不复用旧高度。
    /// 不用 attributed string 的 hash —— 那个在每个 cell 上算一次比测量还贵。
    private func cacheKey(for attributes: UICollectionViewLayoutAttributes, width: CGFloat) -> String? {
        guard let entry = currentEntry else { return nil }
        return "\(entry.id)|\(entry.text.count)|\(entry.summary?.count ?? 0)|\(Int(width))"
    }

    /// 高度缓存。**有上限**（LRU 600 条），避免长会话把内存吃满。
    // 测量耗时统计：每 40 次打一行，和 /v1/diag 的 stalls 对照用
    private static var measureCount = 0
    private static var measureTotalMs = 0
    private static var measureWorstMs = 0

    private static func noteMeasure(_ ms: Int) {
        measureCount += 1
        measureTotalMs += ms
        if ms > measureWorstMs { measureWorstMs = ms }
        if measureCount % 40 == 0 {
            let avg = measureTotalMs / max(1, measureCount)
            NSLog("[measure] n=%d avg=%dms worst=%dms", measureCount, avg, measureWorstMs)
            Diag.ping("measure n=\(measureCount) avg=\(avg) worst=\(measureWorstMs)")
        }
    }

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
    /// 渲染结果缓存。
    ///
    /// 真机数据（.86 打点）：apply 的快照只要 54ms、测量 avg 0ms/worst 2ms，
    /// 但主线程仍连续卡 5.4s —— 时间全花在**每个新 cell 的 configure 里重新
    /// 渲染 markdown**（40 条长消息 × 几十毫秒）。所以必须缓存渲染结果，
    /// 并且能在后台预渲染。
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 400
        return cache
    }()

    private static let prefetchQueue = DispatchQueue(label: "dsh.render.prefetch", qos: .userInitiated)

    private static func cacheKey(_ entry: ChatEntry) -> NSString {
        // 必须显式 String(describing:) 再桥接：Swift 5 里直接把插值表达式
        // 当返回值会推断成 String，报 "cannot convert return expression"
        // （CI 抓到的编译错误）。
        String("\(entry.id)|\(entry.text.count)|\(entry.summary?.count ?? 0)|\(entry.running ? 1 : 0)") as NSString
    }

    /// 后台预渲染：把还没进缓存的条目排进后台队列。
    /// 主线程 configure 时直接命中缓存 —— 那 5 秒就是这么省下来的。
    static func prefetch(_ entries: [ChatEntry]) {
        let missing = entries.filter { cache.object(forKey: cacheKey($0)) == nil }
        guard !missing.isEmpty else { return }
        prefetchQueue.async {
            for entry in missing {
                let key = cacheKey(entry)
                guard cache.object(forKey: key) == nil else { continue }
                cache.setObject(build(entry), forKey: key)
            }
        }
    }

    static func attributed(_ entry: ChatEntry) -> NSAttributedString {
        let key = cacheKey(entry)
        if let hit = cache.object(forKey: key) { return hit }
        let built = build(entry)
        cache.setObject(built, forKey: key)
        return built
    }

    private static func build(_ entry: ChatEntry) -> NSAttributedString {
        let out = NSMutableAttributedString()

        // 角色前缀（一条小字），正文用 markdown 富文本
        if let prefix = prefix(for: entry) {
            let color: UIColor = (entry.kind == .user) ? .tintColor : .tertiaryLabel
            let paragraph = NSMutableParagraphStyle()
            // 前缀（▍AI / ▍我）和下面正文之间的间距。
            // 原来是 2pt —— 看着几乎贴在一起（用户实拍「AI 离正文太近」）。
            // 7pt 之后前缀自成一行、正文开头也有呼吸感。
            paragraph.paragraphSpacing = 7
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
            // 思考行按**工具行同一套排版**：等宽 12pt、灰色、随行折行。
            // 只是显示上最多两行，第二行放不下才打省略号（截断交给 TextKit，
            // 见 cell 里的 maximumNumberOfLines = 2）—— 不做"截字符"的手工处理，
            // 那样换行位置和省略号都会和实际排版对不上。
            // 内容仍做尾部限长：CoT 动辄几千字且流式增长，整段重排会把主线程按住
            // （真机 STUCK 曾累积到 2.8s）。两行 ≈ 60 字，留 240 字足够排版。
            // 取**开头**而不是结尾：思考行看的是"这一步打算做什么"，
            // 结尾那几行往往是半句（用户实拍：显示成 "...y're confirming. Short..."）。
            // 截断交给 TextKit（两行 + 行尾省略号），这里只做长度上限。
            let charLimit = 240
            let text = entry.text.count > charLimit
                ? String(entry.text.prefix(charLimit))
                : entry.text
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.lineSpacing = 1
            body = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: style,
                ]
            )
        case .toolCall:
            var text = entry.text
            if let summary = entry.summary, !summary.isEmpty { text += " · " + summary }
            // 不再在末尾加 "›"：每行都挂一个看着像漏字（用户问"结尾那个 > 是什么"）。
            // 整行可点这件事由手势承担，不需要字符提示。
            body = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel,
                ]
            )
        case .fileOutput:
            // 产物卡片走 FileChipView（真视图 + 约束），不该进这里；空串兜底
            body = NSAttributedString(string: entry.text)
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
        case .collapsedSteps:
            // 折叠块（「▸ 本轮过程 · N 步」）。
            // 以前这里没有分支，掉进 default → 16pt + label 色，
            // 于是折起来那行是**黑色大字**，比正文还显眼（用户实拍）。
            // 它本质是背景信息，要和「本轮结束 · 用时…」那类小灰字同一档。
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 4
            style.lineSpacing = 2
            body = NSAttributedString(
                string: entry.text,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel.withAlphaComponent(0.7),
                    .paragraphStyle: style,
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
            if entry.steering { return "▍我 · 已插队，等当前任务完成\n" }
            return entry.queued ? "▍我 · 排队中\n" : "▍我\n"
        case .assistant: return entry.running ? "▍AI（正在生成）\n" : "▍AI\n"
        // 和工具行同一形态：行首 "> "，内容跟在后面。
        // 之前是单独一行 "思考"，视觉上像一个小标题，和 log 列表不是一类东西。
        case .thinking: return "> 思考 · "
        case .toolCall: return "> "
        case .collapsedSteps: return "▸ "
        case .system, .toolResult, .fileOutput: return nil
        }
    }
}
