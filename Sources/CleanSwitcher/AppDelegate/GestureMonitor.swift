import CoreGraphics
import Foundation

/// Trackpad swipes with 3 or 4 fingers — left, right, up, down — read off the private
/// MultitouchSupport framework, every touch frame, no permission. One swipe → one `onSwipe`.
/// While a configured swipe is on — and its momentum after — an event tap drops the scroll and
/// gesture events, so the window under the cursor doesn't scroll (needs Accessibility).
final class GestureMonitor {
    var onSwipe: ((Int, Gesture.Swipe) -> Void)?

    private static var shared: GestureMonitor?
    private static let distance: Float = 0.12       // of the trackpad's width or height
    private static let claimDistance: Float = 0.02  // enough to tell the way, early
    private var started = false
    private var devices: [AnyObject] = []  // held: the framework drops a device nobody holds
    private var swipe: (fingers: Int, x: Float, y: Float, fired: Bool, claimed: Bool)?
    private var tap: CFMachPort?
    private let lock = NSLock()
    private var blockUntil: TimeInterval = 0  // lock only
    private var blockMomentum = false         // lock only; the tap's thread

    // - The framework's touch, as it lays one out

    private struct Point { var x: Float; var y: Float }
    private struct Vector { var position: Point; var velocity: Point }
    private struct Touch {
        var frame: Int32; var timestamp: Double; var identifier: Int32; var state: Int32; var fingerID: Int32; var handID: Int32
        var normalized: Vector; var size: Float; var zero1: Int32; var angle: Float; var majorAxis: Float; var minorAxis: Float
        var absolute: Vector; var zero2: (Int32, Int32); var density: Float
    }
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

    /// Every trackpad, watched, and the scroll-dropping tap; idempotent — call again once
    /// Accessibility is granted. False where the framework isn't there.
    @discardableResult
    func start() -> Bool {
        if tap == nil { startTap() }
        if started { return true }
        guard let framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createList = dlsym(framework, "MTDeviceCreateList"), let register = dlsym(framework, "MTRegisterContactFrameCallback"),
              let deviceStart = dlsym(framework, "MTDeviceStart") else { return false }
        typealias CreateList = @convention(c) () -> Unmanaged<CFArray>
        typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
        typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
        GestureMonitor.shared = self
        let callback: Callback = { _, touches, count, _, _ in
            GestureMonitor.shared?.frame(touches?.assumingMemoryBound(to: Touch.self), Int(count))
            return 0
        }
        devices = unsafeBitCast(createList, to: CreateList.self)().takeRetainedValue() as [AnyObject]
        for device in devices {
            let pointer = Unmanaged.passUnretained(device).toOpaque()
            unsafeBitCast(register, to: Register.self)(pointer, callback)
            unsafeBitCast(deviceStart, to: Start.self)(pointer, 0)
        }
        started = true
        return true
    }

    /// A frame of touches (the framework's thread): 3 or 4 fingers down start a swipe;
    /// their center moved far enough, mostly one way, fires it, once. y grows upward.
    /// A swipe that heads a configured way is claimed early on: from then its scroll and
    /// gesture events are dropped — any other swipe is left to the system (Mission Control, App Exposé…).
    private func frame(_ touches: UnsafeMutablePointer<Touch>?, _ count: Int) {
        guard let touches = touches, count >= 3, count <= 4 else { swipe = nil; return }
        var x: Float = 0, y: Float = 0
        for k in 0..<count { x += touches[k].normalized.position.x; y += touches[k].normalized.position.y }
        x /= Float(count); y /= Float(count)
        guard let current = swipe, current.fingers == count else { swipe = (count, x, y, false, false); return }
        let dx = x - current.x, dy = y - current.y

        // - Claimed: dropping, while the fingers are down

        if !current.claimed, let heading = Self.way(dx, dy, beyond: Self.claimDistance),
           [Preferences.appsGesture, Preferences.appSwitcherGesture, Preferences.windowSwitcherGesture].contains(where: { $0?.matches(fingers: count, heading) == true }) {
            swipe?.claimed = true
        }
        if swipe?.claimed == true { lock.lock(); blockUntil = ProcessInfo.processInfo.systemUptime + 0.25; blockMomentum = true; lock.unlock() }

        // - Fired: once

        guard !current.fired, let swiped = Self.way(dx, dy, beyond: Self.distance) else { return }
        swipe?.fired = true
        DispatchQueue.main.async { self.onSwipe?(count, swiped) }
    }

    /// Moved past `distance`, mostly one way.
    private static func way(_ dx: Float, _ dy: Float, beyond distance: Float) -> Gesture.Swipe? {
        abs(dx) > distance && abs(dx) > 2 * abs(dy) ? (dx < 0 ? .left : .right)
            : abs(dy) > distance && abs(dy) > 2 * abs(dx) ? (dy > 0 ? .up : .down) : nil
    }

    // - Dropping the scroll

    /// An active tap on its own thread, for scroll and gesture events only.
    private func startTap() {
        let types: [CGEventType] = [.scrollWheel] + [18, 19, 20, 29, 30, 31, 32].compactMap { CGEventType(rawValue: $0) }  // rotate, begin/end gesture, gesture, magnify, swipe, smart magnify
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        let callback: CGEventTapCallBack = { _, type, event, info in
            let monitor = Unmanaged<GestureMonitor>.fromOpaque(info!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { monitor.tap.map { CGEvent.tapEnable(tap: $0, enable: true) }; return Unmanaged.passUnretained(event) }
            return monitor.drops(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread { CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes); CFRunLoopRun() }
        thread.name = "GestureMonitor.tap"
        thread.start()
    }

    /// While the fingers are down; then a scroll's momentum — until a new scroll begins.
    private func drops(_ type: CGEventType, _ event: CGEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if ProcessInfo.processInfo.systemUptime < blockUntil { return true }
        guard type == .scrollWheel else { return false }
        if event.getIntegerValueField(.scrollWheelEventScrollPhase) == 1 { blockMomentum = false }  // began
        return blockMomentum && event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
    }
}
