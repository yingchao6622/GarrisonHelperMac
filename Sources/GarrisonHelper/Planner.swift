import Foundation

// Lineup / route planning. Ported from hongxue-stronghold-companion (Apache-2.0):
// Services/LineupPlanner.cs, Services/AutoPlanner.cs, Services/LineupRoutePlanner.cs,
// Models/LineupPlannerModels.cs, Models/LineupRouteModels.cs. See REFERENCES.md.
// Modified: Swift port; adds run context (mode pool, strategy modifiers, enemy needs,
// operators already held, current terminal level).

// MARK: - Goals and rules

struct PlannerGoal: Hashable, Codable {
    let name: String
    let level: Int
    let count: Int
    let isCore: Bool
    var label: String { "\(name) \(level == 2 ? "Ⅱ" : "Ⅰ")（\(count)人）" }
}

enum PlanRules {
    static let noTransform: Set<String> = ["灵巧", "协防干员", "奇迹", "远见", "独行", "绝技", "调和"]
    static let peopleSecond: Set<String> = ["精准", "坚守", "助力", "不屈", "聚合", "奥术"]
    static let noSecond: Set<String> = ["独行", "调和", "协防干员"]
    static let noAdditionalScore: Set<String> = ["奇迹", "投资人", "远见", "独行", "调和"]
    /// Small covenants a 小盟约路线 can be built on: the six with a Ⅱ at 3 people, the layer ones (迅捷 / 灵巧 / 突袭), the
    /// flat 协防干员 and the economy ones (远见 / 奇迹 / 投资人). Not 独行 / 调和 (one unit) or 绝技 (counts elites).
    static let routeSmall: Set<String> = ["精准", "坚守", "助力", "不屈", "聚合", "奥术", "迅捷", "灵巧", "突袭", "协防干员", "远见", "奇迹", "投资人"]
    static let harmony = "调和", solo = "独行", healing = "聚合", mech = "协防干员"

    static func goal(_ c: Covenant, level: Int) -> PlannerGoal {
        let basic = c.activateCount
        if level < 2 || noSecond.contains(c.name) { return PlannerGoal(name: c.name, level: 1, count: basic, isCore: c.isCore) }
        if c.isCore { return PlannerGoal(name: c.name, level: 2, count: 6, isCore: true) }
        if peopleSecond.contains(c.name) { return PlannerGoal(name: c.name, level: 2, count: 3, isCore: false) }
        return PlannerGoal(name: c.name, level: 1, count: basic, isCore: false)
    }
}

// MARK: - Run context: strategy, enemies

/// Strategy pieces that change lineup arithmetic (LineupPlannerModels.cs PlannerStrategies).
enum StrategyPiece: String, Codable { case none, mech, pith, shapeshifter }

/// What the chosen strategy means for planning. Piece rules come from hongxue; the other modifiers
/// are read from the strategy text (【盟约】 names) and its effect kind in StrongholdAssistant's strategy_effects.
struct StrategyModifiers: Hashable {
    var id: String?
    var name = "未选择"
    var piece: StrategyPiece = .none
    var mechElite = false
    var favoredCores: [String] = []
    var activeCovenantBonus = false
    var eliteFocus = false
    var healerProvided = false
    var stackingBonus = false
    var economyNote: String?
    var notes: [String] = []

    var piecePlaces: Int { piece == .mech || piece == .pith ? 1 : 0 }
    var extraHarmony: Int { piece == .pith ? 1 : 0 }
    var mechCap: Int { piece == .mech ? (mechElite ? 5 : 3) : 0 }
    var transformOptions: [Int] { piece == .mech || piece == .shapeshifter ? [0, 1, 2, 3] : [0, 1, 2] }
    var freeTransforms: Int { piece == .mech || piece == .shapeshifter ? 1 : 0 }

    static func from(_ s: Strategy?, coreNames: Set<String>) -> StrategyModifiers {
        guard let s else { return StrategyModifiers() }
        var m = StrategyModifiers(id: s.id, name: s.name)
        switch s.id {
        case "band_mech": m.piece = .mech; m.notes.append("暴躁铁皮占 1 个位置，可带 3 次转职（精锐 5 次），自身算【协防干员】")
        case "band_pith": m.piece = .pith; m.notes.append("优等生 Pith 占 1 个位置，算【调和】：场上每个核心盟约激活人数 +1")
        case "band_damaztic": m.piece = .shapeshifter; m.notes.append("每 5 回合送 1 个变形同构体：规划允许最多 3 次转职")
        case "band_amiya": m.activeCovenantBonus = true; m.notes.append("众志合一：激活盟约数达到 3/4/5 种分别加成，优先多盟约阵容")
        case "band_amedic": m.healerProvided = true; m.notes.append("外勤医疗送医疗预备干员：阵容不强制带奶")
        case "band_ioleta", "band_weakness", "band_evolve", "band_upgrade", "band_bonus":
            m.eliteFocus = true; m.notes.append("\(s.name)：精锐收益高，同名干员优先凑三连")
        case "band_jenga", "band_sell", "band_takecare", "band_limit", "band_prepfin":
            m.stackingBonus = true; m.notes.append("\(s.name)：额外叠层，本家尽早激活更划算")
        case "band_lmlee": m.economyNote = "得闲饮茶：前两回合资金第 3 回合一起发，第 3 回合再送 2、4 阶干员各 1 名，开局别急着升本"
        case "band_cannot": m.economyNote = "利滚利：资金可继承，留 5 以上每回合 +1，前期少刷新多攒钱"
        case "band_fund": m.economyNote = "私募基金：随机 1–6 资金，冷却等于获得数"
        case "band_price": m.economyNote = "内部货源：下一件装备 −1 资金"
        case "band_protect": m.economyNote = "献身护卫：可用血量换资金（至多 10）"
        default: break
        }
        // Covenant-specific strategies name their core covenant in 【】.
        let named = s.description.components(separatedBy: "【").dropFirst().compactMap { $0.components(separatedBy: "】").first }
        m.favoredCores = Array(Set(named.filter(coreNames.contains))).sorted()
        if !m.favoredCores.isEmpty && m.piece == .none {
            m.notes.append("\(s.name) 围绕【\(m.favoredCores.joined(separator: "】【"))】：优先这条本家")
        }
        return m
    }
}

/// Enemy-driven requirements (data from enemies.json / bosses.json / enemy_types.json).
struct EnemyNeeds: Hashable {
    var antiAir = false          // 飞行：需要远程或领主
    var preferArts = false       // 高防：法术伤害更好
    var preferPhysical = false   // 高法抗：物理伤害更好
    var notes: [String] = []
    var isEmpty: Bool { !antiAir && !preferArts && !preferPhysical && notes.isEmpty }
}

// MARK: - Planner data

/// Immutable data snapshot for planning; safe off the main actor.
struct PlannerData: @unchecked Sendable {
    let ops: [Operator]
    let covenants: [Covenant]
    let profiles: [String: OperatorProfile]
    let byName: [String: Operator]
    let covByName: [String: Covenant]
    let strategy: StrategyModifiers
    let enemy: EnemyNeeds
    let jobChange: [String: [String]]   // covenant → job-change equipment

    /// - Parameters:
    ///   - unavailable: covenants outside this mode's pool or banned this run.
    ///   - selfSelected: 自选干员 the player brought this run (added to the pool).
    init(ops all: [Operator], covenants: [Covenant], profiles: [String: OperatorProfile],
         unavailable: Set<String> = [], selfSelected: Set<String> = [], strategy: StrategyModifiers = .init(),
         enemy: EnemyNeeds = .init(), jobChangeEquipment: [String: String] = [:]) {
        ops = all.filter { o in
            guard o.obtain == nil, !o.isSelfSelected || selfSelected.contains(o.name) else { return false }
            if !o.coreCovenants.isEmpty { return !o.coreCovenants.allSatisfy(unavailable.contains) }
            return o.additionalCovenants.isEmpty || !o.additionalCovenants.allSatisfy(unavailable.contains)
        }
        self.covenants = covenants
        self.profiles = profiles
        byName = Dictionary(ops.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        covByName = Dictionary(covenants.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        self.strategy = strategy
        self.enemy = enemy
        var jc: [String: [String]] = [:]
        for (e, c) in jobChangeEquipment { jc[c, default: []].append(e) }
        jobChange = jc.mapValues { $0.sorted() }
    }

    func isCore(_ c: String) -> Bool { covByName[c]?.isCore ?? false }
    func activate(_ c: String) -> Int { covByName[c]?.activateCount ?? (isCore(c) ? 3 : 2) }
    func secondCount(_ c: String) -> Int { isCore(c) ? 6 : (PlanRules.peopleSecond.contains(c) ? 3 : Int.max) }
    func profile(_ n: String) -> OperatorProfile? { profiles[n] }
    func isTank(_ n: String) -> Bool { profile(n)?.isTank ?? false }
    func isHealer(_ n: String) -> Bool { profile(n)?.isHealer ?? false }
    /// Counts for anti-air: ranged operators and melee 领主 (`OperatorProfile.hitsAir`).
    func isRanged(_ n: String) -> Bool { profile(n)?.hitsAir == true }
    func isArts(_ n: String) -> Bool { ["术师", "辅助"].contains(profile(n)?.profession ?? "") }

    /// Covenant counts (调和 adds one to each core present; strategy pieces included when `pieces`).
    func count(_ team: [String], transforms: [String: String] = [:], mech: [String] = [], pieces: Bool = true) -> [String: Int] {
        var counts: [String: Int] = [:]
        var present = Set<String>()
        var harmony = 0
        for n in team {
            guard let o = byName[n] else { continue }
            for c in Set(o.allCovenants) {
                counts[c, default: 0] += 1
                if isCore(c) { present.insert(c) }
            }
            if o.allCovenants.contains(PlanRules.harmony) { harmony += 1 }
            if let t = transforms[n] { counts[t, default: 0] += 1; if isCore(t) { present.insert(t) } }
        }
        if pieces {
            if strategy.piece == .mech { counts[PlanRules.mech, default: 0] += 1 }
            for t in mech { counts[t, default: 0] += 1; if isCore(t) { present.insert(t) } }
            harmony += strategy.extraHarmony
            if strategy.extraHarmony > 0 { counts[PlanRules.harmony, default: 0] += strategy.extraHarmony }
        }
        if harmony > 0 { for c in present { counts[c, default: 0] += harmony } }
        return counts
    }

    func isActive(_ counts: [String: Int], _ c: String) -> Bool { counts[c, default: 0] >= activate(c) }

    /// Layers per round an operator adds to `covenant` itself (normal traits).
    func layers(_ o: Operator, on covenant: String) -> Double {
        guard let st = profile(o.name)?.stack else { return 0 }
        let per = st.perRound * (st.temporary ? 0.5 : 1)
        switch st.kind {
        case "covenant": return st.covenants.contains(covenant) ? per : 0
        case "self": return o.allCovenants.contains(covenant) ? per : 0
        default: return 0
        }
    }

    /// Layers per round each operator adds, split into covenants the boss lineup keeps (final) and others
    /// (LineupRoutePlanner.StackLayers, amplifiers included).
    func stackLayers(_ team: [Operator], counts: [String: Int], finalActive: Set<String>) -> [String: (final: Double, transition: Double)] {
        func on(_ covs: [String], _ per: Double) -> (Double, Double) {
            var f = 0.0, t = 0.0
            for c in Set(covs) where isActive(counts, c) { if finalActive.contains(c) { f += per } else { t += per } }
            return (f, t)
        }
        func value(_ x: (Double, Double)) -> Double { 6 * x.0 + 2 * x.1 }
        func bestNeighbour(_ me: Operator, _ per: Double) -> Operator? {
            team.filter { $0.name != me.name }.max { value(on($0.allCovenants, per)) < value(on($1.allCovenants, per)) }
        }
        var result: [String: (Double, Double)] = [:]
        for o in team {
            guard let st = profile(o.name)?.stack else { continue }
            let per = st.perRound * (st.temporary ? 0.5 : 1)
            switch st.kind {
            case "covenant": result[o.name] = on(st.covenants, per)
            case "self": result[o.name] = on(o.allCovenants, per)
            case "adjacent":
                let a = on(o.allCovenants, per)
                let b = bestNeighbour(o, per).map { on($0.allCovenants, per) } ?? (0, 0)
                result[o.name] = (a.0 + b.0, a.1 + b.1)
            case "grant": result[o.name] = bestNeighbour(o, per).map { on($0.allCovenants, per) } ?? (0, 0)
            default: break
            }
        }
        let capped = team.filter { if let s = profile($0.name)?.stack { return s.cap != nil && s.kind != "once" && s.kind != "amplifier" }; return false }
        for o in team {
            guard let st = profile(o.name)?.stack, st.kind == "amplifier", let amp = st.amplify else { continue }
            var extra = (0.0, 0.0)
            switch amp.type {
            case "capPercent":
                let eligible = capped.filter { $0.name != o.name && (st.covenants.isEmpty || $0.allCovenants.contains(where: st.covenants.contains)) }
                    .map { c -> (Double, Double) in let r = result[c.name] ?? (0, 0); return (r.0 * amp.value, r.1 * amp.value) }
                    .sorted { value($0) > value($1) }.prefix(amp.scope == "front" ? 1 : 3)
                for e in eligible { extra.0 += e.0; extra.1 += e.1 }
            case "capFlat":
                for c in capped where c.name != o.name && !Set(c.allCovenants).isDisjoint(with: o.allCovenants) {
                    let stc = profile(c.name)!.stack!
                    let r = on(stc.kind == "covenant" ? stc.covenants : c.allCovenants, amp.value * 0.75)
                    extra.0 += r.0; extra.1 += r.1
                }
            case "perEvent":
                extra = team.filter { $0.name != o.name && result[$0.name] != nil && (profile($0.name)?.stack?.amount ?? 0) > 0 }
                    .map { c -> (Double, Double) in
                        let stc = profile(c.name)!.stack!
                        let k = 1 / stc.perRound * (stc.perRound / (stc.amount ?? 1)) * amp.value
                        let r = result[c.name]!
                        return (r.0 * k, r.1 * k)
                    }.max { value($0) < value($1) } ?? (0, 0)
            case "tempBoost":
                extra = on(st.covenants, (amp.value - 2) * 2 * 0.5)
            default: break
            }
            result[o.name] = extra
        }
        return result.mapValues { (final: $0.0, transition: $0.1) }
    }
}

// MARK: - Lineup planner

struct PlannedLineup: Hashable {
    var operators: [String]
    var transforms: [String: String]
    var mech: [String]
    var counts: [String: Int]
    var additionalScore: Int
    var additionalLevels: [String: Int]
    var missingHealer: Bool
    var people: Int
    var transformCount: Int
    var forcedTransforms: Int
    var piecePlaces: Int
    var freeSlots: Int { max(0, people - piecePlaces - operators.count) }
}

final class LineupPlanner {
    struct Request {
        var goals: [PlannerGoal]
        var unavailable: Set<String> = []
        var bannedOperators: Set<String> = []
        var locked: [String] = []
        var preferred: Set<String> = []
        var people = 8
        var transforms = 0
        var maxResults = 3
        var maxNodes = 40000
    }

    private let d: PlannerData
    init(_ data: PlannerData) { d = data }

    func plan(_ r: Request) -> (lineups: [PlannedLineup], limited: Bool, error: String?) {
        if let g = r.goals.first(where: { $0.isCore && r.unavailable.contains($0.name) }) {
            return ([], false, "核心盟约「\(g.name)」本局不可用")
        }
        let cands = d.ops.filter { !r.bannedOperators.contains($0.name) }
        let index = Dictionary(cands.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
        if let missing = r.locked.first(where: { index[$0] == nil }) { return ([], false, "必带干员「\(missing)」本局不可用") }
        if r.locked.count > 9 { return ([], false, "必带干员不能超过 9 人") }
        let allowed = d.covenants.map(\.name).filter { !r.unavailable.contains($0) && !PlanRules.noTransform.contains($0) }
        let s = Search(d: d, r: r, ops: cands, allowed: allowed, locked: r.locked.compactMap { index[$0] })
        return (s.solve(), s.limited, nil)
    }

    private final class Search {
        let d: PlannerData
        let r: LineupPlanner.Request
        let ops: [Operator]
        let native: [Set<String>]
        let harmony: [Bool]
        let healer: [Bool]
        let preferred: [Bool]
        let allowedOrdered: [String]
        let allowed: Set<String>
        let locked: [Int]
        let lockedSet: Set<Int>
        let rarity: [String: Int]
        let additionalNames: Set<String>
        let hasSolo: Bool
        let healerData: Bool
        let healingNeed: Int
        let mechCap: Int
        let extraHarmony: Int
        var requireHealer = false
        var teamSize = 0
        var nodes = 0
        var limited = false
        var found: [PlannedLineup] = []
        var seen = Set<String>()
        var picked: [Int] = []
        var used: [Bool]
        var visited = Set<String>()

        init(d: PlannerData, r: LineupPlanner.Request, ops: [Operator], allowed: [String], locked: [Int]) {
            self.d = d; self.r = r; self.ops = ops
            native = ops.map { Set($0.allCovenants) }
            harmony = native.map { $0.contains(PlanRules.harmony) }
            healer = ops.map { d.isHealer($0.name) }
            preferred = ops.map { r.preferred.contains($0.name) }
            allowedOrdered = allowed
            self.allowed = Set(allowed)
            self.locked = locked
            lockedSet = Set(locked)
            used = Array(repeating: false, count: ops.count)
            let natives = native
            rarity = Dictionary(r.goals.map { g in (g.name, natives.filter { $0.contains(g.name) }.count) }, uniquingKeysWith: { a, _ in a })
            let goalNames = Set(r.goals.map(\.name))
            additionalNames = Set(d.covenants.filter { !$0.isCore && !goalNames.contains($0.name) && !PlanRules.noAdditionalScore.contains($0.name) }.map(\.name))
            hasSolo = r.goals.contains { $0.name == PlanRules.solo }
            healerData = healer.contains(true) && !d.strategy.healerProvided
            healingNeed = d.covByName[PlanRules.healing].map { PlanRules.goal($0, level: 1).count } ?? 0
            mechCap = d.strategy.mechCap
            extraHarmony = d.strategy.extraHarmony
        }

        func solve() -> [PlannedLineup] {
            let places = r.people - d.strategy.piecePlaces
            teamSize = min(places, ops.count)
            guard locked.count <= places else { return [] }
            for i in locked { picked.append(i); used[i] = true }
            requireHealer = healerData
            visit()
            if found.isEmpty && requireHealer {
                requireHealer = false
                nodes = 0; visited.removeAll()
                visit()
                found = found.map { var f = $0; f.missingHealer = true; return f }
            }
            return found
        }

        func count(_ team: [Int], _ tr: [Int: String], _ mech: [String] = []) -> [String: Int] {
            var counts: [String: Int] = [:]
            var present = Set<String>()
            var h = 0
            for i in team {
                for c in native[i] where c != PlanRules.harmony {
                    counts[c, default: 0] += 1
                    if d.isCore(c) { present.insert(c) }
                }
                if harmony[i] { h += 1; counts[PlanRules.harmony, default: 0] += 1 }
                if let t = tr[i] { counts[t, default: 0] += 1; present.insert(t) }
            }
            if mechCap > 0 { counts[PlanRules.mech, default: 0] += 1 }
            for t in mech { counts[t, default: 0] += 1; present.insert(t) }
            if extraHarmony > 0 { h += extraHarmony; counts[PlanRules.harmony, default: 0] += extraHarmony }
            if h > 0 { for g in r.goals where g.isCore && present.contains(g.name) { counts[g.name, default: 0] += h } }
            return counts
        }

        func hasHealer(_ team: [Int], _ counts: [String: Int]) -> Bool {
            !requireHealer || team.contains { healer[$0] } || (healingNeed > 0 && counts[PlanRules.healing, default: 0] >= healingNeed)
        }

        func transformDeficit(_ g: PlannerGoal, _ counts: [String: Int]) -> Int {
            let have = counts[g.name, default: 0]
            let deficit = max(0, g.count - have)
            if g.isCore && have == 0 && deficit > 0 {
                return max(1, deficit - picked.filter { harmony[$0] }.count - extraHarmony)
            }
            return deficit
        }

        func contributes(_ i: Int, _ g: PlannerGoal, _ counts: [String: Int]) -> Bool {
            native[i].contains(g.name) || (g.isCore && harmony[i] && (counts[g.name, default: 0] > 0 || (r.transforms > 0 && allowed.contains(g.name))))
        }

        func visit() {
            if found.count >= r.maxResults { return }
            nodes += 1
            if nodes > r.maxNodes { limited = true; return }
            let counts = count(picked, [:])
            if hasSolo && counts[PlanRules.solo, default: 0] > 1 { return }
            let missing = r.goals.filter { counts[$0.name, default: 0] < $0.count }
            let slots = teamSize - picked.count
            let trDeficit = missing.reduce(0) { $0 + transformDeficit($1, counts) }
            let needHealer = !hasHealer(picked, counts)
            if slots <= 0 {
                if missing.allSatisfy({ allowed.contains($0.name) }) && trDeficit <= r.transforms { tryFinish(counts) }
                return
            }
            if !canStillReach(missing, counts, slots) { return }
            if !visited.insert(picked.sorted().map(String.init).joined(separator: ",")).inserted { return }
            let covered = missing.allSatisfy { allowed.contains($0.name) } && trDeficit <= r.transforms
            let pivot: PlannerGoal? = (!missing.isEmpty && !covered) ? missing.min { a, b in
                (allowed.contains(a.name) ? 1 : 0, rarity[a.name] ?? 0, -(a.count - counts[a.name, default: 0]))
                    < (allowed.contains(b.name) ? 1 : 0, rarity[b.name] ?? 0, -(b.count - counts[b.name, default: 0]))
            } : nil
            var branches: [(Int, Double)] = []
            for i in ops.indices where !used[i] {
                if hasSolo && native[i].contains(PlanRules.solo) && counts[PlanRules.solo, default: 0] >= 1 { continue }
                if let p = pivot, !contributes(i, p, counts) { continue }
                if needHealer && slots == 1 && !healer[i] && r.transforms == 0 { continue }
                let gain = missing.filter { contributes(i, $0, counts) }.count
                let extra = native[i].filter { additionalNames.contains($0) }.count
                let heal = needHealer && healer[i] ? 5.0 : 0
                let own = preferred[i] ? 3.0 : 0
                branches.append((i, 10 * Double(gain) + heal + own + 0.8 * Double(extra) + Double(i * 13 % 31) / 50))
            }
            if branches.isEmpty && missing.isEmpty { tryFinish(counts); return }
            var expanded = 0
            for (i, _) in branches.sorted(by: { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }) {
                if nodes > r.maxNodes { break }
                expanded += 1
                if expanded > 48 { if pivot != nil { limited = true }; break }
                picked.append(i); used[i] = true
                visit()
                picked.removeLast(); used[i] = false
            }
        }

        func canStillReach(_ missing: [PlannerGoal], _ counts: [String: Int], _ slots: Int) -> Bool {
            var maxCover = 0
            var unused: [String: Int] = [:]
            for i in ops.indices where !used[i] {
                var cover = 0
                for g in missing where native[i].contains(g.name) || (g.isCore && harmony[i]) {
                    cover += 1
                    unused[g.name, default: 0] += 1
                }
                maxCover = max(maxCover, cover)
            }
            var total = 0
            for g in missing {
                let deficit = transformDeficit(g, counts)
                total += deficit
                var reach = min(slots, unused[g.name, default: 0])
                if allowed.contains(g.name) { reach += r.transforms }
                if deficit > reach { return false }
            }
            return total <= slots * maxCover + r.transforms
        }

        func tryFinish(_ nativeCounts: [String: Int]) {
            let team = picked
            var tr: [Int: String] = [:]
            var mech: [String] = []
            func usedTransforms() -> Int { tr.count + mech.count }
            func assign(_ c: String) -> Bool {
                if mech.count < mechCap && !mech.contains(c) { mech.append(c); return true }
                for i in team.sorted(by: { (lockedSet.contains($0) ? 1 : 0) < (lockedSet.contains($1) ? 1 : 0) })
                where tr[i] == nil && !native[i].contains(c) { tr[i] = c; return true }
                return false
            }
            for g in r.goals {
                for _ in 0..<transformDeficit(g, nativeCounts) {
                    if usedTransforms() >= r.transforms || !allowed.contains(g.name) { return }
                    if !assign(g.name) { return }
                }
            }
            var forced = 0
            let goalTargets = r.goals.map(\.name).filter { allowed.contains($0) }
            while usedTransforms() < r.transforms && mech.count < mechCap {
                guard let t = goalTargets.first(where: { !mech.contains($0) })
                    ?? allowedOrdered.filter({ !mech.contains($0) }).max(by: { transformScore($0, team, tr, mech) < transformScore($1, team, tr, mech) })
                else { break }
                mech.append(t); forced += 1
            }
            for i in team where usedTransforms() < r.transforms && tr[i] == nil {
                let target = goalTargets.first { !native[i].contains($0) }
                    ?? allowedOrdered.filter { !native[i].contains($0) }.max { transformScore($0, team, tr, mech) < transformScore($1, team, tr, mech) }
                if let t = target { tr[i] = t; forced += 1 }
            }
            guard usedTransforms() == r.transforms else { return }
            let counts = count(team, tr, mech)
            if r.goals.contains(where: { counts[$0.name, default: 0] < $0.count }) { return }
            if !hasHealer(team, counts) { return }
            if hasSolo && counts[PlanRules.solo, default: 0] != 1 { return }
            let key = team.map { ops[$0].name }.sorted().joined(separator: ",") + "|"
                + tr.map { "\(ops[$0.key].name):\($0.value)" }.sorted().joined(separator: ",") + "|" + mech.sorted().joined(separator: ",")
            guard seen.insert(key).inserted else { return }
            let (score, levels) = self.score(counts)
            found.append(PlannedLineup(
                operators: team.sorted { (lockedSet.contains($0) ? 0 : 1) < (lockedSet.contains($1) ? 0 : 1) }.map { ops[$0].name },
                transforms: Dictionary(tr.map { (ops[$0.key].name, $0.value) }, uniquingKeysWith: { a, _ in a }),
                mech: mech, counts: counts, additionalScore: score, additionalLevels: levels, missingHealer: false,
                people: r.people, transformCount: r.transforms, forcedTransforms: forced, piecePlaces: d.strategy.piecePlaces))
            found = Array(found.sorted {
                ($0.additionalScore, $0.additionalLevels.count, -$0.operators.count) > ($1.additionalScore, $1.additionalLevels.count, -$1.operators.count)
            }.prefix(r.maxResults))
        }

        func transformScore(_ c: String, _ team: [Int], _ tr: [Int: String], _ mech: [String]) -> Int {
            guard additionalNames.contains(c) else { return 0 }
            let cur = count(team, tr, mech)[c, default: 0]
            if cur + 1 < d.activate(c) { return 0 }
            return PlanRules.peopleSecond.contains(c) && cur + 1 >= 3 ? 3 : 1
        }

        func score(_ counts: [String: Int]) -> (Int, [String: Int]) {
            var levels: [String: Int] = [:]
            for c in d.covenants where additionalNames.contains(c.name) {
                let n = counts[c.name, default: 0]
                guard n >= c.activateCount else { continue }
                levels[c.name] = PlanRules.peopleSecond.contains(c.name) && n >= 3 ? 3 : 1
            }
            return (levels.values.reduce(0, +), levels)
        }
    }
}

// MARK: - Auto planner

enum PlanStyle: String, CaseIterable, Identifiable, Codable {
    case coreFirst = "先大后小"
    case smallFirst = "先小后大"
    var id: String { rawValue }
    /// 大 = the 本家 (core covenant), 小 = small (additional) covenants. Terms from hongxue's planner.
    var explain: String {
        switch self {
        case .coreFirst: "先大后小：开局就凑 3 名本家干员把本家激活，一路叠层；小盟约之后顺手补"
        case .smallFirst: "先小后大：前期本家的低阶牌不够，先用小盟约（附加盟约）撑过前几回合，五本以后换成本家成型阵容"
        }
    }
}

struct PlanStacker: Hashable { let name: String; let tier: Int; let perRound: Double }

struct PlanCandidate: Identifiable, Hashable {
    let main: String
    let final: PlannedLineup
    let mainGoal: PlannerGoal
    let smallGoals: [PlannerGoal]
    let stackers: [PlanStacker]
    let earlyLayers: Double
    let lateLayers: Double
    let activationLevel: Int
    let holders: Int
    let ownedHolders: [String]
    let ownedKept: Int
    let keptSmall: [PlannerGoal]
    let style: PlanStyle
    let styleReason: String
    var score: Double
    var notes: [String]
    /// 小盟约路线: 本家 only at Ⅰ (3 人), the lineup built around two small covenants at Ⅱ.
    var smallRoute = false
    /// The small covenants a 小盟约路线 is built on.
    var pair: [PlannerGoal] = []
    var id: String { smallRoute ? main + "·" + pair.map(\.name).joined(separator: "+") : main }
    var goals: [PlannerGoal] { [mainGoal] + smallGoals }
    var title: String { smallRoute ? pair.map { $0.name + ($0.level == 2 ? "Ⅱ" : "Ⅰ") }.joined(separator: "+") + " · \(main)Ⅰ" : "\(main)\(mainGoal.level == 2 ? "Ⅱ" : "Ⅰ")" }
}

struct PlanRequest {
    /// Search nodes per lineup search. 8000 gave the same routes as 25000 in every case tried (2026-11-21: six setups
    /// incl. 12 held operators) in less than half the time. PLAN_NODES overrides for tests.
    var nodeBudget = Int(ProcessInfo.processInfo.environment["PLAN_NODES"] ?? "") ?? 8000
    var unavailable: Set<String> = []        // banned + out of mode pool
    var bannedOperators: Set<String> = []
    var owned: [String] = []
    var locked: [String] = []
    var people = 8
    var maxTransforms = 2
    /// Terminal level read from the game (nil = unknown); the matching stage keeps held operators.
    var currentLevel: Int?
    /// Small covenants already active in the held lineup: kept as goals when the 本家 allows it.
    var keepSmall: [PlannerGoal] = []
    /// Core covenants other players in the lobby are building → how many of them (their copies come out of the same
    /// shared card pool, so a contested 本家 fills slowly).
    var contested: [String: Double] = [:]
}

struct AutoPlanner {
    static let stackerLevel = 5
    let d: PlannerData

    func candidates(_ req: PlanRequest) -> [PlanCandidate] {
        let pool = d.ops.filter { !req.bannedOperators.contains($0.name) }
        let cores = d.covenants.filter { $0.isCore && !req.unavailable.contains($0.name) }
        var out: [PlanCandidate] = []
        let lock = NSLock()
        // Every route worth listing: each 本家, and per 本家 up to eight 小盟约 pairs (one route per pair overall). The list
        // shows the first 16 and the rest behind 「显示全部」 (2026-11-23: up to 43 routes, under a second).
        let env = ProcessInfo.processInfo.environment
        let smallCap = env["PLAN_SMALL_CAP"].flatMap(Int.init) ?? 99
        let perCore = env["PLAN_PER_CORE"].flatMap(Int.init) ?? 8
        // Each 本家: the usual 本家Ⅱ build, and 小盟约 builds (本家Ⅰ + a pair of small covenants), most promising pairs first.
        DispatchQueue.concurrentPerform(iterations: cores.count * 2) { i in
            let cov = cores[i / 2]
            if i % 2 == 0 {
                if let c = build(cov, pool: pool, req: req) { lock.lock(); out.append(c); lock.unlock() }
                return
            }
            var found = 0
            for pair in smallPairs(cov, pool: pool, req: req) where found < perCore {
                if let c = build(cov, pool: pool, req: req, smallRoute: true, pair: pair) { found += 1; lock.lock(); out.append(c); lock.unlock() }
            }
        }
        // A 本家 other players are building: its cards are shared with them, so the route fills slower.
        for i in out.indices {
            guard let k = req.contested[out[i].main], k >= 0.5 else { continue }
            out[i].score *= max(0.4, 1 - 0.15 * k)
            out[i].notes.append(k >= 1 ? "另有 \(Int(k.rounded())) 名玩家在做\(out[i].main)，牌会被抢" : "有玩家手上有\(out[i].main)的牌，可能会抢")
        }
        // Keep every 本家 build and the best 小盟约 builds (smallCap), one per pair of small covenants.
        var seenPairs = Set<String>(), small = Set<String>()
        for c in out.filter(\.smallRoute).sorted(by: { $0.score > $1.score }) where small.count < smallCap {
            let key = c.pair.map(\.name).sorted().joined(separator: "+")
            if seenPairs.insert(key).inserted { small.insert(c.id) }
        }
        return out.filter { !$0.smallRoute || small.contains($0.id) }.sorted { ($0.score, $0.id) > ($1.score, $1.id) }
    }

    /// Small covenants a route can be built on, best first for this 本家: already held, then shared holders with the
    /// 本家, then the size of the pool (a covenant needs a few more holders than people to be reachable).
    private func smallPartners(_ cov: Covenant, pool: [Operator], req: PlanRequest) -> [Covenant] {
        let held = d.count(Array(Set(req.owned)))
        struct Partner { let c: Covenant; let held: Int; let shared: Int; let total: Int }
        var list: [Partner] = []
        for c in d.covenants where !c.isCore && PlanRules.routeSmall.contains(c.name) && !req.unavailable.contains(c.name) {
            let holders = pool.filter { $0.allCovenants.contains(c.name) }
            let shared = holders.filter { $0.allCovenants.contains(cov.name) }.count
            let need = PlanRules.goal(c, level: 2).count
            if holders.count >= need + 1 { list.append(Partner(c: c, held: held[c.name, default: 0], shared: shared, total: holders.count)) }
        }
        list.sort { a, b in (a.held, a.shared, a.total, a.c.name) > (b.held, b.shared, b.total, b.c.name) }
        return list.prefix(6).map(\.c)
    }

    /// Pairs of partners at their best people level, most promising first (pairs with a held covenant, then pairs of
    /// covenants with a Ⅱ).
    private func smallPairs(_ cov: Covenant, pool: [Operator], req: PlanRequest) -> [[PlannerGoal]] {
        let partners = smallPartners(cov, pool: pool, req: req)
        var pairs: [(goals: [PlannerGoal], rank: Int)] = []
        for i in partners.indices {
            for j in partners.indices where j > i {
                let a = PlanRules.goal(partners[i], level: 2), b = PlanRules.goal(partners[j], level: 2)
                pairs.append(([a, b], i + j - (a.level == 2 ? 1 : 0) - (b.level == 2 ? 1 : 0)))
            }
        }
        return pairs.sorted { $0.rank < $1.rank }.prefix(8).map(\.goals)
    }

    private func build(_ cov: Covenant, pool: [Operator], req: PlanRequest, smallRoute: Bool = false, pair: [PlannerGoal] = []) -> PlanCandidate? {
        let planner = LineupPlanner(d)
        let owned = Set(req.owned)
        let free = d.strategy.freeTransforms
        let order = d.strategy.transformOptions.filter { $0 <= max(req.maxTransforms, free) }
            .sorted { ($0 == free ? 0 : 1, $0) < ($1 == free ? 0 : 1, $1) }
        var final: PlannedLineup?
        var goal: PlannerGoal?
        var kept: [PlannerGoal] = []
        var limited = false
        // Try to keep the small covenants already built, then fewer of them, then none.
        let smallSets: [[PlannerGoal]]
        if smallRoute {
            smallSets = [pair]
        } else {
            smallSets = req.keepSmall.isEmpty ? [[]] : [req.keepSmall, Array(req.keepSmall.prefix(1)), []]
        }
        search: for small in smallSets {
            goal = nil
            for level in smallRoute ? [1] : [2, 1] {
                let g = PlanRules.goal(cov, level: level)
                if let prev = goal, prev.count == g.count { break }
                goal = g
                for t in order {
                    let res = planner.plan(.init(goals: [g] + small, unavailable: req.unavailable, bannedOperators: req.bannedOperators,
                                                 locked: req.locked, preferred: owned, people: req.people, transforms: t, maxResults: 12, maxNodes: req.nodeBudget))
                    limited = limited || res.limited
                    if res.error != nil { return nil }
                    final = res.lineups.min { a, b in
                        func key(_ l: PlannedLineup) -> (Int, Int, Int, Int, Int, Int) {
                            (l.missingHealer ? 1 : 0, l.freeSlots, -l.operators.filter(owned.contains).count, -l.additionalScore,
                             -l.operators.reduce(0) { $0 + (d.byName[$1]?.tier ?? 0) }, l.forcedTransforms)
                        }
                        return key(a) < key(b)
                    }
                    if final != nil { kept = small; break search }
                }
            }
        }
        guard let final, let goal else { return nil }
        let name = cov.name
        let holders = pool.filter { $0.allCovenants.contains(name) }
        let stackers = pool.map { (op: $0, l: d.layers($0, on: name)) }.filter { $0.l > 0 }
            .sorted { ($0.op.tier, -$0.l, $0.op.name) < ($1.op.tier, -$1.l, $1.op.name) }
            .map { PlanStacker(name: $0.op.name, tier: $0.op.tier, perRound: $0.l) }
        func best(_ maxTier: Int) -> [PlanStacker] {
            Array(stackers.filter { $0.tier <= maxTier }.sorted { ($0.perRound, -$0.tier) > ($1.perRound, -$1.tier) }.prefix(3))
        }
        let early = best(AutoPlanner.stackerLevel - 1), late = best(6)
        let earlyL = early.reduce(0) { $0 + $1.perRound }, lateL = late.reduce(0) { $0 + $1.perRound }
        let need = max(1, cov.activateCount - d.strategy.extraHarmony)
        let activation = (1...6).first { l in holders.filter { $0.tier <= l }.count >= need } ?? 0
        var (style, reason) = recommendStyle(name, need, activation, early, late, earlyL, lateL)
        // Already holding most of an early 本家: keep building it.
        let ownedHolders = req.owned.filter { n in holders.contains { $0.name == n } }
        let heldSmall = Set(req.keepSmall.map(\.name))
        if smallRoute {
            style = .smallFirst
            let pair: String = kept.map { g in g.name + (g.level == 2 ? "Ⅱ" : "Ⅰ") + "（\(g.count)人）" }.joined(separator: " + ")
            let doing: [String] = kept.map(\.name).filter { heldSmall.contains($0) }
            reason = "小盟约路线：主力靠 \(pair)，\(name) 只开Ⅰ（\(need)人）凑层数"
            if !doing.isEmpty { reason += "；已经在做 " + doing.joined(separator: "、") }
        } else if style == .smallFirst && Set(ownedHolders).count >= need && activation <= 3 {
            style = .coreFirst
            reason = "已持有 \(Set(ownedHolders).count) 名\(name)干员，本家已经能激活：直接先大后小"
        }
        var smalls = final.additionalLevels.compactMap { k, v in d.covByName[k].map { PlanRules.goal($0, level: v >= 3 ? 2 : 1) } }
            .sorted { ($0.level, $0.name) > ($1.level, $1.name) }
        for k in kept where !smalls.contains(where: { $0.name == k.name }) { smalls.insert(k, at: 0) }
        var notes: [String] = []
        if limited { notes.append("搜索受限，只展示已找到的方案") }
        if goal.level < 2 && !smallRoute && !PlanRules.noSecond.contains(name) { notes.append("\(name) 只凑得到 \(goal.count) 人") }
        let realTransforms = final.transformCount - final.forcedTransforms
        if realTransforms > 0 {
            let targets = Array(Set(Array(final.transforms.values) + final.mech)).sorted()
            let gear = targets.flatMap { d.jobChange[$0] ?? [] }
            notes.append("需要 \(realTransforms) 次转职" + (gear.isEmpty ? "" : "（\(gear.prefix(4).joined(separator: "、"))）"))
        }
        if final.missingHealer { notes.append("成型阵容没有奶位") }
        if final.freeSlots > 0 { notes.append("可用干员不够，空 \(final.freeSlots) 个位置") }
        if !ownedHolders.isEmpty { notes.append("已持有本家 \(Set(ownedHolders).count) 人") }
        if !kept.isEmpty && !smallRoute { notes.append("保留现有小盟约：" + kept.map(\.label).joined(separator: "、")) }
        let ownedKept = final.operators.filter(owned.contains).count
        let keptCount = smallRoute ? kept.filter { heldSmall.contains($0.name) }.count : kept.count
        var score = (goal.level == 2 ? 40.0 : 0) + 10 * Double(final.additionalScore) + lateL + 0.5 * earlyL
            - 6 * Double(max(0, realTransforms - free)) - (final.missingHealer ? 25 : 0) - 10 * Double(final.freeSlots)
            // Switching 本家 costs more the later it is: held 本家 operators weigh more at higher terminal levels.
            + (6 + 3 * Double(max(0, (req.currentLevel ?? 1) - 1))) * Double(Set(ownedHolders).count)
            + 6 * Double(ownedKept) + 12 * Double(keptCount)
        // Strategy and enemy adjustments.
        if d.strategy.favoredCores.contains(name) { score += 30; notes.append("策略「\(d.strategy.name)」加成这条本家") }
        if d.strategy.activeCovenantBonus { score += 6 * Double(final.counts.filter { d.isActive(final.counts, $0.key) }.count) }
        if d.strategy.stackingBonus { score += 0.5 * lateL }
        if d.enemy.antiAir {
            let ranged = final.operators.filter(d.isRanged).count
            if ranged < 3 { score -= 15; notes.append("对空：成型阵容能打飞行的只有 \(ranged) 名（远程 / 领主）") }
        }
        if d.enemy.preferArts { score += 2 * Double(final.operators.filter(d.isArts).count) }
        if d.enemy.preferPhysical { score += 2 * Double(final.operators.filter { !d.isArts($0) }.count) }
        return PlanCandidate(main: name, final: final, mainGoal: goal, smallGoals: smalls, stackers: stackers,
                             earlyLayers: (earlyL * 10).rounded() / 10, lateLayers: (lateL * 10).rounded() / 10,
                             activationLevel: activation, holders: holders.count, ownedHolders: ownedHolders, ownedKept: ownedKept, keptSmall: kept,
                             style: style, styleReason: reason, score: score, notes: notes, smallRoute: smallRoute, pair: smallRoute ? kept : [])
    }

    private func recommendStyle(_ name: String, _ need: Int, _ activation: Int, _ early: [PlanStacker], _ late: [PlanStacker],
                                _ earlyL: Double, _ lateL: Double) -> (PlanStyle, String) {
        func names(_ s: [PlanStacker]) -> String { s.map(\.name).joined(separator: "、") }
        func f(_ x: Double) -> String { String(format: "%.1f", x) }
        if activation == 0 || activation > 3 {
            return (.smallFirst, activation == 0 ? "本局凑不齐 \(need) 名原生\(name)干员，前期只能靠小盟约"
                    : "低阶\(name)干员不够，\(activation) 本才凑得齐 \(need) 人：前期先靠小盟约过渡")
        }
        if lateL <= 0 {
            return activation <= 2 ? (.coreFirst, "\(name)没有专属叠层手，二本就能凑齐 \(need) 人：先激活本家")
                : (.smallFirst, "\(name)没有专属叠层手，三本才凑得齐 \(need) 人：前期先靠小盟约过渡")
        }
        if earlyL >= 0.5 * lateL { return (.coreFirst, "四本前就能给\(name)每回合叠约 \(f(earlyL)) 层（\(names(early))），开局先激活本家一路叠") }
        let lateOnly = late.filter { $0.tier >= AutoPlanner.stackerLevel }
        return (.smallFirst, lateOnly.isEmpty ? "四本前每回合只能给\(name)叠约 \(f(earlyL)) 层：前期先靠小盟约过渡"
                : "\(name)的叠层主力在五本以后（\(names(lateOnly))），四本前每回合只有约 \(f(earlyL)) 层：前期先靠小盟约过渡")
    }
}

// MARK: - Route planner

struct StageDef: Hashable {
    let name: String
    let terminal: Int
    let maxTier: Int
    let tripleSlots: Int
    var people: Int
    var stacking = false
    var smallGoals: [PlannerGoal]? = nil
    var required: [PlannerGoal] = []
    let rounds: String

    static let defaults: [StageDef] = [
        StageDef(name: "开局", terminal: 2, maxTier: 2, tripleSlots: 1, people: 6, rounds: "第 1–3 回合"),
        StageDef(name: "前期", terminal: 3, maxTier: 3, tripleSlots: 1, people: 8, rounds: "第 4–6 回合"),
        StageDef(name: "中期", terminal: 4, maxTier: 4, tripleSlots: 2, people: 8, rounds: "第 7–9 回合"),
        StageDef(name: "后期（叠层）", terminal: 6, maxTier: 6, tripleSlots: 0, people: 8, stacking: true, rounds: "第 10–13 回合"),
    ]
}

struct RouteOp: Hashable, Identifiable {
    let name: String
    let tier: Int
    let isFinal: Bool
    let isNew: Bool
    let owned: Bool
    let viaTriple: Bool
    var transform: String?
    var isTank = false
    var isHealer = false
    var layers = 0.0
    var id: String { name }
}

enum Pace: String { case rush = "抢升本", stay = "补牌", steady = "稳升", max = "满本" }

struct LevelAdvice: Hashable, Identifiable {
    let level: Int
    let pace: Pace
    let focus: String
    let buy: [(reason: String, names: [String])]
    let upgrade: String
    let economy: String
    let reserve: [String]
    let keyCards: [String]
    var id: Int { level }
    static func == (a: LevelAdvice, b: LevelAdvice) -> Bool { a.level == b.level && a.focus == b.focus && a.upgrade == b.upgrade }
    func hash(into h: inout Hasher) { h.combine(level); h.combine(focus) }
}

struct RouteStage: Identifiable, Hashable {
    let def: StageDef
    let ops: [RouteOp]
    let removed: [String]
    let active: [(String, Int)]
    let goalStatus: [(String, Int, Int)]   // name, have, need
    let warnings: [String]
    let focus: String
    let layersPerRound: Double
    var advice: [LevelAdvice] = []
    var isFinal = false
    var id: String { def.name }
    static func == (a: RouteStage, b: RouteStage) -> Bool { a.def == b.def && a.ops == b.ops && a.advice == b.advice }
    func hash(into h: inout Hasher) { h.combine(def); h.combine(ops) }
}

struct PlannedRoute {
    let candidate: PlanCandidate; let style: PlanStyle; let stages: [RouteStage]; let equipment: [String]
    var substitutes: [RouteSubstitute] = []
}

/// A stand-in for a missing operator of the final lineup: covers the same route covenants for now.
struct RouteSubstitute: Hashable {
    let missing: String
    let standIn: String
    /// Held now (else: the current terminal can roll it).
    let owned: Bool
    let text: String
}

struct RouteState { var owned: Set<String> = []; var level: Int?; var money: Int?; var round: Int? }

struct RoutePlanner {
    let d: PlannerData

    /// Stand-ins for final-lineup operators not held yet. A stand-in keeps the 本家 count when the missing operator is a
    /// 本家 member, shares at least one of its route covenants, is held or rollable at the current terminal level, and is
    /// not already in the final lineup. Held first, then the most of the missing operator's route covenants, the most
    /// route covenants overall, the same role (tank / healer / melee or ranged), and the closest tier. The text names
    /// the route covenants the stand-in doesn't carry. Operators the route needs only through a job change are skipped.
    func substitutes(_ c: PlanCandidate, pool: [Operator], owned: Set<String>, level: Int?, limit: Int = 4) -> [RouteSubstitute] {
        let goalNames = Set(c.goals.map(\.name))
        let final = c.final.operators
        let finalSet = Set(final)
        var used = Set<String>()
        var out: [RouteSubstitute] = []
        for name in final where !owned.contains(name) && c.final.transforms[name] == nil {
            guard out.count < limit, let m = d.byName[name] else { continue }
            let need = Set(m.allCovenants).intersection(goalNames)
            guard !need.isEmpty else { continue }
            let mp = d.profile(name)
            func role(_ p: OperatorProfile?) -> String { p?.isHealer == true ? "奶" : p?.isTank == true ? "盾" : p?.position ?? "" }
            let terminal = level ?? max(1, m.tier - 1)
            let best = pool.filter { o in
                !finalSet.contains(o.name) && !used.contains(o.name) && o.obtain == nil
                    && (owned.contains(o.name) || o.tier <= terminal)
                    && (!need.contains(c.main) || o.allCovenants.contains(c.main)) && !need.isDisjoint(with: o.allCovenants)
            }.max { a, b in
                func key(_ o: Operator) -> [Int] {
                    [owned.contains(o.name) ? 1 : 0, need.intersection(o.allCovenants).count, Set(o.allCovenants).intersection(goalNames).count,
                     role(d.profile(o.name)) == role(mp) ? 1 : 0, -abs(o.tier - m.tier)]
                }
                return key(a).lexicographicallyPrecedes(key(b))
            }
            guard let s = best else { continue }
            used.insert(s.name)
            let sp = d.profile(s.name)
            let back: String
            if mp?.isHealer == true && sp?.isHealer != true { back = "要奶的时候换回" }
            else if mp?.isTank == true && sp?.isTank != true { back = "要前排扛伤时换回" }
            else if mp?.isStacker == true && sp?.isStacker != true { back = "要它叠层时换回" }
            else { back = "到手后换回" }
            let kept = need.intersection(s.allCovenants).sorted(), lost = need.subtracting(s.allCovenants).sorted()
            var text = "缺\(name)：先用\(s.name)（" + (owned.contains(s.name) ? "已有" : "\(s.tier)阶，现在能刷") + "，同样算"
                + kept.joined(separator: "、") + (lost.isEmpty ? "" : "，少 1 个" + lost.joined(separator: "、")) + "），\(name)" + back
            if let a = mp?.position, let b = sp?.position, a != b { text += "；\(s.name)是\(b)，换人时站位要跟着换" }
            out.append(RouteSubstitute(missing: name, standIn: s.name, owned: owned.contains(s.name), text: text))
        }
        return out
    }

    func currentStageIndex(_ defs: [StageDef] = StageDef.defaults, level: Int?) -> Int? {
        guard let level else { return nil }
        return defs.indices.last { defs[$0].terminal <= max(level, defs[0].terminal) } ?? 0
    }

    func plan(_ c: PlanCandidate, style: PlanStyle, req: PlanRequest, state: RouteState) -> PlannedRoute {
        let owned = state.owned
        let goals = c.goals
        let finalNames = Set(c.final.operators)
        let finalCounts = d.count(c.final.operators, transforms: c.final.transforms, mech: c.final.mech)
        let finalActive = Set(finalCounts.filter { d.isActive(finalCounts, $0.key) }.map(\.key))
        let piece = d.strategy.piecePlaces
        let defs: [StageDef] = StageDef.defaults.map { def in
            var x = def
            x.people = max(1, (def.stacking ? c.final.people : def.people) - piece)
            if def.stacking { return x }
            x.smallGoals = style == .smallFirst && def.terminal < AutoPlanner.stackerLevel ? c.smallGoals : nil
            x.required = (style == .coreFirst || def.terminal >= AutoPlanner.stackerLevel) ? [c.mainGoal] : []
            return x
        }
        let pool = d.ops.filter { !req.bannedOperators.contains($0.name) }
        func stageGoals(_ def: StageDef) -> [PlannerGoal] { def.stacking || def.smallGoals == nil ? goals : def.smallGoals! }
        func weight(_ s: Int) -> Double { 0.7 + 0.15 * Double(defs.count - s) }
        let current = currentStageIndex(defs, level: state.level)
        func ownedBonus(_ s: Int) -> Double { s == current ? 45 : (current.map { s > $0 } ?? true ? 12 : 4) }
        let finalTr = c.final.transforms
        func ctx(_ s: Int, next: Set<String>, previous: [String]?) -> StageCtx {
            StageCtx(d: d, def: defs[s], goals: stageGoals(defs[s]), next: next, finalNames: finalNames,
                     previous: Set(previous ?? []), prevCounts: previous.map { d.count($0) }, finalActive: finalActive,
                     weight: weight(s), owned: owned, ownedBonus: ownedBonus(s),
                     transforms: defs[s].stacking ? finalTr : [:], mech: defs[s].stacking ? c.final.mech : [],
                     additionalNames: Set(d.covenants.filter { !$0.isCore }.map(\.name)))
        }
        var teams = Array(repeating: [String](), count: defs.count)
        var next = finalNames
        for s in stride(from: defs.count - 1, through: 0, by: -1) {
            teams[s] = solve(ctx(s, next: next, previous: nil), pool: pool, current: nil)
            if !defs[s].stacking { next = Set(teams[s]) }
        }
        for s in defs.indices {
            let after = s + 1 < defs.count && !defs[s + 1].stacking ? Set(teams[s + 1]) : finalNames
            teams[s] = solve(ctx(s, next: after, previous: s > 0 ? teams[s - 1] : nil), pool: pool, current: teams[s])
        }

        var stages: [RouteStage] = []
        var previous = Set<String>()
        for (s, def) in defs.enumerated() {
            stages.append(makeStage(def: def, team: teams[s], transforms: def.stacking ? finalTr : [:], mech: def.stacking ? c.final.mech : [],
                                    goals: stageGoals(def), candidate: c, style: style, finalNames: finalNames, previous: previous,
                                    owned: owned, finalActive: finalActive, isFinal: false))
            previous = Set(teams[s])
        }
        let finalDef = StageDef(name: "成型阵容（打 Boss）", terminal: 6, maxTier: 6, tripleSlots: 0, people: c.final.people, rounds: "Boss 回合前换上")
        stages.append(makeStage(def: finalDef, team: c.final.operators, transforms: finalTr, mech: c.final.mech, goals: goals, candidate: c,
                                style: style, finalNames: finalNames, previous: previous, owned: owned, finalActive: finalActive, isFinal: true))
        stages = advise(stages, style: style, candidate: c, state: state)
        let targets = Array(Set(Array(finalTr.values) + c.final.mech)).sorted()
        let gear = targets.map { t in "\(t)：" + (d.jobChange[t]?.joined(separator: " / ") ?? "变形同构体") }
        return PlannedRoute(candidate: c, style: style, stages: stages, equipment: gear,
                            substitutes: substitutes(c, pool: pool, owned: owned, level: state.level))
    }

    private func makeStage(def: StageDef, team: [String], transforms: [String: String], mech: [String], goals: [PlannerGoal],
                           candidate c: PlanCandidate, style: PlanStyle, finalNames: Set<String>, previous: Set<String>,
                           owned: Set<String>, finalActive: Set<String>, isFinal: Bool) -> RouteStage {
        let counts = d.count(team, transforms: transforms, mech: mech)
        let teamOps = team.compactMap { d.byName[$0] }
        var warnings: [String] = []
        if !teamOps.contains(where: { d.isTank($0.name) }) { warnings.append("缺少盾位（重装）") }
        if def.terminal >= 3 && !d.strategy.healerProvided && !teamOps.contains(where: { d.isHealer($0.name) })
            && !d.isActive(counts, PlanRules.healing) { warnings.append("缺少奶位（医疗 / 聚合）") }
        if d.enemy.antiAir && def.terminal >= 3 {
            let ranged = teamOps.filter { d.isRanged($0.name) }.count
            if ranged < 3 { warnings.append("能打飞行的只有 \(ranged) 名（远程 / 领主）") }
        }
        if def.stacking || isFinal {
            for g in goals where g.isCore && counts[g.name, default: 0] < g.count { warnings.append("\(g.name) 未达规划（\(counts[g.name, default: 0])/\(g.count)）") }
        }
        let layers = d.stackLayers(teamOps, counts: counts, finalActive: finalActive)
        let ops: [RouteOp] = teamOps.map { o in
            RouteOp(name: o.name, tier: o.tier, isFinal: finalNames.contains(o.name), isNew: !previous.contains(o.name),
                    owned: owned.contains(o.name), viaTriple: o.tier > def.maxTier, transform: transforms[o.name],
                    isTank: d.isTank(o.name), isHealer: d.isHealer(o.name), layers: layers[o.name]?.final ?? 0)
        }.sorted { ($0.isFinal ? 0 : 1, -$0.tier, $0.name) < ($1.isFinal ? 0 : 1, -$1.tier, $1.name) }
        let active = counts.filter { d.isActive(counts, $0.key) && $0.key != PlanRules.harmony }
            .sorted { (d.isCore($0.key) ? 0 : 1, -$0.value, $0.key) < (d.isCore($1.key) ? 0 : 1, -$1.value, $1.key) }
            .map { ($0.key, $0.value) }
        let finalLayers = layers.values.reduce(0) { $0 + $1.final }
        let mainText = "\(c.main) \(counts[c.main, default: 0])/\(c.mainGoal.count)"
        let goalNames = Set(goals.map(\.name))
        let smallText = active.filter { a in !d.isCore(a.0) && goalNames.contains(a.0) }.map { a in "\(a.0) \(a.1)" }.joined(separator: "、")
        let focus: String
        if isFinal { focus = "成型阵容：打 Boss 前核对阵容、盟约及站位" }
        else if def.stacking { focus = finalLayers > 0 ? "叠层：成型阵容盟约保持激活，每回合约叠 \(String(format: "%.1f", finalLayers)) 层" : "叠层：成型阵容盟约保持激活，尽量多上叠层手" }
        else if def.smallGoals != nil { focus = (smallText.isEmpty ? "小盟约过渡" : "小盟约过渡：\(smallText)") + "；本家 \(mainText)，不专门搜" }
        else if style == .smallFirst { focus = "本家成型：\(mainText)，五阶叠层手上场" }
        else if def.terminal >= AutoPlanner.stackerLevel { focus = "补小盟约、换高阶卡：\(mainText)" + (smallText.isEmpty ? "" : "，\(smallText)") }
        else { focus = "凑本家：\(mainText)" + (finalLayers > 0 ? "，每回合约叠 \(String(format: "%.1f", finalLayers)) 层" : "") }
        return RouteStage(def: def, ops: ops, removed: previous.subtracting(team).sorted(), active: active,
                          goalStatus: goals.map { ($0.name, counts[$0.name, default: 0], $0.count) },
                          warnings: warnings, focus: focus, layersPerRound: (finalLayers * 10).rounded() / 10, isFinal: isFinal)
    }

    /// Per-level operating advice (AutoPlanner.Advise): pace, purchase priorities, reserve cards, upgrade and funds.
    private func advise(_ stages: [RouteStage], style: PlanStyle, candidate c: PlanCandidate, state: RouteState) -> [RouteStage] {
        let owned = state.owned
        let endgame = stages.filter { $0.isFinal || $0.def.stacking }.flatMap(\.ops).reduce(into: [RouteOp]()) { acc, o in if !acc.contains(where: { $0.name == o.name }) { acc.append(o) } }
        var out = stages
        for (index, stage) in stages.enumerated() {
            if stage.isFinal {
                let have = stage.ops.filter(\.owned).map(\.name), miss = stage.ops.filter { !$0.owned }.map(\.name)
                out[index].advice = [LevelAdvice(level: 6, pace: .max, focus: "Boss 前核对",
                                                  buy: [("已持有", have), ("还缺", miss)].filter { !$0.1.isEmpty },
                                                  upgrade: "按成型阵容补缺口，核对精锐与转职；同作用人选不必全部买齐",
                                                  economy: "持有记录不代表实际上场，先确认关键功能位和目标盟约生效",
                                                  reserve: [], keyCards: miss)]
                continue
            }
            let later = stages[(index + 1)...].flatMap { s in s.ops.map { ($0, s) } }
                .reduce(into: [(RouteOp, RouteStage)]()) { acc, x in if !acc.contains(where: { $0.0.name == x.0.name }) { acc.append(x) } }
            let next = stages[(index + 1)...].first { !$0.isFinal }?.def
            let lastLevel = next.map { $0.terminal - 1 } ?? stage.def.terminal
            var levels: [LevelAdvice] = []
            for level in stage.def.terminal...max(stage.def.terminal, lastLevel) {
                let team = (level == stage.def.terminal ? stage.ops
                    : (endgame.filter { $0.tier <= level } + stage.ops).reduce(into: [RouteOp]()) { acc, o in if !acc.contains(where: { $0.name == o.name }) { acc.append(o) } })
                    .filter { $0.tier <= level }
                let goals = stage.def.smallGoals != nil && level < AutoPlanner.stackerLevel ? c.smallGoals
                    : stage.def.stacking ? c.goals : [c.mainGoal]
                var priorities: [(RouteOp, String, Bool)] = []
                for op in team {
                    var reasons: [String] = []
                    let covs = d.byName[op.name]?.allCovenants ?? []
                    for g in goals where covs.contains(g.name) {
                        let need = max(1, d.activate(g.name) - (d.strategy.extraHarmony > 0 && g.isCore ? 1 : 0))
                        let have = team.filter { owned.contains($0.name) && (d.byName[$0.name]?.allCovenants.contains(g.name) ?? false) }.count
                        if have < need { reasons.append("补\(g.name)激活人选") }
                    }
                    if op.isTank && !team.contains(where: { $0.isTank && owned.contains($0.name) }) { reasons.append("补盾位") }
                    if level >= 3 && op.isHealer && !d.strategy.healerProvided && !team.contains(where: { $0.isHealer && owned.contains($0.name) }) { reasons.append("补奶位") }
                    if c.stackers.contains(where: { $0.name == op.name }) && !c.stackers.contains(where: { $0.tier <= level && owned.contains($0.name) }) { reasons.append("启动本家叠层") }
                    priorities.append((op, reasons.isEmpty ? "顺手补强" : reasons.joined(separator: "、"), !reasons.isEmpty))
                }
                let keys = priorities.filter { $0.2 && !owned.contains($0.0.name) }.map(\.0.name)
                let pace: Pace = level == 6 ? .max : style == .smallFirst && level < AutoPlanner.stackerLevel ? .rush : keys.isEmpty ? .steady : .stay
                var groups: [(String, [String])] = []
                for (op, reason, _) in priorities.sorted(by: { ($0.2 ? 0 : 1, owned.contains($0.0.name) ? 1 : 0, $0.0.tier) < ($1.2 ? 0 : 1, owned.contains($1.0.name) ? 1 : 0, $1.0.tier) }) {
                    let label = reason + (owned.contains(op.name) ? " · 已有" : "")
                    if let i = groups.firstIndex(where: { $0.0 == label }) { groups[i].1.append(op.name) } else { groups.append((label, [op.name])) }
                }
                let currentNames = Set(team.map(\.name))
                let reserve = later.filter { !currentNames.contains($0.0.name) && $0.0.tier <= level && !owned.contains($0.0.name) }
                    .sorted { ($0.0.isFinal ? 0 : 1) < ($1.0.isFinal ? 0 : 1) }.prefix(6).map { "\($0.0.name)（\($0.1.isFinal ? "成型" : $0.1.def.name)）" }
                let focus = level == AutoPlanner.stackerLevel ? "五本：补\(c.main)激活人选和本家叠层手；有六阶需求时再准备升六本" : stage.focus
                var upgrade: String
                switch pace {
                case .max: upgrade = "满本：核对上场盟约，按缺口补叠层与成型阵容；同作用人选不必全部买齐"
                case .rush: upgrade = "能稳住战斗就准备升 \(level + 1) 本；本家的卡见到就留，不为凑齐理想阵容反复刷新"
                case .stay: upgrade = "关键作用还缺，先补 \(keys.prefix(4).joined(separator: "、"))；同作用人选可替代，作用齐了、能稳住战斗再升 \(level + 1) 本"
                case .steady: upgrade = "本级关键牌都有了；能稳住战斗就升 \(level + 1) 本，其他增强牌顺手拿"
                }
                if level == AutoPlanner.stackerLevel && !endgame.contains(where: { $0.tier == 6 }) && !c.stackers.contains(where: { $0.tier == 6 }) {
                    upgrade = "这条路线没有明确的六阶需求：先留资金补关键作用与叠层，是否升六本按局势决定"
                }
                var economy = d.strategy.economyNote ?? "资金不确定时，只把升本当参考条件"
                if state.level == level, let m = state.money {
                    economy = "当前资金 \(m)" + (pace == .rush ? "：够升本就升" : pace == .stay ? "：先买关键牌，剩余再考虑升本" : "") + (d.strategy.economyNote.map { "；\($0)" } ?? "")
                }
                levels.append(LevelAdvice(level: level, pace: pace, focus: focus, buy: groups.map { ($0.0, $0.1) }, upgrade: upgrade,
                                          economy: economy, reserve: Array(reserve), keyCards: keys))
            }
            out[index].advice = levels
        }
        return out
    }

    // One stage: seeded greedy fill + swap improvement (LineupRoutePlanner.SolveStage).
    private func solve(_ ctx: StageCtx, pool allPool: [Operator], current: [String]?) -> [String] {
        let def = ctx.def
        let tierOK = allPool.filter { $0.tier <= def.maxTier || (def.tripleSlots > 0 && $0.tier == def.maxTier + 1) }
        // Only operators that can matter for this stage (speed): held / neighbouring stages / goal holders /
        // a few of the best tanks and healers.
        let relevant = Set(ctx.goals.map(\.name)).union(ctx.finalActive).union(def.required.map(\.name))
        var keep = Set(tierOK.filter { o in ctx.owned.contains(o.name) || ctx.next.contains(o.name) || ctx.previous.contains(o.name)
            || ctx.finalNames.contains(o.name) || !relevant.isDisjoint(with: o.allCovenants) }.map(\.name))
        for role in [true, false] {
            let picks = tierOK.filter { role ? d.isTank($0.name) : d.isHealer($0.name) }.sorted { $0.tier > $1.tier }.prefix(4)
            keep.formUnion(picks.map(\.name))
        }
        let pool = tierOK.filter { keep.contains($0.name) }.sorted { $0.name < $1.name }
        let size = min(def.people, pool.count)
        func holders(_ c: String) -> [Operator] {
            pool.filter { $0.allCovenants.contains(c) }.sorted { a, b in
                func k(_ o: Operator) -> (Int, Int, Int, Int, Int, String) {
                    (ctx.owned.contains(o.name) ? 0 : 1, ctx.next.contains(o.name) ? 0 : 1, ctx.finalNames.contains(o.name) ? 0 : 1,
                     o.tier > def.maxTier ? 1 : 0, -o.tier, o.name)
                }
                return k(a) < k(b)
            }
        }
        var seeds: [[Operator]] = [[],
                                   pool.filter { ctx.next.contains($0.name) }.sorted { $0.tier > $1.tier },
                                   pool.filter { ctx.previous.contains($0.name) }.sorted { $0.tier > $1.tier },
                                   pool.filter { ctx.owned.contains($0.name) }.sorted { $0.tier > $1.tier }]
        if let current { seeds.append(pool.filter { current.contains($0.name) }) }
        var combined: [Operator] = []
        for g in ctx.goals.sorted(by: { ($0.isCore ? 0 : 1) < ($1.isCore ? 0 : 1) }) {
            let need = d.activate(g.name)
            seeds.append(Array(holders(g.name).prefix(need)))
            let have = combined.filter { $0.allCovenants.contains(g.name) }.count
            combined += holders(g.name).filter { h in !combined.contains { $0.name == h.name } }.prefix(max(0, need - have))
        }
        seeds.append(combined)
        if !def.stacking { for g in def.required { seeds.append(Array(holders(g.name).prefix(g.count))) } }

        var solved = Array(repeating: ([Operator](), -Double.infinity), count: seeds.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: seeds.count) { i in
            var team: [Operator] = []
            for o in seeds[i] where team.count < size && ctx.canAdd(team, o) && !team.contains(where: { $0.name == o.name }) { team.append(o) }
            while team.count < size {
                var pick: Operator?
                var ps = -Double.infinity
                for o in pool where !team.contains(where: { $0.name == o.name }) && ctx.canAdd(team, o) {
                    team.append(o)
                    let sc = ctx.score(team)
                    team.removeLast()
                    if sc > ps + 1e-9 { pick = o; ps = sc }
                }
                guard let p = pick else { break }
                team.append(p)
            }
            var cur = ctx.score(team)
            for _ in 0..<30 {
                var gain = 1e-9
                var swap: (Int, Operator)?
                for slot in team.indices {
                    let out = team[slot]
                    for o in pool where !team.contains(where: { $0.name == o.name }) {
                        team[slot] = o
                        if ctx.isValid(team) {
                            let g = ctx.score(team) - cur
                            if g > gain { gain = g; swap = (slot, o) }
                        }
                        team[slot] = out
                    }
                }
                guard let (slot, o) = swap else { break }
                team[slot] = o
                cur += gain
            }
            lock.lock(); solved[i] = (team, cur); lock.unlock()
        }
        var best: [Operator] = []
        var bestScore = -Double.infinity
        for (team, score) in solved where score > bestScore + 1e-9 { best = team; bestScore = score }
        return best.map(\.name)
    }
}

/// Stage scoring (LineupRoutePlanner.StageContext) + run context bonuses.
private struct StageCtx {
    let d: PlannerData
    let def: StageDef
    let goals: [PlannerGoal]
    let next: Set<String>
    let finalNames: Set<String>
    let previous: Set<String>
    let prevCounts: [String: Int]?
    let finalActive: Set<String>
    let weight: Double
    let owned: Set<String>
    let ownedBonus: Double
    let transforms: [String: String]
    let mech: [String]
    let additionalNames: Set<String>

    func canAdd(_ team: [Operator], _ o: Operator) -> Bool { o.tier <= def.maxTier || team.filter { $0.tier > def.maxTier }.count < def.tripleSlots }
    func isValid(_ team: [Operator]) -> Bool { team.filter { $0.tier > def.maxTier }.count <= def.tripleSlots }

    func points(_ counts: [String: Int], only: Set<String>?) -> Int {
        let coreReady = goals.filter(\.isCore).allSatisfy { counts[$0.name, default: 0] >= d.activate($0.name) }
        var p = 0
        for (c, n) in counts where (only == nil || only!.contains(c)) && !PlanRules.noAdditionalScore.contains(c) && n >= d.activate(c) {
            p += d.isCore(c) ? (n >= 6 ? 4 : 2) : (n >= d.secondCount(c) ? (coreReady ? 3 : 2) : 1)
        }
        return p
    }

    func roleScore(_ team: [Operator], _ counts: [String: Int], layerWeight: Double, transitionLayers: Bool) -> Double {
        var s = 0.0
        if !team.contains(where: { d.isTank($0.name) }) { s -= 600 }
        if def.terminal >= 3 && !d.strategy.healerProvided && !team.contains(where: { d.isHealer($0.name) }) && !d.isActive(counts, PlanRules.healing) { s -= 600 }
        let layers = d.stackLayers(team, counts: counts, finalActive: finalActive)
        s += layerWeight * layers.values.reduce(0) { $0 + 6 * $1.final + (transitionLayers ? 2 * $1.transition : 0) }
        for o in team {
            guard let cons = d.profile(o.name)?.consumes, !cons.isEmpty else { continue }
            if cons.contains(where: { d.isActive(counts, $0) && finalActive.contains($0) }) { s += 30 }
            else if cons.contains(where: { d.isActive(counts, $0) }) { s += 10 }
        }
        // Run context: enemies and strategy.
        if d.enemy.antiAir && def.terminal >= 3 { s -= 120 * Double(max(0, 3 - team.filter { d.isRanged($0.name) }.count)) }
        if d.enemy.preferArts { s += 6 * Double(team.filter { d.isArts($0.name) }.count) }
        if d.enemy.preferPhysical { s += 6 * Double(team.filter { !d.isArts($0.name) }.count) }
        if d.strategy.activeCovenantBonus { s += 25 * Double(min(5, counts.filter { d.isActive(counts, $0.key) }.count)) }
        return s
    }

    func score(_ team: [Operator]) -> Double {
        let names = team.map(\.name)
        let counts = d.count(names, transforms: transforms, mech: mech)
        var s: Double
        if def.stacking {
            let core = goals.filter(\.isCore).reduce(0) { $0 + max(0, $1.count - counts[$1.name, default: 0]) }
            let extras = goals.filter { !$0.isCore }.map { max(0, $0.count - counts[$0.name, default: 0]) }
            s = -400 * Double(core + (extras.min() ?? 0))
            for c in finalActive where d.isActive(counts, c) { s += 150 }
            s += roleScore(team, counts, layerWeight: 3, transitionLayers: false)
        } else {
            let scored: Set<String>? = def.smallGoals == nil ? nil : additionalNames
            s = 60 * Double(points(counts, only: scored) + points(counts, only: Set(goals.map(\.name))))
            for g in goals { s += 20 * Double(min(counts[g.name, default: 0], g.count)) }
            s += roleScore(team, counts, layerWeight: weight, transitionLayers: true)
            for g in def.required { s -= 300 * Double(max(0, g.count - counts[g.name, default: 0])) }
            if let prev = prevCounts {
                for g in goals {
                    let drop = min(prev[g.name, default: 0], g.count) - min(counts[g.name, default: 0], g.count)
                    if drop > 0 { s -= 60 * Double(drop) }
                }
            }
        }
        let solo = counts[PlanRules.solo, default: 0]
        if solo > 1 { s -= 60 * Double(solo - 1) }
        for o in team {
            let keep = next.contains(o.name), final = finalNames.contains(o.name)
            if keep { s += 14 }
            if previous.contains(o.name) { s += 8 }
            if owned.contains(o.name) { s += ownedBonus }
            if d.strategy.eliteFocus && owned.contains(o.name) { s += 6 }
            guard !def.stacking else { continue }
            if final { s += 5 }
            s += 1.5 * Double(o.tier)
            if o.tier > def.maxTier && !keep && !final { s -= 6 }
        }
        return s
    }
}
