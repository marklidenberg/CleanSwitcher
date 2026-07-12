import Foundation

/// Hardcoded tuning for the switcher's two-row model and input behavior.
/// Kept in one place so the main-row split and key-repeat feel are easy to
/// adjust; a Preferences UI can grow on top of these later.
enum SwitcherConfig {

    // NOTE: the two-row TTL lives in Preferences.mainRowTTL (user-configurable).

    // MARK: - Continuous key repeat

    /// Delay before a held navigation key (Tab/Shift+Tab/arrows) starts repeating.
    static let repeatInitialDelay: TimeInterval = 0.35
    /// Interval between repeats while the key stays held.
    static let repeatInterval: TimeInterval = 0.09
}
