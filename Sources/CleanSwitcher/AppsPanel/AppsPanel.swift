import Cocoa

/// The Apps panel: a compact box — or pill — on the optical center (Preferences' position), like Cmd+Tab's: the
/// pinned apps in rows, a line (optional), the recent ones in fixed slots under them.
/// Typing turns it into the search list. See AppsPanel.md.
final class AppsPanel: NSPanel, NSTextFieldDelegate, AppIconViewDelegate {
    private(set) var isOpen = false
    private var previewing = false  // shown for Preferences: a sample, not for use

    private static let columns = 7          // the recent grid's width, in slots
    private static let searchWidth: CGFloat = 380
    private var pinnedSize: CGFloat { CGFloat(Preferences.appsPinnedSize) }
    private var recentSize: CGFloat { CGFloat(Preferences.appsRecentSize) }
    private var gap: CGFloat { CGFloat(Preferences.appsGap) }
    private var pad: CGFloat { CGFloat(Preferences.appsPadding) }
    private var pinnedStep: CGFloat { pinnedSize + gap }
    private var recentStep: CGFloat { recentSize + gap }
    /// Pinned to recent: a hairline with room around it, or just a gap.
    private var between: CGFloat { Preferences.appsSeparator ? 2 * max(gap, 8) + 1 : gap }

    /// Where a drag would drop it.
    private enum Target: Equatable { case pinned(row: Int, index: Int, newRow: Bool), recent, hide }

    private var store = AppsStore.load()
    private var running: [String: NSRunningApplication] = [:]
    private var installed: [String: URL] = [:]
    private var lastUsed: [String: TimeInterval] = [:]
    private var views: [String: AppIconView] = [:]  // kept across opens: a reopen draws nothing anew
    private var icons: [String: NSImage] = [:]
    private var drag: (id: String, fromPinned: Bool, target: Target)?
    private var dragTop: CGFloat = 0  // the box's top, held still while a drag is on
    private var geometry = (pinnedTop: CGFloat(0), separatorY: CGFloat(0), hideTop: CGFloat(0))
    private var restTimer: Timer?
    private var letters: [String: String] = [:]  // each shown app's letters, where the letters are on
    private var typedLetters = ""                // typed so far, of the letters
    private var typedText = ""                   // the same keys as typed — the search's text, if it comes to that
    private var letterTimer: Timer?
    private var renaming: String?                // the app whose name is in the rename field
    /// CleanSwitcher itself, chosen: its settings.
    var onOpenSettings: (() -> Void)?
    private var activationObserver: NSObjectProtocol?  // the app opening: in front — the panel goes
    private var opening = false                  // an app is on its way to the front: keys till then are dropped
    private var clickMonitor: Any?  // a click in another app — off the box — closes it
    private var anchor: CGPoint?    // the cursor at open, where "near the cursor" is on
    private var centerX: CGFloat = 0
    private var restTop: CGFloat = 0  // the box's top before typing: the search keeps it
    private var dragCenterX: CGFloat = 0

    private let canvas = CanvasView()
    private let box = NSView()                  // the shadow; its glass inside, clipped to the shape
    private let glass = NSVisualEffectView()
    private let separator = CALayer()
    private let hideArea = CAShapeLayer()
    private let hideLabel = CATextLayer()
    private let renameField = NSTextField()
    private let searchField = NSTextField()
    private let results = SearchList()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none  // shows at once

        // - The canvas: the whole screen, clear — clicks off the box pass through; they close it (clickMonitor)

        canvas.autoresizingMask = [.width, .height]
        canvas.wantsLayer = true
        canvas.onClick = { [weak self] in self?.dismiss() }
        canvas.onType = { [weak self] text, keyCode in self?.typed(text, keyCode) }
        canvas.onEscape = { [weak self] in guard let self = self else { return }; if self.typedLetters.isEmpty { self.dismiss() } else { self.typedLetters = ""; self.typedText = ""; self.layout(animated: false) } }
        canvas.onDelete = { [weak self] in guard let self = self, !self.typedLetters.isEmpty else { return }; self.letterTimer?.invalidate(); self.typedLetters.removeLast(); self.typedText = String(self.typedText.dropLast()); self.layout(animated: false) }

        // -- The box: Cmd+Tab's glass, a soft shadow

        box.wantsLayer = true
        box.layer?.shadowColor = NSColor.black.cgColor
        box.layer?.shadowOpacity = 0.55
        box.layer?.shadowRadius = 30
        box.layer?.shadowOffset = CGSize(width: 0, height: -12)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        glass.autoresizingMask = [.width, .height]
        box.addSubview(glass)
        canvas.addSubview(box)

        // -- The line, the hide area, the rename field

        separator.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        hideArea.fillColor = NSColor.white.withAlphaComponent(0.04).cgColor
        hideArea.strokeColor = NSColor.white.withAlphaComponent(0.25).cgColor
        hideArea.lineDashPattern = [5, 4]
        hideArea.isHidden = true
        hideLabel.string = "Drop here to hide from recent"
        hideLabel.fontSize = 12
        hideLabel.alignmentMode = .center
        hideLabel.foregroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        hideLabel.contentsScale = 2
        hideArea.addSublayer(hideLabel)
        for sublayer in [separator, hideArea] { canvas.layer?.addSublayer(sublayer) }
        renameField.font = .systemFont(ofSize: 12, weight: .medium)
        renameField.alignment = .center
        renameField.bezelStyle = .roundedBezel
        renameField.delegate = self
        renameField.isHidden = true

        // -- The search: in the box, unseen until something is typed — the canvas takes the keys till then

        searchField.font = .systemFont(ofSize: 17)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.textColor = .white
        searchField.delegate = self
        results.onOpen = { [weak self] id in self?.openApp(id) }
        results.onPin = { [weak self] id in self?.togglePin(id) }
        for view in [searchField, results, renameField] as [NSView] { canvas.addSubview(view) }

        let content = NSView()
        content.addSubview(canvas)
        contentView = content
        DispatchQueue.global(qos: .utility).async { self.scanInstalled() }
    }

    override var canBecomeKey: Bool { !previewing }

    // - Open, close — as little work as possible before it shows

    func toggle() { isOpen && !previewing ? dismiss() : open() }

    func open() {
        guard !isOpen || previewing else { return }
        previewing = false
        isOpen = true
        ignoresMouseEvents = false
        prepare()
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.dismiss() }
        }

        // - The cursor to the pinned apps (opt-out in Preferences) — unless the box came to it

        if Preferences.moveCursorOnOpen, anchor == nil {
            let point = convertPoint(toScreen: canvas.convert(CGPoint(x: centerX, y: geometry.pinnedTop + pinnedHeight / 2), to: nil))
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y))  // Quartz: top-left origin
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        // - Show, take the keyboard — a non-activating panel, the app in front stays in front.
        //   The canvas, not the field: a field focused brings up the system's text-input UI, slow

        makeKeyAndOrderFront(nil)
        makeFirstResponder(canvas)
        DispatchQueue.main.async { self.store.save() }
    }

    /// A sample for Preferences: shown, not key, redrawn with the current settings.
    func preview() {
        if !isOpen {
            previewing = true
            isOpen = true
            ignoresMouseEvents = true  // a sample: the clicks go on to Preferences
            prepare()
            orderFront(nil)
        } else {
            layout(animated: false)
        }
    }

    func endPreview() { if previewing { dismiss() } }

    func dismiss() {
        guard isOpen else { return }
        isOpen = false
        previewing = false
        drag = nil
        restTimer?.invalidate()
        letterTimer?.invalidate()
        renaming = nil
        renameField.isHidden = true
        activationObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        activationObserver = nil
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        clickMonitor = nil
        orderOut(nil)
        store.save()
        DispatchQueue.global(qos: .utility).async { self.scanInstalled() }  // fresh for the next search
    }

    /// Over the screen under the mouse; the apps read; laid out.
    private func prepare() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        if frame != screen.frame { setFrame(screen.frame, display: false) }
        canvas.frame = NSRect(origin: .zero, size: screen.frame.size)
        anchor = Preferences.appsNearCursor && !previewing ? canvas.convert(convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) : nil
        searchField.stringValue = ""
        typedLetters = ""
        typedText = ""
        letterTimer?.invalidate()
        opening = false
        results.show([])
        running = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app != NSRunningApplication.current {
            if let id = app.bundleIdentifier { running[id] = app }
        }
        lastUsed = AppListProvider.lastFocusTimes()
        let now = Date().timeIntervalSince1970
        store.update(recent: lastUsed.filter { id, time in now - time <= Preferences.mainRowTTL && (!Preferences.appsRecentRunningOnly || running[id] != nil) && id != Bundle.main.bundleIdentifier && url(id) != nil })
        layout(animated: false)
    }

    // - Apps

    private func scanInstalled() {
        let directories = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var found: [String: URL] = [:]
        for directory in directories {
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "app" {
                if let id = Bundle(url: url)?.bundleIdentifier, found[id] == nil { found[id] = url }
            }
        }
        DispatchQueue.main.async { self.installed = found }
    }

    private func url(_ id: String) -> URL? { running[id]?.bundleURL ?? installed[id] ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    /// The user's name for it, else its own.
    private func name(_ id: String) -> String {
        let name = id == renaming ? renameField.stringValue.trimmingCharacters(in: .whitespaces) : store.names[id]
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? ownName(id)
    }

    private func ownName(_ id: String) -> String {
        running[id]?.localizedName ?? url(id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }

    private func icon(_ id: String) -> NSImage {
        if let cached = icons[id] { return cached }
        let image = running[id]?.icon ?? url(id).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(named: NSImage.applicationIconName)!
        icons[id] = image
        return image
    }

    /// Activate it; reopen it — running, windowless: it makes a window, as from the Dock; or launch it.
    /// The panel goes once the app is in front — hiding it first would flash the app behind for a moment.
    private func openApp(_ id: String) {
        guard !previewing else { return }
        opening = true
        letterTimer?.invalidate()
        if id == Bundle.main.bundleIdentifier {
            dismiss()
            return onOpenSettings?() ?? ()
        }
        if let app = running[id], !WindowListProvider.windows(for: app).isEmpty {
            app.unhide()
            if app.isActive { return dismiss() }  // in front already: no activation comes
            app.activate(options: [.activateIgnoringOtherApps])
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.dismiss()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in if self?.opening == true { self?.dismiss() } }  // in case it never comes — this opening's, not a later one's
        } else if let url = url(id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { self.dismiss() }
            }
        }
    }

    /// From the search: pinned — at the end of the last row, a new row once it's full; unpinned — to recent.
    private func togglePin(_ id: String) {
        if store.isPinned(id) { store.unpin(id) }
        else { let last = store.rows.last?.count ?? Self.columns; store.pin(id, row: last >= Self.columns ? store.rows.count : store.rows.count - 1, index: last, newRow: last >= Self.columns) }
        store.save()
        layout(animated: true)
        search()
    }

    // - Layout: the box on the screen's center — the pinned rows, the line, the recent slots

    /// The pinned rows without the dragged one; empty rows gone.
    private var pinnedRows: [[String]] { store.rows.map { $0.filter { $0 != drag?.id } }.filter { !$0.isEmpty } }

    private var pinnedHeight: CGFloat { CGFloat(max(1, displayedRows.count)) * pinnedStep - gap }

    /// The rows as drawn: the dragged one's drop gap (nil) in, a new row where it would make one.
    private var displayedRows: [[String?]] {
        var rows: [[String?]] = pinnedRows
        if let drag = drag, case let .pinned(row, index, newRow) = drag.target {
            if newRow { rows.insert([nil], at: min(row, rows.count)) } else if rows.indices.contains(row) { rows[row].insert(nil, at: min(index, rows[row].count)) }
        }
        return rows
    }

    /// The box's corner: around the cursor where "near the cursor" is on — kept on the screen —
    /// else centered, its middle at Preferences' position down the screen.
    private func origin(for size: CGSize) -> CGPoint {
        let bounds = canvas.bounds
        guard let anchor = anchor else {
            return CGPoint(x: bounds.midX - size.width / 2, y: max(40, bounds.height * CGFloat(Preferences.appsPosition) / 100 - size.height / 2))
        }
        return CGPoint(x: min(max(16, anchor.x - size.width / 2), bounds.width - size.width - 16),
                       y: min(max(40, anchor.y - size.height / 2), bounds.height - size.height - 16))
    }

    private func width(_ count: Int, _ size: CGFloat) -> CGFloat { CGFloat(max(count, 1)) * (size + gap) - gap }

    private func layout(animated: Bool) {
        let searching = !query.isEmpty && !previewing
        var placed: [(String, CGPoint, CGFloat)] = []
        var boxFrame: CGRect

        if searching {
            // -- Typing: the box holds the field and the list

            let listHeight = results.isHidden ? 0 : results.fittingSize.height
            boxFrame = CGRect(x: 0, y: 0, width: Self.searchWidth, height: pad + 26 + (listHeight > 0 ? 8 + listHeight : 0) + pad)
            boxFrame.origin = CGPoint(x: min(max(16, centerX - boxFrame.width / 2), canvas.bounds.width - boxFrame.width - 16), y: min(restTop, canvas.bounds.height - boxFrame.height - 16))
            searchField.frame = CGRect(x: boxFrame.minX + pad + 4, y: boxFrame.minY + pad, width: boxFrame.width - 2 * pad - 8, height: 24)
            results.frame = CGRect(x: boxFrame.minX + pad / 2, y: boxFrame.minY + pad + 34, width: boxFrame.width - pad, height: listHeight)
            box.layer?.cornerRadius = 18
            glass.layer?.cornerRadius = 18
        } else {
            // -- Sizes, then the box around them, on the center

            let rows = displayedRows
            let slotCount = (store.slots.values.max() ?? -1) + 1
            let recentColumns = min(Self.columns, max(slotCount, 1))
            let recentRows = (slotCount + Self.columns - 1) / Self.columns
            let recentHeight = recentRows > 0 ? CGFloat(recentRows) * recentStep - gap : 0
            let contentWidth = max(rows.map { width($0.count, pinnedSize) }.max() ?? 0, slotCount > 0 ? width(recentColumns, recentSize) : 0, pinnedSize)
            let contentHeight = pinnedHeight + (recentRows > 0 ? between + recentHeight : 0)
            let pill = Preferences.appsShape == "pill"
            let side = pill ? (contentHeight + 2 * pad) * 0.28 : 0  // room for the round ends
            boxFrame = CGRect(x: 0, y: 0, width: contentWidth + 2 * pad + 2 * side, height: contentHeight + 2 * pad)
            boxFrame.origin = drag == nil ? origin(for: boxFrame.size) : CGPoint(x: dragCenterX - boxFrame.width / 2, y: dragTop)
            centerX = boxFrame.midX
            if drag == nil { restTop = boxFrame.minY }
            let radius = pill ? boxFrame.height / 2 : 22
            box.layer?.cornerRadius = radius
            glass.layer?.cornerRadius = radius

            let top = boxFrame.minY + pad, separatorY = top + pinnedHeight + between / 2
            geometry = (top, separatorY, boxFrame.maxY + 16)
            for (r, row) in rows.enumerated() {
                let x0 = centerX - width(row.count, pinnedSize) / 2
                for (k, id) in row.enumerated() { if let id = id { placed.append((id, CGPoint(x: x0 + CGFloat(k) * pinnedStep + pinnedSize / 2, y: top + CGFloat(r) * pinnedStep + pinnedSize / 2), pinnedSize)) } }
            }
            let recentTop = top + pinnedHeight + between, recentX0 = centerX - width(recentColumns, recentSize) / 2
            for (id, slot) in store.slots where id != drag?.id {
                placed.append((id, CGPoint(x: recentX0 + CGFloat(slot % Self.columns) * recentStep + recentSize / 2, y: recentTop + CGFloat(slot / Self.columns) * recentStep + recentSize / 2), recentSize))
            }
            searchField.frame = CGRect(x: boxFrame.minX + pad, y: boxFrame.minY + 2, width: 10, height: 20)  // unseen
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            separator.isHidden = !Preferences.appsSeparator || recentRows == 0
            separator.frame = CGRect(x: centerX - contentWidth / 2, y: separatorY, width: contentWidth, height: 1)
            CATransaction.commit()
        }
        searchField.alphaValue = searching ? 1 : 0
        results.isHidden = !searching || results.isEmpty
        box.frame = boxFrame

        // - The letters, where they're on: the pinned's among themselves; the recent's too — none a pinned one's start

        letters = [:]
        if Preferences.appsLetters != .off && !searching {
            letters = makeLetters(placed.map(\.0).filter(store.isPinned))
            if Preferences.appsLettersRecent { letters.merge(makeLetters(placed.map(\.0).filter { !store.isPinned($0) }, avoiding: Array(letters.values))) { pinned, _ in pinned } }
        }

        // - The icons

        let shown = Set(placed.map(\.0)).union([drag?.id].compactMap { $0 })
        for (id, view) in views where !shown.contains(id) { view.isHidden = true }
        for (id, point, size) in placed {
            let view = views[id] ?? {
                let view = AppIconView(id: id, icon: icon(id))
                view.delegate = self
                canvas.addSubview(view, positioned: .below, relativeTo: renameField)
                views[id] = view
                return view
            }()
            view.isHidden = searching
            view.place(center: point, size: size, animated: animated && view.frame.width == size)
            view.recent = !store.isPinned(id)
            let tag = letters[id], match = typedLetters.isEmpty || tag?.hasPrefix(typedLetters) == true
            view.showLetters(tag, typed: match ? typedLetters.count : 0)
            view.alphaValue = match ? 1 : CGFloat(Preferences.appsUnmatchedOpacity) / 100
        }

        // - The line blue while a drag crosses it; the hide area under the box while a drag is on

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let crossing = drag.map { $0.fromPinned != ($0.target != .recent && $0.target != .hide) } ?? false
        separator.backgroundColor = (crossing ? NSColor.systemBlue : NSColor.white.withAlphaComponent(0.15)).cgColor
        if searching { separator.isHidden = true }
        let hideFrame = CGRect(x: boxFrame.minX, y: geometry.hideTop, width: boxFrame.width, height: 50)
        hideArea.isHidden = drag == nil
        hideArea.frame = hideFrame
        hideArea.path = CGPath(roundedRect: CGRect(origin: .zero, size: hideFrame.size), cornerWidth: 14, cornerHeight: 14, transform: nil)
        hideArea.strokeColor = (drag?.target == .hide ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.25)).cgColor
        hideLabel.frame = CGRect(x: 0, y: 17, width: hideFrame.width, height: 18)
        CATransaction.commit()
    }

    // - AppIconViewDelegate: click opens; drag — across the line pins or unpins, among the pinned
    //   moves (a new row above, between or below), onto the hide area hides

    func appClicked(_ id: String) { openApp(id) }

    func appDragged(_ id: String, to center: CGPoint) {
        guard !previewing else { return }
        restTimer?.invalidate()
        let fromPinned = drag?.fromPinned ?? store.isPinned(id)
        if drag == nil {
            dragTop = box.frame.minY
            dragCenterX = box.frame.midX
            drag = (id, fromPinned, fromPinned ? .pinned(row: 0, index: 0, newRow: false) : .recent)
        }

        // - Decided on the rows as they stood when the drag began, so nothing shifts under the cursor

        let rows = pinnedRows, top = dragTop + pad, pinnedEnd = top + CGFloat(rows.count) * pinnedStep - gap / 2
        let target: Target
        if center.y > geometry.hideTop - 10 { target = .hide }
        else if center.y > pinnedEnd + min(pinnedSize, between + recentSize / 2) { target = .recent }
        else if rows.isEmpty || center.y < top - gap / 2 { target = .pinned(row: 0, index: 0, newRow: true) }
        else if center.y >= pinnedEnd { target = .pinned(row: rows.count, index: 0, newRow: true) }
        else {
            let r = min(rows.count - 1, Int(((center.y - top + gap / 2) / pinnedStep).rounded(.down)))
            let x0 = centerX - width(rows[r].count + 1, pinnedSize) / 2
            target = .pinned(row: r, index: max(0, min(rows[r].count, Int(((center.x - x0) / pinnedStep).rounded(.down)))), newRow: false)
        }
        drag = (id, fromPinned, target)
        layout(animated: true)
        if let view = views[id] {
            let size = target == .recent || target == .hide ? recentSize : pinnedSize
            view.place(center: center, size: size, animated: false)
            canvas.addSubview(view, positioned: .below, relativeTo: renameField)
        }
    }

    func appDragEnded(_ id: String) {
        guard let drag = drag else { return }
        switch drag.target {
        case let .pinned(row, index, newRow): store.pin(id, row: row, index: index, newRow: newRow)
        case .recent: if drag.fromPinned { store.unpin(id) }
        case .hide: store.hide(id)
        }
        self.drag = nil
        store.save()
        layout(animated: true)
    }

    /// Still on it for Preferences' delay — it opens (opt-out in Preferences). Only after a move:
    /// the cursor warped onto an icon at open opens nothing.
    func appCursorMoved(_ id: String) {
        restTimer?.invalidate()
        guard Preferences.appsOpenOnRest, drag == nil, renaming == nil, !previewing, query.isEmpty else { return }
        restTimer = Timer.scheduledTimer(withTimeInterval: Double(Preferences.appsRestDelay) / 1000, repeats: false) { [weak self] _ in
            guard let self = self, self.isOpen, self.drag == nil, self.query.isEmpty, NSEvent.pressedMouseButtons == 0 else { return }
            self.openApp(id)
        }
    }

    func appHovered(_ id: String, _ inside: Bool) { restTimer?.invalidate() }

    /// A menu: its own name, Rename…, Reset name.
    func appRightClicked(_ id: String) {
        guard drag == nil, !previewing else { return }
        restTimer?.invalidate()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: ownName(id), action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        for (title, action, enabled) in [("Rename…", #selector(rename(_:)), true), ("Reset name", #selector(resetName(_:)), store.names[id] != nil)] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.isEnabled = enabled
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // - Rename: the name in a field under the icon, the letters redrawn as it's typed; ⏎ saves, esc cancels, empty — its own

    @objc private func rename(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let view = views[id] else { return }
        renameField.stringValue = name(id)
        renaming = id
        renameField.frame = CGRect(x: view.frame.midX - 80, y: view.frame.maxY + 8, width: 160, height: 22)
        renameField.isHidden = false
        makeFirstResponder(renameField)
    }

    @objc private func resetName(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        store.names[id] = nil
        store.save()
        layout(animated: false)
    }

    private func endRename(save: Bool) {
        guard let id = renaming else { return }
        if save { store.names[id] = name(id) == ownName(id) ? nil : name(id); store.save() }
        renaming = nil
        renameField.isHidden = true
        makeFirstResponder(canvas)
        layout(animated: false)
    }

    // - Search: fuzzy, a dropdown list under the field; ↑↓ move, ↩ opens, esc clears then closes

    private var query: String { searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased() }

    /// The query's letters in order in the name: a word start and a run score more, a skip less.
    private func fuzzyScore(_ name: String) -> Int? {
        let text = Array(name.lowercased()), letters = Array(query.filter { $0 != " " })
        var score = 0, at = 0, previous = -2
        for letter in letters {
            guard let found = text[at...].firstIndex(of: letter) else { return nil }
            let wordStart = found == 0 || !text[found - 1].isLetter
            score += (wordStart ? 10 : 1) + (found == previous + 1 ? 5 : 0) - min(found - at, 5)
            previous = found
            at = found + 1
        }
        return score
    }

    /// A key on the canvas. Letters off — the search. Letters on — narrows to the apps whose
    /// letters start so; an app's letters complete — it opens: at once where the letters are
    /// all there is, after a pause where a key more goes on into the search.
    private func typed(_ text: String, _ keyCode: UInt16) {
        let mode = Preferences.appsLetters
        guard !opening else { return }
        guard mode != .off else { return startTyping(text) }
        letterTimer?.invalidate()
        let next = typedLetters + (Self.latinKeys[keyCode].map(String.init) ?? "")
        let matching = letters.filter { $0.value.hasPrefix(next) }
        guard next.count > typedLetters.count, !matching.isEmpty else {
            if mode == .pause { startTyping(typedText + text) }
            return
        }
        typedLetters = next
        typedText += text
        layout(animated: false)
        guard let (id, _) = matching.first(where: { $0.value == next }) else { return }
        if mode == .instant, matching.count == 1 { return openApp(id) }
        letterTimer = Timer.scheduledTimer(withTimeInterval: Double(Preferences.appsLettersPause) / 1000, repeats: false) { [weak self] _ in self?.openApp(id) }
    }

    /// A letter key's letter by its place on the keyboard — the same in any layout.
    private static let latinKeys: [UInt16: Character] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]

    /// Each app's shortest start of its name — the vendor dropped, A–Z and 0–9 only — no other app's starts with,
    /// nor any of `avoiding`: `S` Safari pinned, `SL` Slack.
    private func makeLetters(_ ids: [String], avoiding: [String] = []) -> [String: String] {
        let keys = Dictionary(uniqueKeysWithValues: ids.map { id -> (String, String) in
            let name = name(id).replacingOccurrences(of: #"^(Microsoft|Google|Adobe|Apple|JetBrains)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            return (id, String(name.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }))
        }).filter { !$0.value.isEmpty }
        return keys.mapValues { key in
            var n = 1
            while n < key.count, keys.values.filter({ $0.hasPrefix(key.prefix(n)) }).count > 1 || avoiding.contains(where: { $0.hasPrefix(key.prefix(n)) }) { n += 1 }
            return String(key.prefix(n))
        }
    }

    /// The first key typed: into the field, the field takes the keys from here.
    private func startTyping(_ text: String) {
        letterTimer?.invalidate()
        typedLetters = ""
        typedText = ""
        searchField.stringValue = text
        makeFirstResponder(searchField)
        searchField.currentEditor()?.selectedRange = NSRange(location: text.utf16.count, length: 0)
        search()
    }

    private func search() {
        guard !query.isEmpty else {
            // - Cleared: back to as just opened — the canvas takes the keys, the letters from the start

            searchField.stringValue = ""
            makeFirstResponder(canvas)
            typedLetters = ""
            typedText = ""
            results.show([])
            return layout(animated: false)
        }
        let now = Date().timeIntervalSince1970
        let candidates = Set(installed.keys).union(running.keys).union(store.rows.flatMap { $0 })
        let hits = candidates.compactMap { id -> (id: String, name: String, score: Int)? in
            let name = name(id)
            return [name, ownName(id)].compactMap(fuzzyScore).max().map { (id, name, $0) }
        }.sorted {
            (-$0.score, store.isPinned($0.id) ? 0 : 1, -(lastUsed[$0.id] ?? 0), $0.name) < (-$1.score, store.isPinned($1.id) ? 0 : 1, -(lastUsed[$1.id] ?? 0), $1.name)
        }.prefix(8)
        results.show(hits.map { hit in
            let pinned = store.isPinned(hit.id), minutes = lastUsed[hit.id].map { Int((now - $0) / 60) }
            let tag = pinned ? "Pinned" : store.hidden.contains(hit.id) ? "Hidden" : minutes.map { $0 * 60 <= Int(Preferences.mainRowTTL) ? "\($0) min ago" : "" } ?? ""
            return SearchList.Row(id: hit.id, name: hit.name, icon: icon(hit.id), tag: tag, pinned: pinned)
        })
        layout(animated: false)
    }

    func controlTextDidChange(_ notification: Notification) { notification.object as? NSTextField === renameField ? layout(animated: false) : search() }

    func controlTextDidEndEditing(_ notification: Notification) { if notification.object as? NSTextField === renameField { endRename(save: true) } }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === renameField {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): endRename(save: true); return true
            case #selector(NSResponder.cancelOperation(_:)): endRename(save: false); return true
            default: return false
            }
        }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): results.move(1); return true
        case #selector(NSResponder.moveUp(_:)): results.move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if let id = results.selected { openApp(id) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if query.isEmpty { dismiss() } else { searchField.stringValue = ""; search() }
            return true
        default:
            return false
        }
    }
}

/// The canvas: flipped, so positions read top-down; a click on the empty canvas closes.
/// The keys till something is typed: a letter starts the search, Esc closes.
private final class CanvasView: NSView {
    var onClick: (() -> Void)?
    var onType: ((String, UInt16) -> Void)?
    var onEscape: (() -> Void)?
    var onDelete: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return onEscape?() ?? () }
        if event.keyCode == 51 { return onDelete?() ?? () }
        guard event.modifierFlags.intersection([.command, .control]).isEmpty, let text = event.characters,
              let scalar = text.unicodeScalars.first, !CharacterSet.controlCharacters.union(.whitespaces).contains(scalar), scalar.value < 0xF700 else { return }
        onType?(text, event.keyCode)
    }
}

/// The search's dropdown: a row per app — icon, name, when used or «Pinned», a pin.
private final class SearchList: NSView {
    struct Row { let id: String; let name: String; let icon: NSImage; let tag: String; let pinned: Bool }

    var onOpen: ((String) -> Void)?
    var onPin: ((String) -> Void)?
    private var rows: [Row] = []
    private var index = 0
    private let stack = NSStackView()

    var selected: String? { rows.indices.contains(index) ? rows[index].id : nil }
    var isEmpty: Bool { rows.isEmpty }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ rows: [Row]) {
        self.rows = rows
        index = min(index, max(0, rows.count - 1))
        if rows.isEmpty { index = 0 }
        isHidden = rows.isEmpty
        render()
    }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        index = max(0, min(rows.count - 1, index + delta))
        render()
    }

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (k, row) in rows.enumerated() {
            let view = SearchRowView(row: row, selected: k == index)
            view.onOpen = { [weak self] in self?.onOpen?(row.id) }
            view.onPin = { [weak self] in self?.onPin?(row.id) }
            view.onHover = { [weak self] in if self?.index != k { self?.index = k; self?.render() } }
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10).isActive = true
        }
    }
}

private final class SearchRowView: NSView {
    var onOpen: (() -> Void)?
    var onPin: (() -> Void)?
    var onHover: (() -> Void)?

    init(row: SearchList.Row, selected: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : nil
        heightAnchor.constraint(equalToConstant: 38).isActive = true

        let image = NSImageView(image: row.icon)
        image.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: row.name)
        name.font = .systemFont(ofSize: 13.5)
        name.lineBreakMode = .byTruncatingTail
        let tag = NSTextField(labelWithString: row.tag)
        tag.font = .systemFont(ofSize: 11)
        tag.textColor = selected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        let pin = NSButton(image: NSImage(systemSymbolName: row.pinned ? "pin.fill" : "pin", accessibilityDescription: row.pinned ? "Unpin" : "Pin")!, target: self, action: #selector(pinTapped))
        pin.isBordered = false
        pin.contentTintColor = row.pinned || selected ? .white : .secondaryLabelColor
        let line = NSStackView(views: [image, name, NSView(), tag, pin])
        line.spacing = 10
        line.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 26), image.heightAnchor.constraint(equalToConstant: 26),
            pin.widthAnchor.constraint(equalToConstant: 26),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onOpen?() }
    @objc private func pinTapped() { onPin?() }
}
