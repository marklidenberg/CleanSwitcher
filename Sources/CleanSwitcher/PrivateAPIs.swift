import Foundation
import ApplicationServices

// - CGSSetSymbolicHotKeyEnabled — toggle system hotkeys like Cmd+Tab (SkyLight)
//   The effect outlives the process, so it must be restored on exit.

enum CGSSymbolicHotKey: Int, CaseIterable {
    case commandTab = 1
    case commandShiftTab = 2
    case commandKeyAboveTab = 6
}

@_silgen_name("CGSSetSymbolicHotKeyEnabled") @discardableResult
func CGSSetSymbolicHotKeyEnabled(_ hotKey: CGSSymbolicHotKey.RawValue, _ isEnabled: Bool) -> Int32

func setNativeCommandTabEnabled(_ isEnabled: Bool) {
    for hotkey in CGSSymbolicHotKey.allCases {
        CGSSetSymbolicHotKeyEnabled(hotkey.rawValue, isEnabled)
    }
}

// - _AXUIElementGetWindow — AXUIElement window → CGWindowID (HIServices)
//   The only stable identity for keying per-window focus times.

@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
