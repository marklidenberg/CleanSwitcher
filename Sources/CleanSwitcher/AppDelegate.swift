import Cocoa
import Carbon

class AppDelegate: NSObject, NSApplicationDelegate, HotkeyManagerDelegate, AppSwitcherPanelDelegate {

    enum State {
        case idle
        case active
    }

    /// What the open panel is switching between: apps (Cmd+Tab) or the current
    /// app's windows (Cmd+`).
    enum Mode {
        case apps
        case windows
    }

    private var state: State = .idle
    private var mode: Mode = .apps
    private var hotkeyManager: HotkeyManager!
    private var panel: AppSwitcherPanel!
    // PIDs currently shown in the panel — used to append newly-launched apps
    // during the live refresh without duplicating what's already on screen.
    private var shownPIDs: Set<pid_t> = []
    private var statusBarController: StatusBarController!
    private var prefsWindowController: PreferencesWindowController!

    // True once we've taken over Cmd+Tab (event tap live + native Cmd+Tab disabled).
    private var switchingEnabled = false
    // Background monitor that reconciles Accessibility permission state.
    private let permissionQueue = DispatchQueue(label: "com.cleanswitcher.permission")
    private var permissionTimer: DispatchSourceTimer?
    // Polls for newly-opened apps while the panel is shown, so their icons appear as
    // soon as their windows render (see startAppListRefresh).
    private var appListRefreshTimer: DispatchSourceTimer?
    private var activityToken: NSObjectProtocol?
    private var isHandlingRevocation = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start tracking app activation order
        AppListProvider.startObserving()

        // Setup hotkey manager (does NOT take over Cmd+Tab yet — see enableSwitching)
        hotkeyManager = HotkeyManager()
        hotkeyManager.delegate = self

        // Create panel (hidden initially)
        panel = AppSwitcherPanel()
        panel.panelDelegate = self

        // Set app to accessory (no dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Settings: register in-process fallbacks before any read.
        Preferences.registerDefaults()

        // Start at login by default (first run only; respects a later opt-out).
        LoginItem.enableByDefaultOnFirstRun()

        // Menu bar icon (optional, controlled by preferences). Provides a Quit
        // escape hatch even while we're waiting for Accessibility permission.
        statusBarController = StatusBarController()
        statusBarController.onOpenPreferences = { [weak self] in self?.showPreferences() }
        statusBarController.onHideMenuBar = { [weak self] in
            Preferences.showMenuBarIcon = false
            self?.refreshStatusItem()
        }
        refreshStatusItem()

        // Preferences window (reusable single instance, hidden until requested)
        prefsWindowController = PreferencesWindowController()
        prefsWindowController.onToggleMenuBar = { [weak self] _ in self?.refreshStatusItem() }

        // Only take over Cmd+Tab once Accessibility permission is confirmed. Until
        // then, native Cmd+Tab is left working — so a first launch without
        // permission can never leave the system broken.
        if AccessibilityPermission.isGranted {
            enableSwitching()
        } else {
            AccessibilityPermission.prompt()
        }
        // Continuously reconcile permission: enable switching when granted, and
        // (critically) QUIT if it is revoked while running — terminating the
        // process is the only reliable way to release the event tap and clear
        // the macOS input-freeze bug.
        startPermissionMonitor()

        print("CleanSwitcher started. Press Cmd+Tab to activate.")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Re-launching CleanSwitcher.app while it's already running surfaces Preferences.
        showPreferences()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing Preferences must not quit the background agent.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore native Cmd+Tab
        setNativeCommandTabEnabled(true)
        hotkeyManager?.stop()
    }

    // MARK: - HotkeyManagerDelegate

    func hotkeyTriggered() {
        // HotkeyManager already set isActive = true
        guard state == .idle else {
            // Already active - Cmd+Tab pressed again, select next app
            panel.selectNext()
            return
        }
        openPanel(reverse: false)
    }

    func hotkeyTriggeredReverse() {
        // Cmd+Shift+Tab: same as hotkeyTriggered but cycling backward.
        guard state == .idle else {
            panel.selectPrevious()
            return
        }
        openPanel(reverse: true)
    }

    func hotkeyTriggeredWindows() {
        // Cmd+`: from idle, open the window switcher for the frontmost app; while
        // showing apps, dive into the selected app's windows; while already showing
        // windows, cycle to the next one.
        switch state {
        case .idle:
            openWindowPanel(for: NSWorkspace.shared.frontmostApplication, reverse: false)
        case .active:
            if mode == .windows {
                panel.selectNext()
            } else if let app = panel.getSelectedItem()?.appInfo?.app {
                openWindowPanel(for: app, reverse: false)
            }
        }
    }

    func hotkeyTriggeredWindowsReverse() {
        // Cmd+Shift+`: same as hotkeyTriggeredWindows but cycling backward.
        switch state {
        case .idle:
            openWindowPanel(for: NSWorkspace.shared.frontmostApplication, reverse: true)
        case .active:
            if mode == .windows {
                panel.selectPrevious()
            } else if let app = panel.getSelectedItem()?.appInfo?.app {
                openWindowPanel(for: app, reverse: true)
            }
        }
    }

    /// Snapshot the visible apps split into main (recent) and secondary (older),
    /// and show the panel with only the recent apps; the older apps are toggled in
    /// with Cmd+S. Forward opens on the second recent app (quick Alt-Tab back-and-
    /// forth); reverse opens on the last recent app.
    private func openPanel(reverse: Bool) {
        let (main, secondary) = AppListProvider.getSplitApps()

        guard !main.isEmpty else {
            print("No visible apps to switch to")
            hotkeyManager.isActive = false
            return
        }

        mode = .apps
        shownPIDs = Set((main + secondary).map { $0.pid })
        let selectIndex = reverse ? (main.count - 1) : (main.count > 1 ? 1 : 0)
        panel.showWithItems(
            main: main.map { SwitcherItem.app($0) },
            secondary: secondary.map { SwitcherItem.app($0) },
            selectIndex: selectIndex,
            secondaryShown: false
        )

        state = .active
        hotkeyManager.registerActiveHotkeys()
        // Mirror apps opened while the panel is up (they're missing from the initial
        // snapshot until their windows render).
        startAppListRefresh()
    }

    /// Show the window switcher for `app`: one tile per standard window, with the
    /// selected window's title above. Cmd+` cycles; releasing Cmd raises the choice.
    /// Reverse opens on the last window (mirroring the app switcher's reverse).
    private func openWindowPanel(for app: NSRunningApplication?, reverse: Bool) {
        guard let app = app else {
            if state == .idle { hotkeyManager.isActive = false }
            return
        }
        let (mainWindows, secondaryWindows) = WindowListProvider.splitWindows(for: app)
        let total = mainWindows.count + secondaryWindows.count
        guard total > 0 else {
            // Nothing to cycle — abandon the gesture from idle; ignore mid-switch.
            if state == .idle { hotkeyManager.isActive = false }
            return
        }

        mode = .windows
        stopAppListRefresh()  // windows don't stream in like launching apps
        shownPIDs = []
        // Forward selection starts on the second window (quick back-and-forth);
        // reverse on the last.
        let selectIndex = reverse ? (total - 1) : (total > 1 ? 1 : 0)
        // Window switcher is always the vertical icon+name list, secondary shown.
        panel.showWithItems(
            main: mainWindows.map { SwitcherItem.window($0) },
            secondary: secondaryWindows.map { SwitcherItem.window($0) },
            selectIndex: selectIndex,
            vertical: true,
            secondaryShown: true
        )

        state = .active
        hotkeyManager.registerActiveHotkeys()
    }

    func modifierKeyReleased() {
        guard state == .active else { return }

        // Activate the selected app / raise the selected window
        if let selected = panel.getSelectedItem() {
            activateItem(selected)
        }

        dismissPanel()
    }

    func shiftTapped() {
        guard state == .active else { return }
        panel.selectPrevious()
    }

    func mouseClicked() {
        guard state == .active else { return }

        // Use NSEvent.mouseLocation for consistent coordinate system with panel.frame
        let mouseLocation = NSEvent.mouseLocation

        if panel.frame.contains(mouseLocation) {
            // Activate the item under the cursor — a click is deliberate, so it
            // ignores dead-zone hover state. Fall back to the keyboard selection
            // only if the click missed all icons (gap/padding inside the panel).
            if let clickedItem = panel.getItemUnderMouse() {
                activateItem(clickedItem)
            } else if let selected = panel.getSelectedItem() {
                activateItem(selected)
            }
        }
        // Click outside just dismisses without activating
        dismissPanel()
    }

    func keyPressed(_ keyCode: UInt16) {
        guard state == .active else { return }

        switch Int(keyCode) {
        case kVK_Tab:
            panel.selectNext()

        case kVK_Escape:
            dismissPanel()

        case kVK_Return:
            if let selected = panel.getSelectedItem() {
                activateItem(selected)
            }
            dismissPanel()

        case kVK_LeftArrow:
            panel.selectPrevious()

        case kVK_RightArrow:
            panel.selectNext()

        case kVK_UpArrow:
            panel.selectUp()

        case kVK_DownArrow:
            panel.selectDown()

        case kVK_ANSI_H:
            // Cmd+H — activate the selected app and hide every other app, then dismiss.
            if let selected = panel.getSelectedItem() {
                activateItem(selected)
            }
            hideOtherApps()
            dismissPanel()

        case kVK_ANSI_Q:
            quitSelectedApp()

        case kVK_ANSI_W:
            closeSelectedWindow()

        case kVK_ANSI_T:
            panel.toggleSecondary()

        default:
            break
        }
    }

    // MARK: - AppSwitcherPanelDelegate

    /// A click was swallowed by a click shield (outside the panel). The tap's
    /// mouseClicked usually dismisses first; this is the shield-side path so the
    /// panel still closes if the tap misses the event. Both are state-guarded.
    func panelDidRequestDismiss() {
        guard state == .active else { return }
        dismissPanel()
    }

    // MARK: - Private Methods

    /// Activate the app, or raise the window, backing the given tile.
    private func activateItem(_ item: SwitcherItem) {
        if let window = item.window {
            WindowListProvider.raise(window)
        } else if let appInfo = item.appInfo {
            appInfo.app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Cmd+H: hide every regular app EXCEPT the one the switcher just activated —
    /// macOS's "Hide Others", to declutter. Hidden apps drop out of the switcher
    /// (AppListProvider filters `!app.isHidden`), so the next Cmd+Tab shows fewer
    /// icons. `keepPID` is the selected item's app (falling back to the frontmost),
    /// since activation may not have propagated to `frontmostApplication` yet.
    private func hideOtherApps() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let keepPID = panel.getSelectedItem()?.identityPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            if pid == selfPID || pid == keepPID { continue }  // keep ourselves + the activated app
            app.hide()
        }
    }

    private func quitSelectedApp() {
        guard mode == .apps, let item = panel.removeSelectedItem(), let appInfo = item.appInfo else { return }

        // Terminate the app
        appInfo.app.terminate()

        // Remove from our list
        shownPIDs.remove(appInfo.pid)

        // If no more apps, dismiss
        if !panel.hasItems {
            dismissPanel()
        }
    }

    /// Cmd+W in window mode: close the selected window and drop its tile, staying
    /// open so you can close several in a row; dismisses once none are left.
    private func closeSelectedWindow() {
        guard mode == .windows, let item = panel.removeSelectedItem(), let window = item.window else { return }

        WindowListProvider.close(window)

        if !panel.hasItems {
            dismissPanel()
        }
    }

    private func dismissPanel() {
        stopAppListRefresh()
        panel.hidePanel()
        state = .idle
        hotkeyManager.isActive = false
        // Unregister active-only hotkeys so Cmd+H/Q work in other apps
        hotkeyManager.unregisterActiveHotkeys()
    }

    /// While the panel is open, poll for apps that have become visible since it
    /// opened (e.g. ones the user just launched from the Dock/Finder, whose windows
    /// hadn't rendered when the initial snapshot was taken) and append them to the
    /// end — append-only, so it never fights the user's own hide/quit actions and
    /// never reorders or moves the icons already on screen. Runs on the main queue
    /// because building each app's icon (NSImage) must happen on main.
    private func startAppListRefresh() {
        guard appListRefreshTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.state == .active, self.mode == .apps else { return }
            let fresh = AppListProvider.getVisibleApps()
            let additions = fresh.filter { !self.shownPIDs.contains($0.pid) }
            guard !additions.isEmpty else { return }  // no change → no reflow
            additions.forEach { self.shownPIDs.insert($0.pid) }
            self.panel.appendItems(additions.map { SwitcherItem.app($0) })
        }
        appListRefreshTimer = timer
        timer.resume()
    }

    private func stopAppListRefresh() {
        appListRefreshTimer?.cancel()
        appListRefreshTimer = nil
    }

    // MARK: - Switching & Accessibility Permission

    /// Take over Cmd+Tab. Creates the event tap FIRST and only disables native
    /// Cmd+Tab if that succeeded, so a permission failure never breaks the system.
    private func enableSwitching() {
        guard !switchingEnabled else { return }
        guard hotkeyManager.tryCreateEventTap() else { return }  // permission gate
        setNativeCommandTabEnabled(false)
        hotkeyManager.registerHotkeys()
        switchingEnabled = true
        print("Switching enabled.")
    }

    /// Polls Accessibility permission on a background timer and reconciles state.
    /// Deliberately a poll, not a CGEvent-tap callback: macOS does NOT reliably
    /// deliver a tap-disabled event when permission is revoked, so the callback
    /// cannot be trusted to detect revocation.
    private func startPermissionMonitor() {
        guard permissionTimer == nil else { return }
        // Disable App Nap so the timer keeps firing promptly while we hold the
        // tap. Allow idle system sleep — we only want to prevent napping, not keep
        // the whole Mac awake.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Monitor Accessibility permission to prevent input freeze"
        )
        let timer = DispatchSource.makeTimerSource(queue: permissionQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            let granted = AccessibilityPermission.isGranted
            DispatchQueue.main.async { self?.reconcilePermission(granted: granted) }
        }
        permissionTimer = timer
        timer.resume()
    }

    private func reconcilePermission(granted: Bool) {
        if granted {
            if !switchingEnabled { enableSwitching() }
        } else if switchingEnabled {
            handleRevocation()
        }
    }

    /// Accessibility was revoked while we held the event tap. Restore native
    /// Cmd+Tab and QUIT. Terminating the process is the only reliable way to tear
    /// the tap out of the window server and clear the macOS input-freeze bug —
    /// disabling the tap in-process while staying alive is NOT enough.
    private func handleRevocation() {
        guard !isHandlingRevocation else { return }
        isHandlingRevocation = true
        switchingEnabled = false
        setNativeCommandTabEnabled(true)
        hotkeyManager.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Preferences & Menu Bar

    private func showPreferences() {
        prefsWindowController.show()
    }

    private func refreshStatusItem() {
        if Preferences.showMenuBarIcon {
            statusBarController.show()
        } else {
            statusBarController.hide()
        }
    }

}
