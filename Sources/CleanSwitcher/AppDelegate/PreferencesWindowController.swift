import Cocoa
import Carbon

/// A small, programmatic Preferences window — toolbar tabs: General, Switchers, Apps, Look.
/// One instance is held by AppDelegate and reused on every show.
class PreferencesWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {

    /// Called with the new value when "Show icon in menu bar" changes.
    var onToggleMenuBar: ((Bool) -> Void)?
    /// Called when a switcher's mode or shortcut changes.
    var onChangeHotkeys: (() -> Void)?
    /// Called with true when a shortcut recorder starts listening, false when it stops.
    var onRecordingShortcut: ((Bool) -> Void)?

    private var launchAtLoginCheckbox: NSButton!
    private var menuBarCheckbox: NSButton!
    private var appSwitcherModePopup: NSPopUpButton!
    private var windowSwitcherModePopup: NSPopUpButton!
    private var appShortcutButton: NSButton!
    private var windowShortcutButton: NSButton!
    private var appsShortcutButton: NSButton!
    private var appsPopup: NSPopUpButton!
    private var appGesturePopup: NSPopUpButton!
    private var windowGesturePopup: NSPopUpButton!
    private var appsGesturePopup: NSPopUpButton!
    private var pendingTap: Int?  // the Apps recorder: a lone modifier down, its key code
    private var moveCursorCheckbox: NSButton!
    private var openOnRestCheckbox: NSButton!
    private var recentRunningOnlyCheckbox: NSButton!
    private let restDelaySlider = NSSlider(value: 200, minValue: 10, maxValue: 1000, target: nil, action: nil)
    private let restDelayValue = NSTextField(labelWithString: "")
    private let lettersPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let lettersRecentCheckbox = NSButton(checkboxWithTitle: "Recent too", target: nil, action: nil)
    private let lettersPauseSlider = NSSlider(value: 400, minValue: 10, maxValue: 1500, target: nil, action: nil)
    private let lettersPauseValue = NSTextField(labelWithString: "")
    private var shapePopup: NSPopUpButton!
    private let hoverPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var separatorCheckbox: NSButton!
    private var nearCursorCheckbox: NSButton!
    /// Called on a change to the Apps panel's look — it shows a sample.
    var onChangeAppsLook: (() -> Void)?
    /// Called when the Apps panel's sample should go: the window closed or left, or Esc.
    var onEndSample: (() -> Void)?
    private var escMonitor: Any?
    private var recordingButton: NSButton?
    private var keyMonitor: Any?
    private var raiseAllWindowsCheckbox: NSButton!
    private var maximizeNewWindowsCheckbox: NSButton!
    private var hideOtherAppsCheckbox: NSButton!
    private var ttlField: NSTextField!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "CleanSwitcher Preferences"
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false  // keep the single instance across closes

        self.init(window: window)
        window.delegate = self
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, event.window === self?.window, self?.recordingButton == nil { self?.onEndSample?() }
            return event
        }
        setupContent()
        window.center()
    }

    private func setupContent() {
        // - Controls

        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Start at login", target: self, action: #selector(toggleLaunchAtLogin))
        launchAtLoginCheckbox.isHidden = !LoginItem.isSupported  // collapsed on macOS < 13

        menuBarCheckbox = NSButton(checkboxWithTitle: "Show icon in menu bar", target: self, action: #selector(toggleMenuBar))

        appSwitcherModePopup = makeModePopup()
        windowSwitcherModePopup = makeModePopup()
        appGesturePopup = makeGesturePopup()
        windowGesturePopup = makeGesturePopup()
        appsGesturePopup = makeGesturePopup()
        appShortcutButton = makeShortcutButton()
        windowShortcutButton = makeShortcutButton()
        appsShortcutButton = makeShortcutButton()
        appsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        appsPopup.addItems(withTitles: ["On", "Off"])
        appsPopup.target = self
        appsPopup.action = #selector(changeHotkeyMode)
        moveCursorCheckbox = NSButton(checkboxWithTitle: "Move the cursor to the center", target: self, action: #selector(toggleMoveCursor))
        nearCursorCheckbox = NSButton(checkboxWithTitle: "Open near the cursor", target: self, action: #selector(changeLook))
        recentRunningOnlyCheckbox = NSButton(checkboxWithTitle: "Remove a quit app from recent at once", target: self, action: #selector(toggleRecentRunningOnly))
        openOnRestCheckbox = NSButton(checkboxWithTitle: "The cursor stopped on an icon opens it", target: self, action: #selector(toggleOpenOnRest))
        raiseAllWindowsCheckbox = NSButton(checkboxWithTitle: "Bring all windows forward", target: self, action: #selector(toggleRaiseAllWindows))
        maximizeNewWindowsCheckbox = NSButton(checkboxWithTitle: "Open new windows maximized", target: self, action: #selector(toggleMaximizeNewWindows))
        hideOtherAppsCheckbox = NSButton(checkboxWithTitle: "Hide other apps", target: self, action: #selector(toggleHideOtherApps))

        let quitButton = NSButton(title: "Quit CleanSwitcher", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded

        let versionLabel = NSTextField(labelWithString: versionString())
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor

        // - The tabs, each a column of its rows

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let panes: [(String, String, [NSView])] = [
            ("General", "gearshape", [launchAtLoginCheckbox, menuBarCheckbox, makeTTLRow(), separator(),
                                      section("When switching apps"), raiseAllWindowsCheckbox, hideOtherAppsCheckbox, maximizeNewWindowsCheckbox, separator(),
                                      quitButton, versionLabel]),
            ("Switchers", "keyboard", [makeSwitchersGrid()]),
            ("Apps", "capsule", [section("On open"), moveCursorCheckbox, nearCursorCheckbox, separator(),
                                 section("Recent"), recentRunningOnlyCheckbox, separator(),
                                 section("Hover"), makeRestRow(), separator(),
                                 section("Letters"), makeLettersRow()]),
            ("Look", "slider.horizontal.3", makeLookRows()),
        ]
        for (title, symbol, rows) in panes {
            let item = NSTabViewItem(viewController: pane(title, rows))
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        window?.contentViewController = tabs
    }

    /// A pane: its rows top to bottom, 20pt margins, sized to fit — the window takes each pane's size.
    private func pane(_ title: String, _ rows: [NSView]) -> NSViewController {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows where row is NSBox { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let controller = NSViewController()
        controller.title = title
        controller.view = NSView()
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 20),
        ])
        controller.preferredContentSize = NSSize(width: Self.width, height: stack.fittingSize.height + 40)
        return controller
    }

    private static let width: CGFloat = 520

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func section(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// "            Shortcut     Mode          Gesture
    ///  App switcher [ ⌘ Tab ]  [ Normal ▾ ]  [ No gesture ▾ ]"
    private func makeSwitchersGrid() -> NSView {
        let header = ["", "Shortcut", "Mode", "Gesture"].map { title -> NSView in
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            return label
        }
        let grid = NSGridView(views: [header,
            [NSTextField(labelWithString: "App switcher"), appShortcutButton, appSwitcherModePopup, appGesturePopup],
            [NSTextField(labelWithString: "Window switcher"), windowShortcutButton, windowSwitcherModePopup, windowGesturePopup],
            [NSTextField(labelWithString: "Apps"), appsShortcutButton, appsPopup, appsGesturePopup],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        for popup in [appSwitcherModePopup, windowSwitcherModePopup, appsPopup] { popup!.widthAnchor.constraint(equalToConstant: 120).isActive = true }
        return grid
    }

    /// "Recent: used within [ 1h30m ]" — accepts a free-form duration (`10m`,
    /// `1h30m`); commits on Return / focus loss.
    private func makeTTLRow() -> NSView {
        let label = NSTextField(labelWithString: "Recent: used within")
        ttlField = NSTextField(string: "")
        ttlField.placeholderString = "1h30m"
        ttlField.alignment = .center
        ttlField.delegate = self
        ttlField.target = self
        ttlField.action = #selector(commitTTL)
        ttlField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let row = NSStackView(views: [label, ttlField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    /// Popup items follow `HotkeyMode.allCases` order.
    private func makeModePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["Normal", "Recent only", "Disabled"])
        popup.target = self
        popup.action = #selector(changeHotkeyMode)
        return popup
    }

    private func makeShortcutButton() -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(startRecording(_:)))
        button.bezelStyle = .rounded
        button.widthAnchor.constraint(equalToConstant: 110).isActive = true
        return button
    }

    /// Gesture popup items: none, then 3 and 4 fingers — ↔ ← → ↕ ↑ ↓.
    private func makeGesturePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: "No gesture")
        for gesture in Gesture.all { popup.addItem(withTitle: gesture.title) }
        popup.target = self
        popup.action = #selector(changeGesture(_:))
        return popup
    }

    private func gesture(_ popup: NSPopUpButton) -> Gesture? { popup.indexOfSelectedItem > 0 ? Gesture.all[popup.indexOfSelectedItem - 1] : nil }

    private func select(_ gesture: Gesture?, in popup: NSPopUpButton) { popup.selectItem(at: gesture.flatMap { Gesture.all.firstIndex(of: $0) }.map { $0 + 1 } ?? 0) }

    /// A gesture another command shares a swipe with: that one steps back to none.
    @objc private func changeGesture(_ sender: NSPopUpButton) {
        if let chosen = gesture(sender) {
            for other in [appGesturePopup, windowGesturePopup, appsGesturePopup] where other !== sender {
                if let theirs = gesture(other!), theirs.overlaps(chosen) { other!.selectItem(at: 0) }
            }
        }
        Preferences.appSwitcherGesture = gesture(appGesturePopup)
        Preferences.windowSwitcherGesture = gesture(windowGesturePopup)
        Preferences.appsGesture = gesture(appsGesturePopup)
    }

    /// Parse a free-form duration into minutes: unit tokens `d`/`h`/`m` in any
    /// order (`1h30m`, `2h`, `1d`) or a bare number as minutes (`45`). nil if
    /// empty / unparseable.
    private static func parseMinutes(_ text: String) -> Int? {
        let s = text.lowercased().filter { !$0.isWhitespace }
        guard !s.isEmpty else { return nil }
        if let bare = Int(s) { return bare > 0 ? bare : nil }

        var total = 0
        var digits = ""
        var matchedAnyUnit = false
        for ch in s {
            if ch.isNumber { digits.append(ch); continue }
            guard let value = Int(digits) else { return nil }  // unit with no number
            switch ch {
            case "d": total += value * 24 * 60
            case "h": total += value * 60
            case "m": total += value
            default: return nil
            }
            matchedAnyUnit = true
            digits = ""
        }
        // A trailing number with no unit is ambiguous → reject.
        guard digits.isEmpty, matchedAnyUnit, total > 0 else { return nil }
        return total
    }

    /// Minutes → canonical form: `90 → "1h30m"`, `60 → "1h"`, `45 → "45m"`, `1500 → "1d1h"`.
    private static func formatMinutes(_ minutes: Int) -> String {
        var remaining = max(1, minutes)
        let days = remaining / (24 * 60); remaining %= 24 * 60
        let hours = remaining / 60; let mins = remaining % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if mins > 0 || parts.isEmpty { parts.append("\(mins)m") }
        return parts.joined()
    }

    /// Bring the window front. Activating is required for controls to be clickable;
    /// the app stays `.accessory`, so no Dock icon appears.
    func show() {
        syncFromPreferences()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Refresh controls from the source of truth (may have changed via the menu
    /// bar, terminal, or System Settings between shows).
    private func syncFromPreferences() {
        launchAtLoginCheckbox.state = LoginItem.isEnabled ? .on : .off
        menuBarCheckbox.state = Preferences.showMenuBarIcon ? .on : .off
        ttlField.stringValue = Self.formatMinutes(Preferences.mainRowTTLMinutes)
        appSwitcherModePopup.selectItem(at: Preferences.HotkeyMode.allCases.firstIndex(of: Preferences.appSwitcherMode)!)
        windowSwitcherModePopup.selectItem(at: Preferences.HotkeyMode.allCases.firstIndex(of: Preferences.windowSwitcherMode)!)
        raiseAllWindowsCheckbox.state = Preferences.raiseAllWindows ? .on : .off
        maximizeNewWindowsCheckbox.state = Preferences.maximizeNewWindows ? .on : .off
        hideOtherAppsCheckbox.state = Preferences.hideOtherAppsOnSwitch ? .on : .off
        appsPopup.selectItem(at: Preferences.appsEnabled ? 0 : 1)
        select(Preferences.appSwitcherGesture, in: appGesturePopup)
        select(Preferences.windowSwitcherGesture, in: windowGesturePopup)
        select(Preferences.appsGesture, in: appsGesturePopup)
        moveCursorCheckbox.state = Preferences.moveCursorOnOpen ? .on : .off
        openOnRestCheckbox.state = Preferences.appsOpenOnRest ? .on : .off
        recentRunningOnlyCheckbox.state = Preferences.appsRecentRunningOnly ? .on : .off
        syncRestDelay()
        syncLetters()
        syncLook()
        syncShortcutLabels()
    }

    private func syncShortcutLabels() {
        let app = Preferences.appSwitcherShortcut, window = Preferences.windowSwitcherShortcut
        if recordingButton !== appShortcutButton { appShortcutButton.title = app.displayString() }
        if recordingButton !== windowShortcutButton { windowShortcutButton.title = window.displayString() }
        if recordingButton !== appsShortcutButton { appsShortcutButton.title = Preferences.appsShortcut.displayString() }
    }

    // - Shortcut recording
    //   Click a shortcut button, then type the combo. Esc cancels, ⌫ restores the
    //   default. It needs ⌘/⌥/⌃, no ⇧ (reserved for reverse), and must differ from
    //   the other switcher's.

    @objc private func startRecording(_ sender: NSButton) {
        stopRecording()
        recordingButton = sender
        sender.title = "Type shortcut…"
        onRecordingShortcut?(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        guard let button = recordingButton else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = Int(event.keyCode)
        let hasNoModifiers = modifiers.intersection([.command, .option, .control, .shift]).isEmpty
        let slots: [(button: NSButton, fallback: Shortcut, current: Shortcut, save: (Shortcut) -> Void)] = [
            (appShortcutButton, .defaultAppSwitcher, Preferences.appSwitcherShortcut, { Preferences.appSwitcherShortcut = $0 }),
            (windowShortcutButton, .defaultWindowSwitcher, Preferences.windowSwitcherShortcut, { Preferences.windowSwitcherShortcut = $0 }),
            (appsShortcutButton, .defaultApps, Preferences.appsShortcut, { Preferences.appsShortcut = $0 }),
        ]
        guard let slot = slots.first(where: { $0.button === button }) else { return }

        // - The Apps shortcut may be a lone ⌥ / ⌘, tapped: down alone, up with nothing between

        if event.type == .flagsChanged {
            guard button === appsShortcutButton else { return }
            let own: NSEvent.ModifierFlags = [kVK_Option, kVK_RightOption].contains(keyCode) ? .option : .command
            if Shortcut.tapKeys[keyCode] != nil, modifiers.intersection([.command, .option, .control, .shift]) == own { pendingTap = keyCode }
            else if hasNoModifiers, pendingTap == keyCode { slot.save(Shortcut(keyCode: keyCode, modifiers: [])); stopRecording() }
            else { pendingTap = nil }
            return
        }
        pendingTap = nil

        if hasNoModifiers && keyCode == kVK_Escape { stopRecording(); return }

        let shortcut = hasNoModifiers && keyCode == kVK_Delete ? slot.fallback : Shortcut(keyCode: keyCode, modifiers: modifiers)
        let others = slots.filter { $0.button !== button }.map(\.current)
        guard !shortcut.modifiers.isEmpty, !modifiers.contains(.shift), !others.contains(shortcut) else {
            NSSound.beep()
            return
        }

        slot.save(shortcut)
        stopRecording()
    }

    private func stopRecording() {
        pendingTap = nil
        guard recordingButton != nil else { return }
        if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingButton = nil
        syncShortcutLabels()
        onRecordingShortcut?(false)  // re-registers with the (possibly new) shortcuts
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
        onEndSample?()
    }

    func windowDidResignKey(_ notification: Notification) { onEndSample?() }

    private func versionString() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return version.map { "Version \($0)" } ?? ""
    }

    @objc private func toggleLaunchAtLogin() {
        if !LoginItem.setEnabled(launchAtLoginCheckbox.state == .on) {
            launchAtLoginCheckbox.state = LoginItem.isEnabled ? .on : .off  // snap back on failure
        }
    }

    @objc private func toggleMenuBar() {
        let enabled = menuBarCheckbox.state == .on
        Preferences.showMenuBarIcon = enabled
        onToggleMenuBar?(enabled)
    }

    @objc private func toggleRecentRunningOnly() { Preferences.appsRecentRunningOnly = recentRunningOnlyCheckbox.state == .on }
    @objc private func toggleMoveCursor() { Preferences.moveCursorOnOpen = moveCursorCheckbox.state == .on }
    @objc private func toggleOpenOnRest() { Preferences.appsOpenOnRest = openOnRestCheckbox.state == .on; syncRestDelay() }

    /// "[✓] The cursor stopped on an icon opens it   after ——○—— 200 ms"
    private func makeRestRow() -> NSView {
        restDelaySlider.target = self
        restDelaySlider.action = #selector(changeRestDelay)
        restDelaySlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        restDelayValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let row = NSStackView(views: [openOnRestCheckbox, NSTextField(labelWithString: "after"), restDelaySlider, restDelayValue])
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// "[Search after a pause ▾]  [ ] Pinned only
    ///  Open after a pause of ——○—— 400 ms"
    private func makeLettersRow() -> NSView {
        lettersPopup.addItems(withTitles: ["Off", "Search after a pause", "No search"])
        for control in [lettersPopup, lettersRecentCheckbox, lettersPauseSlider] as [NSControl] {
            control.target = self
            control.action = #selector(changeLetters)
        }
        lettersPauseSlider.widthAnchor.constraint(equalToConstant: 100).isActive = true
        lettersPauseValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let top = NSStackView(views: [lettersPopup, lettersRecentCheckbox])
        let bottom = NSStackView(views: [NSTextField(labelWithString: "Open after a pause of"), lettersPauseSlider, lettersPauseValue])
        for row in [top, bottom] { row.alignment = .centerY; row.spacing = 8 }
        let rows = NSStackView(views: [top, bottom])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        return rows
    }

    private func syncLetters() {
        let mode = Preferences.appsLetters
        lettersPopup.selectItem(at: Preferences.LettersMode.allCases.firstIndex(of: mode) ?? 0)
        lettersRecentCheckbox.state = Preferences.appsLettersRecent ? .on : .off
        lettersRecentCheckbox.isEnabled = mode != .off
        lettersPauseSlider.doubleValue = Double(Preferences.appsLettersPause)
        lettersPauseSlider.isEnabled = mode != .off
        lettersPauseValue.stringValue = "\(Preferences.appsLettersPause) ms"
    }

    /// Saved; the sample drawn with the letters.
    @objc private func changeLetters() {
        Preferences.appsLetters = Preferences.LettersMode.allCases[lettersPopup.indexOfSelectedItem]
        Preferences.appsLettersRecent = lettersRecentCheckbox.state == .on
        Preferences.appsLettersPause = Int((lettersPauseSlider.doubleValue / 10).rounded()) * 10
        syncLetters()
        onChangeAppsLook?()
    }

    private func syncRestDelay() {
        restDelaySlider.doubleValue = Double(Preferences.appsRestDelay)
        restDelaySlider.isEnabled = Preferences.appsOpenOnRest
        restDelayValue.stringValue = "\(Preferences.appsRestDelay) ms"
    }

    @objc private func changeRestDelay() {
        Preferences.appsRestDelay = Int((restDelaySlider.doubleValue / 10).rounded()) * 10
        syncRestDelay()
    }

    /// The Apps panel's look: shape, line, sizes — each change shows a sample of it.
    private lazy var lookSliders: [(slider: NSSlider, value: NSTextField, get: () -> Int, set: (Int) -> Void)] = [
        (NSSlider(), NSTextField(labelWithString: ""), { Preferences.appsPinnedSize }, { Preferences.appsPinnedSize = $0 }),
        (NSSlider(), NSTextField(labelWithString: ""), { Preferences.appsRecentSize }, { Preferences.appsRecentSize = $0 }),
        (NSSlider(), NSTextField(labelWithString: ""), { Preferences.appsGap }, { Preferences.appsGap = $0 }),
        (NSSlider(), NSTextField(labelWithString: ""), { Preferences.appsPadding }, { Preferences.appsPadding = $0 }),
        (NSSlider(), NSTextField(labelWithString: ""), { Preferences.appsPosition }, { Preferences.appsPosition = $0 }),
        (NSSlider(), NSTextField(labelWithString: ""), { Preferences.appsUnmatchedOpacity }, { Preferences.appsUnmatchedOpacity = $0 }),
    ]
    private static let lookUnits = [" pt", " pt", " pt", " pt", "% down", "%"]

    private func makeLookRows() -> [NSView] {
        shapePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        shapePopup.addItems(withTitles: ["Pill", "Box"])
        shapePopup.target = self
        shapePopup.action = #selector(changeLook)
        separatorCheckbox = NSButton(checkboxWithTitle: "Line between pinned and recent", target: self, action: #selector(changeLook))
        let shapeLabel = NSTextField(labelWithString: "Shape")
        shapeLabel.widthAnchor.constraint(equalToConstant: 105).isActive = true
        let shapeRow = NSStackView(views: [shapeLabel, shapePopup, separatorCheckbox])
        shapeRow.alignment = .centerY
        shapeRow.spacing = 8
        let titles = ["Pinned icon", "Recent icon", "Gap", "Padding", "Position", "Not matching"], ranges: [ClosedRange<Double>] = [32...120, 24...120, 0...40, 4...40, 15...85, 0...100]
        hoverPopup.addItems(withTitles: ["None", "Plate", "Glow"])
        hoverPopup.target = self
        hoverPopup.action = #selector(changeLook)
        let hoverLabel = NSTextField(labelWithString: "Hover")
        hoverLabel.widthAnchor.constraint(equalToConstant: 105).isActive = true
        let hoverRow = NSStackView(views: [hoverLabel, hoverPopup])
        hoverRow.alignment = .centerY
        hoverRow.spacing = 8
        return [shapeRow, hoverRow] + lookSliders.enumerated().map { k, entry in
            entry.slider.minValue = ranges[k].lowerBound
            entry.slider.maxValue = ranges[k].upperBound
            entry.slider.target = self
            entry.slider.action = #selector(changeLook)
            entry.slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
            entry.value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let label = NSTextField(labelWithString: titles[k])
            label.widthAnchor.constraint(equalToConstant: 105).isActive = true
            let row = NSStackView(views: [label, entry.slider, entry.value])
            row.alignment = .centerY
            row.spacing = 8
            return row
        }
    }

    private func syncLook() {
        shapePopup.selectItem(at: Preferences.appsShape == "box" ? 1 : 0)
        separatorCheckbox.state = Preferences.appsSeparator ? .on : .off
        hoverPopup.selectItem(at: Preferences.HoverStyle.allCases.firstIndex(of: Preferences.appsHoverStyle) ?? 0)
        nearCursorCheckbox.state = Preferences.appsNearCursor ? .on : .off
        for (k, entry) in lookSliders.enumerated() {
            entry.slider.doubleValue = Double(entry.get())
            entry.value.stringValue = "\(entry.get())\(Self.lookUnits[k])"
        }
    }

    /// Saved at once; the sample drawn — the window moved aside from the screen's center, so both show.
    @objc private func changeLook() {
        Preferences.appsShape = shapePopup.indexOfSelectedItem == 1 ? "box" : "pill"
        Preferences.appsSeparator = separatorCheckbox.state == .on
        Preferences.appsHoverStyle = Preferences.HoverStyle.allCases[hoverPopup.indexOfSelectedItem]
        Preferences.appsNearCursor = nearCursorCheckbox.state == .on
        for entry in lookSliders { entry.set(Int(entry.slider.doubleValue.rounded())) }
        syncLook()
        if let window = window, let screen = window.screen, abs(window.frame.midX - screen.frame.midX) < window.frame.width {
            window.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 24, y: window.frame.minY))
        }
        onChangeAppsLook?()
    }

    @objc private func changeHotkeyMode() {
        Preferences.appSwitcherMode = Preferences.HotkeyMode.allCases[appSwitcherModePopup.indexOfSelectedItem]
        Preferences.windowSwitcherMode = Preferences.HotkeyMode.allCases[windowSwitcherModePopup.indexOfSelectedItem]
        Preferences.appsEnabled = appsPopup.indexOfSelectedItem == 0
        onChangeHotkeys?()
    }

    @objc private func toggleRaiseAllWindows() {
        Preferences.raiseAllWindows = raiseAllWindowsCheckbox.state == .on
    }

    @objc private func toggleMaximizeNewWindows() {
        Preferences.maximizeNewWindows = maximizeNewWindowsCheckbox.state == .on
    }

    @objc private func toggleHideOtherApps() {
        Preferences.hideOtherAppsOnSwitch = hideOtherAppsCheckbox.state == .on
    }

    /// Parse and persist the TTL, then re-render canonically. Unparseable input
    /// snaps back. Takes effect on the next Cmd+Tab.
    @objc private func commitTTL() {
        if let minutes = Self.parseMinutes(ttlField.stringValue) { Preferences.mainRowTTLMinutes = minutes }
        ttlField.stringValue = Self.formatMinutes(Preferences.mainRowTTLMinutes)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as AnyObject) === ttlField { commitTTL() }  // commit on focus loss too
    }

    @objc private func quit() {
        // Close first, then terminate — applicationWillTerminate restores native Cmd+Tab.
        window?.close()
        NSApp.terminate(nil)
    }
}
