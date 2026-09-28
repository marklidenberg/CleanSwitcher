import Foundation

/// The Apps panel's persisted state, keyed by bundle id:
///
/// ```
/// rows     the pinned, row by row, in the user's order
/// slots    each recent one's slot in the recent grid — fixed while it stays recent; gaps allowed
/// hidden   never among the recent
/// ```
struct AppsStore: Codable {
    var rows: [[String]] = []
    var slots: [String: Int] = [:]
    var hidden: [String] = []

    init() {}

    /// Reads the one-row pinned list and the recent order too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        rows = try container.decodeIfPresent([[String]].self, forKey: .rows) ?? []
        slots = try container.decodeIfPresent([String: Int].self, forKey: .slots) ?? [:]
        hidden = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
        if rows.isEmpty, let pinned = try container.decodeIfPresent([String].self, forKey: .pinned), !pinned.isEmpty {
            rows = stride(from: 0, to: pinned.count, by: 7).map { Array(pinned[$0..<min($0 + 7, pinned.count)]) }
        }
        if slots.isEmpty, let appeared = try container.decodeIfPresent([String].self, forKey: .appeared) {
            slots = Dictionary(uniqueKeysWithValues: appeared.enumerated().map { ($1, $0) })
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(rows, forKey: .rows)
        try container.encode(slots, forKey: .slots)
        try container.encode(hidden, forKey: .hidden)
    }

    private enum Keys: String, CodingKey { case rows, slots, hidden, pinned, appeared }

    static func load() -> AppsStore {
        Preferences.appsState.flatMap { try? JSONDecoder().decode(AppsStore.self, from: $0) } ?? AppsStore()
    }

    func save() { Preferences.appsState = try? JSONEncoder().encode(self) }

    func isPinned(_ id: String) -> Bool { rows.contains { $0.contains(id) } }

    /// The switcher opens: a slot whose app is no longer recent is freed, a gap; each new
    /// recent app takes the first free slot, the one used longer ago first.
    mutating func update(recent: [String: TimeInterval]) {
        slots = slots.filter { recent[$0.key] != nil && !isPinned($0.key) && !hidden.contains($0.key) }
        for id in recent.keys.filter({ slots[$0] == nil && !isPinned($0) && !hidden.contains($0) }).sorted(by: { recent[$0]! < recent[$1]! }) {
            slots[id] = firstFreeSlot
        }
    }

    var firstFreeSlot: Int { let taken = Set(slots.values); return (0...).first { !taken.contains($0) }! }

    /// Into `row` at `index`; `newRow` — a new row there, above the one at `row`.
    mutating func pin(_ id: String, row: Int, index: Int, newRow: Bool) {
        remove(id)
        if newRow || rows.isEmpty { rows.insert([id], at: min(row, rows.count)) }
        else { let r = min(row, rows.count - 1); rows[r].insert(id, at: min(index, rows[r].count)) }
        rows.removeAll { $0.isEmpty }
    }

    /// Unpinned: among the recent, in the first free slot.
    mutating func unpin(_ id: String) {
        remove(id)
        slots[id] = firstFreeSlot
    }

    mutating func hide(_ id: String) {
        remove(id)
        hidden.append(id)
    }

    /// Out of the pinned rows, its slot, the hidden.
    private mutating func remove(_ id: String) {
        rows = rows.map { $0.filter { $0 != id } }.filter { !$0.isEmpty }
        slots[id] = nil
        hidden.removeAll { $0 == id }
    }
}
