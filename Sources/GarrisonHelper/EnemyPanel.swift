// Portions adapted from StrongholdAssistant (Apache-2.0) and rewritten in Swift for this Mac app; the upstream files are listed
// in REFERENCES.md and their licenses / NOTICEs are in licenses/.
import CoreGraphics
import Foundation

/// The in-game enemy list (the panel the 敌人 button opens during rest: 「悬赏」 with the bounty target, then 「敌人」
/// with this round's enemies, each a name line followed by "•" ability lines). After StrongholdAssistant
/// Services/RoundEnemyReader.cs, which finds the panel by its title and OCRs the left-aligned names below it; here the
/// full-screen OCR is already there, so the 「敌人」 header line anchors the panel and names are matched against
/// data/enemies.json. The list scrolls: names are collected per round across frames.
enum EnemyPanelReader {
    struct Reading: Equatable {
        var enemies: [String]
        var bounty: [String]
    }

    /// - Parameters: texts and size in work-image pixels.
    static func read(_ texts: [OCRText], size: CGSize, matcher: NameMatcher) -> Reading? {
        let h = size.height
        // Section headers: short lines ending in 敌人 / 悬赏 (OCR may read the icon in front as a glyph: 令敌人),
        // right of centre where the panel opens.
        func header(_ word: String) -> OCRText? {
            texts.first { t in
                let s = t.text.trimmingCharacters(in: .whitespaces)
                return s.hasSuffix(word) && s.count <= word.count + 1 && t.box.midX > size.width * 0.5 && t.box.midX < size.width * 0.8
            }
        }
        let enemyHeader = header("敌人"), bountyHeader = header("悬赏")
        guard let anchor = enemyHeader ?? bountyHeader else { return nil }
        // Names start a little right of the header (icon column in between); ability lines start with "•".
        let left = anchor.box.minX + 0.03 * h, right = anchor.box.minX + 0.14 * h
        var enemies: [String] = [], bounty: [String] = []
        for t in texts.sorted(by: { $0.box.minY < $1.box.minY }) where t.box.minX >= left && t.box.minX <= right {
            let s = t.text.trimmingCharacters(in: .whitespaces)
            guard let first = s.first, !"•·✕×*-".contains(first), t.box.height < 0.05 * h else { continue }
            // The whole line must be the name (not a name inside an ability text).
            guard let m = matcher.find(in: t).first, m.box.width >= t.box.width * 0.7 else { continue }
            if let e = enemyHeader, t.box.minY > e.box.maxY {
                if !enemies.contains(m.name) { enemies.append(m.name) }
            } else if let b = bountyHeader, t.box.minY > b.box.maxY {
                if !bounty.contains(m.name) { bounty.append(m.name) }
            }
        }
        guard !enemies.isEmpty || !bounty.isEmpty else { return nil }
        return Reading(enemies: enemies, bounty: bounty)
    }
}

/// Enemies seen in the panel this round (the list scrolls, so frames add up).
struct RoundEnemies: Equatable {
    var round: Int?
    var enemies: [String] = []
    var bounty: [String] = []

    /// Returns true when something new was added.
    mutating func add(_ r: EnemyPanelReader.Reading, round now: Int?) -> Bool {
        if now != round { self = RoundEnemies(round: now) }
        let before = (enemies.count, bounty.count)
        for n in r.enemies where !enemies.contains(n) { enemies.append(n) }
        for n in r.bounty where !bounty.contains(n) { bounty.append(n) }
        return (enemies.count, bounty.count) != before
    }
}
