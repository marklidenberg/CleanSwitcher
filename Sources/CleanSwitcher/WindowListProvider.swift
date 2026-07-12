import Cocoa

struct WindowInfo {
    let axWindow: AXUIElement
    let windowId: CGWindowID
    let title: String
    let appName: String
    let icon: NSImage
    let pid: pid_t
}

/// Session-only per-window last-focus times, keyed by CGWindowID. macOS exposes
/// no such timestamp, so the window switcher's recent/old split relies on this.
/// Stamped on app activation, when this switcher raises a window, and when it
/// opens. Not persisted — window IDs aren't stable across relaunches.
///
/// Limitation: clicking a background window of the same app fires no activation,
/// so it reads as "old" until brought forward via an app switch or this switcher.
enum WindowFocusTracker {
    private static var lastFocusById: [CGWindowID: TimeInterval] = [:]

    static func record(_ windowId: CGWindowID) {
        guard windowId != 0 else { return }
        lastFocusById[windowId] = Date().timeIntervalSince1970
    }

    static func lastFocus(_ windowId: CGWindowID) -> TimeInterval {
        lastFocusById[windowId] ?? 0
    }

    /// Stamp an app's frontmost window as focused now (from the activation observer).
    static func recordFrontWindow(of app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let axWindow = focused, CFGetTypeID(axWindow) == AXUIElementGetTypeID() else {
            return
        }
        var windowId: CGWindowID = 0
        if _AXUIElementGetWindow(axWindow as! AXUIElement, &windowId) == .success { record(windowId) }
    }
}

/// Enumerates, splits, and raises an app's windows via Accessibility (the Cmd+`
/// mode). AX (not CGWindowList) gives usable titles without Screen Recording
/// permission, plus the element needed to raise the window.
enum WindowListProvider {

    /// Standard windows of `app`, front-to-back (AX order).
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
            // - Standard windows only — skip sheets, popovers, dialogs

            var subroleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleValue) == .success,
               let subrole = subroleValue as? String, subrole != (kAXStandardWindowSubrole as String) {
                continue
            }

            // - Title (fall back to app name) + window id

            var titleValue: CFTypeRef?
            let title = (AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue) == .success
                ? titleValue as? String : nil) ?? ""

            var windowId: CGWindowID = 0
            _AXUIElementGetWindow(axWindow, &windowId)

            result.append(WindowInfo(
                axWindow: axWindow, windowId: windowId,
                title: title.isEmpty ? appName : title, appName: appName, icon: icon, pid: pid
            ))
        }
        return result
    }

    /// Split an app's windows into the recent main row and the older secondary row,
    /// each most-recent first. The frontmost window is stamped now (the app is
    /// frontmost when the switcher opens), so it leads and main[1] is the previous
    /// window — quick Cmd+` back-and-forth holds.
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

    /// Close a window by pressing its AX close button (like clicking the red
    /// traffic-light) — apps with unsaved changes may show a sheet.
    static func close(_ window: WindowInfo) {
        var closeButton: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window.axWindow, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
              let button = closeButton, CFGetTypeID(button) == AXUIElementGetTypeID() else {
            return
        }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    /// Bring a window to the front: un-minimize, raise, activate its app, stamp focus.
    static func raise(_ window: WindowInfo) {
        AXUIElementSetAttributeValue(window.axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window.axWindow, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateIgnoringOtherApps])
        WindowFocusTracker.record(window.windowId)
    }
}
