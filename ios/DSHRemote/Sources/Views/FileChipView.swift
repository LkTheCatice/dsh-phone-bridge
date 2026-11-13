import UIKit

/// 产物卡片：「📄 输出文件 · 文件名」。
///
/// 为什么单独做一个 UIView，而不是塞进消息的 NSAttributedString：
///
/// 之前试过三版把卡片画成富文本（`.backgroundColor` 填色 → `minimumLineHeight` 撑高
/// → `baselineOffset` 调居中），每次都出问题：接缝、贴边、文字不居中。
/// 根因是**在文本层里表达布局**：行片段的高度由字体和段落样式决定，
/// 想把文字放在一个固定高度容器的正中，就得去猜 TextKit 把余量分到基线上方还是下方。
///
/// 卡片是布局元素，不是文本。用真正的视图 + Auto Layout 表达，
/// 内外边距、垂直居中、圆角全部由约束保证 —— 没有可猜的地方。
final class FileChipView: UIView {
    static let icon = "📄"

    private let label = UILabel()
    /// 右侧标签：「可预览」/「下载」。把"能不能点开"直接写在卡片上，
    /// 不用让用户点一下才知道。
    private let accessory = UILabel()

    /// 文字内容（含图标，例如 "📄 输出文件 · a.zip"）
    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    /// 文字颜色。折叠行（「本轮过程」）用主题色 —— 灰字太弱，
    /// 用户看不出这一行能点（实拍反馈）。
    /// 右侧标签文本（nil = 不显示）
    var accessoryText: String? {
        get { accessory.text }
        set {
            accessory.text = newValue
            accessory.isHidden = (newValue == nil || newValue?.isEmpty == true)
        }
    }

    /// 标签颜色（可预览时用主题色）
    var accessoryColor: UIColor {
        get { accessory.textColor }
        set { accessory.textColor = newValue }
    }

    var textColor: UIColor {
        get { label.textColor }
        set { label.textColor = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .label
        label.numberOfLines = 1
        // 文件名太长时掐中间，前后都有用（"📄 输出文件 · 手机端...20261113.zip"）
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.font = .systemFont(ofSize: 11, weight: .regular)
        accessory.textColor = .tertiaryLabel
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(accessory)

        NSLayoutConstraint.activate([
            // 上下 8pt、左右 12pt：这两组数就是"卡片内边距"，
            // 文字被约束垂直居中（上下等距），不需要任何基线技巧。
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: -8),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let size = label.intrinsicContentSize
        return CGSize(width: size.width + 24, height: max(32, size.height + 16))
    }
}
