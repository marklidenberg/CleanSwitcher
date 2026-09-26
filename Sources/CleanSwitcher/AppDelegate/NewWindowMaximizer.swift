import Cocoa

/// Maximizes every new standard window of every regular app to its screen's
/// visible frame, while `Preferences.maximizeNewWindows` is on. Needs Accessibility.
enum NewWindowMaximizer {

    private static var observers: [pid_t: AXObserver] = [:]
    private static var isStarted = false

    static func start() {
        guard !isStarted else { return }
        isStarted = true

        // - Observe running apps, apps launched later, and drop terminated ones

        NSWorkspace.shared.runningApplications.forEach { observe($0) }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { observe(app) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let observer = observers.removeValue(forKey: app.processIdentifier) else { return }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    /// Subscribe to the app's window-created notification. A just-launched app may
    /// not answer AX yet, so retry for a few seconds.
    private static func observe(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil, !app.isTerminated else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, window, _, _ in NewWindowMaximizer.windowCreated(window) }, &observer) == .success, let observer = observer else { return }
        guard AXObserverAddNotification(observer, AXUIElementCreateApplication(pid), kAXWindowCreatedNotification as CFString, nil) == .success else {
            if attempt < 10 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { observe(app, attempt: attempt + 1) } }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    /// Delayed so the app's own initial sizing (e.g. restored frame) lands first.
    private static func windowCreated(_ window: AXUIElement) {
        guard Preferences.maximizeNewWindows else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { maximize(window) }
    }

    private static func maximize(_ window: AXUIElement) {
        // - Only resizable standard windows (skips dialogs, panels, sheets)

        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        var isResizable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &isResizable)
        guard subrole as? String == kAXStandardWindowSubrole, isResizable.boolValue else { return }

        // - Pick the screen holding the window's top-left (AX: top-left origin, y down)

        var positionValue: CFTypeRef?
        var position = CGPoint.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success {
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        }
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let topLeft = CGPoint(x: position.x + 1, y: primaryHeight - position.y - 1)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(topLeft) }) ?? NSScreen.main else { return }

        // - Fill its visible frame (position again after resizing, as some apps clamp)

        var origin = CGPoint(x: screen.visibleFrame.minX, y: primaryHeight - screen.visibleFrame.maxY)
        var size = screen.visibleFrame.size
        let originValue = AXValueCreate(.cgPoint, &origin)!
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
    }
}
