import Foundation

/// Keeps the held lineup stable across noisy field readings.
/// The lineup is a multiset of names; board positions don't matter (they shift with the camera when the shop folds,
/// and a unit dragged to another cell is still held). A name's count goes up once two readings in a row show at least
/// that many, and goes down only after three readings in a row show fewer, so a unit that is being dragged, hidden by a
/// popup or misread for one frame is not dropped. Purchases are held as pending until the board shows them.
/// A purchase that is reported after the board already shows the new unit is matched to that unit instead of adding a
/// second copy (2026-11-22 19:51, round 9: one 极光 was held as two for 13 s; 卡涅利安 did the same in rounds 5 and 12).
/// A name the player corrected in the review panel replaces the model's guess for that tier from then on.
struct LineupTracker {
    private var stable: [String: Int] = [:]
    private var history: [String: [Int]] = [:]       // last three counts, newest last
    private var pending: [(name: String, ttl: Int, count: Int)] = []   // count = how many the board must show
    private var corrections: [String: String] = [:]  // "guess#tier" → name
    /// Copies the board added that no purchase has claimed yet, and for how many more readings a purchase may claim them.
    private var unclaimed: [String: (count: Int, ttl: Int)] = [:]
    /// Units the player added by hand (the board never showed them, e.g. hidden behind another unit): held at least this
    /// many until removed by hand.
    private var manual: [String: Int] = [:]

    static let upReadings = 2
    static let downReadings = 3
    static let sightingReadings = 6

    mutating func reset() { stable = [:]; history = [:]; pending = []; corrections = [:]; unclaimed = [:]; manual = [:] }

    /// The player added a unit the board doesn't show.
    mutating func addManual(_ name: String) { manual[name, default: 0] += 1 }
    /// The player removed `name` from the lineup.
    mutating func removeManual(_ name: String) { if let k = manual[name] { manual[name] = k > 1 ? k - 1 : nil } }

    mutating func purchased(_ name: String) {
        if let u = unclaimed[name], u.count > 0 {
            unclaimed[name] = u.count > 1 ? (u.count - 1, u.ttl) : nil
            return
        }
        let before = (stable[name] ?? 0) + pending.filter { $0.name == name }.count
        pending.append((name, 4, before + 1))
    }

    /// Copies of `name` held or bought and not yet on the board.
    func held(_ name: String) -> Int { (stable[name] ?? 0) + pending.filter { $0.name == name }.count }

    /// The player picked `name` for a unit the model read as something else.
    mutating func pin(_ u: FieldUnit, name: String) {
        if let guess = u.candidates.first?.name, guess != name { corrections["\(guess)#\(u.tier)"] = name }
        // Trust it right away: at least one of this name is held.
        stable[name] = max(stable[name] ?? 0, 1)
    }

    /// Name the tracker uses for a unit (the player's correction when there is one).
    func name(of u: FieldUnit) -> String? {
        if let c = u.chosen { return c }
        guard let n = u.name else { return nil }
        return corrections["\(n)#\(u.tier)"] ?? n
    }

    /// Feeds one reading; returns the stable lineup (duplicates kept for 同名多张).
    /// - Parameter partial: part of the board is hidden (detail panel, a unit being dragged): what it shows can add
    ///   units, but a unit it doesn't show isn't counted as missing.
    mutating func update(_ units: [FieldUnit], partial: Bool = false) -> [String] {
        var counts: [String: Int] = [:]
        // A half-hidden board only adds units the model is sure about.
        for u in units where !partial || u.chosen != nil || (u.candidates.first?.p ?? 0) >= 0.9 {
            if let n = name(of: u) { counts[n, default: 0] += 1 }
        }
        unclaimed = unclaimed.compactMapValues { $0.ttl > 1 ? ($0.count, $0.ttl - 1) : nil }
        var touched = Set(counts.keys).union(stable.keys).union(history.keys)
        if partial { touched = touched.filter { (counts[$0] ?? 0) > (stable[$0] ?? 0) } }
        for n in touched {
            var h = history[n] ?? []
            h.append(counts[n] ?? 0)
            if h.count > Self.downReadings { h.removeFirst(h.count - Self.downReadings) }
            let s = stable[n] ?? 0
            let recent = h.suffix(Self.upReadings)
            if recent.count == Self.upReadings, let up = recent.min(), up > s {
                stable[n] = up
                // Copies a pending purchase was waiting for are claimed; the rest may still be claimed by a late report.
                let waited = pending.filter { $0.name == n && $0.count <= up }.count
                let fresh = up - s - waited
                if fresh > 0 { unclaimed[n] = ((unclaimed[n]?.count ?? 0) + fresh, Self.sightingReadings) }
            } else if h.count == Self.downReadings, let most = h.max(), most < s {
                stable[n] = most
            }
            if stable[n] == 0 { stable[n] = nil }
            history[n] = stable[n] == nil && h.allSatisfy({ $0 == 0 }) ? nil : h
        }
        var names = stable.flatMap { Array(repeating: $0.key, count: $0.value) }
        // Pending purchases until the board shows them (or a few readings pass).
        pending = pending.compactMap { p in
            if (stable[p.name] ?? 0) >= p.count { return nil }
            return p.ttl > 1 ? (p.name, p.ttl - 1, p.count) : nil
        }
        names += pending.map(\.name)
        for (n, k) in manual {
            let have = names.filter { $0 == n }.count
            if have < k { names += Array(repeating: n, count: k - have) }
        }
        return names.sorted()
    }
}
