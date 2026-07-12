import Cocoa

/// A small, programmatic Preferences window. One instance is held by AppDelegate
/// and reused on every show.
class PreferencesWindowController: NSWindowController, NSTextFieldDelegate {

    /// Called with the new value when "Show icon in menu bar" changes.
    var onToggleMenuBar: ((Bool) -> Void)?

    private var launchAtLoginCheckbox: NSButton!
    private var menuBarCheckbox: NSButton!
    private var ttlField: NSTextField!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 470),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "CleanSwitcher Preferences"
        window.isReleasedWhenClosed = false  // keep the single instance across closes
        window.center()

        self.init(window: window)
        setupContent()
    }

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        // - Controls

        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Start at login", target: self, action: #selector(toggleLaunchAtLogin))
        launchAtLoginCheckbox.isHidden = !LoginItem.isSupported  // collapsed on macOS < 13

        menuBarCheckbox = NSButton(checkboxWithTitle: "Show icon in menu bar", target: self, action: #selector(toggleMenuBar))

        let quitButton = NSButton(title: "Quit CleanSwitcher", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded

        let versionLabel = NSTextField(labelWithString: versionString())
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor

        // - Stack them and pin to the content view

        let stack = NSStackView(views: [
            launchAtLoginCheckbox, menuBarCheckbox, makeTTLRow(),
            makeSectionLabel("Shortcuts"), makeShortcutsGrid(), quitButton, versionLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
        ])

        // - Size the window to exactly fit the stack (20pt margins)

        stack.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: 380, height: stack.fittingSize.height + 40))
        window?.center()
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

    private func makeSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Read-only two-column reference of the switcher's shortcuts.
    private func makeShortcutsGrid() -> NSView {
        let shortcuts: [(String, String)] = [
            ("⌘ Tab", "Next app"),
            ("⌘ ⇧ Tab", "Previous app"),
            ("⌘ ` (key left of 1)", "Switch the app's windows"),
            ("Tab / →", "Next  (hold to repeat)"),
            ("⇧ Tab / ←", "Previous  (hold to repeat)"),
            ("↑ / ↓", "Move between rows"),
            ("T", "Toggle older apps"),
            ("H", "Hide other apps"),
            ("Q", "Quit app"),
            ("W", "Close window  (window mode)"),
            ("Return", "Activate / raise window"),
            ("Esc", "Dismiss"),
        ]

        let rows: [[NSView]] = shortcuts.map { keys, action in
            let keyLabel = NSTextField(labelWithString: keys)
            keyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            let actionLabel = NSTextField(labelWithString: action)
            actionLabel.font = .systemFont(ofSize: 11)
            actionLabel.textColor = .secondaryLabelColor
            return [keyLabel, actionLabel]
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 5
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = NSGridCell.Placement.leading
        return grid
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
    }

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
