import Foundation

/// Tuning for continuous key repeat while a navigation key is held.
/// (The two-row TTL lives in `Preferences.mainRowTTL`.)
enum SwitcherConfig {

    /// Delay before a held key (Tab/Shift+Tab/arrows) starts repeating.
    static let repeatInitialDelay: TimeInterval = 0.35

    /// Interval between repeats while the key stays held.
    static let repeatInterval: TimeInterval = 0.09
}
