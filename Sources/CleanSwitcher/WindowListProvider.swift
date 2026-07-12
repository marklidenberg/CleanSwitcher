import Cocoa

struct WindowInfo {
    let axWindow: AXUIElement
    let windowId: CGWindowID
    let title: String
    let appName: String
    let icon: NSImage
    let pid: pid_t
}

/// In-memory, session-only record of when each window was last focused, keyed by
/// CGWindowID. macOS exposes no per-window last-focus timestamp, so the window
/// switcher's recent/old split relies on this. Times are recorded when a window's
/// app is activated, when this switcher raises a window, and when the switcher
/// opens (the frontmost window). Not persisted — window IDs aren't stable across
/// relaunches, and window switching is a within-session activity anyway.
///
/// Limitation: focusing a *background window of the same app* by clicking fires
/// no app activation, so it isn't timestamped until the window is brought forward
/// via an app switch or this switcher — until then it reads as "old".
enum WindowFocusTracker {
    private static var lastFocusById: [CGWindowID: TimeInterval] = [:]

    static func record(_ windowId: CGWindowID) {
        guard windowId != 0 else { return }
        lastFocusById[windowId] = Date().timeIntervalSince1970
    }

    static func lastFocus(_ windowId: CGWindowID) -> TimeInterval {
        lastFocusById[windowId] ?? 0
    }

    /// Record the frontmost window of an app as focused now. Called from the app
    /// activation observer so cross-app window recency is captured.
    static func recordFrontWindow(of app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let axWindow = focused, CFGetTypeID(axWindow) == AXUIElementGetTypeID() else {
            return
        }
        var windowId: CGWindowID = 0
        if _AXUIElementGetWindow(axWindow as! AXUIElement, &windowId) == .success {
            record(windowId)
        }
    }
}

/// Enumerates, splits, and raises the windows of a running app via the
/// Accessibility API. Used by the Cmd+` window-switching mode. AX (not
/// CGWindowList) is used for titles because window names from CGWindowList are
/// empty without Screen Recording permission, and AX also gives us the element
/// needed to raise it.
enum WindowListProvider {

    /// Standard windows of `app`, front-to-back (matching AX order).
    static func windows(for app: NSRunningApplication) -> [WindowInfo] {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else {
            return []
        }

        let appName = app.localizedName ?? "Unknown"
        let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()

        var result: [WindowInfo] = []
        for axWindow in axWindows {
            // Only real, standard windows — skip sheets, popovers, and dialogs.
            var subroleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleValue) == .success,
               let subrole = subroleValue as? String,
               subrole != (kAXStandardWindowSubrole as String) {
                continue
            }

            var titleValue: CFTypeRef?
            let title = (AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue) == .success
                ? titleValue as? String : nil) ?? ""

            var windowId: CGWindowID = 0
            _AXUIElementGetWindow(axWindow, &windowId)

            result.append(WindowInfo(
                axWindow: axWindow,
                windowId: windowId,
                title: title.isEmpty ? appName : title,
                appName: appName,
                icon: icon,
                pid: pid
            ))
        }
        return result
    }

    /// Split an app's windows into the recently-focused main row and the
    /// older-than-TTL secondary row (revealed on tab-past), each ordered
    /// most-recent first. The frontmost window is stamped as focused now (the app
    /// is frontmost when the switcher opens), so it always leads the main row and
    /// main[1] is the previous window — quick Cmd+` back-and-forth still works.
    static func splitWindows(for app: NSRunningApplication) -> (main: [WindowInfo], secondary: [WindowInfo]) {
        let wins = windows(for: app)
        if let front = wins.first { WindowFocusTracker.record(front.windowId) }

        let now = Date().timeIntervalSince1970
        let ttl = Preferences.mainRowTTL
        let byRecencyDesc = wins.sorted { WindowFocusTracker.lastFocus($0.windowId) > WindowFocusTracker.lastFocus($1.windowId) }
        var main = byRecencyDesc.filter { now - WindowFocusTracker.lastFocus($0.windowId) <= ttl }
        var secondary = byRecencyDesc.filter { now - WindowFocusTracker.lastFocus($0.windowId) > ttl }

        if main.isEmpty {
            main = byRecencyDesc
            secondary = []
        }
        return (main, secondary)
    }

    /// Close a window by pressing its close button (the AX equivalent of clicking
    /// the red traffic-light). Apps with unsaved changes may show a sheet, exactly
    /// as they would for a manual close.
    static func close(_ window: WindowInfo) {
        var closeButton: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window.axWindow, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
              let button = closeButton, CFGetTypeID(button) == AXUIElementGetTypeID() else {
            return
        }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    /// Bring a window to the front: un-minimize if needed, raise it, then activate
    /// its app so it actually takes focus. Records the window as focused now.
    static func raise(_ window: WindowInfo) {
        AXUIElementSetAttributeValue(window.axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window.axWindow, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.pid)?
            .activate(options: [.activateIgnoringOtherApps])
        WindowFocusTracker.record(window.windowId)
    }
}
