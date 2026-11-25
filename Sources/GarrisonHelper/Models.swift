import Foundation

// Data files come from StrongholdAssistant / ASP Assistant (Apache-2.0). See licenses/.

struct Trait: Codable, Hashable {
    var traitType: String
    var traitDescription: String
}

struct TraitSet: Codable, Hashable {
    var traits: [Trait]
}

struct Operator: Codable, Identifiable, Hashable {
    var name: String
    var iconPath: String
    var tier: Int
    var diy: Bool?
    var coreCovenants: [String]
    var additionalCovenants: [String]
    var normal: TraitSet
    var elite: TraitSet
    var obtain: String?

    var id: String { name }
    var allCovenants: [String] { coreCovenants + additionalCovenants }
    var isSelfSelected: Bool { diy ?? false }
    var traitTypes: Set<String> { Set((normal.traits + elite.traits).map(\.traitType)) }
}

struct EffectText: Codable, Hashable {
    var effectDescription: String
}

struct Equipment: Codable, Identifiable, Hashable {
    var name: String
    var iconPath: String
    var tier: Int
    var normal: EffectText
    var elite: EffectText
    var id: String { name }
}

struct Covenant: Codable, Identifiable, Hashable {
    var name: String
    var bondType: String   // SEASON = 核心盟约, REGULAR = 附加盟约
    var activateCount: Int
    var id: String { name }
    var isCore: Bool { bondType == "SEASON" }
    var iconPath: String { "icons/covenants/\(name).png" }
}

struct CovenantEffect: Codable, Hashable {
    var condition: String
    var text: String
}

struct Strategy: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var initiator: String
    var iconPath: String
    var description: String
    var unlockRequirement: String?
    var initialHp: Int?
}

struct Boss: Codable, Identifiable, Hashable {
    var enemyId: String
    var enemyIndex: String?
    var name: String
    var aliases: [String]?
    var description: String?
    var damageTypes: [String]?
    var abilityList: [String]?
    var iconPath: String
    /// HP by mode name (终极模拟, 规程等级20 …), from activity_table bossInfoDict (scripts/build-boss-hp.py).
    var hpByMode: [String: Int]?
    var id: String { enemyId }
}

struct OperatorStackAmplify: Codable, Hashable {
    var type: String      // capPercent / capFlat / perEvent / tempBoost
    var value: Double
    var scope: String?    // around / front / sameCovenant
}

struct OperatorStack: Codable, Hashable {
    var kind: String          // covenant / self / adjacent / grant / amplifier / once
    var covenants: [String]
    var amount: Double?
    var cap: Double?
    var perRound: Double
    var temporary: Bool
    var amplify: OperatorStackAmplify?
}

struct OperatorProfile: Codable, Hashable {
    var profession: String?
    var subProfession: String?
    var position: String?
    var blockCount: Int?
    var roles: [String]?
    var stack: OperatorStack?
    var consumes: [String]?
    var skill: String?
    /// Attack range cells [dx, dy] when facing right (normal state).
    var range: [[Int]]?

    var isTank: Bool { roles?.contains("盾位") ?? false }
    /// Can hit flying enemies: every ranged operator, and melee 领主 (烈夏, 银灰, 棘刺…), which attack at range.
    /// Same rule as StrongholdAssistant Placement/PlacementPlanner.cs (`AntiAir = !p.IsMelee || p.SubProfession == "领主"`).
    var hitsAir: Bool { position == "远程" || subProfession == "领主" }
    var isHealer: Bool { roles?.contains("奶位") ?? false }
    var isStacker: Bool { stack.map { $0.kind != "once" } ?? false }
    var roleText: String {
        var parts = roles ?? []
        if let s = stack {
            switch s.kind {
            case "covenant": parts.append("叠层" + s.covenants.map { "【\($0)】" }.joined())
            case "self": parts.append("叠层（自身盟约）")
            case "adjacent": parts.append("通用叠层（自身+相邻）")
            case "grant": parts.append("给相邻叠层")
            case "amplifier": parts.append("叠层放大")
            default: break
            }
        }
        if let c = consumes, !c.isEmpty { parts.append("吃层" + c.map { "【\($0)】" }.joined()) }
        return parts.joined(separator: " · ")
    }
}

struct EnemyInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var level: String?
    var damage: [String]?
    var motion: String?
    var hp: Double?
    var atk: Double?
    var def: Double?
    var res: Double?
    var abilities: [String]?
}

struct EnemyVariant: Codable, Hashable { var specialEnemyId: String; var enemyName: String; var iconPath: String?; var weight: Double? }
struct EnemyType: Codable, Hashable {
    var typeCode: String
    var typeName: String
    var typeIconPath: String?
    var firstHalfVariants: [EnemyVariant]?
    var secondHalfVariants: [EnemyVariant]?
    var variants: [EnemyVariant] { (firstHalfVariants ?? []) + (secondHalfVariants ?? []) }
}
struct EnemyTypeFile: Codable { var types: [String: EnemyType] }
struct ModePoolFile: Codable {
    struct Pool: Codable { var coreCovenants: [String]; var additionalCovenants: [String]; var selectCoreGroup: Bool? }
    var modes: [String: Pool]
}

struct BountyInfo: Codable, Hashable {
    var id: String
    var name: String
    var kind: String          // kill / perfect
    var enemyId: String?
    var enemyName: String?
    var count: Int?
    var coin: Int
    var rounds: Int?          // nil = every later battle
    var tag: String?
    var grade: Int?
    var text: String
}

struct TacticInfo: Codable, Hashable { var id: String; var name: String; var desc: String }

// MARK: - File wrappers

struct ProfileFile: Codable { var operators: [String: OperatorProfile] }

struct OperatorFile: Codable { var operators: [Operator] }
struct EquipmentFile: Codable { var manualJobChangeEquipments: [String]?; var equipment: [Equipment] }
struct CovenantFile: Codable { var covenants: [Covenant]; var jobChangeEquipmentToCovenant: [String: String]? }
struct CovenantEffectFile: Codable { var covenants: [String: [CovenantEffect]] }
struct StrategyFile: Codable { var strategies: [Strategy] }
struct BossFile: Codable { var bosses: [Boss] }
struct RoundIncomeFile: Codable { var `default`: [String: Int] }
