import UIKit

/// 「本轮产出」清单卡：一张卡里列出这一轮产出的所有文件。
///
/// 为什么不用文字拼：每一行要**独立可点**（点谁开谁），
/// 文字行做不到命中区分（会被当成一段文本）。
/// 所以这里跟 `FileChipView` 一样，用真视图 + 约束：
///   · 行高固定 32，最多 5 行，超出显示「还有 N 个」
///   · 左侧类型图标、中间文件名、右侧一句指标（时长/体积/类型）
final class FileListCardView: UIView {

    struct Row {
        let path: String
        let metrics: String
    }

    var onTapPath: ((String) -> Void)?
    /// 点「还有 N 个」→ 打开完整列表（此前这一行是死的，超出 5 个的文件没有入口）
    var onTapMore: (() -> Void)?

    private let stack = UIStackView()
    private var rows: [Row] = []
    private var moreCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.tertiarySystemFill
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous

        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 行数（含「还有 N 个」那一行）—— cell 高度按这个算，别让视图自己量
    /// 卡片最多 8 行（再多就用「查看全部」），比原来的 5 行更能一屏交代清楚一轮产出
    static let maxVisibleRows = 8

    static func lineCount(fileCount: Int) -> Int {
        min(fileCount, maxVisibleRows) + (fileCount > maxVisibleRows ? 1 : 0)
    }

    func configure(rows: [Row], moreCount: Int) {
        self.rows = rows
        self.moreCount = moreCount
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (index, row) in rows.enumerated() {
            if index > 0 { stack.addArrangedSubview(separator()) }
            stack.addArrangedSubview(makeLine(row))
        }
        if moreCount > 0 {
            stack.addArrangedSubview(separator())
            let more = MoreControl()
            more.addTarget(self, action: #selector(handleMore), for: .touchUpInside)
            let label = UILabel()
            label.text = "还有 \(moreCount) 个 · 查看全部 ›"
            label.font = .systemFont(ofSize: 12)
            label.textColor = .tintColor
            label.translatesAutoresizingMaskIntoConstraints = false
            more.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: more.leadingAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: more.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: more.centerYAnchor),
                more.heightAnchor.constraint(equalToConstant: 30),
            ])
            stack.addArrangedSubview(more)
        }
    }

    private func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor.separator.withAlphaComponent(0.5)
        line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return line
    }

    private func makeLine(_ row: Row) -> UIControl {
        let control = RowControl()
        control.path = row.path
        control.addTarget(self, action: #selector(handleTap(_:)), for: .touchUpInside)

        let icon = UILabel()
        icon.text = FileKind(path: row.path).icon
        icon.font = .systemFont(ofSize: 13)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let name = UILabel()
        name.text = AppModel.fileName(row.path)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .label
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let metrics = UILabel()
        metrics.text = row.metrics
        metrics.font = .systemFont(ofSize: 11)
        metrics.textColor = .secondaryLabel
        metrics.setContentHuggingPriority(.required, for: .horizontal)
        metrics.setContentCompressionResistancePriority(.required, for: .horizontal)

        let hStack = UIStackView(arrangedSubviews: [icon, name, metrics])
        hStack.axis = .horizontal
        hStack.alignment = .center
        hStack.spacing = 8
        hStack.isUserInteractionEnabled = false
        hStack.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(hStack)
        NSLayoutConstraint.activate([
            hStack.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            hStack.trailingAnchor.constraint(equalTo: control.trailingAnchor),
            hStack.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            control.heightAnchor.constraint(equalToConstant: 32),
        ])
        return control
    }

    @objc private func handleMore() {
        onTapMore?()
    }

    @objc private func handleTap(_ sender: RowControl) {
        guard let path = sender.path else { return }
        onTapPath?(path)
    }

    /// 「还有 N 个」那一行：可点，带按压反馈
    final class MoreControl: UIControl {
        override var isHighlighted: Bool {
            didSet { alpha = isHighlighted ? 0.55 : 1 }
        }
    }

    final class RowControl: UIControl {
        var path: String?
        override var isHighlighted: Bool {
            didSet { alpha = isHighlighted ? 0.55 : 1 }
        }
    }
}
