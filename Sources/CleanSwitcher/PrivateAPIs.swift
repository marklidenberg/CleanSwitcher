import Foundation
import ApplicationServices

// - CGSSetSymbolicHotKeyEnabled — toggle system hotkeys like Cmd+Tab (SkyLight)
//   The effect outlives the process, so it must be restored on exit.

enum CGSSymbolicHotKey: Int, CaseIterable {
    case commandTab = 1
    case commandShiftTab = 2
    case commandKeyAboveTab = 6

    static let appSwitcher: [Self] = [.commandTab, .commandShiftTab]
    static let windowSwitcher: [Self] = [.commandKeyAboveTab]
}

@_silgen_name("CGSSetSymbolicHotKeyEnabled") @discardableResult
func CGSSetSymbolicHotKeyEnabled(_ hotKey: CGSSymbolicHotKey.RawValue, _ isEnabled: Bool) -> Int32

func setNativeCommandTabEnabled(_ isEnabled: Bool, _ hotkeys: [CGSSymbolicHotKey] = CGSSymbolicHotKey.allCases) {
    for hotkey in hotkeys {
        CGSSetSymbolicHotKeyEnabled(hotkey.rawValue, isEnabled)
    }
}

// - _AXUIElementGetWindow — AXUIElement window → CGWindowID (HIServices)
//   The only stable identity for keying per-window focus times.

@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
