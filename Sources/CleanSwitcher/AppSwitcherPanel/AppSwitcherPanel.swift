import Cocoa

protocol AppSwitcherPanelDelegate: AnyObject {
    /// A click landed on a click shield (outside the panel) — dismiss, like Escape.
    func panelDidRequestDismiss()
}

/// The floating switcher panel. See AppSwitcherPanel.md.
class AppSwitcherPanel: NSPanel, AppItemViewDelegate {
    weak var panelDelegate: AppSwitcherPanelDelegate?

    private var appViews: [AppItemView] = []
    private var rows: [[AppItemView]] = []       // main rows first, then secondary
    private var rowStacks: [NSStackView] = []    // horizontal stack per row, parallel to `rows`
    private var verticalStackView: NSStackView!  // title, row stacks, separator, hint

    private var mainRowCount: Int = 0
    private var separator: NSView!

    // Vertical list (window switcher) vs horizontal icon grid (app switcher).
    private var verticalLayout = false
    // Whether the secondary section is on screen (app switcher opens hidden,
    // window switcher opens shown; T toggles).
    private var secondaryShown = false

    private var selectedRow: Int = 0
    private var selectedColumn: Int = 0
    private var visualEffectView: NSVisualEffectView!
    private var maxPanelWidth: CGFloat = 400

    // Hover dead zone — the mouse must move `deadZoneThreshold` px before hover
    // takes over selection.
    private var deadZoneInitialPosition: NSPoint?
    private var isAllowedToMouseHover = false
    private var mouseMonitor: Any?

    // Mid-open resizes can emit spurious mouseEntered, so hover is suppressed for
    // ~100ms around them. The token pairs each delayed restore with its own
    // suppression; only the outermost call captures the pre-suppression value, so
    // overlapping suppressions can't leave hover stuck off.
    private var hoverSuppressionToken = 0
    private var hoverAllowedBeforeSuppression: Bool?

    private var clickShields: [ClickShieldPanel] = []

    // The panel is built immediately but presented after a short delay, so a fast
    // Cmd+Tab tap (press then release) switches without ever flashing it on screen.
    private var pendingShow: DispatchWorkItem?
    private let showDelay: TimeInterval = 0.10
    private var holdStart: Date?  // temporary: measure Tab-press → Cmd-release

    // Recomputed per show from the target screen.
    private var itemSize: CGFloat = 76
    private var itemsPerRow: Int = 1
    private let itemSpacing: CGFloat = 0
    private let rowSpacing: CGFloat = 4
    private let panelPadding: CGFloat = 10
    private let deadZoneThreshold: CGFloat = 3
    private let screenMarginPercent: CGFloat = 0.85
    private let secondaryItemScale: CGFloat = 0.6  // older tiles render smaller
    private let verticalIconSize: CGFloat = 44     // fixed icon for the window list

    // Icon size scales with the screen's point height, floored at base (laptops
    // never shrink) and capped so it can't get absurd.
    private let baseItemSize: CGFloat = 76
    private let maxItemSize: CGFloat = 160
    private let referenceScreenHeight: CGFloat = 1080

    private func iconSize(for screen: NSScreen) -> CGFloat {
        let scaled = baseItemSize * (screen.frame.height / referenceScreenHeight)
        return min(max(scaled, baseItemSize), maxItemSize)
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 132),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false
        )
        setupPanel()
        setupVisualEffectView()
        setupStackView()
    }

    private func setupPanel() {
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none  // no scale/fade-in; the switcher appears at once
    }

    private func setupVisualEffectView() {
        let effectView = HoverTrackingVisualEffectView()
        effectView.onMouseMovement = { [weak self] in self?.handleMouseMoved() }
        visualEffectView = effectView
        visualEffectView.material = .popover
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.wantsLayer = true
        visualEffectView.maskImage = maskImage(cornerRadius: 16)

        // Subtle white glass tint over the blur (liquid-glass look).
        let tintView = GlassTintView()
        tintView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(tintView)
        NSLayoutConstraint.activate([
            tintView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
        ])

        contentView = visualEffectView
    }

    private func maskImage(cornerRadius: CGFloat) -> NSImage {
        let edgeLength = 2.0 * cornerRadius + 1.0
        let image = NSImage(size: NSSize(width: edgeLength, height: edgeLength), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }

    private func setupStackView() {
        verticalStackView = NSStackView()
        verticalStackView.orientation = .vertical
        verticalStackView.spacing = rowSpacing
        verticalStackView.alignment = .centerX
        verticalStackView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(verticalStackView)

        NSLayoutConstraint.activate([
            verticalStackView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: panelPadding),
            verticalStackView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -panelPadding),
            verticalStackView.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: panelPadding),
            verticalStackView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -panelPadding),
        ])

        // The main/secondary divider — re-added to the stack per open.
        separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        NSLayoutConstraint.activate([
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.widthAnchor.constraint(equalToConstant: 60),
        ])
    }

    /// Build and show the panel. `main` is always visible; `secondary` is built but
    /// shown only if `secondaryShown`. `vertical` renders the window-list column.
    func showWithItems(main: [SwitcherItem], secondary: [SwitcherItem], selectIndex: Int, vertical: Bool = false, secondaryShown: Bool) {
        clearAppViews()  // defensive; hide already clears
        self.verticalLayout = vertical
        self.secondaryShown = secondaryShown

        // - Size icons and pack per row for the target screen

        let screen = targetScreen()
        if vertical {
            itemSize = verticalIconSize
            itemsPerRow = 1
        } else {
            itemSize = iconSize(for: screen)
            let availableWidth = maxPanelWidth - panelPadding * 2
            itemsPerRow = max(1, Int(floor((availableWidth + itemSpacing) / (itemSize + itemSpacing))))
        }

        // - Build main, then the divider + secondary

        mainRowCount = addRows(for: main, secondary: false)
        if !secondary.isEmpty {
            separator.isHidden = !secondaryShown
            verticalStackView.addArrangedSubview(separator)
            addRows(for: secondary, secondary: true)
        }

        // - Apply the initial selection

        if !rows.isEmpty {
            let flat = max(0, min(selectIndex, appViews.count - 1))
            if let (row, col) = rowColumn(forFlatIndex: flat) {
                selectedRow = row
                selectedColumn = col
            }
            updateSelectionVisuals()
        }

        sizeAndCenter(on: screen.visibleFrame)
        schedulePresent()
    }

    /// Show a non-interactive placeholder (e.g. "No open windows"). No selectable
    /// items — releasing Cmd, Escape, or a click just dismisses.
    func showPlaceholder(_ text: String) {
        clearAppViews()
        verticalLayout = true
        secondaryShown = false
        selectedRow = -1
        selectedColumn = -1

        let screen = targetScreen()

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        verticalStackView.addArrangedSubview(label)

        sizeAndCenter(on: screen.visibleFrame)
        schedulePresent()
    }

    /// The screen under the cursor; also sets `maxPanelWidth` from it.
    private func targetScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first!
        maxPanelWidth = screen.visibleFrame.width * screenMarginPercent
        return screen
    }

    /// Size to content and center on `screenFrame`.
    private func sizeAndCenter(on screenFrame: NSRect) {
        let size = contentSize()
        setFrame(NSRect(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2,
                        width: size.width, height: size.height), display: true)
    }

    /// Present after `showDelay`; a hide before it fires cancels it, so a fast tap
    /// never flashes the panel.
    private func schedulePresent() {
        holdStart = Date()  // temporary: measure Tab-press → Cmd-release
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingShow = nil
            self?.present()
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    /// Reset hover state, then show with click shields.
    private func present() {
        if let s = holdStart { NSLog("CSFLICK SHOWN after %.0fms", Date().timeIntervalSince(s) * 1000) }
        deadZoneInitialPosition = nil
        isAllowedToMouseHover = false
        cancelHoverSuppression()
        startMouseMonitor()
        showClickShields()
        orderFront(nil)
    }

    /// Wrap `items` into rows of `itemsPerRow`. Secondary rows are hidden until
    /// toggled and (horizontal only) shrunk. Returns the number of rows added.
    @discardableResult
    private func addRows(for items: [SwitcherItem], secondary: Bool) -> Int {
        guard !items.isEmpty else { return 0 }
        var added = 0
        var currentRow: [AppItemView] = []
        var currentStack = createRowStackView()

        func flush() {
            rows.append(currentRow)
            rowStacks.append(currentStack)
            currentStack.isHidden = secondary && !secondaryShown
            verticalStackView.addArrangedSubview(currentStack)
            added += 1
            currentRow = []
            currentStack = createRowStackView()
        }

        let size = (secondary && !verticalLayout) ? (itemSize * secondaryItemScale).rounded() : itemSize
        let cellWidth = min(maxPanelWidth - panelPadding * 2, 460)
        for item in items {
            let itemView = AppItemView(item: item, itemSize: size, showsLabel: verticalLayout, cellWidth: cellWidth)
            itemView.delegate = self
            appViews.append(itemView)
            currentRow.append(itemView)
            currentStack.addArrangedSubview(itemView)
            if currentRow.count >= itemsPerRow { flush() }
        }
        if !currentRow.isEmpty { flush() }
        return added
    }

    /// Flat display index (main then secondary) → (row, column).
    private func rowColumn(forFlatIndex flat: Int) -> (Int, Int)? {
        var remaining = flat
        for (rowIndex, row) in rows.enumerated() {
            if remaining < row.count { return (rowIndex, remaining) }
            remaining -= row.count
        }
        return nil
    }

    private func createRowStackView() -> NSStackView {
        let rowStack = NSStackView()
        rowStack.orientation = .horizontal
        rowStack.spacing = itemSpacing
        rowStack.alignment = .centerY
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        return rowStack
    }

    // - Hover

    private func startMouseMonitor() {
        stopMouseMonitor()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMoved()
        }
    }

    private func handleMouseMoved() {
        let currentPos = NSEvent.mouseLocation

        // - Cross the dead zone before hover takes over

        if !isAllowedToMouseHover {
            guard let start = deadZoneInitialPosition else {
                deadZoneInitialPosition = currentPos
                return
            }
            guard hypot(currentPos.x - start.x, currentPos.y - start.y) > deadZoneThreshold else { return }
            isAllowedToMouseHover = true
        }

        // - Select whatever the cursor is over

        if frame.contains(currentPos) { selectAppUnderMouse() }
    }

    private func selectAppUnderMouse() {
        let windowPoint = mouseLocationOutsideOfEventStream
        for (rowIndex, row) in rows.enumerated() {
            for (colIndex, view) in row.enumerated() where view.convert(view.bounds, to: nil).contains(windowPoint) {
                if selectedRow != rowIndex || selectedColumn != colIndex {
                    selectedRow = rowIndex
                    selectedColumn = colIndex
                    updateSelectionVisuals()
                }
                return
            }
        }
    }

    /// Item under the current mouse position, independent of dead-zone hover state.
    func getItemUnderMouse() -> SwitcherItem? {
        let windowPoint = mouseLocationOutsideOfEventStream
        for row in rows {
            for view in row where !(view.superview?.isHidden ?? true) {
                if view.convert(view.bounds, to: nil).contains(windowPoint) { return view.item }
            }
        }
        return nil
    }

    private func stopMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    // - Click shields
    //   Invisible per-screen panels one level below the switcher that catch clicks
    //   outside it (the .listenOnly tap can't consume them) and request a dismiss.
    //   Recreated per open (screens change) and released on hide.

    private func showClickShields() {
        hideClickShields()
        for screen in NSScreen.screens {
            let shield = ClickShieldPanel(screenFrame: screen.frame)
            shield.onClick = { [weak self] in self?.panelDelegate?.panelDidRequestDismiss() }
            shield.orderFront(nil)
            clickShields.append(shield)
        }
    }

    private func hideClickShields() {
        clickShields.forEach { $0.orderOut(nil) }
        clickShields.removeAll()
    }

    func hidePanel() {
        if let s = holdStart {
            NSLog("CSFLICK RELEASED after %.0fms — %@", Date().timeIntervalSince(s) * 1000,
                  pendingShow != nil ? "NOT shown (cancelled)" : "was shown")
        }
        holdStart = nil
        pendingShow?.cancel()  // a fast tap dismisses before the delayed present fires
        pendingShow = nil
        stopMouseMonitor()
        hideClickShields()
        deadZoneInitialPosition = nil
        isAllowedToMouseHover = false
        cancelHoverSuppression()
        orderOut(nil)
        // Release the item views (and their icons) while closed; the next open
        // rebuilds everything anyway.
        clearAppViews()
    }

    /// Tear down all item views and reset section state. The persistent divider is
    /// detached here and re-added on the next build.
    private func clearAppViews() {
        appViews.forEach { $0.removeFromSuperview() }
        appViews.removeAll()
        rows.removeAll()
        rowStacks.removeAll()
        mainRowCount = 0
        for subview in verticalStackView.arrangedSubviews {
            verticalStackView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
    }

    // - Navigation

    /// Rows the selection can reach: all, or just main while the secondary is off.
    private var navigableRowCount: Int {
        secondaryShown ? rows.count : mainRowCount
    }

    func selectNext() {
        guard !rows.isEmpty else { return }
        var row = selectedRow, col = selectedColumn
        if selectedColumn < rows[selectedRow].count - 1 {
            col += 1
        } else if selectedRow < navigableRowCount - 1 {
            row += 1; col = 0                      // next row, first column
        } else {
            row = 0; col = 0                       // wrap to first row, first column
        }
        applyMove(toRow: row, column: col)
    }

    func selectPrevious() {
        guard !rows.isEmpty else { return }
        var row = selectedRow, col = selectedColumn
        if selectedColumn > 0 {
            col -= 1
        } else if selectedRow > 0 {
            row -= 1; col = rows[row].count - 1    // previous row, last column
        } else {
            row = navigableRowCount - 1; col = rows[row].count - 1  // wrap to last visible row
        }
        applyMove(toRow: row, column: col)
    }

    func selectUp() {
        guard navigableRowCount > 1 else { return }
        let row = selectedRow > 0 ? selectedRow - 1 : navigableRowCount - 1
        applyMove(toRow: row, column: min(selectedColumn, rows[row].count - 1))
    }

    func selectDown() {
        guard navigableRowCount > 1 else { return }
        let row = selectedRow < navigableRowCount - 1 ? selectedRow + 1 : 0
        applyMove(toRow: row, column: min(selectedColumn, rows[row].count - 1))
    }

    private func applyMove(toRow row: Int, column col: Int) {
        selectedRow = row
        selectedColumn = col
        updateSelectionVisuals()
    }

    /// Toggle the secondary section (T). When hiding it with the selection inside,
    /// the selection snaps back to the last main item.
    func toggleSecondary() {
        guard rows.count > mainRowCount else { return }  // nothing to toggle
        secondaryShown.toggle()
        for i in mainRowCount..<rowStacks.count { rowStacks[i].isHidden = !secondaryShown }
        separator.isHidden = !secondaryShown
        if !secondaryShown, selectedRow >= mainRowCount {
            selectedRow = mainRowCount - 1
            selectedColumn = min(selectedColumn, rows[selectedRow].count - 1)
        }
        resizeForLayout()
        updateSelectionVisuals()
    }

    func getSelectedItem() -> SwitcherItem? {
        guard rows.indices.contains(selectedRow), rows[selectedRow].indices.contains(selectedColumn) else { return nil }
        return rows[selectedRow][selectedColumn].item
    }

    func removeSelectedItem() -> SwitcherItem? {
        guard rows.indices.contains(selectedRow), rows[selectedRow].indices.contains(selectedColumn) else { return nil }

        let removedView = rows[selectedRow][selectedColumn]
        let removedItem = removedView.item
        suppressHoverDuringResize()  // the resize below can trigger mouseEntered

        // - Detach the view from every list it's in

        if let flatIndex = appViews.firstIndex(where: { $0 === removedView }) { appViews.remove(at: flatIndex) }
        if let rowStackView = removedView.superview as? NSStackView {
            rowStackView.removeArrangedSubview(removedView)
            removedView.removeFromSuperview()
        }
        rows[selectedRow].remove(at: selectedColumn)

        // - Drop the row if it's now empty

        if rows[selectedRow].isEmpty {
            let rowStackView = rowStacks[selectedRow]
            verticalStackView.removeArrangedSubview(rowStackView)
            rowStackView.removeFromSuperview()
            rows.remove(at: selectedRow)
            rowStacks.remove(at: selectedRow)
            if selectedRow < mainRowCount { mainRowCount -= 1 }
        }

        // - Clamp the selection to what's left

        if rows.isEmpty {
            selectedRow = -1
            selectedColumn = -1
        } else {
            selectedRow = min(selectedRow, rows.count - 1)
            selectedColumn = min(selectedColumn, rows[selectedRow].count - 1)
        }

        if !rows.isEmpty {
            resizeForLayout()
            updateSelectionVisuals()
        }
        return removedItem
    }

    /// Append newly-appeared apps into the MAIN section (before the divider),
    /// without disturbing existing items. App mode only; driven by the live refresh.
    func appendItems(_ items: [SwitcherItem]) {
        guard !items.isEmpty, !rows.isEmpty, !verticalLayout else { return }
        suppressHoverDuringResize()  // the resize below can trigger mouseEntered

        let size = itemSize
        let cellWidth = min(maxPanelWidth - panelPadding * 2, 460)
        for item in items {
            let view = AppItemView(item: item, itemSize: size, showsLabel: false, cellWidth: cellWidth)
            view.delegate = self
            appViews.append(view)

            // Fill the last main row if it has room; else start a new main row just
            // before the divider (arranged index == mainRowCount).
            let lastMainRow = mainRowCount - 1
            if lastMainRow >= 0, rows[lastMainRow].count < itemsPerRow {
                rows[lastMainRow].append(view)
                rowStacks[lastMainRow].addArrangedSubview(view)
            } else {
                let stack = createRowStackView()
                stack.addArrangedSubview(view)
                rows.insert([view], at: mainRowCount)
                rowStacks.insert(stack, at: mainRowCount)
                verticalStackView.insertArrangedSubview(stack, at: mainRowCount)
                if selectedRow >= mainRowCount { selectedRow += 1 }  // secondary shifted down
                mainRowCount += 1
            }
        }

        resizeForLayout()
        updateSelectionVisuals()
    }

    var hasItems: Bool { !rows.isEmpty }

    // - Sizing

    /// Content size that fits all arranged subviews.
    private func contentSize() -> CGSize {
        visualEffectView.layoutSubtreeIfNeeded()
        let fitting = verticalStackView.fittingSize
        let width = min(fitting.width + panelPadding * 2, maxPanelWidth)
        return CGSize(width: max(width, 1), height: max(fitting.height + panelPadding * 2, 1))
    }

    /// Resize keeping the TOP edge and horizontal center fixed (horizontal layouts).
    private func resizeKeepingTop() {
        let size = contentSize()
        var frame = self.frame
        let centerX = frame.midX
        let topY = frame.maxY  // AppKit y is bottom-up, so the top edge is maxY
        frame.size = size
        frame.origin.x = centerX - size.width / 2
        frame.origin.y = topY - size.height
        setFrame(frame, display: true)
    }

    /// Resize keeping the CENTER fixed (vertical list, which could run off-screen).
    private func resizeKeepingCenter() {
        let size = contentSize()
        var frame = self.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        frame.size = size
        frame.origin.x = center.x - size.width / 2
        frame.origin.y = center.y - size.height / 2
        setFrame(frame, display: true)
    }

    private func resizeForLayout() {
        if verticalLayout { resizeKeepingCenter() } else { resizeKeepingTop() }
    }

    /// Suppress hover around a mid-open resize, restoring the pre-suppression value
    /// once things settle.
    private func suppressHoverDuringResize() {
        if hoverAllowedBeforeSuppression == nil { hoverAllowedBeforeSuppression = isAllowedToMouseHover }
        isAllowedToMouseHover = false
        hoverSuppressionToken += 1
        let token = hoverSuppressionToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.hoverSuppressionToken == token else { return }
            if let allowed = self.hoverAllowedBeforeSuppression {
                self.isAllowedToMouseHover = allowed
                self.hoverAllowedBeforeSuppression = nil
            }
        }
    }

    /// Drop any pending hover restore. Called on open/close, where hover is reset
    /// wholesale — a stale restore must not re-enable hover past the fresh dead zone.
    private func cancelHoverSuppression() {
        hoverSuppressionToken += 1
        hoverAllowedBeforeSuppression = nil
    }

    private func updateSelectionVisuals() {
        for (rowIndex, row) in rows.enumerated() {
            for (colIndex, view) in row.enumerated() {
                view.setSelected(rowIndex == selectedRow && colIndex == selectedColumn)
            }
        }
    }

    func appItemHovered(_ view: AppItemView) {
        guard isAllowedToMouseHover else { return }
        for (rowIndex, row) in rows.enumerated() {
            if let colIndex = row.firstIndex(where: { $0 === view }) {
                selectedRow = rowIndex
                selectedColumn = colIndex
                updateSelectionVisuals()
                return
            }
        }
    }
}

/// The panel's content view; forwards mouse movement over the panel to the hover
/// logic. Global monitors never see the app's OWN events, so when CleanSwitcher
/// itself is active this tracking area keeps hover alive. Both paths call the
/// idempotent handleMouseMoved, so double delivery is harmless.
private class HoverTrackingVisualEffectView: NSVisualEffectView {
    var onMouseMovement: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { onMouseMovement?() }
    override func mouseEntered(with event: NSEvent) { onMouseMovement?() }
    override func mouseExited(with event: NSEvent) { onMouseMovement?() }
}

/// Invisible, non-activating panel covering one screen just below the switcher.
/// Swallows clicks that would fall through to the app behind the panel and
/// reports them so the switcher can dismiss.
private class ClickShieldPanel: NSPanel {
    var onClick: (() -> Void)?

    init(screenFrame: NSRect) {
        super.init(contentRect: screenFrame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        // One notch below the switcher (.popUpMenu) so it never covers it.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        // Not .clear: the window server treats fully transparent windows as
        // click-through, so a hair of alpha keeps clicks landing here.
        backgroundColor = NSColor.black.withAlphaComponent(0.001)
        ignoresMouseEvents = false
        contentView = ClickShieldView(onClick: { [weak self] in self?.onClick?() })
    }
}

private class ClickShieldView: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The shield is non-activating and never key, so the first click must count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) { onClick() }
    override func otherMouseDown(with event: NSEvent) { onClick() }
}

/// A subtle white glass tint over the blur — brighter in light mode.
private class GlassTintView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = NSColor.white.withAlphaComponent(isDark ? 0.10 : 0.30).cgColor
    }
}
