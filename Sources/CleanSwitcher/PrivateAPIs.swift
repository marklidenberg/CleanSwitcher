import Foundation
import ApplicationServices

// Private API for disabling native Cmd+Tab
// Location: SkyLight.framework (private framework)

enum CGSSymbolicHotKey: Int, CaseIterable {
    case commandTab = 1
    case commandShiftTab = 2
    case commandKeyAboveTab = 6
}

/// Enables/disables system symbolic hotkeys (like Cmd+Tab)
/// Note: The effect persists after the app quits, so we must restore on exit
@_silgen_name("CGSSetSymbolicHotKeyEnabled") @discardableResult
func CGSSetSymbolicHotKeyEnabled(_ hotKey: CGSSymbolicHotKey.RawValue, _ isEnabled: Bool) -> Int32

func setNativeCommandTabEnabled(_ isEnabled: Bool) {
    for hotkey in CGSSymbolicHotKey.allCases {
        CGSSetSymbolicHotKeyEnabled(hotkey.rawValue, isEnabled)
    }
}

// Private AX call that maps an AXUIElement window to its CGWindowID — the only
// stable, comparable identity for a window across separate AX queries. Used to
// key per-window focus times (see WindowFocusTracker). Location: HIServices.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
