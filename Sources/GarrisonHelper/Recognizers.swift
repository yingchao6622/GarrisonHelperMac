import CoreGraphics
import Foundation

// Recognition logic ported from ASP Assistant (Moonfair/ASP_Assistant, Apache-2.0):
// ShopRecognizer, CoreCovenantRecognizer / CovenantIconClassifier and CovenantGrid.
// Modified: MaaFramework OCR replaced by Apple Vision; slot snapping replaced by
// per-label substring boxes from Vision.

struct ShopHit: Identifiable, Hashable {
    var name: String
    let rect: CGRect   // viewport pixels, top-left origin
    /// Stand-in model the card shows (Pith …) when `name` was resolved to the real operator.
    var shownAs: String? = nil
    var id: String { "\(name)@\(Int(rect.minX))" }
    /// Shop slot index (cards are ~162 px apart at 720p).
    func slot(viewport: CGSize) -> Int {
        let s = min(viewport.width / 1280, viewport.height / 720)
        return Int((rect.midX / (162.4 * s)).rounded())
    }
}

enum ShopRecognizer {
    /// Reads the bottom name strip of the shop and returns tracked cards.
    /// `strip` must be the OCR of the viewport area from y = stripTop.
    static func stripRect(viewport: CGSize) -> CGRect {
        let s = min(viewport.width / 1280, viewport.height / 720)
        let top = viewport.height - 72 * s, bottom = viewport.height - 10.8 * s
        return CGRect(x: 0, y: top, width: viewport.width, height: bottom - top)
    }

    /// `labels`: covenant names printed on the cards above the name (奇迹 must not fuzzy-match 云迹).
    static func find(texts: [OCRText], stripOrigin: CGPoint, viewport: CGSize,
                     tracked: [String]?, catalog: [String], labels: [String] = []) -> [ShopHit] {
        let labelSet = Set(labels.map(OCR.normalize))
        if let t = tracked, t.isEmpty { return [] }
        let s = min(viewport.width / 1280, viewport.height / 720)
        let stripHeight = 61.2 * s
        let trackedSet = tracked.map(Set.init)
        let matcher = NameMatcher(names: catalog + (tracked ?? []))

        var hits: [ShopHit] = []
        var seen = Set<String>()
        for t in texts.sorted(by: { $0.box.minX < $1.box.minX }) {
            // Names sit on the lowest row of the strip; the covenant row above them is ignored.
            guard t.box.midY >= stripHeight * 0.1 else { continue }
            // The terminal card (升级 / 已满级) sits left of the first shop card.
            guard t.box.midX + stripOrigin.x > 130 * s else { continue }
            let n = OCR.normalize(t.text)
            if labelSet.contains(n) || labelSet.contains(String(n.dropFirst())) { continue }
            for m in matcher.find(in: t) where trackedSet?.contains(m.name) ?? true {
                let nameX = m.box.minX + stripOrigin.x
                let nameY = t.box.minY + stripOrigin.y
                let id = "\(m.name)@\(Int(nameX / max(1, 80 * s)))"
                guard seen.insert(id).inserted else { continue }
                // Card geometry relative to its name label (720p reference, ASP Assistant).
                let x = max(0, nameX - 32 * s), y = max(0, nameY - 145 * s)
                let rect = CGRect(x: x, y: y, width: min(164 * s, viewport.width - x), height: min(184 * s, viewport.height - y))
                hits.append(ShopHit(name: m.name, rect: rect))
            }
        }
        return hits
    }
}

/// Matches OCR lines against catalog names without guessing ambiguous ones
/// (approach from ASP Assistant's CovenantLabelMatcher / ShopRecognizer).
struct NameMatcher {
    struct Match { let name: String; let box: CGRect }
    private let byKey: [String: String]
    private let keysLongestFirst: [String]

    init(names: [String]) {
        byKey = Dictionary(names.map { (OCR.normalize($0), $0) }, uniquingKeysWith: { a, _ in a })
        keysLongestFirst = byKey.keys.filter { $0.count >= 2 }.sorted { $0.count > $1.count }
    }

    func find(in t: OCRText) -> [Match] {
        let n = OCR.normalize(t.text)
        guard !n.isEmpty else { return [] }
        // 1. Whole line is a name, possibly with one stray glyph from the profession icon in front.
        // One-character names (宴) only when that is the whole label.
        if n.count <= 2, let one = byKey[String(n.suffix(1))], n.count == 1 || !n.first!.isLetter || !CharacterSet.alphanumerics.contains(n.unicodeScalars.first!) {
            return [Match(name: one, box: t.box)]
        }
        for drop in 0...1 where n.count - drop >= 2 {
            let candidate = String(n.dropFirst(drop))
            if let name = byKey[candidate] ?? fuzzy(candidate) {
                let frac = Double(drop) / Double(n.count)
                return [Match(name: name, box: CGRect(x: t.box.minX + t.box.width * frac, y: t.box.minY,
                                                      width: t.box.width * (1 - frac), height: t.box.height))]
            }
        }
        // 2. Several labels merged into one line: exact substrings only.
        var out: [Match] = []
        var used: [Range<String.Index>] = []
        for k in keysLongestFirst {
            var start = t.text.startIndex
            while let r = t.text.range(of: k, range: start..<t.text.endIndex) {
                start = r.upperBound
                if used.contains(where: { $0.overlaps(r) }) { continue }
                used.append(r)
                out.append(Match(name: byKey[k]!, box: t.box(of: r)))
            }
        }
        return out
    }

    /// One edit away from exactly one name of length ≥ 3, or — for two-character names — one wrong character
    /// when only one name fits (何夜 → 伺夜; 乌? stays unmatched because 乌啾 and 乌有 both fit).
    private func fuzzy(_ observed: String) -> String? {
        var found: String?
        let o = Array(observed)
        let cjk = o.allSatisfy { $0.unicodeScalars.allSatisfy { $0.value >= 0x4E00 && $0.value <= 0x9FFF } }
        for (k, name) in byKey {
            let kk = Array(k)
            let near = kk.count >= 3 ? oneEditApart(o, kk) : kk.count == 2 && o.count == 2 && cjk && zip(o, kk).filter { $0 != $1 }.count == 1
            guard near else { continue }
            if found != nil && found != name { return nil }
            found = name
        }
        return found
    }

    private func oneEditApart(_ a: [Character], _ b: [Character]) -> Bool {
        if abs(a.count - b.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count >= b.count { i += 1 }
            if b.count >= a.count { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) == 1
    }
}

struct PreparationResult {
    var banned: [String] = []
    var available: [String] = []
    var uncertain: [String] = []
    var boss: String?
    var isPreparationPage = false
}

enum PreparationRecognizer {
    static func analyze(texts: [OCRText], pixels px: PixelBuffer, viewport: CGRect,
                        covenants: [Covenant], bosses: [Boss]) -> PreparationResult {
        var result = PreparationResult()
        let h = viewport.height
        // Boss / 敌方领袖
        for b in bosses {
            let names = [b.name] + (b.aliases ?? [])
            if texts.contains(where: { t in names.contains { t.text.contains($0) } }) { result.boss = b.name; break }
        }
        guard let coreTitle = texts.first(where: { $0.text.contains("核心盟") }),
              let addTitle = texts.first(where: { $0.text.contains("附加盟") }) else { return result }
        let section = addTitle.box.minY - coreTitle.box.minY
        guard section >= h * 0.12, section <= h * 0.45 else { return result }
        result.isPreparationPage = true

        let names = covenants.map(\.name).sorted { $0.count > $1.count }
        var seen = Set<String>()
        for t in texts where t.box.minY > coreTitle.box.maxY {
            if t.text.contains("盟约") && t.text.count <= 6 { continue } // section titles
            let compact = t.text
            var consumed: [Range<String.Index>] = []
            for name in names {
                var start = compact.startIndex
                while let r = compact.range(of: name, range: start..<compact.endIndex) {
                    start = r.upperBound
                    if consumed.contains(where: { $0.overlaps(r) }) { continue }
                    consumed.append(r)
                    guard seen.insert(name).inserted else { continue }
                    let label = t.box(of: r)
                    // Expect labels below their section title. Core labels sit between the titles.
                    let isCoreRow = label.midY < addTitle.box.minY
                    if let cov = covenants.first(where: { $0.name == name }), cov.isCore != isCoreRow {
                        // A core name in the additional rows (or vice-versa) is some other text.
                        seen.remove(name); continue
                    }
                    let cx = viewport.minX + label.midX
                    let cy = viewport.minY + label.midY - h * 0.075
                    switch IconClassifier.isDisabled(px, viewport: viewport, cx: cx, cy: cy) {
                    case .some(true): result.banned.append(name)
                    case .some(false): result.available.append(name)
                    case .none: result.uncertain.append(name)
                    }
                }
            }
        }
        return result
    }
}

enum IconClassifier {
    /// nil = cannot tell. Thresholds from ASP Assistant's CovenantIconClassifier.
    static func isDisabled(_ px: PixelBuffer, viewport: CGRect, cx: Double, cy: Double) -> Bool? {
        let w = viewport.width, h = viewport.height
        let icon = CGRect(x: cx - w * 0.022, y: cy - h * 0.039, width: w * 0.044, height: h * 0.078)
        let badge = CGRect(x: cx + w * 0.013, y: cy - h * 0.060, width: w * 0.021, height: h * 0.041)
        let cyan = px.fraction(in: icon) { r, g, b in g > 100 && g - r > 45 && b - r > 25 }
        if cyan >= 0.18 { return false }
        let gray = px.fraction(in: icon) { r, g, b in min(r, g, b) > 80 && max(r, g, b) - min(r, g, b) < 65 }
        let white = px.fraction(in: badge) { r, g, b in min(r, g, b) > 140 && max(r, g, b) - min(r, g, b) < 50 }
        if cyan < 0.04 && gray > 0.07 && white > 0.07 { return true }
        // Looser fallback: clearly desaturated icon without any cyan.
        if cyan < 0.02 && gray > 0.25 { return true }
        return nil
    }
}
