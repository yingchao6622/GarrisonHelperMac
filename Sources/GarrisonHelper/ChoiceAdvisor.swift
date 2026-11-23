import CoreGraphics
import Foundation

// Choice screens: 悬赏决策 / 道具补给 / 机密商店 / 战术决策 and 确定自选编队.
// Layouts (1080p reference, scale = min(w/1920, h/1080)) from StrongholdAssistant (Apache-2.0)
// Services/AdaptReader.cs and Services/CustomPickReader.cs; data: bounties.json, adapt_tactics.json.
// Instead of re-reading each card region, the full-screen OCR texts are assigned to cards by position.
// The scoring is this app's.

struct ChoiceCard: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let rect: CGRect          // viewport pixels (highlight)
    var score: Double
    var reason: String
    var best = false
    /// Another player already picked it (悬赏决策: the card turns light grey with their avatar on the corner).
    var taken = false
    static func == (a: ChoiceCard, b: ChoiceCard) -> Bool { a.name == b.name && a.rect == b.rect && a.best == b.best && a.taken == b.taken }
    func hash(into h: inout Hasher) { h.combine(name); h.combine(best) }
}

struct ChoiceScreen: Equatable {
    enum Kind: String { case bounty = "悬赏决策", supply = "道具补给", shop = "机密商店", tactic = "战术决策", selfPick = "自选编队" }
    let kind: Kind
    var cards: [ChoiceCard]
    /// One-line summary for the side panel (自选编队: what to pick in each row).
    var note: String? = nil
}

struct ChoiceContext {
    var bounties: [BountyInfo]
    var tactics: [TacticInfo]
    var enemies: [String: EnemyInfo]           // by id
    var equipmentNames: [String]
    var equipmentValue: (String) -> (Double, String)
    var selfPickValue: (String) -> (Double, String)?
    var selfPickNames: [String]
    var goals: Set<String>                     // covenants of the route
    var main: String?
    var rangedCount: Int                       // held operators that hit fliers (ranged + 领主)
    var heldCount: Int
    var activeCovenants: Int
    var round: Int?
    /// Fighting strength of the held lineup: Σ tier weight (1阶 1 … 6阶 8). Nil when the lineup isn't known.
    var teamPower: Double? = nil

    static let tierWeight: [Int: Double] = [1: 1, 2: 1.6, 3: 2.5, 4: 4, 5: 6, 6: 8]
}

enum ChoiceAdvisor {
    static func normalize(_ s: String) -> String {
        String(s.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace && !"“”\"·•・。.,，「」『』'‘’".contains($0) }).replacingOccurrences(of: "異", with: "异")
            .replacingOccurrences(of: "賞", with: "赏").replacingOccurrences(of: "昇", with: "异")
            // OCR misreads seen on the Mac client (2026-11-22): 悬實决策, 选定悬寞目标, 大鮑勃.
            .replacingOccurrences(of: "悬實", with: "悬赏").replacingOccurrences(of: "悬寞", with: "悬赏")
            .replacingOccurrences(of: "鮑", with: "鲍")
    }

    /// `needle` in `hay` allowing one wrong character for names of 4+ characters (OCR: 姆→妈, 鼠→最).
    static func fuzzyContains(_ hay: String, _ needle: String) -> Bool {
        if hay.contains(needle) { return true }
        let h = Array(hay), n = Array(needle)
        guard n.count >= 4, h.count >= n.count else { return false }
        for i in 0...(h.count - n.count) {
            var miss = 0
            for j in 0..<n.count where h[i + j] != n[j] { miss += 1; if miss > 1 { break } }
            if miss <= 1 { return true }
        }
        return false
    }

    static func read(texts: [OCRText], viewport vp: CGSize, ctx: ChoiceContext, image: CGImage? = nil) -> ChoiceScreen? {
        let s = min(vp.width / 1920, vp.height / 1080)
        func ref(_ r: CGRect) -> CGRect { CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s) }
        // 自选编队 title in the top middle.
        if texts.contains(where: { $0.text.contains("确定自选编队") && $0.box.midY < 120 * s }) {
            return selfPick(texts: texts, s: s, ctx: ctx)
        }
        // The title sits top left; while the popup animates in (or another player is deciding: 正在决策⋯) it can be
        // at the very top edge.
        let header = ref(CGRect(x: 150, y: 0, width: 500, height: 120))
        let top = texts.filter { $0.box.midY < 140 * s }
        guard let title = texts.filter({ header.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }).first(where: { t in
            ["悬赏决策", "道具补给", "机密商店", "战术决策"].contains { normalize(t.text).contains($0) } }) else {
            // Title garbled (赏决策｜洗安県無月标》): the subtitle 「选定悬赏目标，获取额外奖励」 still says it is the bounty popup.
            if top.contains(where: { fuzzyContains(normalize($0.text), "选定悬赏目标") }) { return bounty(texts: texts, s: s, ctx: ctx, image: image) }
            return nil
        }
        // The title and its subtitle can come back as one line (「机密商店｜无需消耗资金，获得装备补给。」, 2026-11-22 20:20):
        // the title word that comes first decides, so 机密商店 isn't taken for 道具补给 because of the subtitle's 「补给」.
        let titleText = normalize(title.text)
        let words: [(String, ChoiceScreen.Kind)] = [("悬赏", .bounty), ("道具补给", .supply), ("机密", .shop), ("战术", .tactic), ("补给", .supply)]
        let kind: ChoiceScreen.Kind = words.compactMap { w, k in titleText.range(of: w).map { (titleText.distance(from: titleText.startIndex, to: $0.lowerBound), k) } }
            .min { $0.0 < $1.0 }?.1 ?? .tactic
        if kind == .bounty { return bounty(texts: texts, s: s, ctx: ctx, image: image) }
        // Card columns scale around the screen centre; the title's left edge gives the span (AdaptReader).
        let titleX = title.box.minX / s
        let span = titleX < 232 ? 0.94 : titleX > 256 ? 1.11 : 1.0
        func X(_ x: Double) -> Double { (960 + (x - 960) * span) * s + (vp.width - 1920 * s) / 2 }
        var cards: [ChoiceCard] = []
        let names: [String] = kind == .bounty ? ctx.bounties.map(\.name) : kind == .tactic ? ctx.tactics.map(\.name) : ctx.equipmentNames
        for col in 0..<3 {
            let left = X(476 + Double(col) * 462), right = X(719 + Double(col) * 462)
            let column = texts.filter { $0.box.midX >= left - 10 * s && $0.box.midX <= right + 10 * s && $0.box.midY > 140 * s && $0.box.midY < 1000 * s }
            for t in column {
                let n = normalize(t.text)
                var match: String?
                if kind == .bounty, n.hasPrefix("悬赏") || n.contains("战术特训") || n.contains("多轮") {
                    // Generic bounty titles: pick the entry whose enemy is named in the card body below.
                    let body = texts.filter { abs($0.box.midX - (left + right) / 2) < 260 * s && $0.box.minY > t.box.maxY && $0.box.minY < t.box.maxY + 220 * s }
                        .map { normalize($0.text) }.joined()
                    match = ctx.bounties.first { b in
                        let series = normalize(b.name).trimmingCharacters(in: CharacterSet(charactersIn: "I!1|"))
                        return n.hasPrefix(series.prefix(4)) && (b.enemyName.map { body.contains(normalize($0)) } ?? false)
                    }?.name ?? ctx.bounties.first { b in b.enemyName.map { body.contains(normalize($0)) } ?? false }?.name
                } else {
                    match = names.first { normalize($0) == n }
                }
                guard let m = match, !cards.contains(where: { $0.name == m && abs($0.rect.midX - (left + right) / 2) < 10 }) else { continue }
                let rect = CGRect(x: X(338 + Double(col) * 462), y: t.box.minY - 60 * s, width: X(719 + Double(col) * 462) - X(338 + Double(col) * 462), height: 400 * s)
                let (score, reason) = value(kind, m, ctx)
                cards.append(ChoiceCard(name: m, rect: rect, score: score, reason: reason))
            }
        }
        guard !cards.isEmpty else { return ChoiceScreen(kind: kind, cards: []) }
        if let i = cards.indices.max(by: { cards[$0].score < cards[$1].score }) { cards[i].best = true }
        return ChoiceScreen(kind: kind, cards: cards.sorted { $0.score > $1.score })
    }

    /// 悬赏决策 on the Mac client: two rows of three cards. Each card has a title ending in 悬赏 / 特训
    /// (long names wrap onto two lines) and a body naming the enemy and the reward. Cards are found from
    /// their titles and matched on title + body together, so wrapped names and odd punctuation still match.
    private static func bounty(texts: [OCRText], s: Double, ctx: ChoiceContext, image: CGImage? = nil) -> ChoiceScreen {
        let px = image.map(PixelBuffer.init)
        let body = texts.filter { $0.box.midY > 130 * s && $0.box.midY < 1060 * s }
        let anchors = body.filter { t in
            let n = normalize(t.text)
            return (n.hasSuffix("悬赏") || n.hasSuffix("特训") || n.hasPrefix("悬赏") || n.hasPrefix("战术特训") || n.hasPrefix("多轮悬赏"))
                && !n.contains("决策") && !n.contains("选定") && n.count <= 16
        }
        var cards: [ChoiceCard] = []
        var used: [CGRect] = []
        for a in anchors.sorted(by: { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }) {
            // Lines of the same card: the title block (one or two lines) and the body under it, which starts left of the title.
            let lines = body.filter { t in
                t.box.minX > a.box.minX - 200 * s && t.box.minX < a.box.minX + 120 * s
                    && t.box.midY > a.box.midY - 60 * s && t.box.midY < a.box.midY + 200 * s
            }.sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
            let top = lines.map(\.box.minY).min() ?? a.box.minY
            let left = lines.map(\.box.minX).min() ?? a.box.minX
            let rect = CGRect(x: left - 16 * s, y: top - 72 * s, width: 432 * s, height: 360 * s)
            if used.contains(where: { $0.intersects(rect.insetBy(dx: 60 * s, dy: 60 * s)) }) { continue }
            let joined = normalize(lines.map(\.text).joined())
            guard let b = matchBounty(joined, ctx.bounties) else { continue }
            used.append(rect)
            let (score, reason) = bountyValue(b, ctx)
            var card = ChoiceCard(name: b.name, rect: rect, score: score, reason: reason)
            if let px, isTaken(px, rect) { card.taken = true }
            cards.append(card)
        }
        guard !cards.isEmpty else { return ChoiceScreen(kind: .bounty, cards: []) }
        // Once the player's own row in the list on the left has its ✓, one of the grey cards is theirs: the decision is
        // made and nothing is recommended any more. Before that every grey card was picked by someone else.
        let decided = px.map { selfDecided($0, s: s) } ?? false
        for i in cards.indices where cards[i].taken {
            cards[i].reason = (decided ? "已被选 · " : "已被别人选走 · ") + cards[i].reason
        }
        if decided {
            return ChoiceScreen(kind: .bounty, cards: cards.sorted { $0.taken != $1.taken ? !$0.taken : $0.score > $1.score })
        }
        // The best of the cards still open (a taken card can't be picked); all taken → nothing to recommend.
        let open = cards.indices.filter { !cards[$0].taken }
        if let i = open.max(by: { cards[$0].score < cards[$1].score }) {
            cards[i].best = true
            if cards[i].score < 0.6, let safe = cards.firstIndex(where: { !$0.taken && $0.name.contains("源石虫") && $0.name.contains("特训") }) {
                // Nothing is worth the risk: the free 源石虫 is the safe pick.
                cards[i].best = false
                cards[safe].best = true
                cards[safe].reason = "其他悬赏都不划算，选这个零风险"
            }
        }
        return ChoiceScreen(kind: .bounty, cards: cards.sorted {
            $0.best != $1.best ? $0.best : $0.taken != $1.taken ? !$0.taken : $0.score > $1.score
        })
    }

    /// A taken card's body is light grey (≈ 170–200) where an open or selected card is near black: the empty strip
    /// under the body text (bottom quarter of the card, away from the edges) decides. Measured on the Mac client
    /// 2026-11-22 (19:28 / 18:29 matches).
    /// The player list on the left marks the player's own row with a cyan ▶ at the screen edge and puts a blue ✓ to the
    /// right of each avatar once that player has picked. Mac client, 1080p reference: ▶ at x ≈ 18, ✓ centred about
    /// x ≈ 172 and 40 px below the ▶ (measured on the 2026-11-22 06:36, 18:29 and 19:28 bounty frames).
    static func selfDecided(_ px: PixelBuffer, s: Double) -> Bool {
        var ys: [Int] = []
        for y in stride(from: Int(200 * s), to: min(px.height, Int(900 * s)), by: 1) {
            for x in Int(4 * s)..<min(px.width, Int(30 * s)) {
                let c = px.rgb(x, y)
                if c.b > 170 && c.g > 140 && c.r < 110 { ys.append(y); break }
            }
        }
        // The ▶ is the longest run of consecutive rows (≈ 15 px); the highlighted avatar's cyan frame adds a stray row or two.
        var best = (start: 0, len: 0), i = 0
        while i < ys.count {
            var j = i
            while j + 1 < ys.count && ys[j + 1] == ys[j] + 1 { j += 1 }
            if j - i + 1 > best.len { best = (i, j - i + 1) }
            i = j + 1
        }
        guard best.len >= Int(6 * s), best.len <= Int(40 * s) else {
            if ProcessInfo.processInfo.environment["BOUNTY_DEBUG"] != nil { print("bounty ▶ not found (longest run \(best.len))") }
            return false
        }
        let arrowY = ys[best.start + best.len / 2]
        var blue = 0
        for y in max(0, arrowY + Int(18 * s))..<min(px.height, arrowY + Int(64 * s)) {
            for x in Int(150 * s)..<min(px.width, Int(198 * s)) {
                let c = px.rgb(x, y)
                if c.b > 190 && c.r < 90 && c.g > 100 && c.g < 225 { blue += 1 }
            }
        }
        if ProcessInfo.processInfo.environment["BOUNTY_DEBUG"] != nil { print("bounty ▶ y \(arrowY)  ✓ blue \(blue)") }
        return blue >= 25
    }

    static func isTaken(_ px: PixelBuffer, _ rect: CGRect) -> Bool {
        let x0 = max(0, Int(rect.minX + rect.width * 0.15)), x1 = min(px.width - 1, Int(rect.maxX - rect.width * 0.15))
        let y0 = max(0, Int(rect.minY + rect.height * 0.80)), y1 = min(px.height - 1, Int(rect.minY + rect.height * 0.94))
        guard x1 > x0, y1 > y0 else { return false }
        var lum = 0.0, chroma = 0.0, n = 0.0
        for y in stride(from: y0, through: y1, by: 3) {
            for x in stride(from: x0, through: x1, by: 3) {
                let c = px.rgb(x, y)
                lum += 0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b)
                chroma += Double(max(c.r, c.g, c.b) - min(c.r, c.g, c.b))
                n += 1
            }
        }
        lum /= n; chroma /= n
        if ProcessInfo.processInfo.environment["BOUNTY_DEBUG"] != nil {
            print(String(format: "bounty card @%d,%d lum %.0f chroma %.0f", Int(rect.minX), Int(rect.minY), lum, chroma))
        }
        return lum > 110 && chroma < 40
    }

    static func matchBounty(_ joined: String, _ all: [BountyInfo]) -> BountyInfo? {
        // The body names the enemy and the reward ("…添加1只X，将其击倒者获得N资金"); titles are generic
        // (悬赏·频次I) and their Roman numerals OCR badly, so the body decides and the title only breaks ties.
        let coin = joined.range(of: #"获得\d资金"#, options: .regularExpression).flatMap { Int(String(joined[$0].filter(\.isNumber))) }
        let free = joined.contains("不获得")
        let rounds: Int? = joined.contains("后续每场") ? nil : joined.contains("两场") || joined.contains("接下来") ? 2 : 1
        let perfect = joined.contains("完美")
        func narrow(_ c: [BountyInfo], _ keep: (BountyInfo) -> Bool) -> [BountyInfo] { let f = c.filter(keep); return f.isEmpty ? c : f }
        func pick(_ c0: [BountyInfo]) -> BountyInfo? {
            var c = c0
            if free { c = narrow(c) { $0.coin == 0 } } else if let coin { c = narrow(c) { $0.coin == coin } }
            c = narrow(c) { $0.rounds == rounds }
            c = narrow(c) { ($0.kind == "perfect") == perfect }
            c = narrow(c) { joined.contains(normalize($0.name)) }
            return c.first
        }
        let byEnemy = all.filter { b in b.enemyName.map { normalize($0).count >= 2 && fuzzyContains(joined, normalize($0)) } ?? false }
        if !byEnemy.isEmpty {
            let longest = byEnemy.map { normalize($0.enemyName!).count }.max()!
            return pick(byEnemy.filter { normalize($0.enemyName!).count == longest })
        }
        let byTitle = all.filter { joined.contains(normalize($0.name)) }
        guard !byTitle.isEmpty else { return nil }
        let longest = byTitle.map { normalize($0.name).count }.max()!
        return pick(byTitle.filter { normalize($0.name).count == longest })
    }

    /// Expected funds of a bounty. The enemy's effective HP (HP × armour, ×2 with a second life) is compared with
    /// what a lineup can usually kill at this round; leaking a boss also costs HP, which is charged as a penalty.
    static func bountyValue(_ b: BountyInfo, _ ctx: ChoiceContext) -> (Double, String) {
        let e = b.enemyId.flatMap { ctx.enemies[$0] }
        if b.coin == 0 { return (0.3, "不给钱，但零风险") }
        let round = Double(ctx.round ?? 6)
        var notes: [String] = []
        var p: Double
        if let e, let hp = e.hp {
            let abilities = (e.abilities ?? []).joined()
            let lives = abilities.contains("首次降至0") || abilities.contains("第二形态") ? 2.0 : 1.0
            let ehp = hp * (1 + (e.def ?? 0) / 1000) * lives
            // What the lineup can kill: by its strength (a typical round-3 lineup of 4–5 low-tier units ≈ 6, the same
            // thresholds the round-based guess gave), by the round when the lineup isn't known.
            let power = ctx.teamPower ?? 2 * round
            let easy = 1500 * power, hard = 4000 * power
            p = ehp <= easy ? 0.95 : ehp >= hard ? 0.3 : 0.95 - 0.65 * (ehp - easy) / (hard - easy)
            if let tp = ctx.teamPower, tp < 4 { notes.append("阵容还弱") }
            notes.append(String(format: "%.1f 万血", hp / 10000) + (lives > 1 ? "×2 条命" : ""))
            if (e.def ?? 0) >= 600 { notes.append("高防，要法伤") }
            if (e.res ?? 0) >= 50 { notes.append("高法抗") }
            if abilities.contains("屏障") { notes.append("有屏障") }
            if e.motion == "FLY" {
                if ctx.rangedCount < 3 { p *= 0.5; notes.append("飞行，能打飞行的不够") } else { notes.append("飞行") }
            }
        } else {
            p = 0.7
        }
        if b.kind == "perfect" {
            if ctx.activeCovenants >= 3 && ctx.heldCount >= 6 { notes.append("要完美作战，阵容够") } else { p *= 0.6; notes.append("要完美作战，阵容还弱") }
        }
        let times = b.rounds.map(Double.init) ?? max(2, 10 - round)
        let boss = e?.level == "BOSS"
        // A failed bounty lets a strong enemy through: HP lost, worth about 1.5 coins (a boss 3).
        let ev = Double(b.coin) * times * p - (1 - p) * (boss ? 3 : 1.5)
        let verdict = p >= 0.8 ? "稳拿" : p >= 0.55 ? "能打" : "很难打"
        return (ev, "\(verdict)，期望 \(String(format: "%.1f", max(0, ev))) 资金"
                + (b.rounds == nil ? "（之后每场）" : b.rounds! > 1 ? "（\(b.rounds!) 场）" : "")
                + (notes.isEmpty ? "" : "：" + notes.joined(separator: "、")))
    }

    private static func value(_ kind: ChoiceScreen.Kind, _ name: String, _ ctx: ChoiceContext) -> (Double, String) {
        switch kind {
        case .bounty:
            guard let b = ctx.bounties.first(where: { $0.name == name }) else { return (0, "") }
            return bountyValue(b, ctx)
        case .supply, .shop:
            let (v, why) = ctx.equipmentValue(name)
            return (v, why.isEmpty ? "对路线帮助不大" : why)
        case .tactic:
            guard let t = ctx.tactics.first(where: { $0.name == name }) else { return (0, "") }
            let named = t.desc.components(separatedBy: "【").dropFirst().compactMap { $0.components(separatedBy: "】").first }
            let hits = named.filter(ctx.goals.contains)
            if t.name.contains("驰援"), let m = ctx.main, named.contains(m) { return (70, "送本家【\(m)】干员") }
            if !hits.isEmpty { return (45 + 10 * Double(hits.count), "加成路线盟约【\(hits.joined(separator: "】【"))】") }
            if t.desc.contains("装备") { return (25, "送装备") }
            return (20, "通用增益")
        case .selfPick:
            return ctx.selfPickValue(name) ?? (0, "")
        }
    }

    /// 确定自选编队: rows of 6 cards (tier 5 at y≈375, the next row 400 lower); names right under the portraits.
    /// Score a 自选 operator needs before it is recommended: 本家 / 叠层 / 小盟约 of a route or the strategy. A 盾位 / 奶位
    /// bonus alone (0.5) is not enough — the user asked why unrelated operators were listed to pick (2026-11-22).
    static let selfPickMin = 1.0

    private static func selfPick(texts: [OCRText], s: Double, ctx: ChoiceContext) -> ChoiceScreen {
        var cards: [ChoiceCard] = []
        // The first card of each row is the operator banned this match: its name (often half read, 「霄陈」) sits right
        // above 「本局禁用」.
        let bannedLabels = texts.filter { normalize($0.text).contains("本局禁用") }
        for t in texts where t.box.midY > 300 * s && t.box.midX > 700 * s {
            let n = normalize(t.text)
            if n.contains("本局禁用") { continue }
            if bannedLabels.contains(where: { b in abs(b.box.minX - t.box.minX) < 150 * s && b.box.minY > t.box.minY && b.box.minY - t.box.minY < 90 * s }) { continue }
            guard let name = ctx.selfPickNames.first(where: { normalize($0) == n || (n.count >= 2 && normalize($0).hasSuffix(n)) }) else { continue }
            guard !cards.contains(where: { $0.name == name }) else { continue }
            let rect = CGRect(x: t.box.midX - 88 * s, y: t.box.minY - 230 * s, width: 176 * s, height: 270 * s)
            let (score, reason) = ctx.selfPickValue(name) ?? (0, "")
            cards.append(ChoiceCard(name: name, rect: rect, score: score, reason: reason))
        }
        // Up to two picks per row (each tier row shows 「0/2」), and only operators that help a route. Equal scores are
        // said to be equal: 43 of the 75 自选 operators carry 协防干员, so a route using it can't tell them apart.
        let rows = Dictionary(grouping: cards.indices) { Int((cards[$0].rect.midY / (150 * s)).rounded()) }
        var lines: [String] = []
        for (k, key) in rows.keys.sorted().enumerated() {
            let ok = rows[key]!.filter { cards[$0].score >= selfPickMin }.sorted { cards[$0].score > cards[$1].score }
            let row = rows.count > 1 ? (k == 0 ? "上排" : "下排") : "这一排"
            func names(_ ix: [Int]) -> String { ix.map { "「\(cards[$0].name)」" }.joined() }
            if ok.isEmpty { lines.append("\(row)没有和路线相关的，可以不选"); continue }
            if ok.count <= 2 { ok.forEach { cards[$0].best = true }; lines.append("\(row)选\(names(ok))"); continue }
            let cut = cards[ok[1]].score
            let above = ok.filter { cards[$0].score > cut + 0.05 }
            let tied = ok.filter { abs(cards[$0].score - cut) <= 0.05 }
            let need = max(0, 2 - above.count)
            // Each row takes two (「6阶自选编队已达上限」): highlight exactly two, the equal others are named as swaps.
            let picked = above.prefix(2) + tied.prefix(need)
            let swaps = tied.dropFirst(need)
            picked.forEach { cards[$0].best = true }
            for i in swaps { cards[i].reason = "和同排推荐的作用一样，可以换着选 · " + cards[i].reason }
            lines.append("\(row)选\(names(Array(picked)))" + (swaps.isEmpty ? "" : "（作用一样，也可换成\(names(Array(swaps)))）"))
        }
        return ChoiceScreen(kind: .selfPick, cards: cards.sorted { $0.best != $1.best ? $0.best : $0.score > $1.score },
                            note: lines.joined(separator: "；"))
    }
}
