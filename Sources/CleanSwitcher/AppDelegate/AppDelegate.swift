import Cocoa
import Carbon

/// The coordinator and switcher state machine. See AppDelegate.md.
class AppDelegate: NSObject, NSApplicationDelegate, HotkeyManagerDelegate, AppSwitcherPanelDelegate {

    enum State { case idle, active }
    enum Mode { case apps, windows }

    private var state: State = .idle
    private var mode: Mode = .apps
    private var hotkeyManager: HotkeyManager!
    private var panel: AppSwitcherPanel!
    // PIDs currently shown — used to append newly-launched apps during the live
    // refresh without duplicating what's on screen.
    private var shownPIDs: Set<pid_t> = []
    private var statusBarController: StatusBarController!
    private var prefsWindowController: PreferencesWindowController!

    // True once we've taken over Cmd+Tab (tap live + native Cmd+Tab disabled).
    private var switchingEnabled = false
    private let permissionQueue = DispatchQueue(label: "com.cleanswitcher.permission")
    private var permissionTimer: DispatchSourceTimer?
    // Polls for newly-opened apps while the panel is shown (see startAppListRefresh).
    private var appListRefreshTimer: DispatchSourceTimer?
    private var activityToken: NSObjectProtocol?
    private var isHandlingRevocation = false
    private var pendingActivationWork: DispatchWorkItem?  // debounced hide/raise on activation
    private var hideGeneration = 0  // bumped per hideApps call; stale pending hides are dropped
    private let hideQueue = DispatchQueue(label: "com.cleanswitcher.hide")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // - On any regular app's activation (opt-in): hide other apps, bring all its
        //   windows forward. Accessory apps (Paste, launchers) are skipped — their
        //   panel acts on the app behind, which must stay visible.
        //   Runs once activations settle (50ms), for the last activated app — hiding
        //   mid-race (macOS may briefly activate Finder) makes apps fight back and
        //   forth. Registered first so no other observer's AX work delays it. Never
        //   issues an activation itself, for the same reason.

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular, app != NSRunningApplication.current else { return }
            self.pendingActivationWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                if Preferences.hideOtherAppsOnSwitch { self?.hideApps(except: app.processIdentifier) }
                // With other apps hidden nothing can cover its windows — raising would only flicker
                if Preferences.raiseAllWindows && !Preferences.hideOtherAppsOnSwitch { WindowListProvider.raiseAll(of: app) }
            }
            self.pendingActivationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }

        // - Core subsystems

        AppListProvider.startObserving()
        hotkeyManager = HotkeyManager()
        hotkeyManager.delegate = self
        panel = AppSwitcherPanel()
        panel.panelDelegate = self
        NSApp.setActivationPolicy(.accessory)  // no Dock icon

        // - Settings and login item

        Preferences.registerDefaults()  // must run before any read
        LoginItem.enableByDefaultOnFirstRun()

        // - Menu bar icon (a Quit escape hatch even before permission is granted)

        statusBarController = StatusBarController()
        statusBarController.onOpenPreferences = { [weak self] in self?.showPreferences() }
        statusBarController.onHideMenuBar = { [weak self] in
            Preferences.showMenuBarIcon = false
            self?.refreshStatusItem()
        }
        refreshStatusItem()

        prefsWindowController = PreferencesWindowController()
        prefsWindowController.onToggleMenuBar = { [weak self] _ in self?.refreshStatusItem() }
        prefsWindowController.onChangeHotkeys = { [weak self] in self?.reconcileHotkeys() }
        prefsWindowController.onRecordingShortcut = { [weak self] isRecording in
            guard let self = self else { return }
            if isRecording {
                // Free every candidate combo so the recorder receives it as a key event
                self.hotkeyManager.setAppShortcut(nil)
                self.hotkeyManager.setWindowShortcut(nil)
                setNativeCommandTabEnabled(false)
            } else {
                self.reconcileHotkeys()
            }
        }

        // - Take over Cmd+Tab only once Accessibility is granted, then keep
        //   reconciling permission (enable when granted, quit if revoked)

        reconcileHotkeys()
        if AccessibilityPermission.isGranted {
            enableSwitching()
        } else {
            AccessibilityPermission.prompt()
        }
        startPermissionMonitor()

        print("CleanSwitcher started. Press Cmd+Tab to activate.")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPreferences()  // relaunching the app surfaces Preferences
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // closing Preferences must not quit the background agent
    }

    func applicationWillTerminate(_ notification: Notification) {
        setNativeCommandTabEnabled(true)
        hotkeyManager?.stop()
    }

    // - HotkeyManagerDelegate

    func hotkeyTriggered() {
        guard state == .idle else {
            panel.selectNext()  // already active — step forward
            return
        }
        guard Preferences.appSwitcherMode == .normal else { switchWithoutPanel(Preferences.appSwitcherMode, toRecent: switchToRecentApp); return }
        openPanel(reverse: false)
    }

    func hotkeyTriggeredReverse() {
        guard state == .idle else {
            panel.selectPrevious()
            return
        }
        guard Preferences.appSwitcherMode == .normal else { switchWithoutPanel(Preferences.appSwitcherMode, toRecent: switchToRecentApp); return }
        openPanel(reverse: true)
    }

    /// Cmd+`: open the window switcher (idle), dive into the selected app's windows
    /// (showing apps), or cycle windows (already in window mode).
    func hotkeyTriggeredWindows() {
        if state == .idle, Preferences.windowSwitcherMode != .normal { switchWithoutPanel(Preferences.windowSwitcherMode, toRecent: switchToRecentWindow); return }
        guard Preferences.windowSwitcherMode != .disabled else { return }
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
        if state == .idle, Preferences.windowSwitcherMode != .normal { switchWithoutPanel(Preferences.windowSwitcherMode, toRecent: switchToRecentWindow); return }
        guard Preferences.windowSwitcherMode != .disabled else { return }
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

    /// A hotkey from idle outside normal mode: no panel — switch to the previous
    /// app/window (recent only) or do nothing (disabled).
    private func switchWithoutPanel(_ hotkeyMode: Preferences.HotkeyMode, toRecent: () -> Void) {
        hotkeyManager.isActive = false
        if hotkeyMode == .recentOnly { toRecent() }
    }

    private func switchToRecentApp() {
        let (main, secondary) = AppListProvider.getSplitApps()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let app = (main + secondary).first(where: { $0.pid != frontPID }) { activateItem(.app(app)) }
    }

    /// The frontmost app's previous window (splitWindows puts the front one first).
    private func switchToRecentWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let (main, secondary) = WindowListProvider.splitWindows(for: app)
        if let window = (main + secondary).dropFirst().first { activateItem(.window(window)) }
    }

    /// Open the app switcher. Forward selects the second recent app (quick Alt-Tab
    /// back-and-forth); reverse selects the last. Secondary starts hidden.
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
            selectIndex: selectIndex, secondaryShown: false
        )

        state = .active
        hotkeyManager.registerActiveHotkeys()
        startAppListRefresh()
    }

    /// Open the window switcher for `app`: one tile per standard window. Forward
    /// selects the second main window, reverse the last. Secondary starts hidden.
    /// An app with no windows shows a "No open windows" placeholder instead.
    private func openWindowPanel(for app: NSRunningApplication?, reverse: Bool) {
        guard let app = app else {
            if state == .idle { hotkeyManager.isActive = false }
            return
        }
        let (mainWindows, secondaryWindows) = WindowListProvider.splitWindows(for: app)
        let total = mainWindows.count + secondaryWindows.count

        mode = .windows
        stopAppListRefresh()  // windows don't stream in like launching apps
        shownPIDs = []

        if total > 0 {
            let selectIndex = reverse ? (mainWindows.count - 1) : (mainWindows.count > 1 ? 1 : 0)
            panel.showWithItems(
                main: mainWindows.map { SwitcherItem.window($0) },
                secondary: secondaryWindows.map { SwitcherItem.window($0) },
                selectIndex: selectIndex, vertical: true, secondaryShown: false
            )
        } else {
            panel.showPlaceholder("No open windows")
        }

        state = .active
        hotkeyManager.registerActiveHotkeys()
    }

    func modifierKeyReleased() {
        guard state == .active else { return }
        if let selected = panel.getSelectedItem() { activateItem(selected) }
        dismissPanel()
    }

    func shiftTapped() {
        guard state == .active else { return }
        panel.selectPrevious()
    }

    func mouseClicked() {
        guard state == .active else { return }

        // - Activate the item under a deliberate click, else the keyboard selection

        if panel.frame.contains(NSEvent.mouseLocation) {
            if let clickedItem = panel.getItemUnderMouse() {
                activateItem(clickedItem)
            } else if let selected = panel.getSelectedItem() {
                activateItem(selected)
            }
        }
        dismissPanel()  // a click outside just dismisses
    }

    func keyPressed(_ keyCode: UInt16) {
        guard state == .active else { return }

        switch Int(keyCode) {
        case kVK_Tab: panel.selectNext()
        case kVK_Escape: dismissPanel()
        case kVK_Return:
            if let selected = panel.getSelectedItem() { activateItem(selected) }
            dismissPanel()
        case kVK_LeftArrow: panel.selectPrevious()
        case kVK_RightArrow: panel.selectNext()
        case kVK_UpArrow: panel.selectUp()
        case kVK_DownArrow: panel.selectDown()
        case kVK_ANSI_H:
            // Activate the selection and hide every other app, then dismiss.
            if let selected = panel.getSelectedItem() { activateItem(selected) }
            // The selected item's app — activation may not have reached frontmostApplication yet
            hideApps(except: panel.getSelectedItem()?.identityPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier)
            dismissPanel()
        case kVK_ANSI_Q: quitSelectedApp()
        case kVK_ANSI_W: closeSelectedWindow()
        case kVK_ANSI_T: panel.toggleSecondary()
        default: break
        }
    }

    // - AppSwitcherPanelDelegate

    /// A click shield swallowed an outside click. Both this and the tap's
    /// mouseClicked dismiss; both are state-guarded.
    func panelDidRequestDismiss() {
        guard state == .active else { return }
        dismissPanel()
    }

    /// Activate the app, or raise the window, backing `item`.
    private func activateItem(_ item: SwitcherItem) {
        if let window = item.window {
            WindowListProvider.raise(window)
        } else if let appInfo = item.appInfo {
            appInfo.app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Hide every regular app except `keepPID` (macOS "Hide Others").
    ///
    /// An app hidden before it has processed its own deactivation still thinks
    /// it's active and hands activation on (usually to Finder), which then hides
    /// the app just switched to. So each app is hidden only once its AXFrontmost
    /// (answered by the app itself) reads false — polled off main, up to ~0.5s,
    /// then skipped. A newer hideApps call cancels the pending ones.
    private func hideApps(except keepPID: pid_t?) {
        hideGeneration += 1
        let generation = hideGeneration
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
            let pid = app.processIdentifier
            if pid == selfPID || pid == keepPID { continue }

            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.1)
            func hideWhenInactive(attempt: Int) {
                var frontmost: CFTypeRef?
                let stillFrontmost = AXUIElementCopyAttributeValue(axApp, kAXFrontmostAttribute as CFString, &frontmost) == .success
                    && frontmost as? Bool == true
                if !stillFrontmost {
                    DispatchQueue.main.async { if generation == self.hideGeneration { app.hide() } }
                } else if attempt < 50 {
                    hideQueue.asyncAfter(deadline: .now() + 0.01) { hideWhenInactive(attempt: attempt + 1) }
                }
            }
            hideQueue.async { hideWhenInactive(attempt: 0) }
        }
    }

    /// Cmd+Q in app mode: terminate the selected app and drop its tile, dismissing
    /// once none are left.
    private func quitSelectedApp() {
        guard mode == .apps, let item = panel.removeSelectedItem(), let appInfo = item.appInfo else { return }
        appInfo.app.terminate()
        shownPIDs.remove(appInfo.pid)
        if !panel.hasItems { dismissPanel() }
    }

    /// Cmd+W in window mode: close the selected window and drop its tile, staying
    /// open to close several in a row; dismisses once none are left.
    private func closeSelectedWindow() {
        guard mode == .windows, let item = panel.removeSelectedItem(), let window = item.window else { return }
        WindowListProvider.close(window)
        if !panel.hasItems { dismissPanel() }
    }

    private func dismissPanel() {
        stopAppListRefresh()
        panel.hidePanel()
        state = .idle
        hotkeyManager.isActive = false
        hotkeyManager.unregisterActiveHotkeys()  // so Cmd+H/Q work in other apps
    }

    /// While the app switcher is open, poll for apps that became visible since it
    /// opened and append them to the end — append-only, so it never reorders or
    /// fights the user's own hide/quit. On main (building each icon must be on main).
    private func startAppListRefresh() {
        guard appListRefreshTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.state == .active, self.mode == .apps else { return }
            let additions = AppListProvider.getVisibleApps().filter { !self.shownPIDs.contains($0.pid) }
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

    // - Switching & Accessibility permission

    /// Take over Cmd+Tab. Creates the event tap FIRST and takes the hotkeys only
    /// if that succeeds, so a permission failure never breaks the system.
    private func enableSwitching() {
        guard !switchingEnabled else { return }
        guard hotkeyManager.tryCreateEventTap() else { return }  // permission gate
        switchingEnabled = true
        reconcileHotkeys()
        NewWindowMaximizer.start()
        print("Switching enabled.")
    }

    /// Own a switcher's shortcut while switching is enabled or its mode is Disabled
    /// (a no-op that needs no permission). The native Cmd+Tab / Cmd+` is turned
    /// off only while an owned shortcut is exactly that combo.
    private func reconcileHotkeys() {
        let ownsApp = switchingEnabled || Preferences.appSwitcherMode == .disabled
        let ownsWindow = switchingEnabled || Preferences.windowSwitcherMode == .disabled
        hotkeyManager.setAppShortcut(ownsApp ? Preferences.appSwitcherShortcut : nil)
        hotkeyManager.setWindowShortcut(ownsWindow ? Preferences.windowSwitcherShortcut : nil)
        setNativeCommandTabEnabled(!(ownsApp && Preferences.appSwitcherShortcut == .defaultAppSwitcher), CGSSymbolicHotKey.appSwitcher)
        setNativeCommandTabEnabled(!(ownsWindow && Preferences.windowSwitcherShortcut == .defaultWindowSwitcher), CGSSymbolicHotKey.windowSwitcher)
    }

    /// Poll Accessibility permission and reconcile. A poll, not the tap-disabled
    /// callback: macOS doesn't reliably deliver that on revoke.
    private func startPermissionMonitor() {
        guard permissionTimer == nil else { return }
        // Disable App Nap so the timer keeps firing while we hold the tap; still
        // allow idle system sleep.
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

    /// Accessibility was revoked while we held the tap. Restore native Cmd+Tab and
    /// QUIT — terminating is the only reliable way to tear the tap out of the window
    /// server and clear the macOS input-freeze bug.
    private func handleRevocation() {
        guard !isHandlingRevocation else { return }
        isHandlingRevocation = true
        switchingEnabled = false
        setNativeCommandTabEnabled(true)
        hotkeyManager.stop()
        NSApp.terminate(nil)
    }

    // - Preferences & menu bar

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
