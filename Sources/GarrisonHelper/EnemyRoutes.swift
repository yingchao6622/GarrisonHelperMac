import CoreGraphics
import Foundation

// This round's enemy routes: which level each round fights and, per map and level, every route as polylines of cell
// centres with the number of enemies taking it. Data: Resources/data/enemy_routes.json (scripts/build-enemy-routes.py
// from StrongholdAssistant data/garrison_routes.json, Apache-2.0; level files of ArknightsGameData act3autochess V3_1).
// Cell (c, r) has its centre at (c + 0.5, r + 0.5), the same grid as data/garrison_maps.json. StrongholdAssistant draws
// the same routes on the board (Placement/EnemyRouteStore.cs, RoundRoutes) and fights them in its placement simulation.

struct EnemyRoute: Hashable, Identifiable {
    let id = UUID()
    let fly: Bool
    let count: Int
    let boss: Bool
    /// Polylines of cell centres (col, row), spawn first; a teleport starts a new segment.
    let segments: [[CGPoint]]

    /// Board cells the route walks through, in order (segments are horizontal / vertical / diagonal between cell
    /// centres; no line between segments).
    var cells: [(Int, Int)] {
        var out: [(Int, Int)] = []
        func add(_ c: Int, _ r: Int) { if out.last.map({ $0 != (c, r) }) ?? true { out.append((c, r)) } }
        for seg in segments {
            if let p = seg.first { add(Int(floor(p.x)), Int(floor(p.y))) }
            for (a, b) in zip(seg, seg.dropFirst()) {
                let steps = max(1, Int(max(abs(b.x - a.x), abs(b.y - a.y)).rounded(.up)) * 2)
                for k in 1...steps {
                    let t = Double(k) / Double(steps)
                    add(Int(floor(a.x + (b.x - a.x) * t)), Int(floor(a.y + (b.y - a.y) * t)))
                }
            }
        }
        return out
    }
}

/// The routes of one round with their enemy counts (StrongholdAssistant RoundRoutes).
struct RoundRoutes: Equatable {
    let map: String
    let round: Int
    let level: String
    let routes: [EnemyRoute]
    /// Enemy names (from the in-game enemy list) the routes were narrowed to; nil = every route of the level.
    var listed: [String]? = nil
    var walking: Int { routes.filter { !$0.fly }.reduce(0) { $0 + $1.count } }
    var flying: Int { routes.filter(\.fly).reduce(0) { $0 + $1.count } }
    var boss: Bool { routes.contains(where: \.boss) || level.hasPrefix("h07") || level.hasPrefix("h08") }

    static func == (a: RoundRoutes, b: RoundRoutes) -> Bool {
        a.map == b.map && a.level == b.level && a.round == b.round && a.routes.count == b.routes.count && a.listed == b.listed
    }

    /// Only the walking / flying routes (the kinds the enemy list shows); boss routes always stay.
    func filtered(fly: Bool, walk: Bool, by names: [String]) -> RoundRoutes {
        RoundRoutes(map: map, round: round, level: level, routes: routes.filter { $0.boss || ($0.fly ? fly : walk) }, listed: names)
    }

    /// Ground / flying routes. The level file's enemy counts are only its template: each match swaps in one enemy group
    /// per round, from 2 to 10+ enemies (2026-11-22 19:51, m02 round 2: the level says 6 walkers, the game sent 10
    /// 萨卡兹刀兵). So counts only weight the routes against each other and are never shown as numbers of enemies.
    var walkRoutes: Int { routes.filter { !$0.fly && !$0.boss }.count }
    var flyRoutes: Int { routes.filter(\.fly).count }
    var kinds: String {
        var parts: [String] = []
        if walkRoutes > 0 { parts.append("地面 \(walkRoutes) 路") }
        if flyRoutes > 0 { parts.append("飞行 \(flyRoutes) 路") }
        return parts.isEmpty ? "只有领袖" : parts.joined(separator: " · ")
    }
    /// 「第 8 回合敌人：地面 2 路 · 飞行 1 路（领袖回合）」.
    var summary: String { "第 \(round) 回合敌人：" + kinds + (boss ? "（领袖回合）" : "") }

    /// Where the routes come from (shown under the summary).
    var sourceNote: String {
        (listed == nil ? "画的是这一关所有可能的路线（每局随机出其中一组）；在游戏里点开敌人列表后会筛掉不来的"
                       : "已按敌人列表筛选（\(listed!.joined(separator: "、"))）") + "。人数每局不同，以游戏里的敌人预览为准"
    }
}

final class EnemyRouteData: @unchecked Sendable {
    private struct File: Decodable {
        struct Route: Decodable { let motion: String; let count: Int?; let boss: Bool?; let segments: [[[Double]]] }
        struct Battle: Decodable { let bossId: String?; let level: String }
        let modes: [String: String]
        let battles: [String: [String: [Battle]]]
        let bossIds: [String: String]
        let maps: [String: [String: [Route]]]
    }
    private let file: File?

    init(resourceRoot: URL) {
        file = try? JSONDecoder().decode(File.self, from: Data(contentsOf: resourceRoot.appendingPathComponent("data/enemy_routes.json")))
    }

    var loaded: Bool { file != nil }

    /// Routes of the battle at `round` on `map` (mode by its Chinese name; boss rounds by the boss's enemy id).
    func routes(map: String, round: Int, mode: String?, bossEnemyId: String?) -> RoundRoutes? {
        guard let file else { return nil }
        let modeId = mode.flatMap { file.modes[$0] } ?? "mode_multi_normal"
        guard let battles = file.battles[modeId]?[String(round)] ?? file.battles["mode_multi_normal"]?[String(round)], !battles.isEmpty else { return nil }
        let battle = battles.count == 1 ? battles[0]
            : battles.first { b in b.bossId.flatMap { file.bossIds[$0] } == bossEnemyId } ?? battles[0]
        // Single-player levels end in "_s"; the multiplayer board uses the plain one when only that exists.
        let plain = battle.level.replacingOccurrences(of: "_s", with: "")
        guard let level = file.maps[map]?[battle.level] ?? file.maps[map]?[plain] else { return nil }
        let routes = level.map { r in
            EnemyRoute(fly: r.motion == "fly", count: r.count ?? 1, boss: r.boss ?? false,
                       segments: r.segments.map { $0.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } }.filter { $0.count >= 2 })
        }.filter { !$0.segments.isEmpty }
        return RoundRoutes(map: map, round: round, level: battle.level, routes: routes)
    }
}
