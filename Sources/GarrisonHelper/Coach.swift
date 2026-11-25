// Portions adapted from StrongholdAssistant (Apache-2.0) and rewritten in Swift for this Mac app; the upstream files are listed
// in REFERENCES.md and their licenses / NOTICEs are in licenses/.
import AppKit
import Foundation
import SwiftUI

/// Turns this run's context (mode, bans, strategy, enemies, current lineup, terminal level) into
/// playable routes; runs field recognition and the optional AI coach.
@MainActor
final class Coach: ObservableObject {
    /// Background music at chosen moments of a match (设置 → 音乐).
    let music = MusicPlayer()
    // Planning
    @Published var candidates: [PlanCandidate] = []
    @Published var selected: String?
    @Published var style: PlanStyle?
    @Published var route: PlannedRoute?
    @Published var planning = false
    @Published var planError: String?

    // Recommended actions (buy / upgrade / refresh / freeze / positioning) and their game overlay.
    @Published var actions: [GameAction] = []
    @AppStorage("overlay.enabled") var overlayEnabled = true
    @AppStorage("overlay.buy") var showBuy = true
    @AppStorage("overlay.upgrade") var showUpgrade = true
    @AppStorage("overlay.refresh") var showRefresh = true
    @AppStorage("overlay.freeze") var showFreeze = true
    @AppStorage("overlay.place") var showPlace = true
    @AppStorage("overlay.routes") var showRoutes = true
    @AppStorage("field.autoSync") var autoSyncField = true
    @AppStorage("debug.capture") var debugCapture = false
    /// Self-tests decide recording here instead of the saved setting (shared by every command-line run).
    var recordOverride: Bool?
    /// Finished matches (战绩 tab).
    let history = MatchHistory()
    /// 特别关注: operators to point out whenever they show up in the shop (comma-separated).
    @AppStorage("watchlist") var watchlistRaw = ""
    var watchlist: [String] { watchlistRaw.split(separator: ",").map(String.init) }
    func setWatchlist(_ names: [String]) { watchlistRaw = names.joined(separator: ",") }
    private var watchAlerted: Set<String> = []
    /// Hidden with the hide hotkey (window and overlay).
    @Published var hidden = false
    @AppStorage("hotkey.hide") var hideHotKey = true

    func toggleHidden() {
        hidden.toggle()
        overlay.suppressed = hidden
        if hidden {
            overlay.hide()
            scanner.sidebarWindow?.orderOut(nil)
        } else {
            scanner.sidebarWindow?.orderFrontRegardless()
        }
    }
    let maps: [GarrisonMap]
    private let overlay = OverlayController()
    /// Last board recognition (map + fitted camera).
    @Published var board: BoardMatch?
    /// This round's enemy routes on the current map (StrongholdAssistant level data), and next round's.
    @Published var enemyRoutes: RoundRoutes?
    @Published var nextEnemyRoutes: RoundRoutes?
    /// Map on screen (the recognised board, else the one picked for the run).
    var currentMap: GarrisonMap? { maps.first { $0.id == (board?.mapId ?? run.mapID) } }
    private lazy var routeData = EnemyRouteData(resourceRoot: catalog.resourceRoot)
    /// Shown in the actions panel when no advice is given (作战中 / 联防).
    @Published var liveNote: String?
    private var boardRecognizer: BoardRecognizer?
    /// Choice popup on screen (悬赏决策 / 道具补给 / 机密商店 / 战术决策 / 自选编队) with recommendations.
    @Published var choice: ChoiceScreen?
    /// 自选干员 value for this run (name → score, reason), from the current routes.
    @Published var selfPickScores: [String: (Double, String)] = [:]
    private var mapVotes: [String: Int] = [:]
    private var tracker = LineupTracker()

    // Field recognition
    /// Manual 识别场上 result, shown for review until 采用 / 放弃.
    @Published var field: FieldReading?
    /// Last live reading (drives positioning advice; never shown as a review panel).
    @Published var liveField: FieldReading?
    @Published var fieldBusy = false
    @Published var fieldError: String?

    // AI
    @Published var aiText = ""
    @Published var aiBusy = false
    @Published var aiError: String?
    @Published var aiTiming: AITiming?
    /// The route the AI coach named in its last answer (blue 「AI」 badge on that tile), and its 路线 line as the tooltip.
    @Published var aiPickID: String?
    @Published var aiPickNote: String?
    /// The route list the last question showed the AI, in its R1, R2… order.
    private var aiRouteIDs: [String] = []
    @AppStorage("ai.provider") var provider: AIProvider = .deepseek
    @AppStorage("ai.strength") var strength: AIStrength = .fast
    /// Longer prompt with the full reference (标准 / 深入).
    var detailed: Bool { strength.detailed }
    @AppStorage("ai.screenshot") var includeScreenshot = false
    @AppStorage("ai.claudeFast") var claudeFast = false
    @Published var keyVersion = 0

    private let catalog: Catalog
    private let run: RunState
    private let scanner: Scanner
    private var planTask: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?
    private var recognizer: FieldRecognizer?
    var recognizerReady: Bool { recognizer != nil && boardRecognizer != nil }

    init(catalog: Catalog, run: RunState, scanner: Scanner) {
        self.catalog = catalog
        self.run = run
        self.scanner = scanner
        let mapFile = try? JSONDecoder().decode(GarrisonMapFile.self,
            from: Data(contentsOf: catalog.resourceRoot.appendingPathComponent("data/garrison_maps.json")))
        maps = mapFile?.maps.sorted { $0.id < $1.id } ?? []
        applyMode()
        scanner.onFrame = { [weak self] frame in await self?.handle(frame) }
        scanner.onFullRead = { [weak self] img in self?.startPrefetch(img) }
        scanner.onStop = { [weak self] in self?.actions = []; self?.overlay.hide(); self?.liveNote = nil }
        scanner.onPurchase = { [weak self] name in self?.purchased(name) }
        let root = catalog.resourceRoot
        Task.detached(priority: .utility) {
            let r = FieldRecognizer(resourceRoot: root)
            let b = BoardRecognizer(resourceRoot: root)
            await MainActor.run { self.recognizer = r; self.boardRecognizer = b }
        }
    }

    // MARK: Run context

    var strategy: Strategy? { catalog.strategies.first { $0.id == run.strategyID } }

    var modifiers: StrategyModifiers {
        var m = StrategyModifiers.from(strategy, coreNames: Set(catalog.coreCovenants.map(\.name)))
        m.mechElite = run.mechElite
        return m
    }

    func applyMode() {
        guard let name = run.mode, let pool = catalog.modes.first(where: { $0.name == name }) else { run.outOfMode = []; return }
        let allowed = Set(pool.cores + pool.additional)
        run.outOfMode = Set(catalog.covenants.map(\.name)).subtracting(allowed)
    }

    var boss: Boss? { catalog.bosses.first { $0.name == run.bossName } }

    func enemyNeeds() -> EnemyNeeds {
        var n = EnemyNeeds()
        var stats: [EnemyInfo] = []
        if let b = boss {
            let text = (b.abilityList ?? []).joined()
            if text.contains("飞行") || text.contains("无人机") { n.antiAir = true; n.notes.append("\(b.name)会召唤飞行/无人机单位：要有远程或领主对空") }
            let dmg = (b.damageTypes ?? []).map { $0 == "MAGIC" ? "法术" : $0 == "PHYSIC" ? "物理" : $0 }
            if !dmg.isEmpty { n.notes.append("\(b.name)造成\(dmg.joined(separator: "+"))伤害") }
            if text.contains("晕眩") { n.notes.append("\(b.name)有范围晕眩：关键输出别挤在一起") }
            if let e = catalog.enemies.first(where: { $0.id == b.enemyId }) { stats.append(e) }
        }
        for name in run.specialEnemies {
            guard let e = catalog.enemies.first(where: { $0.name == name }) else { continue }
            stats.append(e)
            if e.motion == "FLY" { n.antiAir = true }
            var line = "\(e.name)"
            if e.motion == "FLY" { line += "（飞行）" }
            if let a = e.abilities?.first { line += "：\(stripMarkup(a))" }
            n.notes.append(line)
        }
        if n.antiAir && !n.notes.contains(where: { $0.contains("对空") }) { n.notes.insert("有飞行敌人：阵容至少 3 名能打飞行的（远程或领主，其他近战打不到）", at: 0) }
        let defs = stats.compactMap(\.def), res = stats.compactMap(\.res)
        if !defs.isEmpty {
            let d = defs.reduce(0, +) / Double(defs.count), r = res.isEmpty ? 0 : res.reduce(0, +) / Double(res.count)
            if d >= 700 && r < 30 { n.preferArts = true; n.notes.append("敌人防御高（均 \(Int(d))）：法术输出更好打") }
            else if r >= 40 && d < 500 { n.preferPhysical = true; n.notes.append("敌人法抗高（均 \(Int(r))）：物理输出更好打") }
        }
        return n
    }

    private func plannerData() -> PlannerData {
        PlannerData(ops: catalog.operators, covenants: catalog.covenants, profiles: catalog.profiles,
                    unavailable: run.unavailableCovenants, selfSelected: Set(run.selfSelected), strategy: modifiers,
                    enemy: enemyNeeds(), jobChangeEquipment: catalog.jobChangeEquipment)
    }

    private func request() -> PlanRequest {
        var r = PlanRequest()
        r.unavailable = run.unavailableCovenants
        r.bannedOperators = Set(catalog.operators.filter { run.isBanned($0) }.map(\.name))
        r.owned = run.owned
        r.locked = Array(Set(run.locked)).filter { !r.bannedOperators.contains($0) }
        r.people = run.deployCap
        r.maxTransforms = modifiers.transformOptions.max() ?? 2
        r.currentLevel = scanner.hud.level
        r.contested = contestedCovenants
        // Small covenants the held lineup already activates (聚合Ⅱ, 坚守…): routes try to keep them.
        let d = PlannerData(ops: catalog.operators, covenants: catalog.covenants, profiles: catalog.profiles,
                            selfSelected: Set(run.selfSelected), strategy: modifiers)
        let counts = d.count(Array(Set(run.owned)))
        r.keepSmall = catalog.additionalCovenants.compactMap { c -> PlannerGoal? in
            let n = counts[c.name, default: 0]
            guard n >= c.activateCount, !PlanRules.noAdditionalScore.contains(c.name), !run.unavailableCovenants.contains(c.name) else { return nil }
            return PlanRules.goal(c, level: n >= 3 && PlanRules.peopleSecond.contains(c.name) ? 2 : 1)
        }.sorted { ($0.level, counts[$0.name, default: 0]) > ($1.level, counts[$1.name, default: 0]) }
        r.keepSmall = Array(r.keepSmall.prefix(3))
        return r
    }

    private var routeState: RouteState {
        RouteState(owned: Set(run.owned), level: scanner.hud.level, money: scanner.hud.money, round: scanner.hud.round)
    }

    var currentStageIndex: Int? { RoutePlanner(d: plannerData()).currentStageIndex(level: scanner.hud.level) }

    // MARK: Planning

    /// Debounced re-plan whenever the run context changes (a purchase and the merge it causes come as one change).
    func schedulePlan() {
        planTask?.cancel()
        planTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.plan()
        }
    }

    private var lastPlanKey = ""
    private var planRunning = false
    private var planAgain = false

    /// One plan at a time: a change that arrives while planning is folded into one more run with the latest state, so
    /// searches never pile up on the CPU (each one uses every core for about a second).
    func plan() async {
        if planRunning { planAgain = true; return }
        planRunning = true
        defer { planRunning = false }
        repeat {
            planAgain = false
            await planOnce()
        } while planAgain
    }

    private func planOnce() async {
        let d = plannerData(), req = request()
        // Skip when nothing that matters changed (the live loop updates often).
        let key = [req.unavailable.sorted().joined(separator: ","), req.bannedOperators.count.description, req.owned.sorted().joined(separator: ","),
                   req.locked.sorted().joined(separator: ","), "\(req.people)", "\(req.currentLevel ?? 0)", req.keepSmall.map(\.label).joined(),
                   run.strategyID ?? "", "\(run.mechElite)", d.enemy.notes.joined(), run.selfSelected.sorted().joined(separator: ","),
                   req.contested.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value)" }.joined()].joined(separator: "|")
        // Nothing changed: only a switch waiting for confirmation is looked at again, with the routes already found.
        let result: [PlanCandidate]
        if key == lastPlanKey && !candidates.isEmpty {
            guard pendingSwitch != nil, let cached = lastPlanResult else { return }
            result = cached
        } else {
            lastPlanKey = key
            planning = true
            planError = nil
            defer { planning = false }
            let t0 = CFAbsoluteTimeGetCurrent()
            result = await Task.detached(priority: .userInitiated) { AutoPlanner(d: d).candidates(req) }.value
            lastPlanResult = result
            if TickTiming.enabled { print(String(format: "plan candidates %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)) }
        }
        // 推荐 = the best score, but the badge stays on its route while that route is within the margin a followed route
        // gets below: two routes a few points apart must not swap it on every re-plan.
        if let top = result.first {
            let prev = result.first { $0.id == bestID }
            if prev == nil || prev!.score < top.score - max(4, abs(top.score) * 0.08) { bestID = top.id }
        } else { bestID = nil }
        // Routes the player already holds operators for come first, then by score. Re-sorted at most once per round:
        // every purchase, sale and merge re-plans, and the tiles must not move around while the player is clicking.
        let ranked = result.enumerated().sorted { a, b in
            let ha = heldCount(a.element), hb = heldCount(b.element)
            return ha != hb ? ha > hb : a.offset < b.offset
        }.map(\.element)
        let listRoundNow = scanner.hud.round
        if let r = listRoundNow, r == listRound, !candidates.isEmpty {
            let prev = Dictionary(candidates.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            candidates = ranked.filter { prev[$0.id] != nil }.sorted { prev[$0.id]! < prev[$1.id]! } + ranked.filter { prev[$0.id] == nil }
        } else {
            candidates = ranked
            listRound = listRoundNow
        }
        updateSelfPicks(Array(ranked.prefix(3)))
        guard let best = result.first else { planError = "没有可行路线：必带干员被禁，或可用盟约太少"; route = nil; return }
        // Follow the best route unless the player picked one themselves. An automatically followed route is kept
        // while it stays close to the best and the best doesn't use two or more extra held operators (one misread unit
        // must not flip the whole plan, but buying into another 本家 moves it there).
        let current = result.first { $0.id == selected }
        var keep: PlanCandidate
        let advantage = current.map { heldCount(best) - heldCount($0) } ?? 0
        let round = scanner.hud.round
        if userPicked, let current { keep = current }
        // One automatic switch per round: within a round the lineup reading changes as units are moved, bought and merged.
        else if let current, autoSwitchRound != nil, autoSwitchRound == round, advantage < 3, current.score >= best.score * 0.8 { keep = current }
        else if let current, current.score >= best.score - max(4, abs(best.score) * 0.08), advantage < 2 { keep = current }
        else { keep = best }
        // An automatic switch must still win a re-plan at least 3 s later: a unit that was just bought and isn't merged or
        // placed yet, or one misread frame, re-plans once and then changes back (2026-11-22 18:29: seven switches in
        // rounds 4–6, most of them back to 炎 within seconds). A route using 3+ more held operators switches at once: that
        // is the lineup being read for the first time, not one flickering unit.
        if !userPicked, let current, keep.id != current.id, advantage < 3 {
            if let p = pendingSwitch, p.id == keep.id, scanner.clock.timeIntervalSince(p.since) >= 3 {
                pendingSwitch = nil
            } else {
                if pendingSwitch?.id != keep.id { pendingSwitch = (keep.id, scanner.clock) }
                keep = current
                confirmTask?.cancel()
                // Replays confirm on a later frame's plan instead (their clock runs per frame, not in real time).
                if !scanner.isReplaying {
                    confirmTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 3_200_000_000)
                        guard !Task.isCancelled, let self else { return }
                        await self.plan()
                    }
                }
            }
        } else {
            pendingSwitch = nil
        }
        // Any automatic change of route counts (also when the followed route dropped out of the list).
        if let sel = selected, keep.id != sel, !userPicked { autoSwitchRound = round }
        if ProcessInfo.processInfo.environment["PLAN_DEBUG"] != nil {
            print("plan: owned=\(run.owned.sorted().joined(separator: ",")) current=\(current.map { "\($0.id) \(Int($0.score)) held\(heldCount($0))" } ?? "none(\(selected ?? "-"))") best=\(best.id) \(Int(best.score)) held\(heldCount(best)) → \(keep.id)\(pendingSwitch.map { " (pending \($0.id))" } ?? "")  推荐=\(bestID ?? "-")  list(\(candidates.count))=\(candidates.map(\.id).joined(separator: ","))  unavailable=\(req.unavailable.sorted().joined(separator: ","))")
        }
        // The same route keeps its style (先大后小 / 先小后大): a re-plan mid-run must not flip how the player is building.
        await select(keep.id, style: selected == keep.id ? style : nil, byUser: false)
    }

    /// Next-round funds and upgrade price (Economy.swift).
    var forecast: EconomyForecast? {
        let h = scanner.hud
        let start = scanner.roundStart.round == h.round ? scanner.roundStart.startMoney : nil
        return Economy.forecast(round: h.round, money: h.money, startMoney: start, level: h.level, upgradeCost: scanner.controls.upgradeCost,
                                strategy: run.strategyID, table: catalog.roundIncome)
    }

    /// Round of the last automatic route switch.
    private var autoSwitchRound: Int?
    /// Round the route list was last re-sorted in.
    private var listRound: Int?
    /// An automatic route switch waiting for a second plan to agree, and the re-plan that checks it.
    private var pendingSwitch: (id: String, since: Date)?
    /// Routes of the last search (reused while a switch waits for confirmation).
    private var lastPlanResult: [PlanCandidate]?
    private var confirmTask: Task<Void, Never>?

    /// Best-scoring route of the last plan (marked 推荐; the list itself is ordered by operators already held).
    @Published var bestID: String?

    /// Distinct held operators that the route uses (its final lineup or its 本家 holders).
    func heldCount(_ c: PlanCandidate) -> Int {
        Set(run.owned).intersection(Set(c.final.operators).union(c.ownedHolders)).count
    }

    /// True once the player tapped a route or a style; then replans keep it.
    @Published var userPicked = false

    func select(_ id: String, style: PlanStyle?, byUser: Bool = true) async {
        guard let c = candidates.first(where: { $0.id == id }) else { return }
        if byUser { userPicked = true }
        selected = id
        let s = style ?? c.style
        self.style = s
        planning = true
        defer { planning = false }
        let d = plannerData(), req = request(), state = routeState
        let t0 = CFAbsoluteTimeGetCurrent()
        route = await Task.detached(priority: .userInitiated) { RoutePlanner(d: d).plan(c, style: s, req: req, state: state) }.value
        if TickTiming.enabled { print(String(format: "plan route %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)) }
    }

    // MARK: Field recognition (Core ML on the Neural Engine)

    func recognizeField() async {
        fieldBusy = true
        fieldError = nil
        defer { fieldBusy = false }
        guard let recognizer else { fieldError = "小人模型还在加载"; return }
        if let e = recognizer.loadError { fieldError = e; return }
        do {
            let img = try await scanner.captureViewport()
            let eligible = eligibleByTier()
            let prior = Set(run.owned).union(run.owned.compactMap(catalog.prototype(of:)))
            let names = Set(catalog.operators.map(\.name)).union(catalog.prototypes.keys)
            var reading = await Task.detached(priority: .userInitiated) { recognizer.read(img, eligible: eligible, prior: prior, operatorNames: names) }.value
            resolveStandIns(&reading)
            if let br = boardRecognizer {
                let known = run.mapID
                if let m = await Task.detached(priority: .userInitiated, operation: { br.recognize(img, mapId: known) }).value {
                    board = m
                    reading.place(on: m.projection)
                }
            }
            field = reading
            if reading.units.isEmpty { fieldError = "没找到干员角标：请在休整期、棋盘可见时识别" }
        } catch {
            fieldError = error.localizedDescription
        }
    }

    /// 补录 from the mini board: a unit the recognition missed.
    func addMissed(_ name: String) {
        if autoSyncField { tracker.addManual(name) }
        run.owned.append(name)
    }

    /// Fix the name of a unit on the live board (mini board).
    func correctLive(_ unit: FieldUnit, _ name: String) {
        if var f = liveField, let i = f.units.firstIndex(where: { $0.id == unit.id }) {
            f.units[i].chosen = name
            liveField = f
        }
        let old = tracker.name(of: unit)
        tracker.pin(unit, name: name)
        if let old, old != name, let j = run.owned.firstIndex(of: old) { run.owned[j] = name }
        else if !run.owned.contains(name) { run.owned.append(name) }
    }

    /// Remove one copy from the lineup by hand.
    func removeOwned(at i: Int) {
        guard run.owned.indices.contains(i) else { return }
        tracker.removeManual(run.owned[i])
        run.owned.remove(at: i)
    }

    func choose(_ unit: FieldUnit, _ name: String) {
        guard var f = field, let i = f.units.firstIndex(where: { $0.id == unit.id }) else { return }
        f.units[i].chosen = name
        field = f
        tracker.pin(f.units[i], name: name)
    }

    /// Shop purchase confirmed by the scanner.
    func purchased(_ name: String) {
        guard catalog.op(name) != nil else {
            if let e = catalog.equipment.first(where: { $0.name == name }) {
                run.ownedEquipment.append(name)
                if e.normal.effectDescription.contains("销毁") { newItems.append((scanner.hud.round, name)) }
            }
            return
        }
        boughtThisMatch[name, default: 0] += 1
        // The third copy merges into 精锐 at once (the board then shows one unit).
        let held = autoSyncField ? tracker.held(name) : run.owned.filter { $0 == name }.count
        if held >= 2 && !run.elites.contains(name) { run.elites.append(name) }
        if autoSyncField { tracker.purchased(name) } else if run.autoRecordPurchases { run.owned.append(name) }
    }

    /// Used-up items (装备时销毁…) bought this match and the round: 推荐操作 says how to use them during that round.
    private var newItems: [(round: Int?, name: String)] = []

    /// How to use each held used-up item (routes card; the 装备 actions while it was just bought).
    var itemUsages: [(item: String, use: String)] {
        let main = route?.candidate.main, smalls = route?.candidate.smallGoals.map(\.name) ?? []
        let carry = gearHolders.first { $0.kind == .carry }?.name
        var seen = Set<String>()
        return run.ownedEquipment.compactMap { name in
            guard seen.insert(name).inserted, let effect = equipmentInfo[name]?.effect,
                  let use = GearAdvisor.usage(name, effect: effect, main: main, smalls: smalls, owned: run.owned, carry: carry, op: catalog.op)
            else { return nil }
            return (name, use)
        }
    }

    /// Operators bought this match (from the shop), for naming units that show a shared stand-in sprite.
    private var boughtThisMatch: [String: Int] = [:]

    // MARK: Strategy from the screen

    private lazy var strategyReader = StrategyRecognizer(resourceRoot: catalog.resourceRoot)
    private var strategyReads: [String?] = []
    /// Strategy this match was set to from the screen; the player choosing another one stops the automation.
    private var autoStrategy: String?
    private var strategySettled = false
    /// Shown next to the strategy picker.
    @Published var strategyNote: String?

    /// Reads the strategy portrait (top right) on our own board until 5 of the last 7 reads agree, then sets it.
    private func readStrategy(_ frame: Scanner.LiveFrame) {
        let hud = scanner.hud
        if let a = autoStrategy, run.strategyID != a { strategySettled = true; strategyNote = nil }
        guard !strategySettled, !hud.otherBoard, !hud.playerList, hud.isRest || hud.inBattle, let reader = strategyReader else { return }
        strategyReads.append(reader.read(frame.image).id)
        if strategyReads.count > 7 { strategyReads.removeFirst() }
        let votes = Dictionary(grouping: strategyReads.compactMap { $0 }, by: { $0 }).mapValues(\.count)
        guard let (id, n) = votes.max(by: { $0.value < $1.value }), n >= 5 else { return }
        strategySettled = true
        autoStrategy = id
        let name = catalog.strategies.first { $0.id == id }?.name ?? id
        if run.strategyID != id {
            let before = strategy?.name
            run.strategyID = id
            strategyNote = "按画面右上角的头像认出策略：\(name)" + (before.map { "（原来选的是 \($0)）" } ?? "") + "。不对的话手动改，本局不再自动换"
        } else {
            strategyNote = "画面上的策略头像也是 \(name)"
        }
    }

    /// Called when a new run starts.
    func resetRun() {
        strategyReads = []
        autoStrategy = nil
        strategySettled = false
        strategyNote = nil
        DebugRecorder.newMatch()
        roundEnemies = RoundEnemies()
        scanner.roundStart.reset()
        opponentCovenants = [:]
        contestedCovenants = [:]
        matchMaxRound = 0
        matchStartedAt = nil
        matchSnapshot = nil
        matchArchived = false
        boughtThisMatch = [:]
        newItems = []
        spectateReads = 0
        spectateSince = nil
        if eliminated { setEliminated(false) }
        watchAlerted = []
        roundOneReads = 0
        userPicked = false
        listRound = nil
        pendingSwitch = nil
        aiPickID = nil
        aiPickNote = nil
        tracker.reset()
        mapVotes = [:]
        board = nil
        field = nil
        liveField = nil
    }

    func applyField() {
        guard let f = field else { return }
        run.owned = f.units.compactMap(\.name)
        field = nil
        schedulePlan()
    }

    // MARK: Live actions

    private var fieldTick = 0

    func handle(_ frame: Scanner.LiveFrame) async {
        defer { if (recordOverride ?? debugCapture) && frame.fullRead && !eliminated { record(frame) } }
        if frame.fullRead { detectNewMatch(frame); recordSelfPicks(frame); trackElimination() }
        music.update(hud: scanner.hud, eliminated: eliminated)
        if frame.fullRead && !eliminated { readStrategy(frame) }
        if eliminated { return }
        let hud = scanner.hud
        // Choice popups cover the HUD: check them first (full reads only).
        if frame.fullRead {
            choice = ChoiceAdvisor.read(texts: scanner.lastTexts, viewport: CGSize(width: frame.image.width, height: frame.image.height), ctx: choiceContext(),
                                        image: frame.image)
            TickTiming.mark("弹窗")
        }
        if let c = choice, !c.cards.isEmpty {
            let picks = c.cards.filter(\.best).map { "「\($0.name)」" }.joined()
            if c.kind == .selfPick {
                // Only the picks are actions; the rest is one line (listing every card as 「选择」 read as advice to pick it).
                let rest = c.cards.filter { !$0.best }.count
                liveNote = picks.isEmpty ? "自选编队：这一页没有和能玩的路线相关的干员，可以不选"
                    : "自选编队：" + (c.note ?? "选\(picks)") + (rest > 0 ? "；其余 \(rest) 张和路线关系不大，不用选" : "")
                actions = c.cards.filter(\.best).map { GameAction(kind: .choose, title: "选 " + $0.name, reason: $0.reason, rect: $0.rect) }
            } else {
                liveNote = !picks.isEmpty ? "\(c.kind.rawValue)：推荐\(picks)"
                    : c.cards.contains(where: { !$0.taken }) ? "\(c.kind.rawValue)：你已经选好了" : "\(c.kind.rawValue)：能选的都被选走了"
                actions = c.cards.map { GameAction(kind: .choose, title: ($0.best ? "选 " : $0.taken ? "（已被选）" : "") + $0.name, reason: $0.reason, rect: $0.rect) }
            }
            if overlayEnabled {
                overlay.show(over: frame.windowFrame, marks: c.cards.filter(\.best).map { card in
                    let r = card.rect
                    let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(frame.toWindow)
                    return OverlayMark(kind: .choose, label: "推荐：\(card.name)", points: pts, order: 0)
                })
            }
            return
        }
        if frame.fullRead { noteOpponents(frame); noteEnemyPanel(frame) }
        // 作战中或联防：不读阵容，不给操作建议（联防时画面可能是自己的棋盘，也可能是队友的）。玩家列表挡住棋盘时也不给。
        guard hud.isRest, !hud.otherBoard, !hud.inBattle, !hud.playerList else {
            if hud.playerList {
                let c = contestedCovenants.filter { $0.value >= 1 }.sorted { $0.value > $1.value }.map { "\($0.key)×\(Int($0.value.rounded()))" }
                liveNote = "玩家列表挡住了棋盘" + (c.isEmpty ? "" : "；其他玩家在做：" + c.joined(separator: "、"))
            } else if hud.otherBoard {
                let who = hud.boardTag.map { $0.components(separatedBy: "#").first ?? $0 }
                liveNote = (hud.coDefense ? "联防中" : "观战中") + "：画面是" + (who.map { "「\($0)」" } ?? "队友") + "的棋盘，暂停识别"
            } else if hud.coDefense {
                liveNote = "联防中：自己的棋盘，打完回到休整期再给建议"
            } else {
                liveNote = hud.inBattle ? "作战中：休整期再给建议" : nil
            }
            actions = []
            overlay.hide()
            return
        }
        liveNote = nil
        let size = CGSize(width: frame.image.width, height: frame.image.height)
        updateEnemyRoutes()
        if frame.fullRead {
            let img = frame.image
            // Map + camera. Until the map is confirmed (two readings agree) every map is tried.
            var boardFresh = false
            // Started when the read began (alongside the OCR); computed here if it wasn't.
            let early = prefetch.flatMap { $0.image === img ? $0.task : nil }
            prefetch = nil
            let pre = await early?.value
            if let br = boardRecognizer {
                // A manually chosen map is not trusted until the board agrees (users often can't tell the maps apart).
                let confirmed = mapVotes.filter { $0.value >= 2 }.max { $0.value < $1.value }?.key
                let boss = hud.bossRound
                let m: BoardMatch?
                if let pre { m = pre.board } else { m = await Task.detached(priority: .userInitiated) { br.recognize(img, mapId: confirmed, boss: boss) }.value }
                TickTiming.mark("战场")
                if let m {
                    board = m
                    boardFresh = true
                    boardMisses = 0
                    mapVotes[m.mapId, default: 0] += 1
                    if mapVotes[m.mapId, default: 0] >= 2 && run.mapID != m.mapId { run.mapID = m.mapId }
                } else {
                    boardMisses += 1
                }
            }
            // Field (Neural Engine).
            if let recognizer, recognizer.loadError == nil {
                let eligible = eligibleByTier()
                let prior = Set(run.owned).union(run.owned.compactMap(catalog.prototype(of:))), names = Set(catalog.operators.map(\.name)).union(catalog.prototypes.keys)
                var reading: FieldReading
                if let r = pre?.field { reading = r }
                else {
                    let hints = badgeHints()
                    reading = await Task.detached(priority: .userInitiated) { recognizer.read(img, eligible: eligible, prior: prior, operatorNames: names, hints: hints) }.value
                }
                TickTiming.mark("认人")
                resolveStandIns(&reading)
                // Same camera as the last board fit? Compare the board area only: units moving or the shop refreshing
                // change it by 1–5, the camera moving (shop folding) or the 「已就绪」 dimming by ~30 (2026-11-22).
                // The old fit placed units into wrong cells after the shop folded, dropping four of them.
                let boardSig = ScreenSignature(img, region: ScreenSignature.boardRegion)
                if boardFresh { fitSignature = boardSig }
                let sameCamera = boardFresh || (fitSignature.map { boardSig.distance($0) < 8 } ?? false)
                boardUsable = sameCamera && !enemyPanelVisible
                if sameCamera, let p = board?.projection {
                    reading.place(on: p)
                    // Units the last good reading was sure about but whose badge isn't found now: look where they
                    // should stand under this camera (薇薇安娜's badge dimmed below the bar after the shop folded).
                    let missing = (liveField?.units ?? []).filter { u in
                        guard !u.bench, let g = u.grid, u.chosen != nil || (u.candidates.first?.p ?? 0) >= 0.9 else { return false }
                        let cell = [Int(floor(g.x)), max(0, Int(floor(g.y)))]
                        return !reading.units.contains { $0.cell == cell }
                    }
                    if !missing.isEmpty {
                        let hints = missing.compactMap { u -> FieldRecognizer.BadgeHint? in
                            guard let g = u.grid, let n = u.name else { return nil }
                            let q = p.project(g.x, g.y)
                            var names: Set<String> = [n]
                            if let proto = catalog.prototype(of: n) { names.insert(proto) }
                            if let raw = u.candidates.first?.name { names.insert(raw) }
                            return FieldRecognizer.BadgeHint(x: Double(q.x) * 1920 - 35, y: Double(q.y) * 1080 - 112, tier: u.tier, names: names)
                        }
                        let eligible = eligibleByTier()
                        let prior = Set(run.owned).union(run.owned.compactMap(catalog.prototype(of:)))
                        let names = Set(catalog.operators.map(\.name)).union(catalog.prototypes.keys)
                        let found = await Task.detached(priority: .userInitiated) {
                            recognizer.recheck(img, hints: hints, eligible: eligible, prior: prior, operatorNames: names)
                        }.value
                        if !found.isEmpty {
                            var extra = FieldReading(units: found, millis: (0, 0), computeUnits: "")
                            resolveStandIns(&extra)
                            extra.place(on: p)
                            reading.units += extra.units.filter { u in !u.bench && u.cell != nil && !reading.units.contains { $0.cell == u.cell } }
                        }
                        TickTiming.mark("复查")
                    }
                }
                // An operator's detail panel (tapping a unit) or a unit being dragged to the sell box hides part of the
                // board. Such a reading still proves the units it sees (they can be added) but can't remove anyone or
                // drive positioning. The panel shows up whenever the player taps a unit, so dropping the reading would
                // leave the lineup empty for long stretches.
                let partialView = scanner.lastTexts.contains { t in ["攻击范围", "拖拽至", "至此出售", "至此售出", "查看详情"].contains { t.text.contains($0) } }
                // Not usable at all: the round-start income popup over the board, a camera the last board fit doesn't
                // match (shop folding / unfolding, the 「已就绪」 dimming), or no units found (right after a fight the tier
                // badges aren't drawn yet).
                let unusable = scanner.lastTexts.contains { $0.text.hasPrefix("获得") && $0.box.midY > size.height * 0.3 && $0.box.midY < size.height * 0.7 }
                    || (board != nil && !sameCamera)
                    || reading.units.isEmpty
                if !unusable {
                    // The player's corrections from the review panel apply to live readings too.
                    for i in reading.units.indices where reading.units[i].chosen == nil {
                        if let n = tracker.name(of: reading.units[i]), n != reading.units[i].name { reading.units[i].chosen = n }
                    }
                    // A reading that suddenly misses several units (something half-covers the board, or the camera is
                    // still moving while the shop folds: 2026-11-22 10 → 6 units, everyone shifted a cell, and 褐果 /
                    // 玛恩纳 were read as 霜叶 / 艾雅法拉) only counts once it has repeated three times.
                    let prevCount = liveField?.units.count ?? 0
                    let fewer = prevCount - reading.units.count >= 2 && Double(reading.units.count) < Double(prevCount) * 0.85
                    if partialView {
                        if liveField == nil { liveField = reading }
                    } else if !fewer || partialReadings >= 2 {
                        liveField = reading
                        partialReadings = 0
                        let onBoard = reading.units.filter { !$0.bench }.count
                        if let remaining = hud.remainingDeploy, (6...12).contains(onBoard + remaining), run.deployCap != onBoard + remaining {
                            run.deployCap = onBoard + remaining
                        }
                    } else {
                        partialReadings += 1
                    }
                    if autoSyncField && board != nil {
                        let names = tracker.update(reading.units, partial: partialView || fewer)
                        if !names.isEmpty && names != run.owned.sorted() { run.owned = names }
                    }
                }
            }
        }
        let input = AdvisorInput(
            cards: scanner.cards, controls: scanner.controls, hud: scanner.hud, owned: run.owned, route: route,
            currentStage: currentStageIndex, deployCap: run.deployCap, field: liveField,
            map: maps.first { $0.id == (board?.mapId ?? run.mapID) }, projection: boardUsable ? board?.projection : nil, viewport: size,
            catalog: (tier: { [catalog] n in catalog.op(n)?.tier ?? catalog.equipment.first(where: { e in e.name == n })?.tier },
                      isOperator: { [catalog] n in catalog.op(n) != nil },
                      op: { [catalog] n in catalog.op(n) }),
            profiles: catalog.profiles, eliteFocus: modifiers.eliteFocus, elites: Set(run.elites), ownedEquipment: run.ownedEquipment,
            equipment: equipmentInfo, round: scanner.hud.round, forecast: forecast, enemyRoutes: enemyRoutes)
        actions = ActionAdvisor.advise(input)
        // Items bought this round that are used by equipping them: whom to give them (they can't be read off the screen
        // once equipped, so this only lasts for the round of the purchase).
        let usages = Dictionary(itemUsages.map { ($0.item, $0.use) }, uniquingKeysWith: { a, _ in a })
        for item in newItems where item.round == scanner.hud.round {
            if let use = usages[item.name], !actions.contains(where: { $0.kind == .equip && $0.title.hasSuffix(item.name) }) {
                actions.insert(GameAction(kind: .equip, title: "装备 " + item.name, reason: use, rect: nil), at: 0)
            }
        }
        // 特别关注: always point them out (with a sound once per round), even when the advice wouldn't buy them.
        let watched = Set(watchlist)
        let seen = scanner.cards.filter { watched.contains($0.name) }
        for card in seen.reversed() where !actions.contains(where: { $0.kind == .buy && $0.title.contains(card.name) }) {
            actions.insert(GameAction(kind: .buy, title: "关注 \(card.label)", reason: "特别关注的干员出现在商店", rect: card.rect), at: 0)
        }
        let alertKey = "\(scanner.hud.round ?? 0)#" + seen.map(\.name).sorted().joined(separator: ",")
        if !seen.isEmpty, !watchAlerted.contains(alertKey), recordOverride == nil {
            watchAlerted.insert(alertKey)
            NSSound(named: "Glass")?.play()
        }
        TickTiming.mark("建议")
        guard overlayEnabled else { overlay.hide(); return }
        let shown: Set<String> = Set([showBuy ? "buy" : nil, showUpgrade ? "upgrade" : nil, showRefresh ? "refresh" : nil,
                                       showFreeze ? "freeze" : nil, showPlace ? "place" : nil].compactMap { $0 })
        func toWindow(_ p: CGPoint) -> CGPoint { frame.toWindow(p) }
        let marks: [OverlayMark] = actions.filter { shown.contains($0.kind.setting) }.compactMap { a in
            let pts: [CGPoint]
            if let q = a.quad { pts = q.map(toWindow) }
            else if let r = a.rect { pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(toWindow) }
            else { return nil }
            return OverlayMark(kind: a.kind, label: a.title, points: pts, order: a.kind == .buy ? a.order : 0)
        }
        overlay.show(over: frame.windowFrame, marks: marks, lines: showRoutes ? routeLines(frame) : [])
    }

    /// This round's routes for the map on screen: the recognised board, else the map picked for the run.
    func updateEnemyRoutes() {
        guard let map = board?.mapId ?? run.mapID, let round = scanner.hud.round else {
            if enemyRoutes != nil { enemyRoutes = nil }
            return
        }
        var r = routeData.routes(map: map, round: round, mode: run.mode, bossEnemyId: boss?.enemyId)
        // The level lists the routes of every enemy group the round can draw; the game picks one at random. With the
        // enemy list read this round, keep only the kinds that are really coming (2026-11-22 round 1: 源石虫 and 普通囚犯
        // walk, so the level's two flying routes don't apply).
        if let all = r, roundEnemies.round == round, !roundEnemies.enemies.isEmpty {
            let motions = Set((roundEnemies.enemies + roundEnemies.bounty).compactMap { n in catalog.enemies.first { $0.name == n }?.motion })
            if !motions.isEmpty {
                r = all.filtered(fly: motions.contains("FLY"), walk: motions.contains("WALK"), by: roundEnemies.enemies)
            }
        }
        if r != enemyRoutes { enemyRoutes = r }
        let n = routeData.routes(map: map, round: round + 1, mode: run.mode, bossEnemyId: boss?.enemyId)
        if n != nextEnemyRoutes { nextEnemyRoutes = n }
    }

    /// Fliers this round against the operators on the field that can hit them (ranged and 领主; other melee can't).
    var antiAirNote: String? {
        guard let f = liveField else { return nil }
        let listedFliers = roundEnemies.round == scanner.hud.round
            ? roundEnemies.enemies.filter { n in catalog.enemies.first { $0.name == n }?.motion == "FLY" } : []
        let flies = (enemyRoutes?.flyRoutes ?? 0) > 0
        guard flies || !listedFliers.isEmpty else { return nil }
        let ranged = f.units.filter { !$0.bench && $0.name.map { catalog.profiles[$0]?.hitsAir == true } == true }.count
        guard ranged < 2 else { return nil }
        let what = listedFliers.isEmpty ? "飞行敌人" : "飞行敌人（\(listedFliers.joined(separator: "、"))）"
        return "这回合有\(what)，场上能打飞行的只有 \(ranged) 名（远程和领主能打，其他近战打不到）"
    }

    /// Enemy routes drawn on the board (window points): ground routes red, thicker with more enemies; flying routes
    /// cyan, dashed. Routes over the same cells are nudged apart a little so each stays visible.
    private func routeLines(_ frame: Scanner.LiveFrame) -> [OverlayLine] {
        // Only over our own board as last fitted: opening the enemy list pans the camera to the enemy staging area.
        guard boardUsable, let routes = enemyRoutes?.routes, !routes.isEmpty, let proj = board?.projection else { return [] }
        let size = CGSize(width: frame.image.width, height: frame.image.height)
        let top = Double(routes.map(\.count).max() ?? 1)
        var seen: [String: Int] = [:]
        return routes.sorted { ($0.fly ? 1 : 0, -$0.count) < ($1.fly ? 1 : 0, -$1.count) }.map { r in
            let key = r.cells.map { "\($0.0),\($0.1)" }.joined(separator: ";")
            let k = seen[key, default: 0]; seen[key] = k + 1
            let nudge = Double(k) * 0.08 + (r.fly ? 0.12 : 0)
            let segs = r.segments.map { seg in seg.map { frame.toWindow(proj.point($0.x + nudge, $0.y + nudge, in: size)) } }
            return OverlayLine(segments: segs, fly: r.fly, boss: r.boss, weight: Double(r.count) / top,
                               label: r.boss ? "领袖" : r.fly ? "飞行" : "地面")
        }
    }

    private func record(_ frame: Scanner.LiveFrame) {
        let h = scanner.hud
        let info: [String: Any] = [
            "hud": ["round": h.round as Any, "money": h.money as Any, "level": h.level as Any, "remainingDeploy": h.remainingDeploy as Any,
                    "rest": h.isRest, "battle": h.inBattle, "otherBoard": h.otherBoard, "coDefense": h.coDefense,
                    "boardTag": h.boardTag as Any, "boss": h.bossRound],
            "bar": scanner.bar.map { ["name": $0.name, "level": $0.level as Any, "layers": $0.layers as Any, "active": $0.active] },
            "cards": scanner.cards.map { ["name": $0.name, "slot": $0.slot, "price": $0.price as Any] },
            "controls": ["upgradeCost": scanner.controls.upgradeCost as Any, "refreshCost": scanner.controls.refreshCost as Any,
                         "frozen": scanner.controls.frozen, "maxed": scanner.controls.maxed],
            "board": board.map { ["map": $0.mapId, "expanded": $0.expanded, "score": $0.score] } as Any,
            "field": (liveField?.units ?? []).map { ["bench": $0.bench, "cell": $0.cell as Any, "tier": $0.tier,
                                                 "candidates": $0.candidates.map { "\($0.name) \(Int($0.p * 100))%" }] },
            "owned": run.owned,
            "route": route.map { "\($0.candidate.main) \($0.style.rawValue)" } as Any,
            "routes": ["list": candidates.prefix(8).map(\.id), "best": bestID as Any, "ai": aiPickID as Any, "userPicked": userPicked,
                       "pending": pendingSwitch?.id as Any],
            "choice": choice.map { ["kind": $0.kind.rawValue, "cards": $0.cards.map { "\($0.name) \(String(format: "%.1f", $0.score)) \($0.reason)" }] } as Any,
            "actions": actions.map { "[\($0.kind.rawValue)] \($0.title) — \($0.reason)" },
            "ocr": scanner.lastTexts.map { "\(Int($0.box.minX)),\(Int($0.box.minY)) \($0.text)" },
            "timing": TickTiming.summary(),
            "version": AppVersion.display,
            "opponents": contestedCovenants,
        ]
        DebugRecorder.save(image: frame.image, info: info)
    }

    func choiceContext() -> ChoiceContext {
        let r = route
        let goals = Set(r?.candidate.goals.map(\.name) ?? [])
        let gear = Set((r?.equipment ?? []).flatMap { $0.components(separatedBy: "：").last?.components(separatedBy: " / ") ?? [] })
        let held = Set(run.owned)
        let holders = gearHolders
        let info = equipmentInfo, owned = run.ownedEquipment, round = scanner.hud.round
        let d = PlannerData(ops: catalog.operators, covenants: catalog.covenants, profiles: catalog.profiles, selfSelected: Set(run.selfSelected), strategy: modifiers)
        let counts = d.count(Array(held))
        let scores = selfPickScores
        return ChoiceContext(
            bounties: catalog.bounties, tactics: catalog.tactics,
            enemies: Dictionary(catalog.enemies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            equipmentNames: catalog.equipment.map(\.name),
            equipmentValue: { [catalog, run] name in
                var v = ActionAdvisor.equipmentValue(name, info: info[name], gearNeeded: gear, goals: goals, owned: owned, round: round, holders: holders)
                // Used-up items say whom to give them, as in the shop (道具补给 / 机密商店 only said 「盟约装备」).
                if let effect = info[name]?.effect,
                   let use = GearAdvisor.usage(name, effect: effect, main: r?.candidate.main, smalls: r?.candidate.smallGoals.map(\.name) ?? [],
                                               owned: run.owned, carry: holders.first { $0.kind == .carry }?.name, op: catalog.op) {
                    v.1 += (v.1.isEmpty ? "" : "；") + "拿了" + use
                }
                return v
            },
            selfPickValue: { scores[$0] },
            selfPickNames: catalog.operators.filter(\.isSelfSelected).map(\.name),
            goals: goals, main: r?.candidate.main,
            rangedCount: held.filter { catalog.profiles[$0]?.hitsAir == true }.count,
            heldCount: held.count, activeCovenants: counts.filter { d.isActive(counts, $0.key) }.count, round: round,
            teamPower: run.owned.isEmpty ? nil : run.owned.reduce(0) { $0 + (ChoiceContext.tierWeight[catalog.op($1)?.tier ?? 1] ?? 1) })
    }

    /// Scores every 自选干员 against the top routes (本家 holder, stacker, small-goal holder, role).
    private func updateSelfPicks(_ top: [PlanCandidate]) {
        let d = PlannerData(ops: catalog.operators, covenants: catalog.covenants, profiles: catalog.profiles, strategy: modifiers)
        let antiAir = enemyNeeds().antiAir
        var out: [String: (Double, String)] = [:]
        for o in catalog.operators where o.isSelfSelected {
            if o.coreCovenants.isEmpty ? (!o.additionalCovenants.isEmpty && o.additionalCovenants.allSatisfy(run.unavailableCovenants.contains))
                : o.coreCovenants.allSatisfy(run.unavailableCovenants.contains) { continue }
            // Each reason carries its weight; the two heaviest are shown, naming the route when it isn't the first one.
            var v = 0.0, why: [(w: Double, text: String)] = []
            for (i, c) in top.enumerated() {
                let w = [1.0, 0.6, 0.4][i]
                let route = i == 0 ? "" : "「\(c.title)」路线的"
                if o.allCovenants.contains(c.main) { v += 4 * w; why.append((4 * w, route + "本家【\(c.main)】")) }
                if d.layers(o, on: c.main) > 0 { v += 3 * w; why.append((3 * w, i == 0 ? "给本家叠层" : route + "叠层手")) }
                let smalls = c.smallGoals.filter { o.allCovenants.contains($0.name) }
                if !smalls.isEmpty {
                    v += 1.5 * w * Double(smalls.count)
                    why.append((1.5 * w * Double(smalls.count), route + "小盟约【\(smalls.map(\.name).joined(separator: "】【"))】"))
                }
            }
            // Breaks the 协防干员 ties when this match has fliers to shoot.
            if antiAir, catalog.profiles[o.name]?.hitsAir == true { v += 0.3; why.append((0.3, "能打飞行")) }
            if d.isTank(o.name) { v += 0.5; why.append((0.5, "盾位")) }
            if d.isHealer(o.name) { v += 0.5; why.append((0.5, "奶位")) }
            if modifiers.favoredCores.contains(where: o.allCovenants.contains) { v += 2; why.append((2, "配合策略")) }
            let shown = why.sorted { $0.w > $1.w }.prefix(2).map(\.text).joined(separator: "、")
            out[o.name] = (v, v < ChoiceAdvisor.selfPickMin ? "和能玩的路线关系不大，不用选" + (shown.isEmpty ? "" : "（只是\(shown)）") : shown)
        }
        selfPickScores = out
    }

    /// Who should carry equipment: the held lineup, or the route's final lineup before anything is held.
    var gearHolders: [GearAdvisor.Holder] {
        let names = run.owned.isEmpty ? (route?.stages.last?.ops.map(\.name) ?? []) : run.owned
        return GearAdvisor.holders(names, op: { [catalog] in catalog.op($0) }, profiles: catalog.profiles)
    }

    /// Equipment already bought → who to give it to.
    var gearAssignments: [(item: String, to: String)] {
        let holders = gearHolders
        return run.ownedEquipment.compactMap { e in
            GearAdvisor.target(catalog.equipmentCategories[e] ?? [], holders).map { (e, $0.name) }
        }
    }

    private lazy var equipmentInfo: [String: (categories: [String], effect: String)] = Dictionary(
        catalog.equipment.map { ($0.name, (catalog.equipmentCategories[$0.name] ?? [], $0.normal.effectDescription)) },
        uniquingKeysWith: { a, _ in a })

    private func eligibleByTier() -> [Int: [String]] {
        let pieces = modifiers.piece
        func isPiece(_ o: Operator) -> Bool { (pieces == .mech && o.name == "暴躁铁皮") || (pieces == .pith && o.name.hasPrefix("Pith（")) }
        var eligible: [Int: [String]] = [:]
        for o in catalog.operators {
            if o.obtain != nil { if !isPiece(o) { continue } } else if run.isBanned(o) { continue }
            eligible[o.tier, default: []].append(o.name)
        }
        // Stand-in models (Pith, Sharp, 郁金香 …) stand for operators the player doesn't own, at those operators' tiers.
        for (shown, slots) in catalog.prototypes {
            for t in Set(slots.map(\.tier)) where !(eligible[t]?.contains(shown) ?? false) { eligible[t, default: []].append(shown) }
        }
        return eligible
    }

    // MARK: 自选编队

    /// After 「确定自选编队」 is confirmed (「已选择自选编队」 in the middle), the chosen 自选 operators are listed on the
    /// right: a 5-阶 row and a 6-阶 row, up to two each (StrongholdAssistant CustomPickReader reads the same result area).
    /// OCR splits short names into single characters (风 + 笛), so each line is joined before matching.
    private func recordSelfPicks(_ frame: Scanner.LiveFrame) {
        let texts = scanner.lastTexts
        guard texts.contains(where: { $0.text.contains("已选择自选编队") }) else { return }
        // On the Mac client the confirmation only shows a toast over the same grid (「3/3 确定自选编队」 still up): the
        // names on the right are cards on the grid, not the picks (2026-11-23: 结城理 recorded, the picks were Pith /
        // 嵯峨 / 丰川祥子 / 维什戴尔). Record nothing rather than the wrong operators.
        if texts.contains(where: { $0.text.contains("确定自选编队") }) { return }
        let w = Double(frame.image.width), h = Double(frame.image.height)
        let right = texts.filter { $0.box.midX > w * 0.74 && $0.box.midY > h * 0.15 && $0.box.midY < h * 0.9 }
            .sorted { $0.box.midY < $1.box.midY }
        var lines: [[OCRText]] = []
        for t in right {
            if let i = lines.firstIndex(where: { abs($0[0].box.midY - t.box.midY) < h * 0.012 }) { lines[i].append(t) } else { lines.append([t]) }
        }
        let names = catalog.operators.filter(\.isSelfSelected).map(\.name).sorted { $0.count > $1.count }
        var picked: [String] = []
        for line in lines {
            let text = line.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined().replacingOccurrences(of: " ", with: "")
            guard text.count >= 1 else { continue }
            // Two picks of a tier sit on one line: take every name in it (longest first, without overlaps).
            var rest = text, found: [String] = []
            for n in names where rest.contains(n) {
                found.append(n)
                rest = rest.replacingOccurrences(of: n, with: "|")
            }
            if !found.isEmpty {
                for n in found.sorted(by: { (text.range(of: $0)?.lowerBound ?? text.endIndex) < (text.range(of: $1)?.lowerBound ?? text.endIndex) })
                where !picked.contains(n) { picked.append(n) }
                continue
            }
            // A name cut short (予愿安洁莉娜 read as 予…莉娜): the one whose characters cover most of the line, if unique.
            let scored = names.map { n in (n, n.filter { text.contains($0) }.count) }.filter { $0.1 >= 2 && Double($0.1) >= Double($0.0.count) * 0.5 }
            if let best = scored.max(by: { $0.1 < $1.1 }), scored.filter({ $0.1 == best.1 }).count == 1, !picked.contains(best.0) { picked.append(best.0) }
        }
        guard !picked.isEmpty, Set(picked) != Set(run.selfSelected) else { return }
        run.selfSelected = picked
        newMatchNote = "已记下本局自选：" + picked.joined(separator: "、")
    }

    // MARK: Other players

    /// Core covenants each other player is building (by player tag), from the player list and from their boards in
    /// 联防 / 观战 (the top bar shows the board owner's covenants).
    /// Player → core covenant → evidence (1: on the player list, or active / with layers on their board; 0.5: only
    /// present on their bar, i.e. they hold a card or two).
    private var opponentCovenants: [String: [String: Double]] = [:]
    /// Core covenant → how many other players build it (evidence-weighted; feeds the planner).
    @Published var contestedCovenants: [String: Double] = [:]

    /// Units the last good reading was sure about, for looking again where a badge went missing.
    private func badgeHints() -> [FieldRecognizer.BadgeHint] {
        (liveField?.units ?? []).compactMap { u in
            guard let n = u.name, u.chosen != nil || (u.candidates.first?.p ?? 0) >= 0.9 else { return nil }
            var names: Set<String> = [n]
            if let proto = catalog.prototype(of: n) { names.insert(proto) }
            if let raw = u.candidates.first?.name { names.insert(raw) }
            return FieldRecognizer.BadgeHint(x: u.x, y: u.y, tier: u.tier, names: names)
        }
    }

    /// This round's enemies from the in-game enemy panel (when the player opens it).
    @Published var roundEnemies = RoundEnemies()
    private lazy var enemyMatcher = NameMatcher(names: catalog.enemies.map(\.name))

    /// The enemy list is open on the last full read (the camera is panned to the enemy staging area).
    private var enemyPanelVisible = false

    private func noteEnemyPanel(_ frame: Scanner.LiveFrame) {
        let size = CGSize(width: frame.image.width, height: frame.image.height)
        // A new round forgets last round's list.
        if roundEnemies.round != nil, roundEnemies.round != scanner.hud.round, scanner.hud.round != nil { roundEnemies = RoundEnemies(round: scanner.hud.round) }
        let read = EnemyPanelReader.read(scanner.lastTexts, size: size, matcher: enemyMatcher)
        enemyPanelVisible = read != nil
        if read != nil { boardUsable = false }
        guard let r = read else { return }
        var next = roundEnemies
        if next.add(r, round: scanner.hud.round) { roundEnemies = next }
    }

    /// Short traits of a listed enemy: 飞行 / 法术 / 高防 / 高法抗 and its first ability.
    func enemyTraits(_ name: String) -> String {
        guard let e = catalog.enemies.first(where: { $0.name == name }) else { return name }
        var t: [String] = []
        if e.motion == "FLY" { t.append("飞行") }
        if (e.damage ?? []).contains("法术") { t.append("法伤") }
        if (e.def ?? 0) >= 800 { t.append("高防") }
        if (e.res ?? 0) >= 50 { t.append("高法抗") }
        return t.isEmpty ? name : "\(name)（\(t.joined(separator: "、"))）"
    }

    private func noteOpponents(_ frame: Scanner.LiveFrame) {
        let texts = scanner.lastTexts, hud = scanner.hud
        let size = CGSize(width: frame.image.width, height: frame.image.height)
        let cores = Set(catalog.coreCovenants.map(\.name))
        var changed = false
        if hud.playerList {
            // Rows: a player tag (NAME#1234) on the left; that player's covenants to its right, a little lower. Rows of
            // other players have a 「前往观战」 button; ours doesn't.
            let tags = texts.filter { $0.text.range(of: #"#\s?\d{3,5}"#, options: .regularExpression) != nil && $0.box.midX < size.width * 0.25 }
                .sorted { $0.box.midY < $1.box.midY }
            let buttons = texts.filter { ($0.text.contains("观战") || $0.text.contains("前往")) && $0.box.midX < size.width * 0.12 }
            for (i, tag) in tags.enumerated() {
                guard buttons.contains(where: { abs($0.box.midY - tag.box.midY) < size.height * 0.03 }) else { continue }
                let bottom = i + 1 < tags.count ? tags[i + 1].box.minY : tag.box.maxY + size.height * 0.1
                let row = texts.filter { $0.box.midY > tag.box.maxY && $0.box.midY < bottom && $0.box.midX > size.width * 0.2 && $0.box.midX < size.width * 0.55 }
                let found = Dictionary(uniqueKeysWithValues: cores.filter { c in row.contains { $0.text.contains(c) } }.map { ($0, 1.0) })
                let name = tag.text.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespaces) ?? tag.text
                if !found.isEmpty && opponentCovenants[name] != found { opponentCovenants[name] = found; changed = true }
            }
        } else if hud.otherBoard, let tag = hud.boardTag, tag != "自己" {
            let bar = CovenantBarReader.read(texts: texts, image: frame.image, covenants: catalog.covenants)
            var found: [String: Double] = [:]
            for b in bar where cores.contains(b.name) { found[b.name] = b.active || (b.layers ?? 0) > 0 ? 1 : 0.5 }
            let name = tag.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespaces) ?? tag
            if !found.isEmpty && opponentCovenants[name] != found { opponentCovenants[name] = found; changed = true }
        }
        guard changed else { return }
        var counts: [String: Double] = [:]
        for player in opponentCovenants.values { for (c, w) in player { counts[c, default: 0] += w } }
        contestedCovenants = counts
        schedulePlan()
    }

    // MARK: Parallel recognition

    /// Board fit (CPU) and unit recognition (Neural Engine) for a frame, started when its full read begins so they run
    /// while the OCR worker reads the text. Only between battles (that's when units are read).
    private var prefetch: (image: CGImage, task: Task<(board: BoardMatch?, field: FieldReading?), Never>)?

    private func startPrefetch(_ img: CGImage) {
        let hud = scanner.hud
        guard hud.isRest, !hud.otherBoard, !hud.inBattle, let br = boardRecognizer else { prefetch = nil; return }
        let confirmed = mapVotes.filter { $0.value >= 2 }.max { $0.value < $1.value }?.key
        let boss = hud.bossRound
        let recognizer = (self.recognizer?.loadError == nil) ? self.recognizer : nil
        let eligible = eligibleByTier()
        let prior = Set(run.owned).union(run.owned.compactMap(catalog.prototype(of:)))
        let names = Set(catalog.operators.map(\.name)).union(catalog.prototypes.keys)
        let hints = badgeHints()
        prefetch = (img, Task.detached(priority: .userInitiated) {
            async let board = br.recognize(img, mapId: confirmed, boss: boss)
            let field = recognizer?.read(img, eligible: eligible, prior: prior, operatorNames: names, hints: hints)
            return (await board, field)
        })
    }

    // MARK: New match

    /// Highest round seen in this match, and full reads in a row showing round 1 after it.
    private var matchMaxRound = 0
    private var matchStartedAt: Date?
    /// The match as last seen mid-game (by the time round 1 shows again, the bar and HUD already show the new match).
    private var matchSnapshot: MatchRecord?
    private var roundOneReads = 0
    private var prepSeenAt: Date?

    /// A new match starts when the round counter falls from 3+ back to 1 on two reads in a row (one misread round must
    /// not wipe the lineup). The 「确认本局信息」 page can't tell: the same page opens mid-match from the HUD. When it shows,
    /// its bans / 敌方领袖 / 特训敌人 are read (before round 2, or when none are set yet) and kept through the reset that
    /// follows at round 1.
    private func detectNewMatch(_ frame: Scanner.LiveFrame) {
        let texts = scanner.lastTexts
        let isPrep = texts.contains { $0.text.contains("核心盟") } && texts.contains { $0.text.contains("附加盟") }
            && texts.contains { $0.text.contains("敌方领袖") || $0.text.contains("本局禁用") }
        if isPrep {
            if matchMaxRound < 2 || run.bannedCovenants.isEmpty {
                scanner.applyPreparation(texts: texts, image: frame.image)
                prepSeenAt = Date()
            }
            return
        }
        guard let r = scanner.frameRound, !scanner.hud.bossRound else { return }
        if r == 1 && matchMaxRound >= 3 {
            roundOneReads += 1
            if roundOneReads >= 2 { startNewMatch(reason: "回合数回到 1") }
        } else {
            roundOneReads = 0
            matchMaxRound = max(matchMaxRound, r)
            if matchStartedAt == nil { matchStartedAt = Date() }
            if r >= 2 && scanner.hud.isRest && !scanner.hud.otherBoard { matchSnapshot = currentMatchRecord() }
        }
    }

    private func currentMatchRecord() -> MatchRecord {
        MatchRecord(started: matchStartedAt ?? Date(), ended: Date(), mode: run.mode, strategy: strategy?.name,
                    map: board?.mapId ?? run.mapID, boss: run.bossName, rounds: matchMaxRound, level: scanner.hud.level,
                    lineup: run.owned, covenants: scanner.bar.filter(\.active).map { $0.name + (($0.level ?? 1) >= 2 ? "Ⅱ" : "Ⅰ") },
                    route: route?.candidate.title)
    }

    /// Saves the match that just ended to the history (from the last mid-game snapshot when there is one), once.
    /// - Parameter out: the player was eliminated: the last round seen on our own board is the one reached (later rounds
    ///   were only watched).
    func archiveMatch(out: Bool = false) {
        guard matchMaxRound >= 3, !matchArchived else { return }
        var r = matchSnapshot ?? currentMatchRecord()
        if !out { r.rounds = max(r.rounds, matchMaxRound) }
        r.ended = Date()
        history.add(r)
        matchArchived = true
        matchSnapshot = nil
        matchStartedAt = nil
    }

    // MARK: Eliminated

    /// Out of the match: the game shows other players' boards from then on. Advice, planning and most reading stop
    /// until our own board shows again or a new match starts (2026-11-22: after round 11 the whole of round 12 was
    /// spent on another player's board and the helper kept reading).
    @Published var eliminated = false
    private var matchArchived = false
    private var spectateReads = 0
    private var spectateSince: Date?
    private var ownBoardReads = 0
    /// How long a rest phase must stay on someone else's board (ELIM_SECONDS overrides it for replays, which run faster
    /// than the game).
    nonisolated static let spectateSeconds = ProcessInfo.processInfo.environment["ELIM_SECONDS"].flatMap(Double.init) ?? 20

    private func trackElimination() {
        let hud = scanner.hud
        let said = scanner.lastTexts.contains { t in ["你已被淘汰", "已被淘汰", "你被淘汰", "模拟失败", "已出局"].contains { t.text.contains($0) } }
        let watching = hud.otherBoard && !hud.coDefense && (hud.boardTag.map { $0 != "自己" } ?? false)
        if said || (watching && hud.isRest) {
            ownBoardReads = 0
            spectateReads += said ? 6 : 1
            if spectateSince == nil { spectateSince = Date() }
            // A whole rest phase on someone else's board (a look at a teammate is shorter).
            if !eliminated, spectateReads >= 6, said || Date().timeIntervalSince(spectateSince!) > Self.spectateSeconds { setEliminated(true) }
        } else if hud.isRest && !hud.otherBoard && !hud.playerList && hud.round != nil {
            // Our own board twice in a row (the spectator tag fades in, so one frame can look like ours).
            ownBoardReads += 1
            guard ownBoardReads >= 2 else { return }
            spectateReads = 0
            spectateSince = nil
            if eliminated { setEliminated(false) }
        }
    }

    private func setEliminated(_ out: Bool) {
        eliminated = out
        scanner.idleInterval = out ? 4 : nil
        if out {
            archiveMatch(out: true)
            actions = []
            choice = nil
            overlay.hide()
            liveNote = "你已出局（画面在观战别人），已暂停计算；新的一局开始时自动继续"
        } else {
            liveNote = nil
        }
    }

    private func startNewMatch(reason: String) {
        // Bans and enemies read from this match's 确认本局信息 page (just before round 1) survive the reset.
        let keep = prepSeenAt.map { Date().timeIntervalSince($0) < 15 * 60 } ?? false
        let (bans, boss, specials) = (run.bannedCovenants, run.bossName, run.specialEnemies)
        archiveMatch()
        run.newRun()
        if keep { run.bannedCovenants = bans; run.bossName = boss; run.specialEnemies = specials }
        resetRun()
        schedulePlan()
        matchMaxRound = 0
        roundOneReads = 0
        autoSwitchRound = nil
        newMatchNote = "新的一局（\(reason)）：已清空上一局的阵容" + (keep ? "，禁用和敌人用开局页读到的" : "、禁用和敌人")
        let note = newMatchNote
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if self?.newMatchNote == note { self?.newMatchNote = nil }
        }
    }
    /// Shown once after an automatic new-match reset.
    @Published var newMatchNote: String?

    /// Board frames in a row where the map / camera wasn't matched.
    private var boardMisses = 0
    /// Board-area signature of the frame the current board fit came from.
    private var fitSignature: ScreenSignature?
    /// The last full read matched the board, or showed the same camera as the last fit (overlays on the board are
    /// only drawn then: with the enemy list open the camera pans to the enemy staging area).
    private var boardUsable = false
    /// Live readings in a row that missed many units.
    private var partialReadings = 0

    /// A unit read as a stand-in model (Pith …) is the real operator of that tier the player doesn't own. The stand-in
    /// models look alike (Pith / 预备干员-重装 split the vote), so all stand-ins among the candidates are pooled: an
    /// operator already held / bought through such a card first, then one the route uses; the rest stay as alternatives.
    /// A 自选 stand-in the player picked stays itself.
    private func resolveStandIns(_ reading: inout FieldReading) {
        let held = run.owned
        let routeNames = Set(route?.stages.flatMap { $0.ops.map(\.name) } ?? [])
        // Copies known to be on the board or bench: the held lineup and this match's purchases. A stand-in sprite
        // (郁金香 …) looks the same for every operator of its slot, so each known copy names one unit: with 薇薇安娜
        // held and 可露希尔 just bought, the second 郁金香 T5 is 可露希尔, not another 薇薇安娜 (2026-11-22).
        var budget: [String: Int] = [:]
        for n in held { budget[n, default: 0] += 1 }
        for (n, c) in boughtThisMatch { budget[n] = max(budget[n] ?? 0, c) }
        for i in reading.units.indices {
            let u = reading.units[i]
            guard u.chosen == nil, let top = u.candidates.first?.name, catalog.prototypes[top] != nil,
                  !run.selfSelected.contains(top) else { continue }
            let standIns = u.candidates.filter { catalog.prototypes[$0.name] != nil && !run.selfSelected.contains($0.name) }
            var real: [(name: String, p: Double)] = []
            for c in standIns {
                for slot in catalog.prototypes[c.name]! where slot.tier == u.tier && !real.contains(where: { $0.name == slot.name }) {
                    real.append((slot.name, c.p))
                }
            }
            guard !real.isEmpty else { continue }
            let pooled = standIns.reduce(0) { $0 + $1.p }
            func rank(_ n: String) -> Int { (budget[n] ?? 0) > 0 ? 0 : held.contains(n) ? 1 : routeNames.contains(n) ? 2 : 3 }
            let ordered = real.enumerated().sorted { (rank($0.element.name), $0.offset) < (rank($1.element.name), $1.offset) }.map(\.element)
            if let first = ordered.first, (budget[first.name] ?? 0) > 0 { budget[first.name]! -= 1 }
            reading.units[i].candidates = ordered.enumerated().map { k, c in (name: c.name, p: k == 0 ? pooled : c.p * 0.5) }
                + u.candidates.filter { catalog.prototypes[$0.name] == nil }
        }
    }

    // MARK: AI

    func aiConfig() -> AIConfig {
        let d = UserDefaults.standard
        return AIConfig(provider: provider,
                        baseURL: d.string(forKey: "ai.base.\(provider.rawValue)")?.nonEmpty ?? provider.defaultBase,
                        model: d.string(forKey: "ai.model.\(provider.rawValue)")?.nonEmpty ?? provider.defaultModel,
                        key: APIKeyStore.load(provider), claudeEffort: strength.claudeEffort, claudeFast: claudeFast,
                        thinking: strength.thinking)
    }

    var supportsImages: Bool {
        provider.isAnthropic || UserDefaults.standard.bool(forKey: "ai.vision.\(provider.rawValue)")
    }

    func stateSummary() -> String {
        let hud = scanner.hud
        var l: [String] = []
        l.append("模式：\(run.mode ?? "未设定")；策略：\(strategy.map { "\($0.name)（\($0.description.replacingOccurrences(of: "\n", with: " "))）" } ?? "未选择")")
        let needs = enemyNeeds()
        l.append("敌方领袖：\(run.bossName ?? "未知")；特训敌人：\(run.specialEnemies.isEmpty ? "未知" : run.specialEnemies.joined(separator: "、"))")
        if let r = enemyRoutes { l.append(r.summary + (nextEnemyRoutes.map { "；下回合 \($0.kinds)" } ?? "") + "（人数每局随机，未知）") }
        if roundEnemies.round == scanner.hud.round, !roundEnemies.enemies.isEmpty {
            l.append("本回合敌人列表：" + roundEnemies.enemies.map(enemyTraits).joined(separator: "、"))
        }
        if !needs.notes.isEmpty { l.append("敌情：" + needs.notes.joined(separator: "；")) }
        l.append("第 \(hud.round.map(String.init) ?? "?") 回合，资金 \(hud.money.map(String.init) ?? "?")，终端 \(hud.level.map(String.init) ?? "?") 本")
        // The shop and this round's prices: without them the AI suggested upgrading with all the money and buying two cards
        // anyway (2026-11-23: 11 funds, upgrade 11).
        let shop = scanner.cards.map { c in "\(c.name)(\(c.price.map(String.init) ?? "?"))" }
        if !shop.isEmpty { l.append("商店（括号里是价格）：" + shop.joined(separator: "、") + (scanner.controls.frozen ? "（已冻结）" : "")) }
        let up = scanner.controls.upgradeCost, refresh = scanner.controls.refreshCost
        l.append("这回合升本价 \(up.map(String.init) ?? "?")，刷新 \(refresh.map(String.init) ?? "?")"
                 + ((hud.money != nil && up != nil) ? "；升本后剩 \(max(0, hud.money! - up!))" : ""))
        l.append("本局不可用盟约：\(run.unavailableCovenants.isEmpty ? "无" : run.unavailableCovenants.sorted().joined(separator: "、"))")
        let owned = run.owned.map { n in "\(n)(\(catalog.op(n).map { "\($0.tier)阶 \($0.allCovenants.joined(separator: "/"))" } ?? "")\(run.elites.contains(n) ? " 已精锐" : ""))" }
        l.append("当前阵容：\(owned.isEmpty ? "未知" : owned.joined(separator: "、"))")
        if let f = forecast {
            l.append("下回合资金约 \(f.nextMoney.map(String.init) ?? "?")，升本价 \(f.nextUpgradeCost.map(String.init) ?? "?")；剩的钱" + (f.carries ? "能" : "不能") + "留到下回合")
        }
        let activeBar = scanner.bar.filter(\.active), idleBar = scanner.bar.filter { !$0.active }
        if !activeBar.isEmpty { l.append("顶栏已激活：" + activeBar.map { "\($0.name)\($0.level == 2 ? "Ⅱ" : "Ⅰ")\($0.layers.map { " \($0)层" } ?? "")" }.joined(separator: "、")) }
        if !idleBar.isEmpty { l.append("顶栏未激活：" + idleBar.map { "\($0.name)\($0.layers.flatMap { $0 > 0 ? " \($0)层" : nil } ?? "")" }.joined(separator: "、")) }
        return l.joined(separator: "\n")
    }

    func routeSummary() -> String {
        guard let r = route else { return "（规划器未给出路线）" }
        var l: [String] = ["规划器路线：本家 \(r.candidate.mainGoal.label)，\(r.style.rawValue)。\(r.candidate.styleReason)"]
        let cur = currentStageIndex ?? 0
        for (i, s) in r.stages.enumerated() where i >= cur && i <= cur + 1 || s.isFinal {
            let miss = s.ops.filter { !$0.owned }.map(\.name)
            l.append("\(s.def.name)\(s.isFinal ? "" : "（\(s.def.terminal)本）")：\(s.ops.map(\.name).joined(separator: "、"))；还缺 \(miss.isEmpty ? "无" : miss.joined(separator: "、"))")
        }
        if !r.substitutes.isEmpty { l.append("替补：" + r.substitutes.map(\.text).joined(separator: "；")) }
        let acts = actions.filter { [.buy, .upgrade, .save, .refresh, .freeze, .unfreeze].contains($0.kind) }
        if !acts.isEmpty { l.append("规则建议的操作：" + acts.map { "\($0.title)（\($0.reason)）" }.joined(separator: "；")) }
        let list = aiRouteChoices()
        if !list.isEmpty {
            l.append("可选路线（编号 名称｜成型阵容｜备注）：")
            for (i, c) in list.enumerated() {
                var tags: [String] = []
                if c.id == selected { tags.append("正在走") }
                if c.id == bestID { tags.append("规划器推荐") }
                let held = heldCount(c)
                if held > 0 { tags.append("已有 \(held) 人") }
                tags += c.notes.prefix(2)
                let name = c.smallRoute ? c.title : "\(c.title)·\(c.id == selected ? (style ?? c.style).rawValue : c.style.rawValue)"
                l.append("R\(i + 1) \(name)｜\(c.final.operators.joined(separator: "、"))" + (tags.isEmpty ? "" : "｜" + tags.joined(separator: "；")))
            }
        }
        return l.joined(separator: "\n")
    }

    /// The routes shown to the AI: the list as the player sees it, at most 12.
    private func aiRouteChoices() -> [PlanCandidate] { Array(candidates.prefix(12)) }

    /// Finds the route the AI named on its 路线 line: 「R3」 first, else a route title / 本家 name on that line.
    static func routePick(in text: String, routes: [PlanCandidate]) -> (index: Int, line: String)? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-*#>·•")) }
        let routeLines = lines.filter { $0.hasPrefix("路线") || $0.hasPrefix("推荐路线") } + lines.filter { $0.contains("路线") && !$0.hasPrefix("路线") }
        let rx = try! NSRegularExpression(pattern: "R\\s*(\\d{1,2})")
        for line in routeLines {
            // Names: a 小盟约 route when both its small covenants are named, else the one 本家 route named.
            let named = routes.indices.filter { !routes[$0].smallRoute && line.contains(routes[$0].main) }
            let byName = routes.firstIndex { $0.smallRoute && $0.pair.allSatisfy { line.contains($0.name) } } ?? (named.count == 1 ? named[0] : nil)
            let ns = line as NSString
            if let m = rx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               let n = Int(ns.substring(with: m.range(at: 1))), n >= 1, n <= routes.count {
                // The number wins unless the line names a different route (「R3 维多利亚Ⅱ」 with R3 = 莱塔尼亚: the name).
                let c = routes[n - 1]
                let own = [c.main] + c.pair.map(\.name)
                if byName == nil || own.contains(where: line.contains) { return (n - 1, line) }
            }
            if let byName { return (byName, line) }
        }
        return nil
    }

    /// While streaming only complete lines are read (「R1」 may still become 「R12」).
    private func notePick(streaming: Bool = false) {
        let routes = aiRouteIDs.compactMap { id in candidates.first { $0.id == id } }
        let text = streaming ? String(aiText[..<(aiText.lastIndex(where: \.isNewline) ?? aiText.startIndex)]) : aiText
        guard routes.count == aiRouteIDs.count, let pick = Coach.routePick(in: text, routes: routes) else { return }
        aiPickID = routes[pick.index].id
        aiPickNote = "AI：" + pick.line
    }

    /// The open popup's cards with the rule scores, and the question for the AI.
    func choicePrompt(_ c: ChoiceScreen) -> String {
        var l = ["现在弹出了「\(c.kind.rawValue)」，要在这里做选择。可选（编号 名称｜规则评分｜规则的理由）："]
        for (i, card) in c.cards.enumerated() {
            l.append("C\(i + 1) \(card.name)｜\(String(format: "%.1f", card.score))｜\(card.reason)" + (card.taken && !card.reason.hasPrefix("已被") ? "（已被选走，不能选）" : ""))
        }
        let picks = c.cards.filter(\.best).map(\.name)
        l.append("规则推荐：" + (picks.isEmpty ? "无" : picks.joined(separator: "、")))
        switch c.kind {
        case .bounty:
            l.append("悬赏：选一个目标，击倒它才拿得到奖励资金；打不过会漏怪掉血。按当前阵容强度、敌人血量和特性判断。")
        case .selfPick:
            l.append("自选编队：每排最多选两张，选能接上可选路线本家 / 小盟约 / 叠层的。")
        case .supply, .shop:
            l.append("拿一件装备（免费），按路线和谁来带判断。")
        case .tactic:
            l.append("选一个战术，优先加成路线盟约的。")
        }
        if detailed {
            l.append("请给出：1）选哪张（写 C编号 和名称，可以不同意规则推荐）；2）理由和风险；3）选完之后这回合商店怎么做。简体中文 Markdown，不超过 200 字。")
        } else {
            l.append("""
            选哪张？严格按以下格式，每行一句，总共不超过 60 字：
            - 选：（C编号 名称；可以不同意规则推荐）
            - 理由：
            """)
        }
        return l.joined(separator: "\n")
    }

    func stopAI() { aiTask?.cancel(); aiBusy = false }

    func askAdvice() {
        aiTask?.cancel()
        aiTask = Task { await runAdvice() }
    }

    private func runAdvice() async {
        aiBusy = true
        aiError = nil
        aiText = ""
        aiTiming = nil
        aiPickID = nil
        aiPickNote = nil
        aiRouteIDs = aiRouteChoices().map(\.id)
        defer { aiBusy = false }
        let config = aiConfig()
        if config.key == nil && provider != .custom { aiError = "请先在「设置 → AI」填写 \(provider.title) 的 API Key"; return }
        var image: CGImage?
        if includeScreenshot && supportsImages { image = try? await scanner.captureViewport() }
        let user: String
        if let c = choice, !c.cards.isEmpty {
            // A popup is open (悬赏决策 / 道具补给 / 机密商店 / 战术决策 / 自选编队): ask about the popup, not the shop
            // (the user got shop advice while choosing a bounty, 2026-11-22).
            user = """
            \(stateSummary())

            \(routeSummary())

            \(choicePrompt(c))
            """
        } else if detailed {
            user = """
            \(stateSummary())

            \(routeSummary())

            请给出：1）这回合具体操作（买/卖/留/升本/刷新），总花费不能超过当前资金；2）推荐路线：单独一行写「路线：R编号 名称」（从可选路线里选，可以不同意规划器），再写理由、风险；3）接下来 2~3 回合的关键牌和资金节奏。简体中文 Markdown，不超过 320 字。
            """
        } else {
            user = """
            \(stateSummary())

            \(routeSummary())

            这回合怎么做？买的牌、升本、刷新加起来不能超过当前资金（价格见上）。严格按以下格式，每行一句，总共不超过 100 字：
            - 路线：（从可选路线里选一个，写编号和名称，如 R2 维多利亚Ⅱ；可以不同意规划器）
            - 买：
            - 卖/下场：
            - 升本/刷新：
            - 提醒：
            """
        }
        let maxTokens: Int
        switch strength {
        case .fast: maxTokens = config.provider.isAnthropic ? 900 : 280
        case .standard: maxTokens = config.provider.isAnthropic ? 2000 : 760
        case .deep: maxTokens = config.provider.isAnthropic ? 4000 : 760   // thinking models get at least 4000 (AIClient)
        }
        do {
            let client = AIClient(config: config)
            let (_, timing) = try await client.stream(system: AIPrompts.system, cachedContext: detailed ? AIPrompts.catalog(catalog) : nil,
                                                      user: user, image: image, maxTokens: maxTokens) { [weak self] t in
                guard let self else { return }
                self.aiText += t
                if self.aiPickID == nil, t.contains("\n") { self.notePick(streaming: true) }
            }
            aiTiming = timing
            notePick()
        } catch is CancellationError {
            notePick()
        } catch {
            if (error as NSError).code != NSURLErrorCancelled { aiError = error.localizedDescription }
        }
    }
}

extension String { var nonEmpty: String? { isEmpty ? nil : self } }
