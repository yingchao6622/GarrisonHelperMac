// Portions adapted from ASP Assistant (Apache-2.0) and rewritten in Swift for this Mac app; the upstream files are listed
// in REFERENCES.md and their licenses / NOTICEs are in licenses/.
import AppKit
import Foundation
import SwiftUI

/// Static game catalog loaded from Resources/data.
@MainActor
final class Catalog: ObservableObject {
    let operators: [Operator]
    let equipment: [Equipment]
    let covenants: [Covenant]
    let covenantEffects: [String: [CovenantEffect]]
    let strategies: [Strategy]
    let bosses: [Boss]
    let roundIncome: [(round: Int, income: Int)]
    let jobChangeEquipment: [String: String]
    let profiles: [String: OperatorProfile]
    let enemies: [EnemyInfo]
    let bounties: [BountyInfo]
    let tactics: [TacticInfo]
    /// Equipment function tags (攻击/防御/生存/技力/经济/盟约/其他).
    let equipmentCategories: [String: [String]]
    let enemyTypes: [EnemyType]
    let modes: [(name: String, cores: [String], additional: [String])]
    /// Stand-in models (Pith, Sharp, 郁金香 …) → the real operators shown with them, by tier.
    let prototypes: [String: [(name: String, tier: Int)]]
    let loadError: String?

    func op(_ name: String) -> Operator? { operatorsByName[name] }
    private(set) lazy var operatorsByName: [String: Operator] =
        Dictionary(operators.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    var coreCovenants: [Covenant] { covenants.filter(\.isCore) }
    var additionalCovenants: [Covenant] { covenants.filter { !$0.isCore } }

    private var imageCache: [String: NSImage] = [:]
    let resourceRoot: URL

    init() {
        let root = Catalog.locateResources()
        resourceRoot = root
        var errors: [String] = []
        func load<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
            let url = root.appendingPathComponent("data/\(name).json")
            do {
                return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
            } catch {
                errors.append("\(name).json: \(error)")
                return nil
            }
        }
        operators = load("operators", OperatorFile.self)?.operators ?? []
        equipment = load("equipment", EquipmentFile.self)?.equipment ?? []
        let covFile = load("covenants", CovenantFile.self)
        // Keep the in-game display order: core covenants as in ASP data, then additional.
        let order = ["炎", "萨尔贡", "维多利亚", "谢拉格", "阿戈尔", "叙拉古", "卡西米尔", "乌萨斯", "伊比利亚", "莱塔尼亚",
                     "精准", "迅捷", "灵巧", "坚守", "助力", "远见", "奇迹", "投资人", "突袭", "不屈", "调和", "协防干员", "独行", "绝技", "聚合", "奥术"]
        covenants = (covFile?.covenants ?? []).sorted {
            (order.firstIndex(of: $0.name) ?? 99) < (order.firstIndex(of: $1.name) ?? 99)
        }
        jobChangeEquipment = covFile?.jobChangeEquipmentToCovenant ?? [:]
        covenantEffects = load("covenant_effects", CovenantEffectFile.self)?.covenants ?? [:]
        strategies = load("strategies", StrategyFile.self)?.strategies ?? []
        bosses = load("bosses", BossFile.self)?.bosses ?? []
        profiles = load("operator_profiles", ProfileFile.self)?.operators ?? [:]
        enemies = load("enemies", [EnemyInfo].self) ?? []
        bounties = load("bounties", [BountyInfo].self) ?? []
        tactics = load("adapt_tactics", [TacticInfo].self) ?? []
        struct Cats: Decodable { let categories: [String: [String]] }
        equipmentCategories = load("equipment_categories", Cats.self)?.categories ?? [:]
        let typeOrder = ["FLY", "SPECIAL", "INVISIBLE", "REFLECTION", "CRITIC", "REBORN", "ELEMENT", "DOT", "TIMES"]
        enemyTypes = (load("enemy_types", EnemyTypeFile.self)?.types.values.map { $0 } ?? [])
            .sorted { (typeOrder.firstIndex(of: $0.typeCode) ?? 99) < (typeOrder.firstIndex(of: $1.typeCode) ?? 99) }
        let modeOrder = ["入门协议", "标准模拟", "险境模拟", "绝境模拟", "终极模拟", "极速模拟"] + (1...20).map { "规程等级\($0)" }
        modes = (load("mode_pools", ModePoolFile.self)?.modes ?? [:]).map { ($0.key, $0.value.coreCovenants, $0.value.additionalCovenants) }
            .sorted { (modeOrder.firstIndex(of: $0.0) ?? 99) < (modeOrder.firstIndex(of: $1.0) ?? 99) }
        let income = load("round_income", RoundIncomeFile.self)?.default ?? [:]
        roundIncome = income.compactMap { k, v in Int(k).map { ($0, v) } }.sorted { $0.round < $1.round }
        struct Slot: Decodable { let name: String; let tier: Int }
        struct Protos: Decodable { let prototypes: [String: [Slot]] }
        prototypes = (load("prototypes", Protos.self)?.prototypes ?? [:]).mapValues { $0.map { ($0.name, $0.tier) } }
        loadError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func covenant(named name: String) -> Covenant? { covenants.first { $0.name == name } }

    /// The stand-in model an operator is shown with when the player doesn't own it (nil for most operators).
    func prototype(of name: String) -> String? { prototypeOf[name] }
    private(set) lazy var prototypeOf: [String: String] = {
        var m: [String: String] = [:]
        for (p, slots) in prototypes { for s in slots { m[s.name] = p } }
        return m
    }()

    /// Real operator behind a stand-in shop card ("Pith" at 3本 is 卡涅利安), from the covenant labels printed on the
    /// card and the terminal level. Nil when `shown` is not a stand-in or the card can't be told apart.
    func resolvePrototype(_ shown: String, labels: Set<String>, maxTier: Int?, tier: Int? = nil) -> String? {
        guard let slots = prototypes[shown] else { return nil }
        let pool = slots.filter { s in (tier == nil || s.tier == tier) && (maxTier == nil || s.tier <= maxTier!) }
        guard !pool.isEmpty else { return nil }
        if labels.isEmpty { return pool.count == 1 ? pool[0].name : nil }
        let scored = pool.map { s -> (String, Int) in
            let covs = Set(op(s.name)?.allCovenants ?? [])
            return (s.name, 2 * covs.intersection(labels).count - labels.subtracting(covs).count - covs.subtracting(labels).count)
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 > 0 else { return nil }
        if scored.count > 1 && scored[1].1 == best.1 { return nil }
        return best.0
    }

    func image(_ relativePath: String) -> NSImage? {
        if let cached = imageCache[relativePath] { return cached }
        let url = resourceRoot.appendingPathComponent(relativePath)
        guard let img = NSImage(contentsOf: url) else { return nil }
        imageCache[relativePath] = img
        return img
    }

    /// All names that can appear on shop cards (operators + equipment).
    var shopNames: [String] { operators.filter { $0.obtain == nil }.map(\.name) + equipment.map(\.name) }

    nonisolated static var resourceRootURL: URL { locateResources() }

    nonisolated private static func locateResources() -> URL {
        if let r = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: r.appendingPathComponent("data/operators.json").path) {
            return r
        }
        // `swift build` binaries (.build/debug/GarrisonHelper, .build/apple/Products/Release/…): walk up to the package.
        // Not #filePath: that would put the developer's home folder path into every build.
        var dir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("data/operators.json").path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
    }
}

/// Per-run state: mode, strategy, enemies, bans, held operators. Persisted in UserDefaults.
@MainActor
final class RunState: ObservableObject {
    struct Saved: Codable {
        var autoBannedCovenants: [String] = []
        var manualBannedOperators: [String] = []
        var manualUnbannedOperators: [String] = []
        var bossName: String?
        var owned: [String]? = nil
        var locked: [String]? = nil
        var autoRecordPurchases: Bool? = nil
        var mode: String? = nil
        var strategyID: String? = nil
        var mechElite: Bool? = nil
        var specialEnemies: [String]? = nil
        var selfSelected: [String]? = nil
        var mapID: String? = nil
        var deployCap: Int? = nil
        var ownedEquipment: [String]? = nil
        var elites: [String]? = nil
    }

    @Published var bannedCovenants: Set<String> = [] { didSet { save() } }
    @Published var manualBannedOperators: Set<String> = [] { didSet { save() } }
    @Published var manualUnbannedOperators: Set<String> = [] { didSet { save() } }
    @Published var bossName: String? { didSet { save() } }
    /// Operators the player holds right now (场上 + 整备区). Duplicates allowed (同名多张).
    @Published var owned: [String] = [] { didSet { save() } }
    /// Operators the route must keep (必带).
    @Published var locked: [String] = [] { didSet { save() } }
    @Published var autoRecordPurchases = true { didSet { save() } }
    /// 模式（决定本局可出现的盟约池）。nil = 不限。
    @Published var mode: String? { didSet { save() } }
    @Published var strategyID: String? { didSet { save() } }
    @Published var mechElite = false { didSet { save() } }
    /// 特训敌人（敌人名称）。
    @Published var specialEnemies: [String] = [] { didSet { save() } }
    /// 本局带入的自选干员。
    @Published var selfSelected: [String] = [] { didSet { save() } }
    /// 战场（地图），用于站位建议。
    @Published var mapID: String? { didSet { save() } }
    /// 上场人数上限：识别到「场上人数 + 剩余可放置」后自动更新。
    @Published var deployCap = 8 { didSet { save() } }
    /// 买到的装备（用于推荐合成 / 给谁带）。
    @Published var ownedEquipment: [String] = [] { didSet { save() } }
    /// Operators already merged into 精锐 this run (a 精锐 can't be merged again, so more copies are no use). Set when the
    /// third copy is bought, or by hand from the route panel.
    @Published var elites: [String] = [] { didSet { save() } }
    /// Covenants outside the chosen mode's pool (set by the coach from the catalog).
    @Published var outOfMode: Set<String> = []

    private let key = "runState.v1"
    private var loading = true

    init() {
        if let data = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            bannedCovenants = Set(s.autoBannedCovenants)
            manualBannedOperators = Set(s.manualBannedOperators)
            manualUnbannedOperators = Set(s.manualUnbannedOperators)
            bossName = s.bossName
            owned = s.owned ?? []
            locked = s.locked ?? []
            autoRecordPurchases = s.autoRecordPurchases ?? true
            mode = s.mode
            strategyID = s.strategyID
            mechElite = s.mechElite ?? false
            specialEnemies = s.specialEnemies ?? []
            selfSelected = s.selfSelected ?? []
            mapID = s.mapID
            deployCap = s.deployCap ?? 8
            ownedEquipment = s.ownedEquipment ?? []
            elites = s.elites ?? []
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Saved(autoBannedCovenants: Array(bannedCovenants), manualBannedOperators: Array(manualBannedOperators),
                      manualUnbannedOperators: Array(manualUnbannedOperators), bossName: bossName, owned: owned, locked: locked,
                      autoRecordPurchases: autoRecordPurchases, mode: mode, strategyID: strategyID, mechElite: mechElite,
                      specialEnemies: specialEnemies, selfSelected: selfSelected, mapID: mapID, deployCap: deployCap, ownedEquipment: ownedEquipment, elites: elites)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Banned this run or not in the mode's pool.
    var unavailableCovenants: Set<String> { bannedCovenants.union(outOfMode) }

    /// Same rule as ASP Assistant: an operator with core covenants is disabled only when all of
    /// them are unavailable; one without core covenants when none of its additional covenants is available.
    func isAutoBanned(_ op: Operator) -> Bool {
        let off = unavailableCovenants
        guard !off.isEmpty else { return false }
        if !op.coreCovenants.isEmpty { return op.coreCovenants.allSatisfy(off.contains) }
        if op.additionalCovenants.isEmpty { return false }
        return op.additionalCovenants.allSatisfy(off.contains)
    }

    func isBanned(_ op: Operator) -> Bool {
        if op.isSelfSelected && !selfSelected.contains(op.name) { return true }
        if manualBannedOperators.contains(op.name) { return true }
        if manualUnbannedOperators.contains(op.name) { return false }
        return isAutoBanned(op)
    }

    func toggleManualBan(_ op: Operator) {
        if isBanned(op) {
            manualBannedOperators.remove(op.name)
            if isAutoBanned(op) { manualUnbannedOperators.insert(op.name) }
        } else {
            manualUnbannedOperators.remove(op.name)
            if !isAutoBanned(op) { manualBannedOperators.insert(op.name) }
        }
    }

    func newRun() {
        owned = []
        locked = []
        bannedCovenants = []
        manualBannedOperators = []
        manualUnbannedOperators = []
        bossName = nil
        specialEnemies = []
        ownedEquipment = []
        elites = []
        mapID = nil
        deployCap = 8
    }
}
