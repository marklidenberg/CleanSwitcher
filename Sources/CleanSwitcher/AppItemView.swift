import Cocoa

protocol AppItemViewDelegate: AnyObject {
    func appItemHovered(_ view: AppItemView)
}

class AppItemView: NSView {
    weak var delegate: AppItemViewDelegate?

    let item: SwitcherItem
    private let iconImageView: NSImageView
    private var badgeView: NSView?
    private var badgeLabel: NSTextField?
    private var nameLabel: NSTextField?
    private var isSelected = false

    private let itemSize: CGFloat
    private let iconSize: CGFloat
    // Vertical-list cell (icon + name to the right) vs the default square icon tile.
    private let showsLabel: Bool
    private let cellWidth: CGFloat  // fixed width for labeled cells, so icons align in a column

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
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
                // Icon centered in view
                iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconImageView.widthAnchor.constraint(equalToConstant: iconSize),
                iconImageView.heightAnchor.constraint(equalToConstant: iconSize),

                // Self constraints
                widthAnchor.constraint(equalToConstant: itemSize),
                heightAnchor.constraint(equalToConstant: itemSize)
            ])
        }
    }

    /// Horizontal cell: [icon] [name], for the vertical window-switcher list.
    private func setupLabeledLayout() {
        let label = NSTextField(labelWithString: item.title)
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        nameLabel = label

        let hPad: CGFloat = 10
        let gap: CGFloat = 10
        let vPad: CGFloat = 6

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: iconSize),
            iconImageView.heightAnchor.constraint(equalToConstant: iconSize),

            label.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: gap),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Fixed cell width so every row's icon lines up in a column and long
            // names truncate rather than widening the panel.
            widthAnchor.constraint(equalToConstant: cellWidth),
            heightAnchor.constraint(equalToConstant: iconSize + vPad * 2)
        ])
    }

    private func setupBadge() {
        guard let badgeText = item.badge else { return }

        // Create badge background (red circle), scaled to icon size
        let badgeSize: CGFloat = max(20, itemSize * 0.26)
        let badgeContainer = NSView()
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeContainer.layer?.cornerRadius = badgeSize / 2
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeContainer)
        self.badgeView = badgeContainer

        // Create badge label
        let label = NSTextField(labelWithString: formatBadge(badgeText))
        label.font = NSFont.systemFont(ofSize: max(11, itemSize * 0.145), weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(label)
        self.badgeLabel = label

        NSLayoutConstraint.activate([
            // Badge in top-right corner
            badgeContainer.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            badgeContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: badgeSize),
            badgeContainer.heightAnchor.constraint(equalToConstant: badgeSize),

            // Label centered in badge
            label.centerXAnchor.constraint(equalTo: badgeContainer.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: badgeContainer.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.trailingAnchor, constant: -4)
        ])
    }

    private func formatBadge(_ badge: String) -> String {
        // If it's a number greater than 99, show "99+"
        if let num = Int(badge), num > 99 {
            return "99+"
        }
        return badge
    }

    private func setupTrackingArea() {
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = isSelected
            ? NSColor.white.withAlphaComponent(0.3).cgColor
            : NSColor.clear.cgColor
    }

    // MARK: - Mouse Tracking

    override func mouseEntered(with event: NSEvent) {
        delegate?.appItemHovered(self)
    }

    override func mouseExited(with event: NSEvent) {
        // Selection will be handled by delegate
    }
}
