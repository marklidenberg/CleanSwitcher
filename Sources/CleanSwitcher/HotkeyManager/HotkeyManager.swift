import Cocoa
import Carbon

protocol HotkeyManagerDelegate: AnyObject {
    /// App shortcut (Cmd+Tab): open (from idle) or step forward (while active).
    func hotkeyTriggered()
    /// App shortcut + Shift: open in reverse (from idle) or step backward (while active).
    func hotkeyTriggeredReverse()
    /// Window shortcut (Cmd+`): open the window switcher, dive into the selected
    /// app's windows, or cycle windows (depending on state).
    func hotkeyTriggeredWindows()
    /// Window shortcut + Shift: hotkeyTriggeredWindows cycling backward.
    func hotkeyTriggeredWindowsReverse()
    func modifierKeyReleased()
    func keyPressed(_ keyCode: UInt16)
    /// Shift tapped while the hold modifiers are down, no Shift+Tab in between —
    /// "select previous".
    func shiftTapped()
    func mouseClicked()
}

/// Global hotkeys + the modifier/mouse event tap. See HotkeyManager.md.
class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    private static let signature: OSType = {
        "smpl".utf16.reduce(0) { ($0 << 8) + OSType($1) }
    }()

    private var hotKeyPressedHandler: EventHandlerRef?
    private var appShortcut: Shortcut?
    private var windowShortcut: Shortcut?
    private var appHotKeyRefs: [EventHotKeyRef] = []
    private var windowHotKeyRefs: [EventHotKeyRef] = []
    private var activeHotKeyRefs: [EventHotKeyRef?] = []
    // The shortcut that opened the panel — its modifiers keep it open (main only).
    private var holdShortcut = Shortcut.defaultAppSwitcher
    private var eventTap: CFMachPort?

    // Dedicated thread + run loop that services the event tap, so its callback is
    // never starved by main-thread UI work. `_tapStopRequested` covers the startup
    // race: a stop() before the thread stores its run loop makes the thread exit.
    private var eventTapThread: Thread?
    private var _eventTapRunLoop: CFRunLoop?      // stateQueue only
    private var _tapStopRequested = false         // stateQueue only

    private let stateQueue = DispatchQueue(label: "com.cleanswitcher.state")

    private var holdWatchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.cleanswitcher.holdwatchdog")

    // State protected by stateQueue.
    private var _isActive = false
    private var _holdFlags = Shortcut.defaultAppSwitcher.holdFlags
    private var _shiftWasDown = false
    private var _tabSeenDuringShift = false

    var isActive: Bool {
        get { stateQueue.sync { _isActive } }
        set { stateQueue.sync { _isActive = newValue } }
    }

    private var holdFlags: CGEventFlags {
        get { stateQueue.sync { _holdFlags } }
        set { stateQueue.sync { _holdFlags = newValue } }
    }

    private var shiftWasDown: Bool {
        get { stateQueue.sync { _shiftWasDown } }
        set { stateQueue.sync { _shiftWasDown = newValue } }
    }

    // Whether a reverse hotkey fired during the current Shift hold — distinguishes a
    // bare Shift tap from Shift held as part of Shift+Tab.
    private var tabSeenDuringShift: Bool {
        get { stateQueue.sync { _tabSeenDuringShift } }
        set { stateQueue.sync { _tabSeenDuringShift = newValue } }
    }

    private enum HotkeyID: UInt32 {
        case tab = 1
        case h = 2
        case q = 3
        case leftArrow = 4
        case rightArrow = 5
        case escape = 6
        case returnKey = 7
        case upArrow = 8
        case downArrow = 9
        case shiftTab = 11
        case windowSwitch = 12
        case windowSwitchReverse = 13
        case w = 14
        case t = 15
        case tabNavigate = 16       // Tab while active, when the app shortcut isn't Tab
        case shiftTabNavigate = 17
    }

    // Hotkeys that map to a delegate keyPressed(_:) call.
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

    // Ordinary hold+key combos with no switcher action. Registered as no-op Carbon
    // hotkeys while the panel is open so they're swallowed instead of leaking to
    // the app behind it. Excludes the action keys and W/T (registered separately).
    private static let swallowKeyCodes: [Int] = [
        kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_Z,
        kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B, kVK_ANSI_E,
        kVK_ANSI_R, kVK_ANSI_Y, kVK_ANSI_O, kVK_ANSI_U, kVK_ANSI_I,
        kVK_ANSI_P, kVK_ANSI_L, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_N, kVK_ANSI_M,
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
        kVK_ANSI_Backslash, kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_ANSI_Comma,
        kVK_ANSI_Period, kVK_ANSI_Slash,
        kVK_Space, kVK_Delete, kVK_ForwardDelete,
    ]

    // Hold-to-repeat state (holdRepeatQueue only).
    private var holdRepeatTimer: DispatchSourceTimer?
    private let holdRepeatQueue = DispatchQueue(label: "com.cleanswitcher.holdrepeat")
    private var heldKeyCode: Int = 0
    private var heldTicks: Int = 0

    func stop() {
        // - Unregister the global hotkeys

        setAppShortcut(nil)
        setWindowShortcut(nil)

        // - Unregister the active-only hotkeys and stop repeats

        unregisterActiveHotkeys()
        stopHoldRepeat()

        // - Remove the Carbon handler and disable the tap

        if let handler = hotKeyPressedHandler {
            RemoveEventHandler(handler)
            hotKeyPressedHandler = nil
        }
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }

        // - Stop the tap thread's run loop so the thread can exit

        stateQueue.sync {
            _tapStopRequested = true
            if let runLoop = _eventTapRunLoop {
                CFRunLoopStop(runLoop)
                _eventTapRunLoop = nil
            }
        }
        eventTapThread = nil
    }

    /// Register the hotkeys that only work while the panel is active — with the
    /// hold modifiers of the shortcut that opened it — then start the watchdog and
    /// hold-repeat. A combo already taken (e.g. Tab when the app shortcut is
    /// Cmd+Tab) fails to register and the global hotkey handles it instead.
    func registerActiveHotkeys() {
        guard activeHotKeyRefs.isEmpty else { return }
        let eventTarget = GetEventDispatcherTarget()
        let modifiers = holdShortcut.carbonModifiers

        // - Action hotkeys

        let hotkeys: [(HotkeyID, Int, Int)] = [
            (.h, kVK_ANSI_H, modifiers), (.q, kVK_ANSI_Q, modifiers), (.w, kVK_ANSI_W, modifiers), (.t, kVK_ANSI_T, modifiers),
            (.leftArrow, kVK_LeftArrow, modifiers), (.rightArrow, kVK_RightArrow, modifiers),
            (.upArrow, kVK_UpArrow, modifiers), (.downArrow, kVK_DownArrow, modifiers),
            (.escape, kVK_Escape, modifiers), (.returnKey, kVK_Return, modifiers),
            (.tabNavigate, kVK_Tab, modifiers), (.shiftTabNavigate, kVK_Tab, modifiers | shiftKey),
        ]
        for (hotkeyID, keyCode, keyModifiers) in hotkeys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotkeyManager.signature, id: hotkeyID.rawValue)
            RegisterEventHotKey(UInt32(keyCode), UInt32(keyModifiers), id, eventTarget, UInt32(kEventHotKeyNoOptions), &ref)
            activeHotKeyRefs.append(ref)
        }

        // - Swallow every other hold+key combo (ids absent from hotkeyToKeyCode →
        //   the handler no-ops them; the 0x1000 offset keeps them off the action ids)

        for keyCode in HotkeyManager.swallowKeyCodes {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotkeyManager.signature, id: UInt32(0x1000 + keyCode))
            RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, eventTarget, UInt32(kEventHotKeyNoOptions), &ref)
            activeHotKeyRefs.append(ref)
        }

        startHoldWatchdog()
        startHoldRepeat()
    }

    func unregisterActiveHotkeys() {
        stopHoldWatchdog()
        stopHoldRepeat()
        for ref in activeHotKeyRefs where ref != nil { UnregisterEventHotKey(ref!) }
        activeHotKeyRefs.removeAll()
    }

    /// Route a hotkey press to the delegate. Runs on the Carbon dispatch thread
    /// (main). A press from idle makes its shortcut the hold shortcut.
    func handleHotkeyPressed(_ id: UInt32) {
        func open(with shortcut: Shortcut?) {
            if !isActive, let shortcut = shortcut {
                holdShortcut = shortcut
                holdFlags = shortcut.holdFlags
            }
            isActive = true
        }

        switch id {
        case HotkeyID.tab.rawValue, HotkeyID.tabNavigate.rawValue:
            open(with: appShortcut)
            DispatchQueue.main.async { self.delegate?.hotkeyTriggered() }

        case HotkeyID.shiftTab.rawValue, HotkeyID.shiftTabNavigate.rawValue:
            // Mark the Shift hold so its release isn't also read as a bare tap.
            open(with: appShortcut)
            tabSeenDuringShift = true
            DispatchQueue.main.async { self.delegate?.hotkeyTriggeredReverse() }

        case HotkeyID.windowSwitch.rawValue:
            open(with: windowShortcut)
            DispatchQueue.main.async { self.delegate?.hotkeyTriggeredWindows() }

        case HotkeyID.windowSwitchReverse.rawValue:
            open(with: windowShortcut)
            tabSeenDuringShift = true
            DispatchQueue.main.async { self.delegate?.hotkeyTriggeredWindowsReverse() }

        default:
            if let keyCode = HotkeyManager.hotkeyToKeyCode[id] {
                DispatchQueue.main.async { self.delegate?.keyPressed(keyCode) }
            }
        }
    }

    // - Hold-to-repeat
    //   Poll live key state; once a navigation key is held past the initial delay,
    //   keep firing its action. The first step is the Carbon press; this drives the
    //   continuous repeats (Carbon doesn't deliver reliable repeats while held).

    private func startHoldRepeat() {
        guard holdRepeatTimer == nil else { return }
        let tick = 0.04
        let initialDelayTicks = max(1, Int((SwitcherConfig.repeatInitialDelay / tick).rounded()))
        let repeatTicks = max(1, Int((SwitcherConfig.repeatInterval / tick).rounded()))
        let holdFlags = self.holdFlags
        let appKeyCode = appShortcut?.keyCode ?? kVK_Tab

        let timer = DispatchSource.makeTimerSource(queue: holdRepeatQueue)
        timer.schedule(deadline: .now() + tick, repeating: tick, leeway: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isActive else { return }

            // - The hold modifiers must still be held

            let flags = CGEventSource.flagsState(.combinedSessionState)
            guard flags.contains(holdFlags) else { self.heldKeyCode = 0; self.heldTicks = 0; return }
            let shift = flags.contains(.maskShift)
            func down(_ code: Int) -> Bool { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) }

            // - Which navigation key is held, and what it repeats (window-switch key
            //   excluded — repeating it in app mode would reopen the window panel)

            var code = 0
            var action: (() -> Void)?
            if down(kVK_Tab) || down(appKeyCode) {
                code = down(kVK_Tab) ? kVK_Tab : appKeyCode
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
                self.heldKeyCode = 0; self.heldTicks = 0
                return
            }

            // - Count ticks past the initial delay, then fire at the repeat interval

            if code == self.heldKeyCode {
                self.heldTicks += 1
                let past = self.heldTicks - initialDelayTicks
                if past >= 0 && past % repeatTicks == 0 { DispatchQueue.main.async { action() } }
            } else {
                self.heldKeyCode = code  // newly held — the Carbon press did step one
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

    // - Hold-release watchdog
    //   Backstop for a dropped modifier-up event: poll the live modifier state and
    //   dismiss the moment the hold modifiers are no longer physically held.

    private func startHoldWatchdog() {
        guard holdWatchdog == nil else { return }
        let holdFlags = self.holdFlags
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isActive else { return }
            if !CGEventSource.flagsState(.combinedSessionState).contains(holdFlags) {
                self.isActive = false  // mirror the tap's immediate-set
                DispatchQueue.main.async { self.delegate?.modifierKeyReleased() }
            }
        }
        holdWatchdog = timer
        timer.resume()
    }

    private func stopHoldWatchdog() {
        holdWatchdog?.cancel()
        holdWatchdog = nil
    }

    /// Register the app switcher's global hotkey (+ its Shift variant); nil
    /// unregisters. Idempotent.
    func setAppShortcut(_ shortcut: Shortcut?) {
        guard shortcut != appShortcut else { return }
        appHotKeyRefs.forEach { UnregisterEventHotKey($0) }
        appHotKeyRefs = shortcut.map { registerGlobalHotkeys($0, .tab, reverse: .shiftTab) } ?? []
        appShortcut = shortcut
    }

    /// Register the window switcher's global hotkey (+ its Shift variant); nil
    /// unregisters. Idempotent.
    func setWindowShortcut(_ shortcut: Shortcut?) {
        guard shortcut != windowShortcut else { return }
        windowHotKeyRefs.forEach { UnregisterEventHotKey($0) }
        windowHotKeyRefs = shortcut.map { registerGlobalHotkeys($0, .windowSwitch, reverse: .windowSwitchReverse) } ?? []
        windowShortcut = shortcut
    }

    /// Carbon needs an exact modifier match, so the Shift variant is its own registration.
    private func registerGlobalHotkeys(_ shortcut: Shortcut, _ hotkeyID: HotkeyID, reverse reverseID: HotkeyID) -> [EventHotKeyRef] {
        installHotkeyHandlerIfNeeded()
        let registrations = shortcut.keyCodes.flatMap { [($0, shortcut.carbonModifiers, hotkeyID), ($0, shortcut.carbonModifiers | shiftKey, reverseID)] }
        return registrations.compactMap { keyCode, modifiers, id in
            var ref: EventHotKeyRef?
            let hotkeyID = EventHotKeyID(signature: HotkeyManager.signature, id: id.rawValue)
            RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotkeyID, GetEventDispatcherTarget(), UInt32(kEventHotKeyNoOptions), &ref)
            return ref
        }
    }

    /// Install the Carbon handler that forwards presses to handleHotkeyPressed.
    private func installHotkeyHandlerIfNeeded() {
        guard hotKeyPressedHandler == nil else { return }
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))]
        let handler: EventHandlerUPP = { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let userData = userData {
                Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue().handleHotkeyPressed(id.id)
            }
            return noErr
        }
        let userDataPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), handler, eventTypes.count, &eventTypes, userDataPtr, &hotKeyPressedHandler)
    }

    /// Create the `.listenOnly` CGEvent tap (modifier release + mouse clicks).
    /// Returns false when `CGEvent.tapCreate` fails (Accessibility not granted) —
    /// the caller uses this as the gate before disabling native Cmd+Tab.
    @discardableResult
    func tryCreateEventTap() -> Bool {
        if eventTap != nil { return true }  // idempotent

        // keyDown would need Input Monitoring, so only flags + mouse here.
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .flagsChanged {
                let flags = event.flags
                let shiftIsDown = flags.contains(.maskShift)
                let holdIsDown = flags.contains(manager.holdFlags)

                // - Detect a bare Shift tap while the hold modifiers are down

                if holdIsDown {
                    if shiftIsDown && !manager.shiftWasDown {
                        // Fresh Shift hold — the release decides between a bare tap
                        // and Shift+Tab (which marks tabSeenDuringShift).
                        manager.tabSeenDuringShift = false
                    } else if !shiftIsDown && manager.shiftWasDown && !manager.tabSeenDuringShift {
                        DispatchQueue.main.async { manager.delegate?.shiftTapped() }
                    }
                    manager.shiftWasDown = shiftIsDown
                }

                // - Hold modifiers released → dismiss

                if !holdIsDown {
                    manager.shiftWasDown = false
                    manager.isActive = false
                    DispatchQueue.main.async { manager.delegate?.modifierKeyReleased() }
                }
            } else if type == .leftMouseDown || type == .rightMouseDown {
                // Can't consume (.listenOnly); outside clicks are caught by the
                // panel's shields, this stays the dismiss/activate path.
                if manager.isActive {
                    DispatchQueue.main.async { manager.delegate?.mouseClicked() }
                }
            } else if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                // macOS disabled the tap after heavy input / timeout — re-enable.
                // (Revocation is handled by AppDelegate's poll; this event isn't
                // reliably delivered on revoke.)
                if let eventTap = manager.eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            }

            return Unmanaged.passUnretained(event)
        }

        let userDataPtr = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask), callback: callback, userInfo: userDataPtr
        )
        guard let eventTap = eventTap else {
            print("Event tap not created — Accessibility permission not yet granted. Waiting…")
            return false
        }

        // - Service the tap on a dedicated high-priority thread + run loop, so the
        //   hold-release callback isn't starved by main-thread UI work

        stateQueue.sync { _tapStopRequested = false }
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            // Store the run loop and check for an early stop() in one critical
            // section, so a stop can't fall between the two.
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
