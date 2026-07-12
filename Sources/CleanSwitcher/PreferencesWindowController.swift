import Cocoa

/// A small, reusable Preferences window built programmatically.
/// One instance is held by AppDelegate and reused on every show/reopen.
class PreferencesWindowController: NSWindowController, NSTextFieldDelegate {

    /// Invoked when the "Show icon in menu bar" checkbox changes, so the caller
    /// can show/hide the status item live. Carries the new value.
    var onToggleMenuBar: ((Bool) -> Void)?

    private var launchAtLoginCheckbox: NSButton!
    private var menuBarCheckbox: NSButton!
    private var ttlField: NSTextField!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "CleanSwitcher Preferences"
        // Keep the single instance alive across closes.
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
        setupContent()
    }

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        launchAtLoginCheckbox = NSButton(
            checkboxWithTitle: "Start at login",
            target: self,
            action: #selector(toggleLaunchAtLogin)
        )
        // Hidden (collapsed by the stack view) on macOS < 13 where it's unsupported.
        launchAtLoginCheckbox.isHidden = !LoginItem.isSupported

        menuBarCheckbox = NSButton(
            checkboxWithTitle: "Show icon in menu bar",
            target: self,
            action: #selector(toggleMenuBar)
        )

        let quitButton = NSButton(title: "Quit CleanSwitcher", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded

        let versionLabel = NSTextField(labelWithString: versionString())
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            launchAtLoginCheckbox,
            menuBarCheckbox,
            makeTTLRow(),
            makeSectionLabel("Shortcuts"),
            makeShortcutsGrid(),
            quitButton,
            versionLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20)
        ])

        // Size the window to exactly fit the stack (20pt margins), so the version
        // label at the bottom is never clipped or left floating.
        stack.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: 380, height: stack.fittingSize.height + 40))
        window?.center()
    }

    /// "Recent: used within [ 1h30m ]" — the recency TTL control. Accepts a
    /// free-form duration (e.g. `10m`, `1h`, `1h30m`); commits on Return / focus loss.
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

    /// A read-only two-column reference of the switcher's shortcuts.
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

    // MARK: - Duration parsing

    /// Parse a free-form duration into minutes. Accepts unit tokens `d`/`h`/`m`
    /// combined in any order (`1h30m`, `90m`, `2h`, `1d`) and a bare number as
    /// minutes (`45`). Returns nil for empty/unparseable input.
    private static func parseMinutes(_ text: String) -> Int? {
        let s = text.lowercased().filter { !$0.isWhitespace }
        guard !s.isEmpty else { return nil }
        if let bare = Int(s) { return bare > 0 ? bare : nil }

        var total = 0
        var digits = ""
        var matchedAnyUnit = false
        for ch in s {
            if ch.isNumber {
                digits.append(ch)
                continue
            }
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

    /// Render minutes back to canonical form: `90 -> "1h30m"`, `60 -> "1h"`,
    /// `45 -> "45m"`, `1500 -> "1d1h"`.
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

    /// Brings the window to the front. Works for an `.accessory`/LSUIElement app:
    /// activating is required for controls to become clickable, and we stay
    /// `.accessory` so no Dock icon appears.
    func show() {
        syncFromPreferences()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Refresh control states from the current source of truth (they may have
    /// changed via the menu bar, the terminal, or System Settings between shows).
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
        let want = launchAtLoginCheckbox.state == .on
        if !LoginItem.setEnabled(want) {
            // Toggle failed — snap the checkbox back to the real state.
            launchAtLoginCheckbox.state = LoginItem.isEnabled ? .on : .off
        }
    }

    @objc private func toggleMenuBar() {
        let enabled = menuBarCheckbox.state == .on
        Preferences.showMenuBarIcon = enabled
        onToggleMenuBar?(enabled)
    }

    /// Commit the TTL field: parse it and persist minutes, then re-render the field
    /// in canonical form. Unparseable input is discarded (field snaps back).
    /// Takes effect on the next Cmd+Tab, since the split re-reads the pref.
    @objc private func commitTTL() {
        if let minutes = Self.parseMinutes(ttlField.stringValue) {
            Preferences.mainRowTTLMinutes = minutes
        }
        ttlField.stringValue = Self.formatMinutes(Preferences.mainRowTTLMinutes)
    }

    // Commit when focus leaves the TTL field (not just on Return).
    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as AnyObject) === ttlField { commitTTL() }
    }

    @objc private func quit() {
        // Close the window first, then terminate. `applicationWillTerminate`
        // restores the native Cmd+Tab hotkey on the way out.
        window?.close()
        NSApp.terminate(nil)
    }
}
