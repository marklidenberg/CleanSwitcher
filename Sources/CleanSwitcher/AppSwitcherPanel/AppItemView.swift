import Cocoa

protocol AppItemViewDelegate: AnyObject {
    func appItemHovered(_ view: AppItemView)
}

/// One tile: a square icon (app grid) or `[icon] [name]` row (window list),
/// with an optional red notification badge.
class AppItemView: NSView {
    weak var delegate: AppItemViewDelegate?

    let item: SwitcherItem
    private let iconImageView: NSImageView
    private var isSelected = false

    private let itemSize: CGFloat
    private let iconSize: CGFloat
    private let showsLabel: Bool   // labeled row (window list) vs bare icon tile
    private let cellWidth: CGFloat // fixed width for labeled cells, so icons align in a column

    init(item: SwitcherItem, itemSize: CGFloat = 76, showsLabel: Bool = false, cellWidth: CGFloat = 360) {
        self.item = item
        self.itemSize = itemSize
        self.iconSize = itemSize
        self.showsLabel = showsLabel
        self.cellWidth = cellWidth

        iconImageView = NSImageView()
        iconImageView.image = item.icon
        iconImageView.imageScaling = .scaleProportionallyUpOrDown

        super.init(frame: NSRect(x: 0, y: 0, width: itemSize, height: itemSize))

        setupViews()
        setupBadge()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        if showsLabel {
            setupLabeledLayout()
        } else {
            NSLayoutConstraint.activate([
                iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconImageView.widthAnchor.constraint(equalToConstant: iconSize),
                iconImageView.heightAnchor.constraint(equalToConstant: iconSize),
                widthAnchor.constraint(equalToConstant: itemSize),
                heightAnchor.constraint(equalToConstant: itemSize),
            ])
        }
    }

    /// `[icon] [name]` row, for the vertical window-switcher list.
    private func setupLabeledLayout() {
        let label = NSTextField(labelWithString: item.title)
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let hPad: CGFloat = 10, gap: CGFloat = 10, vPad: CGFloat = 6
        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: iconSize),
            iconImageView.heightAnchor.constraint(equalToConstant: iconSize),

            label.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: gap),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Fixed cell width so icons line up in a column and long names truncate.
            widthAnchor.constraint(equalToConstant: cellWidth),
            heightAnchor.constraint(equalToConstant: iconSize + vPad * 2),
        ])
    }

    private func setupBadge() {
        guard let badgeText = item.badge else { return }

        // - Red circle scaled to the icon

        let badgeSize: CGFloat = max(20, itemSize * 0.26)
        let badgeContainer = NSView()
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeContainer.layer?.cornerRadius = badgeSize / 2
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeContainer)

        // - Count label (>99 shows "99+")

        let label = NSTextField(labelWithString: Int(badgeText).map { $0 > 99 ? "99+" : badgeText } ?? badgeText)
        label.font = NSFont.systemFont(ofSize: max(11, itemSize * 0.145), weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(label)

        NSLayoutConstraint.activate([
            badgeContainer.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            badgeContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: badgeSize),
            badgeContainer.heightAnchor.constraint(equalToConstant: badgeSize),

            label.centerXAnchor.constraint(equalTo: badgeContainer.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: badgeContainer.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.trailingAnchor, constant: -4),
        ])
    }

    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        layer?.backgroundColor = isSelected ? NSColor.white.withAlphaComponent(0.3).cgColor : NSColor.clear.cgColor
    }

    override func mouseEntered(with event: NSEvent) { delegate?.appItemHovered(self) }
}
