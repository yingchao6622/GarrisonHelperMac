import AppKit
import CoreGraphics
import Foundation
import Vision

// HUD / covenant-bar / purchase recognition. Layout constants (1920×1080 reference) come from
// StrongholdAssistant's EconomyReader and CovenantBarReader and hongxue's ShopPurchaseDetector
// (Apache-2.0); MaaFramework OCR and pixel matching are replaced by Apple Vision text boxes.

struct HudReading: Equatable {
    var round: Int?
    var money: Int?
    var level: Int?
    var remainingDeploy: Int?
    var isRest = false
    var bossRound = false
    /// Showing another player's board (联防 / 观战): a player tag under the board, or 联防 without the 「自己」 tag.
    var otherBoard = false
    /// 联防 phase (「层数叠加已禁用」 / 「联防开始」): the board shown may be ours (tag 「自己」) or the partner's.
    var coDefense = false
    /// Tag under the board in 联防 / 观战: "自己" for our own board, the player's name (NAME#1234) otherwise.
    var boardTag: String?
    /// The player list (「前往观战」 buttons down the left) covers the board.
    var playerList = false
    /// Fighting (kill counter instead of 「休息一下」).
    var inBattle = false
}

enum HudReader {
    static func scale(_ vp: CGSize) -> Double { min(vp.width / 1920, vp.height / 1080) }

    static func number(_ s: String) -> Int? {
        let digits = s.map { c -> Character in
            switch c { case "O", "o", "〇": return "0"; case "l", "I", "|": return "1"; default: return c }
        }.filter(\.isNumber)
        return digits.isEmpty || digits.count > 3 ? nil : Int(String(digits))
    }

    static func read(texts: [OCRText], viewport vp: CGSize) -> HudReading {
        let s = scale(vp)
        var r = HudReading()
        let top = texts.filter { $0.box.midY < vp.height * 0.10 }
        // 回合 N（"回合" and the digits are often separate boxes on the same row）
        if let label = top.first(where: { $0.text.contains("回合") }) {
            let after = label.text.components(separatedBy: "回合").last ?? ""
            r.round = number(after)
            if r.round == nil, let digits = top.filter({ $0.box.minX >= label.box.maxX - 4 && $0.box.minX < label.box.maxX + 90 * s
                && abs($0.box.midY - label.box.midY) < label.box.height }).min(by: { $0.box.minX < $1.box.minX }) {
                r.round = number(digits.text)
            }
            if let n = r.round, !(1...20).contains(n) { r.round = nil }
            r.bossRound = label.text.contains("?") || label.text.contains("？")
        }
        let heading = top.map(\.text).joined()
        r.isRest = heading.contains("休息") || heading.contains("休整") || texts.contains { $0.text.contains("准备就绪") }
        r.inBattle = !r.isRest && top.contains { $0.text.range(of: #"^\s*\d{1,3}\s*/\s*\d{1,3}\s*$"#, options: .regularExpression) != nil && abs($0.box.midX - vp.width / 2) < vp.width * 0.15 }
        r.coDefense = texts.contains { ($0.text.contains("叠加已禁用") || $0.text.contains("已禁用") || $0.text.contains("联防")) && $0.box.midY < vp.height * 0.5 }
        // Whose board: 「自己」 or a player tag (NAME#1234) centred under the board.
        let tagZone = texts.filter { $0.box.midY > vp.height * 0.75 && abs($0.box.midX - vp.width / 2) < vp.width * 0.25 }
        if tagZone.contains(where: { $0.text.trimmingCharacters(in: .whitespaces) == "自己" }) {
            r.boardTag = "自己"
        } else if let t = tagZone.first(where: { $0.text.range(of: #"#\d{3,5}$"#, options: .regularExpression) != nil }) {
            r.boardTag = t.text.trimmingCharacters(in: .whitespaces)
        }
        // Without a tag the scanner decides from the covenant bar (see Scanner.process); 联防 defaults to "not ours".
        r.otherBoard = r.boardTag.map { $0 != "自己" } ?? r.coDefense
        r.playerList = texts.filter { ($0.text.contains("观战") || $0.text.contains("前往")) && $0.box.midX < vp.width * 0.12 }.count >= 2
        // 资金 is read from the badge pixels in refine() (full-screen OCR merges the coin icon into the number).
        if texts.contains(where: { $0.text.contains("已满级") && $0.box.midY > vp.height * 0.6 }) { r.level = 6 }
        // 终端等级 I…VI is read from the panel art in refine(); OCR turns the Roman glyphs into 1s.
        let joined = texts.map { $0.text.replacingOccurrences(of: " ", with: "") }.joined(separator: "\n")
        if let m = joined.range(of: #"可放置角色[：:]?\s*[0-9oO]+"#, options: .regularExpression) {
            r.remainingDeploy = number(String(joined[m]).components(separatedBy: CharacterSet(charactersIn: "：:色")).last ?? "")
        }
        return r
    }

    /// Gold funds badge at the bottom right (coin icon + digits).
    static func moneyBadge(_ image: CGImage) -> CGRect? {
        let vp = CGSize(width: image.width, height: image.height)
        let s = scale(vp)
        return goldBox(image, in: CGRect(x: vp.width - 220 * s, y: vp.height - 330 * s, width: 205 * s, height: 100 * s))
    }

    /// 资金 digits only: the three-diamond coin icon in the left part of the badge reads as 8 or 3
    /// (9 → 89, 5 → 85), so the digits are read right of it.
    static func readMoney(_ image: CGImage) -> Int? {
        guard let badge = moneyBadge(image) else { return nil }
        let s = scale(CGSize(width: image.width, height: image.height))
        let iconEnd = badge.minX + 52 * s
        let digits = CGRect(x: iconEnd, y: badge.minY, width: max(8, badge.maxX - iconEnd), height: badge.height)
        if let dir = ProcessInfo.processInfo.environment["BADGE_DEBUG"], let c = image.cropped(digits.insetBy(dx: -2, dy: -badge.height * 0.3)) {
            try? NSBitmapImageRep(cgImage: c).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/money-\(Int(Date().timeIntervalSince1970 * 1000)).png"))
        }
        for k in [0.3, 0.6, 0.1] {
            if let n = OCR.readNumber(image, in: digits.insetBy(dx: -2, dy: -badge.height * k), inks: [.gold]), (0...99).contains(n) { return n }
        }
        return nil
    }

    /// Bounding box of the gold funds badge (border, coin icon and digits) inside `area`.
    static func goldBox(_ image: CGImage, in area: CGRect) -> CGRect? {
        let a = area.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let crop = image.cropped(a) else { return nil }
        let px = PixelBuffer(crop)
        func gold(_ x: Int, _ y: Int) -> Bool { let c = px.rgb(x, y); return c.r > 170 && c.g > 120 && c.b < 110 && c.r - c.b > 90 }
        var rows = [Int](repeating: 0, count: px.height)
        for y in 0..<px.height { for x in 0..<px.width where gold(x, y) { rows[y] += 1 } }
        guard let peak = rows.max(), peak > 8 else { return nil }
        // The badge's hexagon outline gives two long horizontal edges; other gold art nearby (coin piles,
        // unit icons) is narrower. Keep the band from the first long edge to the last one ~1 badge height below.
        let strong = rows.indices.filter { Double(rows[$0]) >= Double(peak) * 0.5 }
        guard let top = strong.first else { return nil }
        let limit = top + Int(Double(px.height) * 0.62)
        let bottom = strong.filter { $0 <= limit }.last ?? top
        var minX = Int.max, maxX = -1, hits = 0
        for y in top...bottom { for x in 0..<px.width where gold(x, y) { hits += 1; minX = min(minX, x); maxX = max(maxX, x) } }
        guard hits > 20, maxX > minX + 8, bottom > top + 4 else { return nil }
        return CGRect(x: a.minX + Double(minX), y: a.minY + Double(top), width: Double(maxX - minX + 1), height: Double(bottom - top + 1))
    }

    /// The terminal panel's 升级 / 已满级 label (bottom-left of the shop row).
    static func levelAnchor(_ texts: [OCRText], _ vp: CGSize) -> OCRText? {
        texts.filter { ($0.text.contains("升级") || $0.text.contains("满级")) && $0.box.midY > vp.height * 0.7 && $0.box.midX < vp.width * 0.45 }
            .min { $0.box.minX < $1.box.minX }
    }

    /// Terminal level from the panel art: levels 1–3 are white bars, higher levels are Roman numerals.
    static func panelLevel(_ image: CGImage, anchor: OCRText) -> Int? {
        let vp = CGSize(width: image.width, height: image.height)
        let s = scale(vp)
        if anchor.text.contains("满级") { return 6 }
        let art = CGRect(x: anchor.box.midX - 46 * s, y: anchor.box.midY - 150 * s, width: 92 * s, height: 70 * s)
        if let dir = ProcessInfo.processInfo.environment["BAR_DEBUG"], let c = image.cropped(art) {
            try? NSBitmapImageRep(cgImage: c).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/level-art.png"))
        }
        // Match the glyph (I…VI drawn as dark blocks) against templates taken from the Mac client.
        // No guessing from bar counts: a covered or animating panel then reads as 1.
        if let mask = levelGlyphMask(image, art: art), let n = LevelGlyphs.classify(mask) { return n }
        return nil
    }

    /// 32×24 binary mask of the dark glyph under the LEVEL label.
    static func levelGlyphMask(_ image: CGImage, art: CGRect) -> [UInt8]? {
        let g = CGRect(x: art.midX - art.width * 0.32, y: art.minY + art.height * 0.36, width: art.width * 0.64, height: art.height * 0.64)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard g.width > 8, g.height > 8, let crop = image.cropped(g) else { return nil }
        let px = PixelBuffer(crop)
        var m = [UInt8](repeating: 0, count: 32 * 24)
        for y in 0..<24 { for x in 0..<32 {
            // Majority vote inside each cell.
            let x0 = x * px.width / 32, x1 = max(x0 + 1, (x + 1) * px.width / 32)
            let y0 = y * px.height / 24, y1 = max(y0 + 1, (y + 1) * px.height / 24)
            var dark = 0, n = 0
            for yy in y0..<y1 { for xx in x0..<x1 { let c = px.rgb(xx, yy); n += 1; if max(c.r, c.g, c.b) < 90 { dark += 1 } } }
            m[y * 32 + x] = dark * 2 >= n ? 1 : 0
        } }
        return m
    }

    static func levelArt(_ image: CGImage, anchor: OCRText) -> CGRect {
        let s = scale(CGSize(width: image.width, height: image.height))
        return CGRect(x: anchor.box.midX - 46 * s, y: anchor.box.midY - 150 * s, width: 92 * s, height: 70 * s)
    }

    private static func darkBars(_ px: PixelBuffer, _ r: CGRect) -> Int {
        let rect = r.integral.intersection(CGRect(x: 0, y: 0, width: px.width, height: px.height))
        guard rect.width > 3, rect.height > 3 else { return 0 }
        var runs = 0, inRun = false, width = 0
        var widths: [Int] = []
        for x in Int(rect.minX)..<Int(rect.maxX) {
            var dark = 0
            for y in Int(rect.minY)..<Int(rect.maxY) { let c = px.rgb(x, y); if max(c.r, c.g, c.b) < 90 { dark += 1 } }
            let on = Double(dark) >= rect.height * 0.45
            if on { width += 1 }
            if on && !inRun { runs += 1 }
            if !on && inRun { widths.append(width); width = 0 }
            inRun = on
        }
        if inRun { widths.append(width) }
        // Bars are wide blocks; ignore hairlines.
        return widths.filter { Double($0) >= rect.width * 0.08 }.count
    }

    static func roman(_ t: String) -> Int? {
        let map: [String: Int] = ["Ⅰ": 1, "Ⅱ": 2, "Ⅲ": 3, "Ⅳ": 4, "Ⅴ": 5, "Ⅵ": 6, "I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6]
        let cleaned = String(t.map { "|lL1".contains($0) ? "I" : $0 }.filter { "IVⅠⅡⅢⅣⅤⅥ".contains($0) })
        return map[cleaned]
    }

    /// Second pass on the viewport image for values the full-screen OCR missed (lone digits).
    static func refine(_ r: HudReading, texts: [OCRText], image: CGImage) -> HudReading {
        var r = r
        let vp = CGSize(width: image.width, height: image.height)
        let s = scale(vp)
        // While a unit is dragged onto the sell box the funds badge moves and the LEVEL art is covered.
        let dragging = texts.contains { $0.text.contains("拖拽至") || $0.text.contains("至此出售") }
        if dragging { return r }
        if r.level == nil, let a = levelAnchor(texts, vp) { r.level = panelLevel(image, anchor: a) }
        if r.money == nil { r.money = readMoney(image) }
        if r.round == nil, let label = texts.first(where: { $0.text.contains("回合") && $0.box.midY < vp.height * 0.1 }) {
            let rect = CGRect(x: label.box.maxX, y: label.box.minY - label.box.height * 0.6, width: 70 * s, height: label.box.height * 2.2)
            if let n = OCR.readNumber(image, in: rect, inks: [.darkOnCyan, .white]), (1...20).contains(n) { r.round = n }
        }
        return r
    }
}

struct BarReading: Hashable, Identifiable {
    let name: String
    let level: Int?        // activation level (strokes above the ring); nil = not activated
    let layers: Int?       // number inside the ring
    var active: Bool = true
    var id: String { name }
}

enum CovenantBarReader {
    /// Covenants on the top bar (StrongholdAssistant CovenantBarReader layout): Roman level strokes above the ring,
    /// layer count inside it, name below. Each label is read on its own; the digits and strokes are measured
    /// relative to the name (offsets calibrated on the Mac client: digit ≈ 29, ring centre ≈ 69, strokes ≈ 92
    /// reference pixels above the name's centre).
    static func read(texts: [OCRText], image: CGImage, covenants: [Covenant]) -> [BarReading] {
        let vp = CGSize(width: image.width, height: image.height)
        let s = HudReader.scale(vp)
        let area = CGRect(x: vp.width / 2 - 520 * s, y: 40 * s, width: 1040 * s, height: 190 * s)
        let inBar = texts.filter { area.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
        let names = covenants.map(\.name).sorted { $0.count > $1.count }
        let px = PixelBuffer(image)
        var out: [BarReading] = []
        for t in inBar {
            let compact = t.text.replacingOccurrences(of: " ", with: "")
            for n in names where compact.contains(n) && !out.contains(where: { $0.name == n }) {
                guard t.box.midY > 110 * s else { continue }
                let box = t.box(of: compact.range(of: n)!)
                let cx = box.midX, cy = box.midY
                let digitRect = CGRect(x: cx - 24 * s, y: cy - 48 * s, width: 48 * s, height: 34 * s)
                let layers = OCR.readNumber(image, in: digitRect, inks: [.white])
                if let dir = ProcessInfo.processInfo.environment["BAR_DEBUG"], let c = image.cropped(digitRect) {
                    try? NSBitmapImageRep(cgImage: c).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/digit-\(n).png"))
                }
                // Activated ring: cyan icon in the middle of the ring.
                let icon = CGRect(x: cx - 14 * s, y: cy - 80 * s, width: 28 * s, height: 24 * s)
                let cyan = px.fraction(in: icon) { r, g, b in b > 150 && g > 140 && b - r > 50 }
                let level = strokes(px, CGRect(x: cx - 16 * s, y: cy - 104 * s, width: 32 * s, height: 22 * s))
                let active = cyan > 0.12 || level > 0
                out.append(BarReading(name: n, level: active ? max(1, level) : nil, layers: layers, active: active))
            }
        }
        return out.sorted { ($0.active ? 0 : 1, $0.name) < ($1.active ? 0 : 1, $1.name) }
    }

    /// Number of bright vertical strokes (Ⅰ / Ⅱ / Ⅲ) in a small region.
    static func strokes(_ px: PixelBuffer, _ r: CGRect) -> Int {
        let rect = r.integral.intersection(CGRect(x: 0, y: 0, width: px.width, height: px.height))
        guard rect.width > 2, rect.height > 2 else { return 0 }
        var runs = 0, inRun = false
        for x in Int(rect.minX)..<Int(rect.maxX) {
            var white = 0
            for y in Int(rect.minY)..<Int(rect.maxY) { let c = px.rgb(x, y); if min(c.r, c.g, c.b) > 185 { white += 1 } }
            let on = Double(white) >= rect.height * 0.35
            if on && !inRun { runs += 1 }
            inRun = on
        }
        return runs <= 3 ? runs : 0
    }
}

/// Confirms a purchase from a stable named card, its slot going empty twice, and funds dropping
/// (same evidence as hongxue's ShopPurchaseDetector).
struct PurchaseTracker {
    private var slots: [Int: (name: String, seen: Int)] = [:]
    private var empties: [Int: Int] = [:]
    private var lastMoney: Int?
    private var moneyWhenStable: Int?

    /// `cards`: slot index → catalog name visible in the shop strip this frame.
    mutating func update(cards: [Int: String], money: Int?, shopVisible: Bool) -> [String] {
        guard shopVisible else { empties.removeAll(); return [] }
        var bought: [String] = []
        for (slot, name) in cards {
            if slots[slot]?.name == name { slots[slot]!.seen += 1 } else { slots[slot] = (name, 1) }
            empties[slot] = 0
        }
        if let m = money, slots.values.contains(where: { $0.seen >= 2 }) { moneyWhenStable = moneyWhenStable.map { max($0, m) } ?? m }
        let gone = slots.keys.filter { cards[$0] == nil }
        // Refresh / closing the shop empties every slot at once — not a purchase.
        if gone.count <= 2 && !cards.isEmpty {
            for slot in gone {
                empties[slot, default: 0] += 1
                guard let s = slots[slot], s.seen >= 2, empties[slot, default: 0] >= 2 else { continue }
                if let before = moneyWhenStable, let now = money, now < before {
                    bought.append(s.name)
                    moneyWhenStable = now
                }
                slots[slot] = nil
                empties[slot] = nil
            }
        } else if cards.isEmpty || gone.count > 2 {
            for slot in gone { slots[slot] = nil; empties[slot] = nil }
        }
        if let m = money { lastMoney = m; if moneyWhenStable == nil { moneyWhenStable = m } }
        return bought
    }
}

// MARK: - Shop / control positions for action highlights

/// One card in the shop (viewport pixels).
struct ShopCard: Hashable, Identifiable {
    let name: String
    let slot: Int
    let rect: CGRect
    var price: Int?
    /// Stand-in model shown on the card (Pith …) when `name` is the resolved real operator.
    var shownAs: String? = nil
    /// Name as the player finds it in the shop: 「卡涅利安（卡面 Pith）」 for a stand-in card.
    var label: String { shownAs.map { "\(name)（卡面 \($0)）" } ?? name }
    var id: String { "\(slot)-\(name)" }
}

/// Positions of the shop's controls, read from the full-screen OCR (viewport pixels).
struct GameControls: Equatable {
    var refresh: CGRect?
    var freeze: CGRect?
    var frozen = false
    var level: CGRect?
    var levelX: Double?
    var levelY: Double?
    var maxed = false
    var upgradeCost: Int?
    var refreshCost: Int?

    /// Button rect from its text box: the icon sits to the left of the label.
    static func button(_ t: OCRText) -> CGRect {
        let h = t.box.height
        return CGRect(x: t.box.minX - 1.8 * h, y: t.box.minY - 0.7 * h, width: t.box.width + 2.3 * h, height: h * 2.4)
    }

    static func read(texts: [OCRText], image: CGImage) -> GameControls {
        var c = GameControls()
        let vp = CGSize(width: image.width, height: image.height)
        let s = HudReader.scale(vp)
        let lower = texts.filter { $0.box.midY > vp.height * 0.45 }
        if let r = lower.first(where: { $0.text.replacingOccurrences(of: " ", with: "").hasSuffix("刷新") }) {
            c.refresh = button(r)
            // Cost badge sits just above the refresh button (EconomyReader).
            c.refreshCost = OCR.readNumber(image, in: CGRect(x: r.box.midX - 30 * s, y: r.box.minY - 50 * s, width: 60 * s, height: 44 * s), inks: [.gold, .white])
        }
        if let f = lower.first(where: { $0.text.contains("冻结") || $0.text.contains("解冻") }) {
            c.freeze = button(f)
            c.frozen = f.text.contains("解冻")
        }
        // Terminal panel: anchored on its 升级 / 已满级 button (the LEVEL art is often unreadable).
        if let a = HudReader.levelAnchor(texts, vp) {
            let w = 80 * s
            c.level = CGRect(x: a.box.midX - w, y: a.box.minY - 200 * s, width: 2 * w, height: a.box.height + 215 * s)
            c.levelX = a.box.midX
            c.levelY = a.box.midY
            c.maxed = a.text.contains("满级")
        } else if let lv = texts.first(where: { $0.text.uppercased().contains("LEVEL") || $0.text.uppercased().contains("LEUEL") }) {
            let w = 80 * s
            c.level = CGRect(x: lv.box.midX - w, y: lv.box.minY - 20 * s, width: 2 * w, height: vp.height - lv.box.minY + 15 * s)
            c.levelX = lv.box.midX
        }
        return c
    }
}

enum ShopPriceReader {
    struct Result { var prices: [Int: Int] = [:]; var centers: [Int: Double] = [:]; var upgradeCost: Int? }

    @inline(__always) static func gold(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 170 && c.g > 115 && c.b < 75 && c.r - c.b > 125 && c.g - c.b > 70 }

    /// Gold price badges in the coin row above the cards (same row as the funds badge, EconomyReader/ShopReader):
    /// one blob per badge, digits read with tiled OCR; a lone narrow stroke is a 1. The grey upgrade-cost badge
    /// above LEVEL sits in the same row.
    static func read(_ image: CGImage, cards: [ShopHit], levelX: Double?, levelY: Double? = nil) -> Result {
        var out = Result()
        let vp = CGSize(width: image.width, height: image.height)
        let s720 = min(vp.width / 1280, vp.height / 720)
        let s = HudReader.scale(vp)
        // Price badge: top-right of the card (Mac client: 111 / 3 reference px from the card's top-left),
        // gold digit on black when affordable, white on grey when not.
        let px = PixelBuffer(image)
        for card in cards {
            let slot = card.slot(viewport: vp)
            var c = CGPoint(x: card.rect.minX + 111 * s720, y: card.rect.minY + 3 * s720)
            // The card position comes from its name label and can be off by a few pixels; centre on the gold hexagon
            // (outline + digit) so the digit is not cut (a cut 3 reads as 2).
            for _ in 0..<2 {
                guard let g = goldCentroid(px, CGRect(x: c.x - 20 * s720, y: c.y - 17 * s720, width: 40 * s720, height: 34 * s720)) else { break }
                c = g
            }
            out.centers[slot] = c.x
            // Only the hex's middle: the gold outline would otherwise be read as strokes.
            let r = CGRect(x: c.x - 9 * s720, y: c.y - 11 * s720, width: 18 * s720, height: 22 * s720)
            // 0 = free card (晋升奖励 after a 3-merge, 信标 / 寻呼模块 picks).
            // Free reward cards show a cyan 0.
            if let n = readAny(image, around: r, inks: [.gold, .white, .cyan], allowZero: true), (0...20).contains(n) { out.prices[slot] = n }
        }
        // Upgrade cost: hex badge above the terminal panel's 升级 button.
        if let lx = levelX, let ly = levelY {
            let r = CGRect(x: lx - 24 * s, y: ly - 194 * s - 20 * s, width: 48 * s, height: 40 * s)
            if let n = readAny(image, around: r, inks: [.cyan, .white, .gold]), (1...30).contains(n) { out.upgradeCost = n }
        }
        if ProcessInfo.processInfo.environment["PRICE_DEBUG"] != nil { print("prices \(out.prices) upgrade \(out.upgradeCost.map(String.init) ?? "-")") }
        return out
    }

    private static func goldCentroid(_ px: PixelBuffer, _ r: CGRect) -> CGPoint? {
        let a = r.integral.intersection(CGRect(x: 0, y: 0, width: px.width, height: px.height))
        guard a.width > 4, a.height > 4 else { return nil }
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in Int(a.minY)..<Int(a.maxY) { for x in Int(a.minX)..<Int(a.maxX) where gold(px.rgb(x, y)) { sx += Double(x); sy += Double(y); n += 1 } }
        guard n >= 12 else { return nil }
        return CGPoint(x: sx / n, y: sy / n)
    }

    /// Tries a few paddings around a badge; small crops read unreliably.
    private static func readAny(_ image: CGImage, around r: CGRect, inks: [DigitReader.Ink] = [.gold], allowZero: Bool = false) -> Int? {
        let h = r.height
        var zero = false
        for (dx, dy) in [(0.1, 0.05), (0.3, 0.12), (0.55, 0.3)] {
            let rr = r.insetBy(dx: -h * dx, dy: -h * dy)
            if let dir = ProcessInfo.processInfo.environment["PRICE_DUMP"], let c = image.cropped(rr.integral) {
                try? NSBitmapImageRep(cgImage: c).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/p\(Int(r.minX))-\(dx).png"))
            }
            if let n = OCR.readNumber(image, in: rr, inks: inks), n <= 30 {
                if n > 0 { return n }
                if allowZero { zero = true }
            }
        }
        // 0 (free) only when no padding reads a real price: a cut 3 / 8 can look like 0.
        return zero ? 0 : nil
    }

    /// The digit inside a hex badge is one narrow vertical stroke → 1.
    private static func isOne(_ px: PixelBuffer, _ a: Int, _ b: Int, _ y0: Int, _ y1: Int) -> Bool {
        let w = b - a, h = y1 - y0
        guard w > 4, h > 4 else { return false }
        let inner = (a + w / 4, a + 3 * w / 4, y0 + h / 5, y1 - h / 5)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in inner.2...inner.3 { for x in inner.0...inner.1 where gold(px.rgb(x, y)) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= 0 else { return false }
        let gw = Double(maxX - minX + 1), gh = Double(maxY - minY + 1)
        if ProcessInfo.processInfo.environment["PRICE_DEBUG"] != nil { print("isOne blob \(a)-\(b) glyph \(gw)x\(gh) h=\(h)") }
        return gh >= Double(h) * 0.4 && gw / gh < 0.45
    }
}


/// Terminal-level glyph templates captured from the Mac client (data/level_glyphs.json, built by --make-level-templates).
enum LevelGlyphs {
    private struct T: Codable { let level: Int; let mask: String }
    static let templates: [(Int, [UInt8])] = {
        let url = Catalog.resourceRootURL.appendingPathComponent("data/level_glyphs.json")
        guard let d = try? Data(contentsOf: url), let t = try? JSONDecoder().decode([T].self, from: d) else { return [] }
        return t.map { ($0.level, $0.mask.utf8.map { $0 == 49 ? 1 : 0 }) }
    }()

    static func distance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var d = 0
        for i in 0..<min(a.count, b.count) where a[i] != b[i] { d += 1 }
        return Double(d) / Double(a.count)
    }

    static func classify(_ m: [UInt8]) -> Int? {
        guard !templates.isEmpty, m.reduce(0, { $0 + Int($1) }) > 20 else { return nil }
        var best: [Int: Double] = [:]
        for (lv, t) in templates { best[lv] = min(best[lv] ?? 1, distance(m, t)) }
        let r = best.sorted { $0.value < $1.value }
        guard r[0].value < 0.22, r.count < 2 || r[1].value - r[0].value > 0.02 else { return nil }
        return r[0].key
    }

    static func encode(_ m: [UInt8]) -> String { String(m.map { $0 == 1 ? "1" : "0" }) }
}
