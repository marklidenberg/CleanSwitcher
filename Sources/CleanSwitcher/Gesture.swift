import Foundation

/// A trackpad swipe a command answers to: 3 or 4 fingers, and which way —
///
/// ```
/// sideways  ← or →      vertical  ↑ or ↓
/// left      ←           up        ↑
/// right     →           down      ↓
/// ```
struct Gesture: Equatable {
    enum Swipe { case left, right, up, down }

    enum Way: String, CaseIterable {
        case sideways, left, right, vertical, up, down

        var swipes: Set<Swipe> {
            switch self {
            case .sideways: return [.left, .right]
            case .left: return [.left]
            case .right: return [.right]
            case .vertical: return [.up, .down]
            case .up: return [.up]
            case .down: return [.down]
            }
        }

        var arrow: String { ["sideways": "↔", "left": "←", "right": "→", "vertical": "↕", "up": "↑", "down": "↓"][rawValue]! }
    }

    let fingers: Int
    let way: Way

    static let all: [Gesture] = [3, 4].flatMap { fingers in Way.allCases.map { Gesture(fingers: fingers, way: $0) } }

    /// "3-left" — how it's stored.
    var code: String { "\(fingers)-\(way.rawValue)" }

    init(fingers: Int, way: Way) { self.fingers = fingers; self.way = way }

    init?(code: String) {
        let parts = code.split(separator: "-")
        guard parts.count == 2, let fingers = Int(parts[0]), [3, 4].contains(fingers), let way = Way(rawValue: String(parts[1])) else { return nil }
        self.init(fingers: fingers, way: way)
    }

    /// "3 fingers ←"
    var title: String { "\(fingers) fingers \(way.arrow)" }

    func matches(fingers: Int, _ swipe: Swipe) -> Bool { fingers == self.fingers && way.swipes.contains(swipe) }

    /// Some swipe would set both off.
    func overlaps(_ other: Gesture) -> Bool { fingers == other.fingers && !way.swipes.isDisjoint(with: other.way.swipes) }
}
