import Cocoa

/// Owns the optional menu bar icon (`NSStatusItem`) and its menu.
/// The status item is not retained by the system, so this controller holds a
/// strong reference for as long as the icon should be visible.
class StatusBarController: NSObject {

    /// Invoked when the user picks "Preferences…" from the menu.
    var onOpenPreferences: (() -> Void)?

    /// Invoked when the user picks "Hide from menu bar" from the menu.
    var onHideMenuBar: (() -> Void)?

    private var statusItem: NSStatusItem?

    /// Shows the menu bar icon (no-op if already visible).
    func show() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Tab-key glyph (arrow to a bar), matching the app's ⇥ icon. Template
        // image so it adapts to the light/dark menu bar.
        let image = NSImage(systemSymbolName: "arrow.right.to.line", accessibilityDescription: "CleanSwitcher")
        image?.isTemplate = true
        item.button?.image = image
        item.menu = makeMenu()
        statusItem = item
    }

    /// Removes the menu bar icon (no-op if already hidden).
    func hide() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let hideMenuBar = NSMenuItem(title: "Hide from menu bar", action: #selector(hideMenuBar), keyEquivalent: "")
        hideMenuBar.target = self
        menu.addItem(hideMenuBar)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit CleanSwitcher", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - Actions

    @objc private func openPreferences() {
        onOpenPreferences?()
    }

    @objc private func hideMenuBar() {
        onHideMenuBar?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
