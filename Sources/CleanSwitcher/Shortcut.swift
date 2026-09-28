import Cocoa
import Carbon

/// A switcher hotkey: a key plus ⌘ / ⌥ / ⌃ (at least one). Shift is reserved —
/// the same shortcut + Shift goes backward. Its modifiers are what must stay held
/// to keep the panel open.
struct Shortcut: Equatable {
    let keyCode: Int
    let modifiers: NSEvent.ModifierFlags

    static let holdModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
    static let defaultAppSwitcher = Shortcut(keyCode: kVK_Tab, modifiers: .command)
    static let defaultWindowSwitcher = Shortcut(keyCode: kVK_ANSI_Grave, modifiers: .command)
    static let defaultApps = Shortcut(keyCode: kVK_Space, modifiers: .option)

    /// The modifier keys the Apps shortcut can be, tapped alone — its key code, no modifiers.
    static let tapKeys: [Int: String] = [kVK_Option: "Left ⌥", kVK_RightOption: "Right ⌥", kVK_Command: "Left ⌘", kVK_RightCommand: "Right ⌘"]

    var isTap: Bool { Shortcut.tapKeys[keyCode] != nil }

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Shortcut.holdModifiers)
    }

    static func == (a: Shortcut, b: Shortcut) -> Bool {
        a.keyCodes == b.keyCodes && a.modifiers == b.modifiers
    }

    /// The key left of "1" is grave (ANSI) or section (ISO) — register both.
    var keyCodes: [Int] {
        [kVK_ANSI_Grave, kVK_ISO_Section].contains(keyCode) ? [kVK_ANSI_Grave, kVK_ISO_Section] : [keyCode]
    }

    var carbonModifiers: Int {
        (modifiers.contains(.command) ? cmdKey : 0) | (modifiers.contains(.option) ? optionKey : 0) | (modifiers.contains(.control) ? controlKey : 0)
    }

    var holdFlags: CGEventFlags {
        CGEventFlags()
            .union(modifiers.contains(.command) ? .maskCommand : [])
            .union(modifiers.contains(.option) ? .maskAlternate : [])
            .union(modifiers.contains(.control) ? .maskControl : [])
    }

    /// "⌘ Tab", "⌃ ⌥ Q"; `reverse` adds ⇧.
    func displayString(reverse: Bool = false) -> String {
        if let tap = Shortcut.tapKeys[keyCode] { return "\(tap) (tap)" }
        let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }.map { $0.1 }
        return (symbols + (reverse ? ["⇧"] : []) + [keyName]).joined(separator: " ")
    }

    private var keyName: String {
        let names: [Int: String] = [
            kVK_Tab: "Tab", kVK_Space: "Space", kVK_Return: "Return", kVK_Escape: "Esc", kVK_Delete: "⌫",
            kVK_ANSI_Grave: "`", kVK_ISO_Section: "`",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        if let name = names[keyCode] { return name }

        // - Letters/digits from the ASCII-capable layout (so a Cyrillic layout still reads "Q")

        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &characters)
        }
        return status == noErr && length > 0 ? String(utf16CodeUnits: characters, count: length).uppercased() : "#\(keyCode)"
    }
}
