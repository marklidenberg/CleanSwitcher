import Cocoa
import Carbon

protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyTriggered()
    /// Cmd+Shift+Tab: open the switcher in reverse (from idle) or step backward
    /// (while active) — mirrors the native reverse-cycling gesture.
    func hotkeyTriggeredReverse()
    /// Cmd+`: open the window switcher (from idle), switch the app switcher into
    /// window mode for the selected app, or cycle windows (while already in it).
    func hotkeyTriggeredWindows()
    /// Cmd+Shift+`: same as hotkeyTriggeredWindows but cycling windows backward.
    func hotkeyTriggeredWindowsReverse()
    func modifierKeyReleased()
    func keyPressed(_ keyCode: UInt16)
    /// Shift pressed and released while Cmd is held, with no Shift+Tab in
    /// between — the legacy "tap Shift to go back" gesture. Fires on release so
    /// it can't double up with hotkeyTriggeredReverse.
    func shiftTapped()
    func mouseClicked()
}

class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    private static let signature: OSType = {
        "smpl".utf16.reduce(0) { ($0 << 8) + OSType($1) }
    }()

    private var hotKeyPressedHandler: EventHandlerRef?
    private var tabHotKeyRef: EventHotKeyRef?
    private var shiftTabHotKeyRef: EventHotKeyRef?
    // Two refs: the key left of "1" is a different virtual keycode on ANSI
    // (grave, 50) vs ISO (section, 10) MacBook keyboards; register both.
    private var windowSwitchHotKeyRef: EventHotKeyRef?
    private var windowSwitchISOHotKeyRef: EventHotKeyRef?
    private var windowSwitchReverseHotKeyRef: EventHotKeyRef?
    private var windowSwitchReverseISOHotKeyRef: EventHotKeyRef?
    private var activeHotKeyRefs: [EventHotKeyRef?] = []
    private var eventTap: CFMachPort?

    // Dedicated thread + run loop that services the event tap, so its callback is
    // never starved by main-thread UI work (see setupEventTap for rationale).
    private var eventTapThread: Thread?
    // Written by the tap thread, read by stop() — access only under stateQueue.
    // The flag covers the startup race: if stop() runs before the thread has
    // stored its run loop, the thread sees it and exits instead of running
    // unstoppable forever.
    private var _eventTapRunLoop: CFRunLoop?
    private var _tapStopRequested = false

    // Serial queue for thread-safe state access
    private let stateQueue = DispatchQueue(label: "com.cleanswitcher.state")

    // Backstop watchdog (see startCmdWatchdog) — polls live modifier state while
    // the panel is active in case the .listenOnly tap drops the Cmd-up event.
    private var cmdWatchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.cleanswitcher.cmdwatchdog")

    // State protected by stateQueue
    private var _isActive = false
    private var _shiftWasDown = false
    private var _tabSeenDuringShift = false

    var isActive: Bool {
        get { stateQueue.sync { _isActive } }
        set { stateQueue.sync { _isActive = newValue } }
    }

    private var shiftWasDown: Bool {
        get { stateQueue.sync { _shiftWasDown } }
        set { stateQueue.sync { _shiftWasDown = newValue } }
    }

    // Whether Cmd+Shift+Tab fired during the current Shift hold. Distinguishes
    // a bare Shift tap (select previous) from Shift held as part of Shift+Tab.
    private var tabSeenDuringShift: Bool {
        get { stateQueue.sync { _tabSeenDuringShift } }
        set { stateQueue.sync { _tabSeenDuringShift = newValue } }
    }

    // Hotkey IDs - using actual key codes for easy mapping
    private enum HotkeyID: UInt32 {
        case tab = 1        // Cmd+Tab - activate/next
        case h = 2          // Cmd+H - hide
        case q = 3          // Cmd+Q - quit
        case leftArrow = 4  // Cmd+Left - previous
        case rightArrow = 5 // Cmd+Right - next
        case escape = 6     // Cmd+Escape - dismiss
        case returnKey = 7  // Cmd+Return - activate
        case upArrow = 8    // Cmd+Up - previous row
        case downArrow = 9  // Cmd+Down - next row
        case shiftTab = 11  // Cmd+Shift+Tab - activate in reverse/previous
        case windowSwitch = 12 // Cmd+` - switch between the current app's windows
        case windowSwitchReverse = 13 // Cmd+Shift+` - cycle windows backward
        case w = 14         // Cmd+W - close the selected window (window mode)
        case t = 15         // Cmd+T - toggle the secondary (older apps) section
    }

    // Map hotkey IDs to key codes for delegate
    private static let hotkeyToKeyCode: [UInt32: UInt16] = [
        HotkeyID.tab.rawValue: UInt16(kVK_Tab),
        HotkeyID.h.rawValue: UInt16(kVK_ANSI_H),
        HotkeyID.q.rawValue: UInt16(kVK_ANSI_Q),
        HotkeyID.leftArrow.rawValue: UInt16(kVK_LeftArrow),
        HotkeyID.rightArrow.rawValue: UInt16(kVK_RightArrow),
        HotkeyID.upArrow.rawValue: UInt16(kVK_UpArrow),
        HotkeyID.downArrow.rawValue: UInt16(kVK_DownArrow),
        HotkeyID.escape.rawValue: UInt16(kVK_Escape),
        HotkeyID.returnKey.rawValue: UInt16(kVK_Return),
        HotkeyID.w.rawValue: UInt16(kVK_ANSI_W),
        HotkeyID.t.rawValue: UInt16(kVK_ANSI_T),
    ]

    // Ordinary Cmd+<key> combos that have no switcher action. Registered as no-op
    // Carbon hotkeys while the panel is open so they're swallowed instead of leaking
    // to the app behind the panel (e.g. Cmd+W closing a tab). Excludes the action
    // keys (Tab/H/Q/arrows/Escape/Return), which are registered separately.
    private static let swallowKeyCodes: [Int] = [
        kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_Z,
        kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B, kVK_ANSI_E,
        // (W and S are registered as active hotkeys, not swallowed)
        kVK_ANSI_R, kVK_ANSI_Y, kVK_ANSI_O, kVK_ANSI_U, kVK_ANSI_I,
        kVK_ANSI_P, kVK_ANSI_L, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_N, kVK_ANSI_M,
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
        kVK_ANSI_Backslash, kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_ANSI_Comma,
        kVK_ANSI_Period, kVK_ANSI_Slash,
        kVK_Space, kVK_Delete, kVK_ForwardDelete,
    ]

    // Continuous auto-repeat while a navigation key is physically held (so holding
    // Tab keeps advancing instead of stopping after one step). Implemented by
    // polling live key state — Carbon hotkeys don't deliver reliable repeat/release
    // events while held — on a dedicated queue, only while the panel is active.
    private var holdRepeatTimer: DispatchSourceTimer?
    private let holdRepeatQueue = DispatchQueue(label: "com.cleanswitcher.holdrepeat")
    private var heldKeyCode: Int = 0   // holdRepeatQueue only
    private var heldTicks: Int = 0     // holdRepeatQueue only

    func stop() {
        // Unregister tab hotkeys
        if let ref = tabHotKeyRef {
            UnregisterEventHotKey(ref)
            tabHotKeyRef = nil
        }
        if let ref = shiftTabHotKeyRef {
            UnregisterEventHotKey(ref)
            shiftTabHotKeyRef = nil
        }
        if let ref = windowSwitchHotKeyRef {
            UnregisterEventHotKey(ref)
            windowSwitchHotKeyRef = nil
        }
        if let ref = windowSwitchISOHotKeyRef {
            UnregisterEventHotKey(ref)
            windowSwitchISOHotKeyRef = nil
        }
        if let ref = windowSwitchReverseHotKeyRef {
            UnregisterEventHotKey(ref)
            windowSwitchReverseHotKeyRef = nil
        }
        if let ref = windowSwitchReverseISOHotKeyRef {
            UnregisterEventHotKey(ref)
            windowSwitchReverseISOHotKeyRef = nil
        }

        // Unregister active hotkeys
        unregisterActiveHotkeys()
        stopHoldRepeat()

        if let handler = hotKeyPressedHandler {
            RemoveEventHandler(handler)
            hotKeyPressedHandler = nil
        }
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
        // Stop the dedicated event-tap thread's run loop so the thread can exit
        stateQueue.sync {
            _tapStopRequested = true
            if let runLoop = _eventTapRunLoop {
                CFRunLoopStop(runLoop)
                _eventTapRunLoop = nil
            }
        }
        eventTapThread = nil
    }

    /// Register hotkeys that only work when panel is active (Cmd+H, Cmd+Q, etc.)
    func registerActiveHotkeys() {
        guard activeHotKeyRefs.isEmpty else { return }

        let eventTarget = GetEventDispatcherTarget()

        let hotkeys: [(HotkeyID, Int)] = [
            (.h, kVK_ANSI_H),
            (.q, kVK_ANSI_Q),
            (.w, kVK_ANSI_W),
            (.t, kVK_ANSI_T),
            (.leftArrow, kVK_LeftArrow),
            (.rightArrow, kVK_RightArrow),
            (.upArrow, kVK_UpArrow),
            (.downArrow, kVK_DownArrow),
            (.escape, kVK_Escape),
            (.returnKey, kVK_Return),
        ]

        for (hotkeyID, keyCode) in hotkeys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotkeyManager.signature, id: hotkeyID.rawValue)
            RegisterEventHotKey(UInt32(keyCode), UInt32(cmdKey), id, eventTarget, UInt32(kEventHotKeyNoOptions), &ref)
            activeHotKeyRefs.append(ref)
        }

        // Swallow every other ordinary Cmd+<key> combo so it doesn't leak to the
        // app behind the panel. These ids are absent from `hotkeyToKeyCode`, so the
        // Carbon handler no-ops them — registration alone consumes the keystroke.
        // The 0x1000 offset keeps the ids clear of the action ids (1–9).
        for keyCode in HotkeyManager.swallowKeyCodes {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotkeyManager.signature, id: UInt32(0x1000 + keyCode))
            RegisterEventHotKey(UInt32(keyCode), UInt32(cmdKey), id, eventTarget, UInt32(kEventHotKeyNoOptions), &ref)
            activeHotKeyRefs.append(ref)
        }

        // Second layer of the sticky-panel defense (the dedicated tap thread is
        // the first): a poll that dismisses even if the Cmd-up event is dropped.
        startCmdWatchdog()
        // Continuous auto-repeat while a navigation key stays held.
        startHoldRepeat()
    }

    /// Unregister active-only hotkeys so they work normally in other apps
    func unregisterActiveHotkeys() {
        stopCmdWatchdog()
        stopHoldRepeat()
        for ref in activeHotKeyRefs {
            if let ref = ref {
                UnregisterEventHotKey(ref)
            }
        }
        activeHotKeyRefs.removeAll()
    }

    // MARK: - Hotkey dispatch & auto-repeat

    /// Route a hotkey press to the delegate and arm auto-repeat for held
    /// navigation keys. Runs on the main run loop (the Carbon dispatch thread).
    func handleHotkeyPressed(_ id: UInt32) {
        switch id {
        case HotkeyID.tab.rawValue:
            // Cmd+Tab - activate switcher or select next
            isActive = true
            DispatchQueue.main.async { self.delegate?.hotkeyTriggered() }

        case HotkeyID.shiftTab.rawValue:
            // Cmd+Shift+Tab - activate switcher in reverse or select previous.
            // Marks the Shift hold so its release isn't also treated as a bare
            // Shift tap (which would double-step).
            isActive = true
            tabSeenDuringShift = true
            DispatchQueue.main.async { self.delegate?.hotkeyTriggeredReverse() }

        case HotkeyID.windowSwitch.rawValue:
            // Cmd+` - window switcher / cycle windows
            isActive = true
            DispatchQueue.main.async { self.delegate?.hotkeyTriggeredWindows() }

        case HotkeyID.windowSwitchReverse.rawValue:
            // Cmd+Shift+` - reverse window cycling. Marks the Shift hold so its
            // release isn't also treated as a bare Shift tap (which would double-step).
            isActive = true
            tabSeenDuringShift = true
            DispatchQueue.main.async { self.delegate?.hotkeyTriggeredWindowsReverse() }

        default:
            // Other hotkeys (H, Q, arrows, etc.) - only registered when active
            if let keyCode = HotkeyManager.hotkeyToKeyCode[id] {
                DispatchQueue.main.async { self.delegate?.keyPressed(keyCode) }
            }
        }
    }

    // MARK: - Hold-to-repeat

    /// While the panel is active, poll the live key state and, once a navigation
    /// key (Tab, Shift+Tab, ←/→) has been held past the initial delay, keep firing
    /// its action at the repeat interval. The first step is done by the Carbon
    /// press; this only drives the continuous repeats. Polling (not Carbon
    /// repeat/release events, which aren't reliably delivered while a hotkey is
    /// held) is what makes a held Tab actually keep advancing instead of sticking.
    private func startHoldRepeat() {
        guard holdRepeatTimer == nil else { return }
        let tick = 0.04
        let initialDelayTicks = max(1, Int((SwitcherConfig.repeatInitialDelay / tick).rounded()))
        let repeatTicks = max(1, Int((SwitcherConfig.repeatInterval / tick).rounded()))

        let timer = DispatchSource.makeTimerSource(queue: holdRepeatQueue)
        timer.schedule(deadline: .now() + tick, repeating: tick, leeway: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isActive else { return }

            let flags = CGEventSource.flagsState(.combinedSessionState)
            // Cmd must still be held; if not, dismissal is handled elsewhere.
            guard flags.contains(.maskCommand) else { self.heldKeyCode = 0; self.heldTicks = 0; return }
            let shift = flags.contains(.maskShift)

            func down(_ code: Int) -> Bool {
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
            }

            // Which navigation key is held, and what it repeats. The window-switch
            // key is intentionally excluded (repeating it in app mode would reopen
            // the window panel every tick).
            var code = 0
            var action: (() -> Void)?
            if down(kVK_Tab) {
                code = kVK_Tab
                action = shift
                    ? { [weak self] in self?.delegate?.hotkeyTriggeredReverse() }
                    : { [weak self] in self?.delegate?.hotkeyTriggered() }
            } else if down(kVK_LeftArrow) {
                code = kVK_LeftArrow
                action = { [weak self] in self?.delegate?.keyPressed(UInt16(kVK_LeftArrow)) }
            } else if down(kVK_RightArrow) {
                code = kVK_RightArrow
                action = { [weak self] in self?.delegate?.keyPressed(UInt16(kVK_RightArrow)) }
            }

            guard code != 0, let action = action else {
                self.heldKeyCode = 0
                self.heldTicks = 0
                return
            }

            if code == self.heldKeyCode {
                self.heldTicks += 1
                let past = self.heldTicks - initialDelayTicks
                if past >= 0 && past % repeatTicks == 0 {
                    DispatchQueue.main.async { action() }
                }
            } else {
                // Newly held — start counting; the Carbon press already did step one.
                self.heldKeyCode = code
                self.heldTicks = 0
            }
        }
        holdRepeatTimer = timer
        timer.resume()
    }

    private func stopHoldRepeat() {
        holdRepeatTimer?.cancel()
        holdRepeatTimer = nil
        holdRepeatQueue.async { [weak self] in
            self?.heldKeyCode = 0
            self?.heldTicks = 0
        }
    }

    // MARK: - Cmd-release Watchdog

    /// Backstop for a dropped Cmd-up event. Dismissal normally rides the
    /// `.listenOnly` tap's flagsChanged callback, but that single event can be
    /// lost — e.g. macOS disables the tap by timeout exactly as Cmd is released
    /// (re-enabled only afterward) — which leaves the panel stuck open. While the
    /// panel is active, poll the *live* modifier state and dismiss the moment Cmd
    /// is no longer physically held, independent of event delivery. The tap stays
    /// the instant primary path; this only catches the miss (worst case ~100ms).
    private func startCmdWatchdog() {
        guard cmdWatchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isActive else { return }
            let cmdDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
            if !cmdDown {
                self.isActive = false  // mirror the tap's immediate-set
                DispatchQueue.main.async {
                    self.delegate?.modifierKeyReleased()
                }
            }
        }
        cmdWatchdog = timer
        timer.resume()
    }

    private func stopCmdWatchdog() {
        cmdWatchdog?.cancel()
        cmdWatchdog = nil
    }

    // MARK: - Carbon Hotkey Registration

    /// Installs the Carbon event handler and registers the global Cmd+Tab hotkey.
    /// Paired with `stop()`, which removes both — so this can be called again to
    /// re-enable switching after a permission revoke.
    func registerHotkeys() {
        let eventTarget = GetEventDispatcherTarget()

        var eventTypes = [EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )]

        let handler: EventHandlerUPP = { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )

            if let userData = userData {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handleHotkeyPressed(id.id)
            }
            return noErr
        }

        let userDataPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(eventTarget, handler, eventTypes.count, &eventTypes, userDataPtr, &hotKeyPressedHandler)

        // Only register Cmd+Tab / Cmd+Shift+Tab at startup - other hotkeys
        // registered when panel is active. Carbon hotkeys need an exact modifier
        // match, so the Shift variant must be its own registration — without it,
        // Cmd+Shift+Tab (whose native handler we disable) would do nothing.
        let id = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyID.tab.rawValue)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey), id, eventTarget, UInt32(kEventHotKeyNoOptions), &tabHotKeyRef)
        let shiftId = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyID.shiftTab.rawValue)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey | shiftKey), shiftId, eventTarget, UInt32(kEventHotKeyNoOptions), &shiftTabHotKeyRef)

        // Cmd + the key left of "1" — window switcher. Registered globally like
        // Cmd+Tab so it works from idle and while the panel is open; the native
        // hotkey is already disabled by setNativeCommandTabEnabled (commandKeyAboveTab).
        // That physical key is grave (50) on ANSI keyboards but section (10) on ISO
        // MacBooks, so register both so it works "left of 1" on any layout.
        let windowId = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyID.windowSwitch.rawValue)
        RegisterEventHotKey(UInt32(kVK_ANSI_Grave), UInt32(cmdKey), windowId, eventTarget, UInt32(kEventHotKeyNoOptions), &windowSwitchHotKeyRef)
        RegisterEventHotKey(UInt32(kVK_ISO_Section), UInt32(cmdKey), windowId, eventTarget, UInt32(kEventHotKeyNoOptions), &windowSwitchISOHotKeyRef)

        // Cmd+Shift+ same key — reverse window cycling (mirrors Cmd+Shift+Tab).
        let windowReverseId = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyID.windowSwitchReverse.rawValue)
        RegisterEventHotKey(UInt32(kVK_ANSI_Grave), UInt32(cmdKey | shiftKey), windowReverseId, eventTarget, UInt32(kEventHotKeyNoOptions), &windowSwitchReverseHotKeyRef)
        RegisterEventHotKey(UInt32(kVK_ISO_Section), UInt32(cmdKey | shiftKey), windowReverseId, eventTarget, UInt32(kEventHotKeyNoOptions), &windowSwitchReverseISOHotKeyRef)
    }

    // MARK: - Event Tap (for modifier release and mouse clicks only)
    // Note: keyDown removed - using Carbon hotkeys instead (only requires Accessibility permission)

    /// Creates the CGEvent tap. Returns true on success (or if already created).
    /// Returns false when `CGEvent.tapCreate` fails — which happens when
    /// Accessibility permission is not granted. The caller uses this as the gate:
    /// native Cmd+Tab is only disabled once this succeeds.
    @discardableResult
    func tryCreateEventTap() -> Bool {
        // Idempotent: never create a second tap / run-loop source.
        if eventTap != nil { return true }

        // Only listen for flagsChanged and mouse clicks
        // keyDown events require Input Monitoring permission, so we use Carbon hotkeys instead
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo = userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .flagsChanged {
                let flags = event.flags

                // Detect shift key tap (press then release while Cmd is held)
                let shiftIsDown = flags.contains(.maskShift)
                let cmdIsDown = flags.contains(.maskCommand)

                if cmdIsDown {
                    if shiftIsDown && !manager.shiftWasDown {
                        // Fresh Shift hold while Cmd is held. Don't act yet —
                        // the release decides between a bare tap (select
                        // previous) and Shift+Tab (the shiftTab hotkey, which
                        // marks tabSeenDuringShift so we stay silent here).
                        manager.tabSeenDuringShift = false
                    } else if !shiftIsDown && manager.shiftWasDown && !manager.tabSeenDuringShift {
                        // Bare Shift tap: pressed and released with no Tab.
                        DispatchQueue.main.async {
                            manager.delegate?.shiftTapped()
                        }
                    }
                    manager.shiftWasDown = shiftIsDown
                }

                // Check if Command key was released
                if !cmdIsDown {
                    manager.shiftWasDown = false
                    // Set inactive immediately
                    manager.isActive = false
                    DispatchQueue.main.async {
                        manager.delegate?.modifierKeyReleased()
                    }
                }
            } else if type == .leftMouseDown || type == .rightMouseDown {
                if manager.isActive {
                    DispatchQueue.main.async {
                        manager.delegate?.mouseClicked()
                    }
                    // NOTE: the tap is .listenOnly (so revoking Accessibility can
                    // never freeze input), which means we CANNOT consume the click.
                    // Clicks outside the panel are swallowed by AppSwitcherPanel's
                    // per-screen click shields instead; this callback stays the
                    // primary dismiss/activate path.
                }
            } else if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                // Benign: macOS disables the tap after heavy input or a timeout —
                // just re-enable it. (Revocation is handled by AppDelegate's
                // permission poll, because macOS does NOT reliably deliver this
                // event when Accessibility permission is revoked.)
                if let eventTap = manager.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }

            return Unmanaged.passUnretained(event)
        }

        let userDataPtr = Unmanaged.passUnretained(self).toOpaque()

        // .listenOnly (passive): the window server never waits on this tap, so
        // revoking Accessibility while it's alive cannot freeze input. The cost is
        // we can't consume events (see the mouseDown branch above).
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: userDataPtr
        )

        guard let eventTap = eventTap else {
            print("Event tap not created — Accessibility permission not yet granted. Waiting…")
            return false
        }

        // Service the tap on a dedicated, high-priority thread with its own run loop.
        // Previously the source was added to the main run loop, so the Cmd-release
        // callback competed with main-thread UI work (loading icons, building the
        // panel). When that work ran long, macOS disabled the tap by timeout and the
        // Cmd-up event was lost — leaving the switcher panel stuck open. A dedicated
        // thread keeps the callback responsive regardless of what the UI is doing.
        stateQueue.sync { _tapStopRequested = false }
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            // Store the run loop and check for an early stop() in one critical
            // section, so a stop can never fall between the two.
            let shouldRun: Bool = self.stateQueue.sync {
                self._eventTapRunLoop = CFRunLoopGetCurrent()
                return !self._tapStopRequested
            }
            guard shouldRun else { return }
            CGEvent.tapEnable(tap: eventTap, enable: true)
            print("Event tap created successfully")
            CFRunLoopRun()
        }
        thread.name = "com.cleanswitcher.eventtap"
        thread.qualityOfService = .userInteractive
        eventTapThread = thread
        thread.start()
        return true
    }
}
