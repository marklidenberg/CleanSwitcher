import Cocoa

/// The optional menu bar icon (`NSStatusItem`) and its menu. Holds a strong
/// reference for as long as the icon should be visible.
class StatusBarController: NSObject {

    var onOpenPreferences: (() -> Void)?
    var onHideMenuBar: (() -> Void)?

    private var statusItem: NSStatusItem?

    func show() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Tab-key glyph, template so it adapts to the light/dark menu bar.
        let image = NSImage(systemSymbolName: "arrow.right.to.line", accessibilityDescription: "CleanSwitcher")
        image?.isTemplate = true
        item.button?.image = image
        item.menu = makeMenu()
        statusItem = item
    }

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

    @objc private func openPreferences() { onOpenPreferences?() }
    @objc private func hideMenuBar() { onHideMenuBar?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
