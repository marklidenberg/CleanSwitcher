import ApplicationServices

/// macOS Accessibility (AX) trust. The CGEvent tap requires it; native Cmd+Tab
/// must stay enabled until it's granted, so a first launch can't break switching.
enum AccessibilityPermission {

    /// Cheap and thread-safe; safe to call from the event-tap callback.
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Show the system prompt and register the app in the Accessibility list.
    /// Shown at most once per process, so call once at launch — then poll
    /// `isGranted`, never call this from a timer.
    @discardableResult
    static func prompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: kCFBooleanTrue as Any] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
