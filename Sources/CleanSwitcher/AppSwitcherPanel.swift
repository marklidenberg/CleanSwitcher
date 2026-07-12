import Cocoa

protocol AppSwitcherPanelDelegate: AnyObject {
    /// A click landed on a click shield (outside the panel) — dismiss, like Escape.
    func panelDidRequestDismiss()
}

class AppSwitcherPanel: NSPanel, AppItemViewDelegate {
    weak var panelDelegate: AppSwitcherPanelDelegate?

    private var appViews: [AppItemView] = []
    private var rows: [[AppItemView]] = []       // All rows: main first, then secondary
    private var rowStacks: [NSStackView] = []    // Horizontal stack per row, parallel to `rows`
    private var verticalStackView: NSStackView!  // Contains title, row stacks, separator, hint

    // The switcher has two sections drawn from the same items: the main row(s) —
    // recent apps/windows — and the secondary row(s) — everything older. Both are
    // always shown; the secondary tiles are rendered faded (see secondary opacity).
    // A thin divider separates them.
    private var mainRowCount: Int = 0
    private var separator: NSView!

    // Vertical layout: a single column of icon+name rows (the window switcher).
    // Off = the horizontal icon grid (the app switcher). Drives sizing and the
    // mid-open resize anchor.
    private var verticalLayout = false

    // Whether the secondary section is currently on screen. The app switcher opens
    // with it hidden and toggles it via Cmd+S; the window switcher opens with it shown.
    private var secondaryShown = false

    private var selectedRow: Int = 0
    private var selectedColumn: Int = 0
    private var visualEffectView: NSVisualEffectView!
    private var maxPanelWidth: CGFloat = 400

    // Dead zone for hover - like AltTab's CursorEvents
    private var deadZoneInitialPosition: NSPoint?
    private var isAllowedToMouseHover = false
    private var mouseMonitor: Any?

    // Mid-open resizes (remove/append) can fire spurious mouseEntered events,
    // so hover is suppressed for ~100ms around them (see
    // suppressHoverDuringResize). The token pairs each delayed restore with its
    // own suppression and the pre-suppression value is captured only by the
    // outermost call, so overlapping suppressions (H twice quickly, or a
    // live-refresh append during a removal) can't clobber each other and leave
    // hover stuck off.
    private var hoverSuppressionToken = 0
    private var hoverAllowedBeforeSuppression: Bool?

    // Invisible per-screen panels that swallow clicks outside the switcher while
    // it's open (the .listenOnly tap can't consume them). See showClickShields.
    private var clickShields: [ClickShieldPanel] = []

    // Recomputed per show based on the target screen (see iconSize(for:)).
    private var itemSize: CGFloat = 76
    // Max items per row, computed from screen width in showWithItems and reused by
    // appendItems so live-added apps pack into rows the same way.
    private var itemsPerRow: Int = 1
    private let itemSpacing: CGFloat = 0
    private let rowSpacing: CGFloat = 4
    private let panelPadding: CGFloat = 10
    private let deadZoneThreshold: CGFloat = 3
    private let screenMarginPercent: CGFloat = 0.85  // Use max 85% of screen width
    // Secondary-row tiles (the older, less-used apps/windows) render smaller than
    // the main row to visually de-emphasize them.
    private let secondaryItemScale: CGFloat = 0.6
    // Fixed icon size for the vertical window list (a list of full-size icons is
    // unwieldy); not screen-scaled like the horizontal grid.
    private let verticalIconSize: CGFloat = 44

    // Icon scaling: base size on a reference-height display, scaled up for
    // larger monitors so icons stay legible. Floored at the base so laptops
    // and standard displays never shrink; capped so it can't get absurd.
    private let baseItemSize: CGFloat = 76
    private let maxItemSize: CGFloat = 160
    private let referenceScreenHeight: CGFloat = 1080

    /// Item/icon size scaled to the given screen's point height.
    private func iconSize(for screen: NSScreen) -> CGFloat {
        let scaled = baseItemSize * (screen.frame.height / referenceScreenHeight)
        return min(max(scaled, baseItemSize), maxItemSize)
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 132),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
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
    }

    private func setupVisualEffectView() {
        let effectView = HoverTrackingVisualEffectView()
        effectView.onMouseMovement = { [weak self] in self?.handleMouseMoved() }
        visualEffectView = effectView
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.wantsLayer = true
        visualEffectView.maskImage = maskImage(cornerRadius: 16)

        // Add darkening overlay for light mode (transparent in dark mode)
        let darkeningView = AppearanceAdaptiveView()
        darkeningView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(darkeningView)
        NSLayoutConstraint.activate([
            darkeningView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            darkeningView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            darkeningView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            darkeningView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])

        contentView = visualEffectView
    }

    private func maskImage(cornerRadius: CGFloat) -> NSImage {
        let edgeLength = 2.0 * cornerRadius + 1.0
        let size = NSSize(width: edgeLength, height: edgeLength)
        let image = NSImage(size: size, flipped: false) { rect in
            let bezierPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.setFill()
            bezierPath.fill()
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
            verticalStackView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -panelPadding)
        ])

        // The main/secondary divider — re-added to the stack per open (see clearAppViews).
        separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        NSLayoutConstraint.activate([
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.widthAnchor.constraint(equalToConstant: 60)
        ])
    }

    // MARK: - Public Methods

    /// Build and show the panel. `main` is always visible; `secondary` is built but
    /// shown only if `secondaryShown` (the app switcher opens hidden and toggles via
    /// Cmd+S; the window switcher opens shown). `vertical` renders a single column of
    /// icon+name rows (the window switcher); off is the horizontal icon grid.
    func showWithItems(main: [SwitcherItem], secondary: [SwitcherItem], selectIndex: Int, vertical: Bool = false, secondaryShown: Bool) {
        // Clear any leftover views (normally already cleared on hide). The panel
        // is rebuilt from scratch every open, so this is just defensive.
        clearAppViews()
        self.verticalLayout = vertical
        self.secondaryShown = secondaryShown

        // Find screen containing mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = targetScreen.visibleFrame

        maxPanelWidth = screenFrame.width * screenMarginPercent
        let availableWidth = maxPanelWidth - panelPadding * 2

        if vertical {
            // One icon+name row per item; fixed compact icon.
            itemSize = verticalIconSize
            itemsPerRow = 1
        } else {
            // Scale icon size to this screen (bigger monitors get bigger icons),
            // then pack as many per row as the width budget allows.
            itemSize = iconSize(for: targetScreen)
            itemsPerRow = max(1, Int(floor((availableWidth + itemSpacing) / (itemSize + itemSpacing))))
        }

        // Main section, then the divider + the secondary section (hidden unless shown).
        mainRowCount = addRows(for: main, secondary: false)
        if !secondary.isEmpty {
            separator.isHidden = !secondaryShown
            verticalStackView.addArrangedSubview(separator)
            addRows(for: secondary, secondary: true)
        }

        // Select the initial item.
        if !rows.isEmpty {
            let flat = max(0, min(selectIndex, appViews.count - 1))
            if let (row, col) = rowColumn(forFlatIndex: flat) {
                selectedRow = row
                selectedColumn = col
            }
            updateSelectionVisuals()
        }

        // Size to content and center on the target screen.
        let size = contentSize()
        setFrame(NSRect(x: screenFrame.midX - size.width / 2,
                        y: screenFrame.midY - size.height / 2,
                        width: size.width, height: size.height), display: true)

        // Reset dead zone - hover will be enabled after mouse moves 3+ pixels
        deadZoneInitialPosition = nil
        isAllowedToMouseHover = false
        cancelHoverSuppression()
        startMouseMonitor()

        showClickShields()
        orderFront(nil)
    }

    /// Wrap `items` into rows of `itemsPerRow`, appending each row's stack to the
    /// vertical stack. Secondary rows are faded (see the secondary-opacity prefs).
    /// Returns the number of rows added.
    @discardableResult
    private func addRows(for items: [SwitcherItem], secondary: Bool) -> Int {
        guard !items.isEmpty else { return 0 }
        var added = 0
        var currentRow: [AppItemView] = []
        var currentStack = createRowStackView()

        func flush() {
            rows.append(currentRow)
            rowStacks.append(currentStack)
            currentStack.isHidden = secondary && !secondaryShown  // secondary hidden until toggled on
            verticalStackView.addArrangedSubview(currentStack)
            added += 1
            currentRow = []
            currentStack = createRowStackView()
        }

        // Vertical rows keep a uniform icon size; horizontal shrinks the secondary.
        let size = (secondary && !verticalLayout) ? (itemSize * secondaryItemScale).rounded() : itemSize
        // Every vertical cell shares one width so the icons form a column; capped
        // to a sensible list width rather than the full screen budget.
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

    /// Flat display index (main then secondary) → (row, column) in `rows`.
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

    private func startMouseMonitor() {
        stopMouseMonitor()

        // Single global monitor for mouse movement
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMoved()
        }
    }

    private func handleMouseMoved() {
        let currentPos = NSEvent.mouseLocation

        // Dead zone logic (like AltTab's CursorEvents)
        if !isAllowedToMouseHover {
            if deadZoneInitialPosition == nil {
                deadZoneInitialPosition = currentPos
                return
            }
            let dx = currentPos.x - deadZoneInitialPosition!.x
            let dy = currentPos.y - deadZoneInitialPosition!.y
            let distance = hypot(dx, dy)
            if distance > deadZoneThreshold {
                isAllowedToMouseHover = true
            } else {
                return
            }
        }

        // Hover enabled - update selection if mouse is over panel
        if frame.contains(currentPos) {
            selectAppUnderMouse()
        }
    }

    private func selectAppUnderMouse() {
        // Use mouseLocationOutsideOfEventStream for accurate position in non-activating panel
        let windowPoint = mouseLocationOutsideOfEventStream

        for (rowIndex, row) in rows.enumerated() {
            for (colIndex, view) in row.enumerated() {
                // Convert view bounds to window coordinates
                let viewFrame = view.convert(view.bounds, to: nil)
                if viewFrame.contains(windowPoint) {
                    if selectedRow != rowIndex || selectedColumn != colIndex {
                        selectedRow = rowIndex
                        selectedColumn = colIndex
                        updateSelectionVisuals()
                    }
                    return
                }
            }
        }
    }

    /// Item under the current mouse position, independent of dead-zone hover state.
    func getItemUnderMouse() -> SwitcherItem? {
        let windowPoint = mouseLocationOutsideOfEventStream
        for row in rows {
            for view in row where !(view.superview?.isHidden ?? true) {
                // Convert view bounds to window coordinates
                let viewFrame = view.convert(view.bounds, to: nil)
                if viewFrame.contains(windowPoint) {
                    return view.item
                }
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

    // MARK: - Click Shields

    /// Cover every screen with an invisible panel one window level below the
    /// switcher while it's open. The event tap is .listenOnly and cannot consume
    /// events, so without these a click outside the panel would also land in the
    /// app under the cursor. The shields catch that click via ordinary
    /// window-server routing (no permissions involved) and request a dismiss —
    /// click-away behaves like Escape. Clicks on the switcher itself are
    /// unaffected: it floats above the shields.
    /// Recreated per open (screens can change) and released on hide so their
    /// full-screen backing stores don't stay resident between switches.
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
        stopMouseMonitor()
        hideClickShields()
        deadZoneInitialPosition = nil
        isAllowedToMouseHover = false
        cancelHoverSuppression()
        orderOut(nil)
        // Release the item views (and their icon image references) while closed,
        // so they don't sit resident between switches. The next open rebuilds
        // everything anyway, so this costs no rebuild latency.
        clearAppViews()
    }

    /// Tear down all item views and reset section state. The persistent divider
    /// is detached here and re-added on the next build.
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

    /// Rows the selection can currently reach: all of them, or just the main
    /// section while the secondary is toggled off.
    private var navigableRowCount: Int {
        secondaryShown ? rows.count : mainRowCount
    }

    func selectNext() {
        guard !rows.isEmpty else { return }

        var row = selectedRow
        var col = selectedColumn
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

        var row = selectedRow
        var col = selectedColumn
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

    /// Move the selection to (row, column), then repaint.
    private func applyMove(toRow row: Int, column col: Int) {
        selectedRow = row
        selectedColumn = col
        updateSelectionVisuals()
    }

    /// Toggle the secondary section on/off (Cmd+S). When hiding it while the
    /// selection sits inside it, the selection snaps back to the last main item.
    func toggleSecondary() {
        guard rows.count > mainRowCount else { return }  // nothing to toggle
        secondaryShown.toggle()
        for i in mainRowCount..<rowStacks.count {
            rowStacks[i].isHidden = !secondaryShown
        }
        separator.isHidden = !secondaryShown
        if !secondaryShown, selectedRow >= mainRowCount {
            selectedRow = mainRowCount - 1
            selectedColumn = min(selectedColumn, rows[selectedRow].count - 1)
        }
        resizeForLayout()
        updateSelectionVisuals()
    }

    func getSelectedItem() -> SwitcherItem? {
        guard selectedRow >= 0 && selectedRow < rows.count else { return nil }
        guard selectedColumn >= 0 && selectedColumn < rows[selectedRow].count else { return nil }
        return rows[selectedRow][selectedColumn].item
    }

    func removeSelectedItem() -> SwitcherItem? {
        guard selectedRow >= 0 && selectedRow < rows.count else { return nil }
        guard selectedColumn >= 0 && selectedColumn < rows[selectedRow].count else { return nil }

        let removedView = rows[selectedRow][selectedColumn]
        let removedItem = removedView.item

        // Temporarily disable hover during removal (panel resize can trigger mouseEntered)
        suppressHoverDuringResize()

        // Remove from flat list
        if let flatIndex = appViews.firstIndex(where: { $0 === removedView }) {
            appViews.remove(at: flatIndex)
        }

        // Remove from current row's stack view
        if let rowStackView = removedView.superview as? NSStackView {
            rowStackView.removeArrangedSubview(removedView)
            removedView.removeFromSuperview()
        }

        // Remove from rows array
        rows[selectedRow].remove(at: selectedColumn)

        // Remove empty rows
        if rows[selectedRow].isEmpty {
            let rowStackView = rowStacks[selectedRow]
            verticalStackView.removeArrangedSubview(rowStackView)
            rowStackView.removeFromSuperview()
            rows.remove(at: selectedRow)
            rowStacks.remove(at: selectedRow)
            if selectedRow < mainRowCount { mainRowCount -= 1 }
        }

        // Adjust selection
        if rows.isEmpty {
            selectedRow = -1
            selectedColumn = -1
        } else {
            // Clamp row
            if selectedRow >= rows.count {
                selectedRow = rows.count - 1
            }
            // Clamp column
            if selectedColumn >= rows[selectedRow].count {
                selectedColumn = rows[selectedRow].count - 1
            }
        }

        if !rows.isEmpty {
            resizeForLayout()
            updateSelectionVisuals()
        }

        return removedItem
    }

    /// Append newly-appeared apps (recent) into the MAIN section — before the
    /// divider, so they don't land among the older secondary apps — without
    /// disturbing existing items. App mode only. Driven by the live-refresh timer.
    func appendItems(_ items: [SwitcherItem]) {
        guard !items.isEmpty, !rows.isEmpty, !verticalLayout else { return }

        // The resize below can trigger a spurious mouseEntered; suppress hover briefly.
        suppressHoverDuringResize()

        let size = itemSize
        let cellWidth = min(maxPanelWidth - panelPadding * 2, 460)
        for item in items {
            let view = AppItemView(item: item, itemSize: size, showsLabel: false, cellWidth: cellWidth)
            view.delegate = self
            appViews.append(view)

            // Fill the last main row if it has room; otherwise start a new main row,
            // inserted just before the divider (arranged index == mainRowCount).
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

    var hasItems: Bool {
        !rows.isEmpty
    }

    // MARK: - Private Methods

    /// Content size that fits all arranged subviews (both sections are shown).
    private func contentSize() -> CGSize {
        visualEffectView.layoutSubtreeIfNeeded()
        let fitting = verticalStackView.fittingSize
        let width = min(fitting.width + panelPadding * 2, maxPanelWidth)
        let height = fitting.height + panelPadding * 2
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    /// Resize to fit content, keeping the panel's TOP edge and horizontal center
    /// fixed (NOT recentering on screen — the panel is already placed), so the top
    /// row stays put as the panel grows/shrinks. Used by the horizontal layouts.
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

    /// Resize to fit visible content, keeping the panel's CENTER fixed. Used by the
    /// vertical window list, where growing downward could run off the screen.
    private func resizeKeepingCenter() {
        let size = contentSize()
        var frame = self.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        frame.size = size
        frame.origin.x = center.x - size.width / 2
        frame.origin.y = center.y - size.height / 2
        setFrame(frame, display: true)
    }

    /// Resize after a mid-open change, keeping the top fixed (horizontal) or the
    /// center fixed (vertical list, which could otherwise overflow growing downward).
    private func resizeForLayout() {
        if verticalLayout { resizeKeepingCenter() } else { resizeKeepingTop() }
    }

    /// Suppress hover briefly around a mid-open resize, restoring the
    /// pre-suppression value once things settle (see the token/value members).
    private func suppressHoverDuringResize() {
        if hoverAllowedBeforeSuppression == nil {
            hoverAllowedBeforeSuppression = isAllowedToMouseHover
        }
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

    /// Drop any pending hover restore. Called when the panel opens or closes,
    /// where hover state is reset wholesale — a stale restore from the previous
    /// open must not re-enable hover past the fresh dead zone.
    private func cancelHoverSuppression() {
        hoverSuppressionToken += 1
        hoverAllowedBeforeSuppression = nil
    }

    /// Repaint the selection highlight.
    private func updateSelectionVisuals() {
        for (rowIndex, row) in rows.enumerated() {
            for (colIndex, view) in row.enumerated() {
                view.setSelected(rowIndex == selectedRow && colIndex == selectedColumn)
            }
        }
    }

    // MARK: - AppItemViewDelegate

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

// MARK: - Hover Tracking Effect View

/// The panel's content view; forwards any mouse movement over the panel to the
/// hover logic. Hover normally rides a global mouseMoved monitor, but global
/// monitors never see the app's OWN events — so when CleanSwitcher itself is the
/// active app (e.g. Cmd+Tab right after using the Preferences window) the
/// monitor goes silent and hover selection dies. This tracking area fires
/// regardless of which app is active. Both paths call handleMouseMoved, which
/// is idempotent, so double delivery is harmless.
private class HoverTrackingVisualEffectView: NSVisualEffectView {
    var onMouseMovement: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { onMouseMovement?() }
    override func mouseEntered(with event: NSEvent) { onMouseMovement?() }
    override func mouseExited(with event: NSEvent) { onMouseMovement?() }
}

// MARK: - Click Shield

/// Invisible, non-activating panel covering one screen just below the switcher.
/// Swallows clicks that would otherwise fall through to the app behind the
/// panel and reports them so the switcher can dismiss.
private class ClickShieldPanel: NSPanel {
    var onClick: (() -> Void)?

    init(screenFrame: NSRect) {
        super.init(
            contentRect: screenFrame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        // One notch below the switcher panel (.popUpMenu) so it never covers it.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        // Not .clear: the window server treats fully transparent windows as
        // click-through; a hair of alpha keeps clicks landing here. Explicitly
        // setting ignoresMouseEvents=false also opts out of that automatism.
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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // The shield is non-activating and never key, so the first click must count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) { onClick() }
    override func otherMouseDown(with event: NSEvent) { onClick() }
}

// MARK: - Appearance Adaptive View

/// A view that darkens the background in light mode only
private class AppearanceAdaptiveView: NSView {
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
        layer?.backgroundColor = isDark ? nil : NSColor.black.withAlphaComponent(0.35).cgColor
    }
}
