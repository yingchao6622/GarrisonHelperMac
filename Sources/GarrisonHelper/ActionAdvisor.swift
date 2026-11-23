// Portions adapted from hongxue-stronghold-companion (Apache-2.0) and rewritten in Swift for this Mac app; the upstream files are listed
// in REFERENCES.md and their licenses / NOTICEs are in licenses/.
import CoreGraphics
import Foundation

/// A recommended in-game action, with where to highlight it (viewport pixels).
struct GameAction: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case buy = "购买", upgrade = "升本", save = "升本预告", refresh = "刷新", freeze = "冻结", unfreeze = "解冻"
        case deploy = "上场", bench = "下场", sell = "出售", place = "站位", choose = "选择", equip = "装备"
        var setting: String {
            switch self {
            case .buy: "buy"
            case .upgrade, .save: "upgrade"
            case .refresh: "refresh"
            case .freeze, .unfreeze: "freeze"
            case .deploy, .bench, .sell, .place: "place"
            case .choose, .equip: "buy"
            }
        }
    }
    let id = UUID()
    let kind: Kind
    let title: String
    let reason: String
    var rect: CGRect? = nil
    var quad: [CGPoint]? = nil
    var order: Int = 0
    /// Board cell (col, row) of a 站位 action and its facing (for the mini board).
    var cell: [Int]? = nil
    var facing: String? = nil
    static func == (a: GameAction, b: GameAction) -> Bool { a.kind == b.kind && a.title == b.title && a.rect == b.rect }
    func hash(into h: inout Hasher) { h.combine(kind.rawValue); h.combine(title) }
}

struct AdvisorInput {
    var cards: [ShopCard]
    var controls: GameControls
    var hud: HudReading
    var owned: [String]
    var route: PlannedRoute?
    var currentStage: Int?
    var deployCap: Int
    var field: FieldReading?
    var map: GarrisonMap?
    var projection: BoardProjection?
    var viewport: CGSize
    var catalog: (tier: (String) -> Int?, isOperator: (String) -> Bool, op: (String) -> Operator?)
    var profiles: [String: OperatorProfile]
    var eliteFocus: Bool
    var ownedEquipment: [String] = []
    var equipment: [String: (categories: [String], effect: String)] = [:]
    var round: Int? = nil
    /// Next-round funds / upgrade price; `carries` false means leftover funds are lost at the end of the round.
    var forecast: EconomyForecast? = nil
    /// This round's enemy routes (placement weighs lanes by enemy count and covers flying routes).
    var enemyRoutes: RoundRoutes? = nil
}

/// Who should carry equipment (this app's rules). Damage dealers get 攻击 / 技力 gear, the front line 防御 / 生存.
/// Operators whose attack grows with covenant layers (蓝毒: 【伊比利亚】每叠加 2 层攻击力 +1%) are the natural
/// carries: they turn attack gear into the most damage. Layer generators (深靛, 流明) are support pieces.
enum GearAdvisor {
    struct Holder: Hashable {
        enum Kind: String { case carry = "主C", tank = "前排" }
        let name: String
        let kind: Kind
        let why: String
        var categories: [String] { kind == .carry ? ["攻击", "技力"] : ["防御", "生存"] }
        var label: String { "\(name)（\(kind.rawValue)：\(categories.joined(separator: "/"))" + (why.isEmpty ? "" : "，\(why)") + "）" }
    }

    static func holders(_ names: [String], op: (String) -> Operator?, profiles: [String: OperatorProfile]) -> [Holder] {
        let unique = Array(Set(names)).sorted()
        var carries: [(name: String, score: Double, why: String)] = []
        for n in unique {
            guard let o = op(n) else { continue }
            let p = profiles[n]
            if p?.isTank == true || p?.isHealer == true { continue }
            let traits = (o.normal.traits + o.elite.traits).map(\.traitDescription).joined()
            var score = Double(o.tier)
            var why = ""
            if traits.contains("攻击力+") && traits.contains("层") { score += 4; why = "攻击随层数涨，最吃装备" }
            else if traits.contains("攻击力") || traits.contains("攻击速度") { score += 1.5 }
            switch p?.profession { case "狙击", "术师": score += 2; case "近卫", "特种": score += 1; default: break }
            if p?.isStacker == true { score -= 3 }
            carries.append((n, score, why))
        }
        var out = carries.sorted { ($0.score, $0.name) > ($1.score, $1.name) }.prefix(2).map { Holder(name: $0.name, kind: .carry, why: $0.why) }
        if let t = unique.filter({ profiles[$0]?.isTank == true }).max(by: { (op($0)?.tier ?? 0) < (op($1)?.tier ?? 0) }) {
            out.append(Holder(name: t, kind: .tank, why: ""))
        }
        return out
    }

    /// Items that are used up when equipped (装备时销毁…): whom to give it and what it does, or nil for ordinary gear.
    /// The user asked how to use 简易通讯机 (2026-11-22): the shop advice bought it and never said.
    static func usage(_ name: String, effect: String, main: String?, smalls: [String], owned: [String], carry: String?,
                      op: (String) -> Operator?) -> String? {
        guard effect.contains("销毁") else { return nil }
        let held = Array(Set(owned)).sorted().compactMap(op)
        func first(_ o: Operator) -> String? { o.coreCovenants.first ?? o.additionalCovenants.first }
        // Bearer whose first covenant is the 本家 (else a small covenant of the route).
        func bearer() -> (name: String, cov: String)? {
            for cov in [main].compactMap({ $0 }) + smalls {
                if let o = held.filter({ first($0) == cov }).min(by: { $0.tier < $1.tier }) { return (o.name, cov) }
            }
            return nil
        }
        if effect.contains("第一盟约") {
            func what(_ cov: String) -> String {
                effect.contains("随机获得") ? "随机送一名\(cov)干员" : effect.contains("免费获取") ? "商店出至多 3 名\(cov)干员，免费拿一名"
                    : "刷新一次商店，优先出\(cov)干员"
            }
            if let b = bearer() { return "装给 \(b.name)（第一盟约是【\(b.cov)】）→ \(what("【\(b.cov)】"))" }
            let target = main.map { "【\($0)】" } ?? "本家"
            return "装给第一盟约是\(target)的干员 → \(what(target))；手上还没有这样的人，先留着"
        }
        if effect.contains("所属盟约层数") {
            if let main, let o = held.first(where: { $0.allCovenants.contains(main) }) { return "装给 \(o.name)：它身上的盟约（含【\(main)】）直接加层，不用激活" }
            return "装给本家干员：它身上的盟约直接加层，不用激活"
        }
        if effect.contains("精锐") { return "装给最想升精锐的人" + (carry.map { "（主C \($0)）" } ?? "") + "：直接升精锐" }
        if name == "拟态物质" {
            let counts = Dictionary(owned.map { ($0, 1) }, uniquingKeysWith: +)
            if let two = counts.filter({ $0.value == 2 }).keys.sorted().first { return "装给 \(two)（已有 2 张）：再送 1 张，凑齐三合一" }
            return "装给已有 2 张的干员会再送 1 张凑三合一；现在没有，装了只随机给一名同阶干员"
        }
        if effect.contains("目标干员和本装备销毁") { return "装给不要的干员（它会被销毁）：换一名同阶干员" }
        // Money, shop and deployment items: anyone can carry them, the effect happens at once.
        var short = effect.replacingOccurrences(of: "装备时销毁，", with: "").replacingOccurrences(of: "装备时销毁", with: "")
        if short.hasPrefix("并") { short.removeFirst() }
        return "装给谁都行，装上就生效：\(short)"
    }

    /// "给 X 带" for one equipment item, from its categories.
    static func target(_ categories: [String], _ holders: [Holder]) -> Holder? {
        holders.first { h in h.categories.contains { categories.contains($0) } }
    }
}

/// Decides buy / upgrade / refresh / freeze and positioning from the route's advice for the current level.
/// Rules follow the route's pace (抢升本 / 补牌 / 稳升 / 满本) from hongxue's AutoPlanner.Advise; the money
/// arithmetic, freeze and positioning rules are this app's.
enum ActionAdvisor {
    /// Value of an equipment card / item for the route (shop, 道具补给, 机密商店).
    static func equipmentValue(_ name: String, info: (categories: [String], effect: String)?, gearNeeded: Set<String>, goals: Set<String>,
                               owned: [String], round: Int?, holders: [GearAdvisor.Holder]) -> (Double, String) {
        let carryH = holders.first { $0.kind == .carry }, tank = holders.first { $0.kind == .tank }?.name
        let carry = carryH?.name
        let carryWhy = carryH.map { $0.why.isEmpty ? "" : "，\($0.name)\($0.why)" } ?? ""
        if gearNeeded.contains(name) { return (60, "路线要的转职装备") }
        let cats = info?.categories ?? []
        let have = owned.filter { $0 == name }.count
        let named = (info?.effect ?? "").components(separatedBy: "【").dropFirst().compactMap { $0.components(separatedBy: "】").first }
        var v = 0.0, why = ""
        if let c = named.first(where: goals.contains) { v = 55; why = "加成【\(c)】" }
        else if cats.contains("经济") && (round ?? 1) <= 6 { v = 45; why = "前期经济装" }
        else if cats.contains("攻击") { v = 35 + (carryWhy.isEmpty ? 0 : 8); why = carry.map { "给 \($0) 带（攻击\(carryWhy)）" } ?? "攻击装备" }
        else if cats.contains("防御") || cats.contains("生存") { v = 32; why = tank.map { "给 \($0) 带（防御 / 生存）" } ?? "防御 / 生存装备" }
        else if cats.contains("技力") { v = 30; why = carry.map { "给 \($0) 带（技力\(carryWhy)）" } ?? "技力装备" }
        else if cats.contains("盟约") { v = 30; why = "盟约装备" }
        if have >= 1 && v > 0 { v += 12; why += "，已有 \(have) 件可合成" }
        return (v, why)
    }

    static func advise(_ x: AdvisorInput) -> [GameAction] {
        var actions: [GameAction] = []
        guard let route = x.route else { return actions }
        let level = x.hud.level ?? 1
        let stageIndex = min(x.currentStage ?? 0, route.stages.count - 1)
        let stage = route.stages[stageIndex]
        let advice = stage.advice.first { $0.level == level } ?? stage.advice.first
        let pace = advice?.pace ?? .steady
        let keys = Set(advice?.keyCards ?? [])
        let stageNames = Set(stage.ops.map(\.name))
        let finalNames = Set(route.stages.last?.ops.map(\.name) ?? [])
        let laterNames = Set(route.stages[stageIndex...].flatMap { $0.ops.map(\.name) })
        var ownedCount: [String: Int] = [:]
        for n in x.owned { ownedCount[n, default: 0] += 1 }
        let gearNeeded = Set(route.equipment.flatMap { $0.components(separatedBy: "：").last?.components(separatedBy: " / ") ?? [] })

        // 1) Value each shop card.
        // Who carries equipment: from the held lineup (see GearAdvisor).
        let holders = GearAdvisor.holders(x.owned, op: x.catalog.op, profiles: x.profiles)
        let goalCovs = Set(route.candidate.goals.map(\.name))
        func value(_ name: String) -> (Double, String) {
            if !x.catalog.isOperator(name) {
                var r = ActionAdvisor.equipmentValue(name, info: x.equipment[name], gearNeeded: gearNeeded, goals: goalCovs,
                                                     owned: x.ownedEquipment, round: x.round, holders: holders)
                if let effect = x.equipment[name]?.effect,
                   let use = GearAdvisor.usage(name, effect: effect, main: route.candidate.main, smalls: route.candidate.smallGoals.map(\.name),
                                               owned: x.owned, carry: holders.first { $0.kind == .carry }?.name, op: x.catalog.op) {
                    r.1 += (r.1.isEmpty ? "" : "；") + "买了" + use
                }
                return r
            }
            let have = ownedCount[name, default: 0]
            let inRoute = laterNames.contains(name) || finalNames.contains(name)
            if have >= 2 && inRoute { return (110, "第三张：合成精锐，还得一张晋升调配特许（商店刷出几名高一阶干员，免费选 1 名）") }
            if keys.contains(name) && have == 0 { return (100, "本阶段关键牌") }
            if stageNames.contains(name) && have == 0 { return (70, "本阶段阵容") }
            if finalNames.contains(name) && have == 0 { return (55, "成型阵容，先留") }
            if laterNames.contains(name) && have == 0 { return (40, "后面阶段要用") }
            if have == 1 && inRoute { return (x.eliteFocus ? 50 : 30, "第二张：再 1 张合精锐") }
            return (0, "")
        }
        func price(_ c: ShopCard) -> (Int, Bool) {
            if let p = c.price, p > 0 { return (p, false) }
            let t = x.catalog.tier(c.name) ?? 1
            // Estimate when the badge is unreadable: operators by tier (Scanner.operatorPrice), equipment ≈ its tier.
            return (x.catalog.isOperator(c.name) ? Scanner.operatorPrice[t] ?? t : min(t, 3), true)
        }
        var money = x.hud.money ?? 0
        let moneyKnown = x.hud.money != nil
        // Free cards (price 0): a 晋升奖励 after a 3-merge (or 信标 / 寻呼模块) — only one can be taken.
        // A single 0 among priced cards is more likely a misread than a reward.
        let zero = x.cards.filter { $0.price == 0 }
        let free = zero.count >= 2 || (!zero.isEmpty && zero.count == x.cards.filter { $0.price != nil }.count) ? zero : []
        if !free.isEmpty {
            // Route value first; otherwise the card whose covenants the held lineup / route already builds.
            var heldCov: [String: Int] = [:]
            for n in Set(x.owned) { for c in x.catalog.op(n)?.allCovenants ?? [] { heldCov[c, default: 0] += 1 } }
            func fit(_ n: String) -> (Double, [String]) {
                let covs = (x.catalog.op(n)?.allCovenants ?? []).filter { goalCovs.contains($0) || heldCov[$0, default: 0] > 0 }
                return (Double(covs.map { heldCov[$0, default: 0] + (goalCovs.contains($0) ? 2 : 0) }.reduce(0, +)), covs)
            }
            func rank(_ c: ShopCard) -> (Double, Double, Int) { (value(c.name).0, fit(c.name).0, x.catalog.tier(c.name) ?? 0) }
            let best = free.max { rank($0) < rank($1) }!
            let routeWhy = value(best.name).1, covs = fit(best.name).1
            let why = !routeWhy.isEmpty ? routeWhy
                : !covs.isEmpty ? "能接上" + covs.map { "【\($0)】（已有 \(heldCov[$0, default: 0]) 人）" }.joined(separator: "") : "阶最高"
            actions.append(GameAction(kind: .buy, title: "免费拿 \(best.label)", reason: "只能选 1 张：" + why
                                      + (free.count > 1 ? "（另有 " + free.filter { $0 != best }.map(\.name).joined(separator: "、") + "）" : ""),
                                      rect: best.rect, order: 1))
            return actions
        }
        let ranked = x.cards.map { ($0, value($0.name)) }.filter { $0.1.0 > 0 }.sorted { $0.1.0 > $1.1.0 }
        let upgradeCost = x.controls.upgradeCost
        // Only advise 升本 when the terminal level, the funds and the upgrade price were all read this round.
        let canUpgrade = x.hud.level != nil && level < 6 && x.controls.level != nil && !x.controls.maxed && moneyKnown && upgradeCost != nil

        // Rush: upgrade first if affordable, keep only must-haves.
        var upgradeNow = false
        if pace == .rush, canUpgrade, let u = upgradeCost, money >= u {
            upgradeNow = true
            money -= u
        }
        // Leftover funds are lost at the end of the round unless the strategy carries them (利滚利): saving only makes
        // sense then. Otherwise the upgrade gets cheaper by waiting (price −1 per round), so spend this round's funds.
        let carries = x.forecast?.carries ?? false
        // Wanted to upgrade but cannot pay: say when it will be affordable instead of highlighting the button.
        if pace == .rush || pace == .steady, canUpgrade, let u = upgradeCost, !upgradeNow, money < u {
            let f = x.forecast
            let when: String
            switch f?.roundsToUpgrade {
            case 1?: when = "下回合升本价 \(max(0, u - 1))、资金约 \(f?.nextMoney.map(String.init) ?? "?")，下回合就能升"
            case let k? where k > 1: when = "升本价每回合降 1，约 \(k) 回合后升得起"
            default: when = "下回合升本价 \(max(0, u - 1))"
            }
            let lead = carries ? "攒钱升 " : (f?.roundsToUpgrade).map { $0 > 1 ? "约 \($0) 回合后升 " : "下回合升 " } ?? "之后升 "
            actions.append(GameAction(kind: .save, title: lead + "\(level + 1) 本",
                                      reason: "这回合升本要 \(u)，现在 \(money)；" + when
                                        + (carries ? "；利滚利：剩的钱留到下回合，本回合只买关键牌" : "；剩的钱留不到下回合，这回合买有用的牌"),
                                      order: 0))
        }
        // While rushing, funds are held back for the upgrade only if they carry over or the upgrade is paid now.
        let holdForUpgrade = pace == .rush && (carries || upgradeNow)
        let threshold: Double = holdForUpgrade ? 100 : pace == .rush ? 55 : pace == .max ? 40 : 55
        var unaffordable: [ShopCard] = []
        var order = 0
        for (card, (v, why)) in ranked where v >= threshold {
            let (p, est) = price(card)
            if !moneyKnown || money >= p {
                if moneyKnown { money -= p }
                order += 1
                actions.append(GameAction(kind: .buy, title: "买 \(card.label)", reason: why + (est ? "（价格按 \(p) 估）" : "（\(p) 资金）"),
                                          rect: card.rect, order: order))
            } else if v >= 70 {
                unaffordable.append(card)
            }
        }
        // Spare money: useful equipment and later-stage cards. While rushing, only once this round's upgrade is paid or
        // the shop is being frozen anyway (what's left would sit idle until next round's income) — buy first, then freeze.
        let willFreeze = !unaffordable.isEmpty && x.controls.freeze != nil && !x.controls.frozen
        if moneyKnown && (pace != .rush || upgradeNow || willFreeze || !carries) {
            for (card, (v, why)) in ranked where v >= 30 && v < threshold && !actions.contains(where: { $0.rect == card.rect })
                && !unaffordable.contains(where: { $0.rect == card.rect }) {
                let (p, est) = price(card)
                // Keeping funds for next round's upgrade only works when they carry over.
                let reserve = (pace == .steady && carries ? (upgradeCost ?? 0) : 0)
                guard money - p >= reserve else { continue }
                money -= p
                order += 1
                let lead = willFreeze ? "冻结前先花掉余钱：" : upgradeNow ? "升完本还剩钱：" : !carries ? "钱留不到下回合：" : "钱有富余："
                actions.append(GameAction(kind: .buy, title: "买 \(card.label)", reason: lead + why + (est ? "（价格按 \(p) 估）" : "（\(p) 资金）"),
                                          rect: card.rect, order: order))
            }
        }
        if upgradeNow, let r = x.controls.level {
            // Useful cards the upgrade leaves no money for (equipment like 聚合急救箱 went unmentioned, 2026-11-23).
            let skipped = ranked.filter { item in item.1.0 >= 30 && !actions.contains { $0.rect == item.0.rect } }.map(\.0.name)
            let note = skipped.isEmpty ? "" : "；升完" + (money > 0 ? "剩 \(money)，" : "没钱了，") + Array(Set(skipped)).sorted().prefix(4).joined(separator: "、") + " 先不买"
            actions.insert(GameAction(kind: .upgrade, title: "升 \(level + 1) 本", reason: "抢升本阶段：先升本，只买关键牌" + note, rect: r, order: 0), at: 0)
        }
        let keysMissing = !keys.subtracting(Set(x.owned)).subtracting(Set(actions.filter { $0.kind == .buy }.map { String($0.title.dropFirst(2)) })).isEmpty
        if !upgradeNow, canUpgrade, let u = upgradeCost, money >= u, pace == .steady || (pace == .stay && !keysMissing) {
            money -= u
            actions.append(GameAction(kind: .upgrade, title: "升 \(level + 1) 本", reason: (pace == .steady ? "稳升阶段" : "本级关键牌已齐") + "：升本 \(u)，买完还剩 \(money + u)", rect: x.controls.level, order: 50))
        }
        // Freeze: something we want but cannot pay for this round.
        if !unaffordable.isEmpty, let f = x.controls.freeze, !x.controls.frozen {
            actions.append(GameAction(kind: .freeze, title: "冻结商店", reason: "留住 " + unaffordable.map(\.name).joined(separator: "、") + "，下回合再买", rect: f, order: 60))
        } else if x.controls.frozen, ranked.filter({ $0.1.0 >= 55 }).isEmpty, let f = x.controls.freeze {
            actions.append(GameAction(kind: .unfreeze, title: "解冻", reason: "冻结的商店里已经没有要的牌", rect: f, order: 60))
        }
        // Refresh: still missing key cards, nothing good left in the shop, and money to spare.
        let bought = Set(actions.filter { $0.kind == .buy }.map { String($0.title.dropFirst(2)) })
        let goodLeft = ranked.contains { item in item.1.0 >= 55 && !bought.contains(item.0.name) }
        // Rushing with funds that carry over: keep them for the upgrade. Otherwise leftover funds are better spent on a refresh.
        if pace != .rush || !carries, keysMissing || pace == .max, !goodLeft, unaffordable.isEmpty, let r = x.controls.refresh {
            let cost = x.controls.refreshCost ?? 1
            if !moneyKnown || money >= cost {
                let reserve = carries && (pace == .steady || pace == .stay) ? (upgradeCost ?? 0) : 0
                if !moneyKnown || money - cost >= 0 && (keysMissing || money - cost >= reserve) {
                    let stillMissing = keys.subtracting(Set(x.owned)).subtracting(bought).sorted()
                    actions.append(GameAction(kind: .refresh, title: "刷新", reason: (stillMissing.isEmpty ? "满本找强化牌" : "还缺 " + stillMissing.prefix(3).joined(separator: "、")) + "，商店里没有要的了", rect: r, order: 70))
                }
            }
        }

        // 2) Positioning from the field reading.
        guard let field = x.field, !field.units.isEmpty else { return actions }
        func view(_ u: FieldUnit) -> CGRect {
            let r = field.toViewport(CGRect(x: u.x - 22, y: u.y - 22, width: 92, height: 150))
            return r
        }
        // 2) Lineup: only changes that can be made right now, a couple at a time (a wall of 上场 / 卖 can't be acted on
        // in a 30-second rest). Ties are broken by name so the advice doesn't swap between equal units every frame.
        let unique = Array(Set(field.units.compactMap(\.name)))
        func rank(_ n: String) -> (Int, Int, String) {
            let o = x.catalog.op(n)
            let pri = stageNames.contains(n) ? 0 : finalNames.contains(n) ? 1 : laterNames.contains(n) ? 2 : 3
            return (pri, -(o?.tier ?? 0), n)
        }
        let team = Array(unique.sorted { rank($0) < rank($1) }.prefix(x.deployCap))
        let teamSet = Set(team)
        let boardNames = Set(field.units.filter { !$0.bench }.compactMap(\.name))
        let boardCount = field.units.filter { !$0.bench }.count
        let freeSlots = max(0, x.hud.remainingDeploy ?? (x.deployCap - boardCount))
        var o = 100
        // Bench units the team wants on the board (one per name: a second copy waits for the merge).
        var seenIn = Set<String>()
        let incoming = field.units.filter { u in
            guard u.bench, let n = u.name, teamSet.contains(n), !boardNames.contains(n) else { return false }
            return seenIn.insert(n).inserted
        }.sorted { rank($0.name!) < rank($1.name!) }
        // Board units outside the team, weakest first.
        let outgoing = field.units.filter { !$0.bench && $0.name.map { !teamSet.contains($0) } == true }
            .sorted { rank($0.name!) > rank($1.name!) }
        // Fill free slots first.
        for u in incoming.prefix(min(2, freeSlots)) {
            o += 1
            actions.append(GameAction(kind: .deploy, title: "上场 \(u.name!)", reason: stageNames.contains(u.name!) ? "本阶段阵容，还有空位" : "还有空位，比整备区其他人合适",
                                      rect: view(u), order: o))
        }
        // No free slot: one swap — the weakest board unit makes room for the best bench unit.
        if freeSlots == 0, let inUnit = incoming.first, let outUnit = outgoing.first, let i = inUnit.name, let out = outUnit.name {
            o += 1
            let keep = laterNames.contains(out)
            actions.append(GameAction(kind: keep ? .bench : .sell, title: (keep ? "下场 " : "卖 ") + out,
                                      reason: (keep ? "留着后面用，" : "路线用不上，") + "给 \(i) 让位", rect: view(outUnit), order: o))
            o += 1
            actions.append(GameAction(kind: .deploy, title: "上场 \(i)", reason: stageNames.contains(i) ? "本阶段阵容" : "比 \(out) 合适", rect: view(inUnit), order: o))
        }
        // Selling from the bench only when it is getting full: the unit the route needs least.
        let benchUnits = field.units.filter(\.bench)
        if benchUnits.count >= 6 {
            let counts = Dictionary(grouping: field.units.compactMap(\.name), by: { $0 }).mapValues(\.count)
            let junk = benchUnits.filter { u in
                guard let n = u.name else { return false }
                // Keep route units and pairs that are one copy from a merge.
                return !laterNames.contains(n) && !finalNames.contains(n) && (counts[n] ?? 0) != 2 && !incoming.contains { $0.id == u.id }
            }.sorted { rank($0.name!) > rank($1.name!) }
            if let u = junk.first, let n = u.name {
                o += 1
                actions.append(GameAction(kind: .sell, title: "卖 \(n)", reason: "整备区快满了，路线用不上", rect: view(u), order: o))
            }
        }
        if let map = x.map, let proj = x.projection {
            let ops = team.compactMap(x.catalog.op)
            var current: [String: (Int, Int)] = [:]
            for u in field.units where !u.bench { if let n = u.name, let c = u.cell { current[n] = (c[0], c[1]) } }
            // The three most important moves (blockers first); the rest follow once those are done.
            for p in PlacementHeuristic.advise(map: map, team: ops, current: current, profiles: x.profiles, enemy: x.enemyRoutes).prefix(3) {
                o += 1
                actions.append(GameAction(kind: .place, title: "\(p.name) \(p.facing.rawValue)", reason: p.reason,
                                          quad: proj.cell(p.col, p.row, in: x.viewport), order: o, cell: [p.col, p.row], facing: p.facing.rawValue))
            }
        }
        return actions
    }
}

extension FieldReading {
    /// Converts a rect in the normalised 1920×1080 frame back to viewport pixels.
    func toViewport(_ r: CGRect) -> CGRect {
        let w = sourceSize.width, h = sourceSize.height
        guard w > 0, h > 0 else { return r }
        let s = max(1920 / w, 1080 / h)
        let ox = (w * s - 1920) / 2, oy = (h * s - 1080) / 2
        return CGRect(x: (r.minX + ox) / s, y: (r.minY + oy) / s, width: r.width / s, height: r.height / s)
    }
}
