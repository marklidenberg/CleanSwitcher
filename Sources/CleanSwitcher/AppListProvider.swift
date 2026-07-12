import Cocoa

struct AppInfo {
    let app: NSRunningApplication
    let name: String
    let icon: NSImage
    let pid: pid_t
    let badge: String?  // Dock badge (notification count)
}

/// MRU-ordered list of switchable apps, split into a recent main row and an
/// older secondary row.
class AppListProvider {

    private static var mruOrder: [pid_t] = []
    private static var isObserving = false

    /// Track app activation order and per-app focus stats.
    static func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        // - Seed with the current frontmost app

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            updateMRU(frontApp.processIdentifier)
        }

        // - Bump MRU + focus stats on every activation

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                updateMRU(app.processIdentifier)
                if let bundleId = app.bundleIdentifier, bundleId != Bundle.main.bundleIdentifier {
                    recordFocus(bundleId)
                    WindowFocusTracker.recordFrontWindow(of: app)
                }
            }
        }

        // - Drop terminated apps from MRU

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                mruOrder.removeAll { $0 == app.processIdentifier }
            }
        }
    }

    // - Focus stats (persisted per bundle, so "recent" survives a restart)
    //   Stored as [bundleId: [count, lastFocusEpoch]].

    private static let focusStatsKey = "focusStats"

    private struct FocusStat {
        var count: Int
        var lastFocus: TimeInterval  // seconds since 1970
    }

    private static func loadFocusStats() -> [String: FocusStat] {
        guard let raw = UserDefaults.standard.dictionary(forKey: focusStatsKey) as? [String: [Double]] else {
            return [:]
        }
        var stats: [String: FocusStat] = [:]
        for (bundleId, pair) in raw where pair.count == 2 {
            stats[bundleId] = FocusStat(count: Int(pair[0]), lastFocus: pair[1])
        }
        return stats
    }

    private static func saveFocusStats(_ stats: [String: FocusStat]) {
        UserDefaults.standard.set(stats.mapValues { [Double($0.count), $0.lastFocus] }, forKey: focusStatsKey)
    }

    private static func recordFocus(_ bundleId: String) {
        var stats = loadFocusStats()
        var stat = stats[bundleId] ?? FocusStat(count: 0, lastFocus: 0)
        stat.count += 1
        stat.lastFocus = Date().timeIntervalSince1970
        stats[bundleId] = stat
        saveFocusStats(stats)
    }

    /// Split the visible apps by last-focus recency into the always-shown main row
    /// (focused within `mainRowTTL`) and the toggle-in secondary row (older / never).
    /// Each section is most-recent first, so main[0] is the current app and main[1]
    /// the previous — quick Alt-Tab back-and-forth holds.
    static func getSplitApps() -> (main: [AppInfo], secondary: [AppInfo]) {
        let stats = loadFocusStats()
        let now = Date().timeIntervalSince1970
        func lastFocus(_ app: AppInfo) -> TimeInterval { stats[app.app.bundleIdentifier ?? ""]?.lastFocus ?? 0 }

        // - Sort visible apps most-recent first, then cut at the TTL

        let ttl = Preferences.mainRowTTL
        let byRecencyDesc = getVisibleApps().sorted { lastFocus($0) > lastFocus($1) }
        var main = byRecencyDesc.filter { now - lastFocus($0) <= ttl }
        var secondary = byRecencyDesc.filter { now - lastFocus($0) > ttl }

        // - Fresh launch (no focus history): keep everything in the main row

        if main.isEmpty {
            main = byRecencyDesc
            secondary = []
        }
        return (main, secondary)
    }

    private static func updateMRU(_ pid: pid_t) {
        mruOrder.removeAll { $0 == pid }
        mruOrder.insert(pid, at: 0)
        if mruOrder.count > 50 { mruOrder.removeLast() }
    }

    /// Regular apps that own an on-screen window OR a Dock badge, self excluded,
    /// MRU-sorted. Hidden apps (Cmd+H) are kept — a hidden app still owns its
    /// windows; only genuinely windowless apps drop out.
    static func getVisibleApps() -> [AppInfo] {
        let visiblePIDs = getVisibleWindowPIDs()
        let badges = getDockBadgesCached()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppInfo? in
            guard app.activationPolicy == .regular, app.processIdentifier != selfPID else { return nil }

            let badge = badges[app.bundleIdentifier ?? ""]
            guard visiblePIDs.contains(app.processIdentifier) || badge != nil else { return nil }

            // Icon size is left alone — AppItemView sizes it via constraints
            // rather than mutating the shared NSImage.
            let name = app.localizedName ?? "Unknown"
            let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
            return AppInfo(app: app, name: name, icon: icon, pid: app.processIdentifier, badge: badge)
        }

        return apps.sorted {
            (mruOrder.firstIndex(of: $0.pid) ?? .max) < (mruOrder.firstIndex(of: $1.pid) ?? .max)
        }
    }

    /// PIDs of apps with a real on-screen window, across all spaces (fullscreen
    /// and other-space windows included).
    private static func getVisibleWindowPIDs() -> Set<pid_t> {
        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var pids = Set<pid_t>()
        for window in windowList {
            // - Keep normal windows: layer 0..20 (skip below-desktop and system UI)

            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            if layer < 0 || layer > 20 { continue }

            // - Skip windows too small to be real (menus, tooltips)

            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 50, (bounds["Height"] ?? 0) >= 50 else { continue }

            // - Off-screen windows count only if they name a real owner (other space)

            let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
            if !isOnScreen {
                guard let ownerName = window[kCGWindowOwnerName as String] as? String, !ownerName.isEmpty else { continue }
            }

            if let pid = window[kCGWindowOwnerPID as String] as? pid_t { pids.insert(pid) }
        }
        return pids
    }

    // - Dock badge scan cache
    //   The scan walks the Dock's AX tree (several IPC round-trips) on the main
    //   thread, and getVisibleApps runs on every Cmd+Tab and every 300ms while the
    //   panel is open. Cache briefly; a badge change just shows ~2s late.

    private static var badgeCache: (badges: [String: String], at: Date)?
    private static let badgeCacheTTL: TimeInterval = 2.0

    private static func getDockBadgesCached() -> [String: String] {
        if let cache = badgeCache, Date().timeIntervalSince(cache.at) < badgeCacheTTL { return cache.badges }
        let fresh = getDockBadges()
        badgeCache = (fresh, Date())
        return fresh
    }

    /// Dock badges (notification counts) keyed by bundle id, read from the Dock's
    /// AX hierarchy (AXStatusLabel on each running application dock item).
    private static func getDockBadges() -> [String: String] {
        var badges: [String: String] = [:]

        // - Find the Dock process and its child list element

        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            return badges
        }
        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return badges
        }

        for child in children {
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue) == .success,
                  roleValue as? String == kAXListRole else { continue }

            var listChildrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &listChildrenValue) == .success,
                  let listChildren = listChildrenValue as? [AXUIElement] else { continue }

            // - Read each running application dock item's badge + bundle id

            for dockItem in listChildren {
                var subroleValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, kAXSubroleAttribute as CFString, &subroleValue) == .success,
                      subroleValue as? String == "AXApplicationDockItem" else { continue }

                var isRunningValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, "AXIsApplicationRunning" as CFString, &isRunningValue) == .success,
                      isRunningValue as? Bool == true else { continue }

                var statusLabelValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, "AXStatusLabel" as CFString, &statusLabelValue) == .success,
                      let statusLabel = statusLabelValue as? String, !statusLabel.isEmpty else { continue }

                var urlValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, kAXURLAttribute as CFString, &urlValue) == .success,
                      let url = urlValue as? URL ?? (urlValue as? NSURL)?.filePathURL else { continue }

                if let bundleId = Bundle(url: url)?.bundleIdentifier { badges[bundleId] = statusLabel }
            }
        }
        return badges
    }
}
