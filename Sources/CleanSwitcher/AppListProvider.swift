import Cocoa

struct AppInfo {
    let app: NSRunningApplication
    let name: String
    let icon: NSImage
    let pid: pid_t
    let badge: String?  // Dock badge (notification count)
}

class AppListProvider {
    // Track app activation order (most recent first)
    private static var mruOrder: [pid_t] = []
    private static var isObserving = false

    /// Start observing app activations to track MRU order
    static func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        // Initialize with current frontmost app
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            updateMRU(frontApp.processIdentifier)
        }

        // Observe app activation
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                updateMRU(app.processIdentifier)
                if let bundleId = app.bundleIdentifier, bundleId != Bundle.main.bundleIdentifier {
                    recordFocus(bundleId)
                    WindowFocusTracker.recordFrontWindow(of: app)
                }
            }
        }

        // Observe app termination to clean up MRU
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                mruOrder.removeAll { $0 == app.processIdentifier }
            }
        }
    }

    // MARK: - Focus stats (recent + popular)

    // Per-bundle focus stats persisted across launches, so the main row's
    // "popular apps" survives a restart. Stored as [bundleId: [count, lastFocusEpoch]].
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
        let raw = stats.mapValues { [Double($0.count), $0.lastFocus] }
        UserDefaults.standard.set(raw, forKey: focusStatsKey)
    }

    /// Record an app activation: bump its focus count and last-focus time.
    private static func recordFocus(_ bundleId: String) {
        var stats = loadFocusStats()
        var stat = stats[bundleId] ?? FocusStat(count: 0, lastFocus: 0)
        stat.count += 1
        stat.lastFocus = Date().timeIntervalSince1970
        stats[bundleId] = stat
        saveFocusStats(stats)
    }

    /// Split the visible apps by how recently they were focused: apps used within
    /// `mainRowTTL` form the always-shown main row; apps last used longer ago (or
    /// never, in this install) form the secondary row, revealed only when the user
    /// tabs past the main row. Both sections are drawn from the same visible-apps
    /// set, so every tile is switchable. Each section is ordered most-recent first —
    /// so main[0] is the current app and main[1] is the previous one, preserving
    /// quick Alt-Tab back-and-forth.
    static func getSplitApps() -> (main: [AppInfo], secondary: [AppInfo]) {
        let all = getVisibleApps()  // MRU-sorted, self excluded
        let stats = loadFocusStats()
        let now = Date().timeIntervalSince1970

        func lastFocus(_ app: AppInfo) -> TimeInterval {
            stats[app.app.bundleIdentifier ?? ""]?.lastFocus ?? 0
        }

        let ttl = Preferences.mainRowTTL
        let byRecencyDesc = all.sorted { lastFocus($0) > lastFocus($1) }
        var main = byRecencyDesc.filter { now - lastFocus($0) <= ttl }
        var secondary = byRecencyDesc.filter { now - lastFocus($0) > ttl }

        // No recent focus history (fresh launch): keep everything in the main row
        // so it's never empty when apps are open.
        if main.isEmpty {
            main = byRecencyDesc
            secondary = []
        }

        return (main, secondary)
    }

    /// Update MRU order when an app is activated
    private static func updateMRU(_ pid: pid_t) {
        // Remove if already in list
        mruOrder.removeAll { $0 == pid }
        // Add to front
        mruOrder.insert(pid, at: 0)
        // Keep list reasonable size
        if mruOrder.count > 50 {
            mruOrder.removeLast()
        }
    }

    /// Returns apps that should be shown in the switcher
    /// Shows apps that are:
    /// - Regular apps (activationPolicy == .regular)
    /// - Have a window OR a dock badge (notification)
    ///
    /// Hidden apps (Cmd+H) are included: native Cmd+Tab keeps them, and a hidden
    /// app still owns its windows. Only genuinely windowless apps are filtered out.
    static func getVisibleApps() -> [AppInfo] {
        // Get PIDs of apps that have at least one on-screen window
        let visiblePIDs = getVisibleWindowPIDs()

        // Get dock badges for all running apps
        let badges = getDockBadgesCached()

        // Get current app's PID to exclude self
        let selfPID = ProcessInfo.processInfo.processIdentifier

        // Filter running applications
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppInfo? in
            // Only include regular apps (not background/accessory apps)
            guard app.activationPolicy == .regular else { return nil }

            // Exclude self
            guard app.processIdentifier != selfPID else { return nil }

            // Get badge for this app (if any)
            let badge = badges[app.bundleIdentifier ?? ""]

            // Include apps that have visible windows OR have a badge
            let hasVisibleWindow = visiblePIDs.contains(app.processIdentifier)
            let hasBadge = badge != nil

            guard hasVisibleWindow || hasBadge else { return nil }

            // Get app info. The icon's logical size is left alone: AppItemView
            // sizes it via constraints (mutating app.icon would touch a shared
            // NSImage), and the reps carry the resolution regardless.
            let name = app.localizedName ?? "Unknown"
            let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()

            return AppInfo(app: app, name: name, icon: icon, pid: app.processIdentifier, badge: badge)
        }

        // Sort by MRU order
        return sortByMRU(apps)
    }

    /// Gets PIDs of all apps with on-screen windows across all spaces
    /// Includes fullscreen windows and windows on other spaces
    private static func getVisibleWindowPIDs() -> Set<pid_t> {
        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements, .optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var pids = Set<pid_t>()
        for window in windowList {
            // Get window layer - layer 0 is normal windows
            // Negative layers are below desktop, high positive layers are system UI
            let layer = window[kCGWindowLayer as String] as? Int ?? 0

            // Accept normal windows (layer 0) and some special cases
            // Layer 0: normal windows
            // Layer < 0: below desktop (skip)
            // Layer 3: screensaver/fullscreen video (some apps)
            // Layer > 20: system UI elements like menubar, dock (skip)
            if layer < 0 || layer > 20 {
                continue
            }

            // Check bounds - skip windows with no size (menus, tooltips, etc.)
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] {
                let width = bounds["Width"] ?? 0
                let height = bounds["Height"] ?? 0
                // Minimum size to be considered a real window
                if width < 50 || height < 50 {
                    continue
                }
            } else {
                continue
            }

            // Check if window is on screen OR if it has valid bounds (for other spaces)
            // Windows on other spaces have isOnScreen = false but still valid
            let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false

            // For windows not on current screen, check if they're just on another space
            // by verifying they have a valid owner name (real app, not system process)
            if !isOnScreen {
                // Skip if no owner name (likely system window)
                guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                      !ownerName.isEmpty else {
                    continue
                }
            }

            if let pid = window[kCGWindowOwnerPID as String] as? pid_t {
                pids.insert(pid)
            }
        }

        return pids
    }

    // The badge scan walks the Dock's AX tree — several IPC round-trips per dock
    // item, on the main thread. getVisibleApps runs on every Cmd+Tab press AND
    // every 300ms while the panel is open (AppDelegate's live refresh), so cache
    // the result briefly instead of re-walking each time. Badges changing within
    // the TTL just show ~2s late on the next open — invisible in practice.
    private static var badgeCache: (badges: [String: String], at: Date)?
    private static let badgeCacheTTL: TimeInterval = 2.0

    private static func getDockBadgesCached() -> [String: String] {
        if let cache = badgeCache, Date().timeIntervalSince(cache.at) < badgeCacheTTL {
            return cache.badges
        }
        let fresh = getDockBadges()
        badgeCache = (fresh, Date())
        return fresh
    }

    /// Gets dock badges (notification counts) for running apps
    /// Queries the Dock's accessibility hierarchy for AXStatusLabel
    private static func getDockBadges() -> [String: String] {
        var badges: [String: String] = [:]

        // Find the Dock process
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            return badges
        }

        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)

        // Get Dock's children
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return badges
        }

        // Find the list element (contains dock items)
        for child in children {
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue) == .success,
                  let role = roleValue as? String,
                  role == kAXListRole else {
                continue
            }

            // Get list children (dock items)
            var listChildrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &listChildrenValue) == .success,
                  let listChildren = listChildrenValue as? [AXUIElement] else {
                continue
            }

            // Check each dock item
            for dockItem in listChildren {
                // Get subrole - must be application dock item
                var subroleValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, kAXSubroleAttribute as CFString, &subroleValue) == .success,
                      let subrole = subroleValue as? String,
                      subrole == "AXApplicationDockItem" else {
                    continue
                }

                // Check if app is running
                var isRunningValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, "AXIsApplicationRunning" as CFString, &isRunningValue) == .success,
                      let isRunning = isRunningValue as? Bool,
                      isRunning else {
                    continue
                }

                // Get the badge label (AXStatusLabel)
                var statusLabelValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, "AXStatusLabel" as CFString, &statusLabelValue) == .success,
                      let statusLabel = statusLabelValue as? String,
                      !statusLabel.isEmpty else {
                    continue
                }

                // Get the app URL to find bundle identifier
                var urlValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(dockItem, kAXURLAttribute as CFString, &urlValue) == .success,
                      let url = urlValue as? URL ?? (urlValue as? NSURL)?.filePathURL else {
                    continue
                }

                // Get bundle identifier from the app URL
                if let bundle = Bundle(url: url),
                   let bundleId = bundle.bundleIdentifier {
                    badges[bundleId] = statusLabel
                }
            }
        }

        return badges
    }

    /// Sort apps by MRU order (most recently used first)
    private static func sortByMRU(_ apps: [AppInfo]) -> [AppInfo] {
        return apps.sorted { app1, app2 in
            let idx1 = mruOrder.firstIndex(of: app1.pid) ?? Int.max
            let idx2 = mruOrder.firstIndex(of: app2.pid) ?? Int.max
            return idx1 < idx2
        }
    }
}
