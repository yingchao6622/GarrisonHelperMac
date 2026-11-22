import CoreGraphics
import Foundation

// Board geometry and a light positioning heuristic.
// Map grids, routes and camera corner points: StrongholdAssistant data/garrison_maps.json (Apache-2.0);
// deploy rule (melee: ground/special, ranged: also high ground) from Placement/GarrisonBoard.cs.
// The placement scoring below is a simplified stand-in for hongxue's PlacementPlanner (simulated annealing),
// not a port of it. See REFERENCES.md.

struct GarrisonMap: Codable, Hashable, Identifiable {
    struct Route: Codable, Hashable { var spawn: [Int]; var cells: [[Int]] }
    var id: String
    var name: String
    var cells: [String]          // rows 0..4, columns -2..9
    var routes: [Route]
    /// Special tiles by kind ("infection" / "mire" / "hide" / "speedup") → [[col, row]] (StrongholdAssistant
    /// data/build_garrison_terrain.py, from the game's level files).
    var terrain: [String: [[Int]]]? = nil

    func tile(_ col: Int, _ row: Int) -> MapTile? {
        guard let t = terrain else { return nil }
        for (k, cells) in t where cells.contains([col, row]) { return MapTile(rawValue: k) }
        return nil
    }

    static let firstColumn = -2
    func type(_ col: Int, _ row: Int) -> Character {
        guard row >= 0, row < cells.count else { return "X" }
        let line = Array(cells[row])
        let i = col - GarrisonMap.firstColumn
        return i >= 0 && i < line.count ? line[i] : "X"
    }
    /// G ground / T special: anyone; H high ground: ranged only.
    func canDeploy(_ col: Int, _ row: Int, melee: Bool) -> Bool {
        let t = type(col, row)
        return t == "G" || t == "T" || (t == "H" && !melee)
    }
}

struct GarrisonMapFile: Codable {
    var cameras: [String: [[[Double]]]]
    var maps: [GarrisonMap]
}

/// Maps grid corners (col,row) to normalized viewport points with a homography through four calibrated corners.
struct BoardProjection {
    private let h: [Double]   // 3×3, row-major
    /// Translation (normalized) fitted from the badges on the board.
    var shift = CGPoint.zero

    init?(corners: [[[Double]]]) {
        // corners: [[[col,row],[x,y]], …] × 4
        guard corners.count == 4 else { return nil }
        var a = [[Double]](), b = [Double]()
        for c in corners {
            let (u, v, x, y) = (c[0][0], c[0][1], c[1][0], c[1][1])
            a.append([u, v, 1, 0, 0, 0, -u * x, -v * x]); b.append(x)
            a.append([0, 0, 0, u, v, 1, -u * y, -v * y]); b.append(y)
        }
        guard let sol = BoardProjection.solve(a, b) else { return nil }
        h = sol + [1]
    }

    func project(_ col: Double, _ row: Double) -> CGPoint {
        let w = h[6] * col + h[7] * row + h[8]
        return CGPoint(x: (h[0] * col + h[1] * row + h[2]) / w + shift.x, y: (h[3] * col + h[4] * row + h[5]) / w + shift.y)
    }

    /// Fits a translation from the tier badges of units on the board (idea from StrongholdAssistant
    /// FieldReader.Camera.FitFieldCamera; badge ↔ cell offsets from FieldReader.ReadCells:
    /// badge ≈ cell centre + (−0.4 tile, −110) with the shop open, (−0.35 tile, −(116 − 2·row)) folded; +26 up on high ground).
    func fitted(to badges: [CGPoint], viewport: CGSize, expanded: Bool) -> BoardProjection {
        guard badges.count >= 2 else { return self }
        let k = viewport.width / 1920
        var dx: [Double] = [], dy: [Double] = []
        for b in badges {
            var best: (Double, CGPoint)?
            for row in 0...3 {
                for col in 0...6 {
                    let c = project(Double(col) + 0.5, Double(row) + 0.5)
                    let n = project(Double(col) + 1.5, Double(row) + 0.5)
                    let tile = abs(n.x - c.x) * viewport.width
                    for lift in [0.0, 26.0] {
                        let e = CGPoint(x: c.x * viewport.width - (expanded ? 0.4 : 0.35) * tile,
                                        y: c.y * viewport.height - ((expanded ? 110 : 116 - 2 * Double(row)) + lift) * k)
                        let d = Double(hypot(b.x - e.x, b.y - e.y))
                        if d < 0.6 * tile && (best == nil || d < best!.0) { best = (d, CGPoint(x: b.x - e.x, y: b.y - e.y)) }
                    }
                }
            }
            if let r = best?.1 { dx.append(r.x); dy.append(r.y) }
        }
        guard dx.count >= 2 else { return self }
        var p = self
        p.shift = CGPoint(x: shift.x + dx.sorted()[dx.count / 2] / viewport.width, y: shift.y + dy.sorted()[dy.count / 2] / viewport.height)
        return p
    }

    /// Quad of one cell in viewport pixels (projection is in the normalised 1920×1080 board frame).
    func cell(_ col: Int, _ row: Int, in size: CGSize) -> [CGPoint] {
        let t = CoverTransform(viewport: size)
        return [(0.0, 0.0), (1, 0), (1, 1), (0, 1)].map { d in t.toViewport(project(Double(col) + d.0, Double(row) + d.1)) }
    }

    /// Grid coordinates (col, row) of a point in the normalised 1920×1080 frame.
    func unproject(_ q: CGPoint) -> (col: Double, row: Double)? {
        let x = q.x - shift.x, y = q.y - shift.y
        // Solve H·(c, r, 1) ∝ (x, y, 1) for c, r.
        let a11 = h[0] - x * h[6], a12 = h[1] - x * h[7], b1 = x * h[8] - h[2]
        let a21 = h[3] - y * h[6], a22 = h[4] - y * h[7], b2 = y * h[8] - h[5]
        let det = a11 * a22 - a12 * a21
        guard abs(det) > 1e-12 else { return nil }
        return ((b1 * a22 - a12 * b2) / det, (a11 * b2 - b1 * a21) / det)
    }

    func point(_ col: Double, _ row: Double, in size: CGSize) -> CGPoint { CoverTransform(viewport: size).toViewport(project(col, row)) }

    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a.enumerated().map { $1 + [b[$0]] }
        let n = 8
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            for r in 0..<n where r != col {
                let f = m[r][col] / m[col][col]
                for k in col...n { m[r][k] -= f * m[col][k] }
            }
        }
        return (0..<n).map { m[$0][n] / m[$0][$0] }
    }
}

enum Facing: String { case right = "→", left = "←", up = "↑", down = "↓" }

struct Placement: Hashable {
    let name: String
    let col: Int
    let row: Int
    let facing: Facing
    let reason: String
}

/// Special tiles (stage_table tileInfo, as summarised in StrongholdAssistant data/build_garrison_terrain.py; how they
/// weigh in placement follows the rules described in StrongholdAssistant Placement/PlacementPlanner.cs).
enum MapTile: String, CaseIterable {
    /// 活性源石（沙漠红地板）: operators on it and enemies walking over it get attack and attack speed, and lose HP over time.
    case infection
    /// 沼泽: operators' attack speed and passing enemies' attack and move speed drop.
    case mire
    /// 隐匿模块: units and enemies on it are invisible.
    case hide
    /// 优化模块（蓝箭头）: operators' attack speed up, passing enemies faster.
    case speedup

    var name: String {
        switch self {
        case .infection: "红地板（活性源石）"
        case .mire: "沼泽"
        case .hide: "隐匿格"
        case .speedup: "蓝箭头（优化模块）"
        }
    }
    var short: String {
        switch self { case .infection: "红地板"; case .mire: "沼泽"; case .hide: "隐匿"; case .speedup: "蓝箭头" }
    }
    var effect: String {
        switch self {
        case .infection: "站上去的干员攻击和攻速提升但会持续掉血；敌人踩过也会变强"
        case .mire: "站上去的干员攻速下降；敌人走过会变慢、攻击降低"
        case .hide: "格子上的干员和敌人都看不见（打不到格子里的敌人）"
        case .speedup: "站上去的干员攻速提升；敌人走过会变快"
        }
    }
    /// Enemies that walk over it before reaching the line come in stronger.
    var buffsEnemies: Bool { self == .infection || self == .speedup }
}

/// Positioning advice on the recognised map. Enemies walk each route from a red spawn (S) to the blue defence point
/// (D). The first melee operator standing on a route is its block point: enemies pile up on it and the cell or two in
/// front of it, so that is where damage counts (cells behind it only see leaks) and every operator faces the way
/// enemies come from. Blockers prefer a cell where routes merge and, when there are enough melee operators to hold
/// each lane, a cell in front of 红地板 / 蓝箭头 so enemies don't walk over them first. Ranged operators cover the
/// cells where enemies stop (enemies on 隐匿格 can't be hit), stand off the path, and like 红地板 / 蓝箭头 (attack /
/// attack speed up; 红地板 drains HP, so not for blockers); nobody stands on 沼泽. Healers stand where their range
/// reaches the blockers; adjacent stackers stand next to members of their covenant. Units already standing well are left
/// alone; only clear improvements are suggested. A simplified stand-in for the simulated-annealing planners of
/// StrongholdAssistant / hongxue, not a port of them.
enum PlacementHeuristic {
    struct Context {
        let map: GarrisonMap
        let profiles: [String: OperatorProfile]
        /// Ground route cells in walking order with the route's share of enemies. With this round's routes
        /// (EnemyRouteData) the weight follows the enemy count (busiest lane 2, a boss counts as 6 enemies); without
        /// them the map's static lanes, the lower one with about twice the enemies of the upper one (as in
        /// StrongholdAssistant's StaticRouteWeight).
        let routes: [(cells: [(Int, Int)], weight: Double)]
        /// Cells flying enemies cross ("c,r" → enemy presence, rising towards the defence point). Fliers aren't
        /// blocked and melee operators can't hit them, so only ranged operators score them.
        let fly: [String: Double]
        /// Enough melee operators to hold each lane in front of the enemy-buff tiles.
        let lanesHeld: Bool

        init(map: GarrisonMap, profiles: [String: OperatorProfile], team: [Operator], enemy: RoundRoutes? = nil) {
            self.map = map; self.profiles = profiles
            let walk = (enemy?.routes ?? []).filter { !$0.fly }
            if !walk.isEmpty {
                // Routes over the same cells are one lane.
                var lanes: [(cells: [(Int, Int)], n: Double)] = []
                for r in walk {
                    let c = r.cells, n = Double(r.count) + (r.boss ? 5 : 0)
                    if let i = lanes.firstIndex(where: { $0.cells.elementsEqual(c, by: ==) }) { lanes[i].n += n } else { lanes.append((c, n)) }
                }
                let top = lanes.map(\.n).max() ?? 1
                // Lanes with a handful of stragglers don't get a blocker of their own.
                routes = lanes.filter { $0.n >= top * 0.12 }.map { ($0.cells, max(0.4, 2 * $0.n / top)) }
            } else {
                routes = map.routes.enumerated().map { k, r in
                    (r.cells.filter { $0.count == 2 }.map { ($0[0], $0[1]) }, k == map.routes.count - 1 && map.routes.count > 1 ? 2.0 : 1.0)
                }
            }
            var fly: [String: Double] = [:]
            let fliers = (enemy?.routes ?? []).filter(\.fly)
            let flyTop = Double(max(1, walk.map(\.count).max() ?? 0, fliers.map(\.count).max() ?? 0))
            for r in fliers {
                let c = r.cells
                for (i, cell) in c.enumerated() {
                    fly["\(cell.0),\(cell.1)", default: 0] += 1.2 * Double(r.count) / flyTop * (1 + Double(i) / Double(max(1, c.count)))
                }
            }
            self.fly = fly
            lanesHeld = team.filter { profiles[$0.name]?.position == "近战" }.count >= max(1, routes.count)
        }

        func melee(_ o: Operator) -> Bool { profiles[o.name]?.position == "近战" }
        /// Ranged operators and melee 领主 cover flying routes.
        func hitsAir(_ o: Operator) -> Bool { profiles[o.name]?.hitsAir == true }
        func role(_ o: Operator) -> Int {
            let p = profiles[o.name]
            if p?.isHealer == true { return 3 }
            if p?.isTank == true || (melee(o) && (p?.blockCount ?? 0) >= 3) { return 0 }
            return melee(o) ? 1 : 2
        }
        func index(_ k: Int, _ c: Int, _ r: Int) -> Int? { routes[k].cells.firstIndex { $0 == (c, r) } }
        func onPath(_ c: Int, _ r: Int) -> Bool { routes.indices.contains { index($0, c, r) != nil } }
        /// Next to a cell where enemies walk before they are blocked (ranged enemies and passers-by hit it).
        func besideOpenPath(_ c: Int, _ r: Int, blocks: [Int?]) -> Bool {
            [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { d in
                routes.indices.contains { k in index(k, c + d.0, r + d.1).map { i in blocks[k].map { i < $0 } ?? true } ?? false }
            }
        }
        /// A non-blocker standing where enemies walk (an unheld lane, or in front of / on the block point) gets hit.
        func exposed(_ c: Int, _ r: Int, blocks: [Int?]) -> Bool {
            routes.indices.contains { k in index(k, c, r).map { i in blocks[k].map { i <= $0 } ?? true } ?? false }
        }

        /// Block point (cell index) of each route given where melee operators stand.
        func blocks(_ placed: [(Operator, Int, Int)]) -> [Int?] {
            routes.indices.map { k in
                placed.filter { melee($0.0) }.compactMap { index(k, $0.1, $0.2) }.min()
            }
        }

        /// How much enemy presence a cell sees: around the block point when the route is blocked, along the whole
        /// route (rising towards the defence point) when it isn't. Enemies on 隐匿格 can't be targeted.
        func dwell(_ c: Int, _ r: Int, blocks: [Int?]) -> Double {
            var v = 0.0
            for k in routes.indices {
                guard let i = index(k, c, r) else { continue }
                let w = routes[k].weight
                if let b = blocks[k] {
                    let d = b - i
                    v += w * (d < 0 ? 0.15 : d <= 1 ? 3 : d == 2 ? 1.8 : 0.8)
                } else {
                    v += w * (1 + 2 * Double(i) / Double(max(1, routes[k].cells.count)))
                }
            }
            return map.tile(c, r) == .hide ? v * 0.2 : v
        }

        func rotate(_ d: [Int], _ f: Facing) -> (Int, Int) {
            switch f {
            case .right: return (d[0], d[1])
            case .left: return (-d[0], -d[1])
            case .up: return (d[1], -d[0])
            case .down: return (-d[1], d[0])
            }
        }
        func rangeCells(_ o: Operator) -> [[Int]] { profiles[o.name]?.range ?? (melee(o) ? [[0, 0], [1, 0]] : [[0, 0], [1, 0], [2, 0], [1, -1], [1, 1]]) }

        /// Best facing and the enemy presence its range covers (ranged operators also count flying enemies).
        func coverage(_ o: Operator, _ c: Int, _ r: Int, blocks: [Int?]) -> (Double, Facing) {
            // Ties (symmetric ranges) face where enemies come from.
            let up = nearestUpstream(c, r)
            let air = hitsAir(o) && !fly.isEmpty
            var best = (0.0, up ?? Facing.right)
            for f in ([up].compactMap { $0 } + [Facing.right, .left, .up, .down].filter { $0 != up }) {
                let v = rangeCells(o).reduce(0.0) { acc, d in
                    let q = rotate(d, f)
                    return acc + dwell(c + q.0, r + q.1, blocks: blocks) + (air ? fly["\(c + q.0),\(r + q.1)"] ?? 0 : 0)
                }
                if v > best.0 { best = (v, f) }
            }
            return best
        }

        /// Flying-enemy presence an anti-air operator's (ranged or 领主) range covers at its best facing.
        func airCoverage(_ o: Operator, _ c: Int, _ r: Int) -> Double {
            guard hitsAir(o), !fly.isEmpty else { return 0 }
            return [Facing.right, .left, .up, .down].map { f in
                rangeCells(o).reduce(0.0) { acc, d in let q = rotate(d, f); return acc + (fly["\(c + q.0),\(r + q.1)"] ?? 0) }
            }.max() ?? 0
        }

        /// Value of holding a route at (c, r): routes through the cell, less when an enemy-buff tile comes first or the
        /// route is already held.
        func blockValue(_ c: Int, _ r: Int, b: [Int?]) -> (Double, [String]) {
            var v = 0.0, notes: [String] = []
            var through = 0
            for k in routes.indices {
                guard let i = index(k, c, r) else { continue }
                through += 1
                var w = routes[k].weight * (8 + 2 * Double(i) / Double(max(1, routes[k].cells.count)))
                if b[k] != nil { w *= 0.25 }       // the lane is already held: this is only a second line
                let buffed = routes[k].cells.prefix(i).compactMap { map.tile($0.0, $0.1) }.filter(\.buffsEnemies)
                if let t = buffed.first {
                    w -= routes[k].weight * (lanesHeld ? (t == .infection ? 6 : 2.5) : (t == .infection ? 2 : 1))
                    if !notes.contains("buffed") { notes.append("buffed") }
                }
                v += w
            }
            if through >= 2 { notes.append("merge") }
            return (v, notes)
        }

        struct BlockSpot { let c: Int; let r: Int; let routes: [Int]; let note: String }

        /// Where the melee operators hold the lanes. Enough of them for every lane and an enemy-buff tile (红地板 /
        /// 蓝箭头) on the lanes, or routes that only merge next to the defence point: one block point per lane, just in
        /// front of the buff tile / the merge. Otherwise one block point where the routes merge, leaving a couple of
        /// cells behind it for a second line. Never on 沼泽 (it slows the blocker's attacks; enemies crossing it are slowed,
        /// which is good).
        func blockPlan(melee n: Int) -> [BlockSpot] {
            guard n > 0, !routes.isEmpty else { return [] }
            func ok(_ cell: (Int, Int)) -> Bool { map.canDeploy(cell.0, cell.1, melee: true) && map.tile(cell.0, cell.1) != .mire }
            let shared = routes[0].cells.filter { cell in routes.allSatisfy { r in r.cells.contains { $0 == cell } } }
            let mergeIndex = shared.first.flatMap { m in routes.map { r in r.cells.firstIndex { $0 == m } ?? 0 } }
            let sharedOK = shared.filter(ok)
            let buffBefore = routes.indices.contains { k in
                routes[k].cells.prefix(mergeIndex?[k] ?? routes[k].cells.count).contains { map.tile($0.0, $0.1)?.buffsEnemies == true }
            }
            let mergeAtGoal = sharedOK.count < 2
            var spots: [BlockSpot] = []
            if routes.count == 1 {
                // One ground lane this round: hold it in front of the first enemy-buff tile, else a couple of cells
                // before the defence point.
                let cells = routes[0].cells
                let buff = cells.firstIndex { map.tile($0.0, $0.1)?.buffsEnemies == true }
                if let buff, let cell = cells.prefix(buff).last(where: ok) {
                    spots.append(BlockSpot(c: cell.0, r: cell.1, routes: [0], note: "front:" + map.tile(cells[buff].0, cells[buff].1)!.rawValue))
                } else if let m = sharedOK.indices.last.map({ sharedOK[max(0, $0 - 2)] }) {
                    spots.append(BlockSpot(c: m.0, r: m.1, routes: [0], note: "only"))
                }
            } else if routes.count > 1 && n >= routes.count && (buffBefore || mergeAtGoal) {
                var used = Set<String>()
                for k in routes.indices.sorted(by: { routes[$0].weight > routes[$1].weight }) {
                    let cut = min(mergeIndex?[k] ?? routes[k].cells.count,
                                  routes[k].cells.firstIndex { map.tile($0.0, $0.1)?.buffsEnemies == true } ?? routes[k].cells.count)
                    guard let cell = routes[k].cells.prefix(cut).last(where: { ok($0) && !used.contains("\($0.0),\($0.1)") }) else { spots = []; break }
                    used.insert("\(cell.0),\(cell.1)")
                    let t = routes[k].cells.prefix(cut + 1).last.flatMap { map.tile($0.0, $0.1) }
                    spots.append(BlockSpot(c: cell.0, r: cell.1, routes: [k], note: t?.buffsEnemies == true ? "front:" + t!.rawValue : "lane"))
                }
            }
            if spots.isEmpty, let m = sharedOK.indices.last.map({ sharedOK[max(0, $0 - 2)] }) {
                spots.append(BlockSpot(c: m.0, r: m.1, routes: Array(routes.indices), note: "merge"))
            } else if spots.isEmpty {
                // Routes never merge on deployable ground: hold each lane at its last deployable cell.
                for k in routes.indices.sorted(by: { routes[$0].weight > routes[$1].weight }).prefix(n) {
                    if let cell = routes[k].cells.last(where: ok) { spots.append(BlockSpot(c: cell.0, r: cell.1, routes: [k], note: "lane")) }
                }
            }
            // Second line: the next shared cell towards the defence point.
            if let last = spots.last, spots.count < n {
                // Not on 红地板 (it drains the blocker's HP).
                let after = sharedOK.filter { cell in
                    let firstSpot = routes[0].cells.firstIndex { $0 == (last.c, last.r) } ?? -1
                    return (routes[0].cells.firstIndex { $0 == cell } ?? -1) > firstSpot && !spots.contains { $0.c == cell.0 && $0.r == cell.1 }
                        && map.tile(cell.0, cell.1) != .infection
                }
                if let b = after.first { spots.append(BlockSpot(c: b.0, r: b.1, routes: Array(routes.indices), note: "backup")) }
            }
            return spots
        }

        /// Direction of the nearest route cell's upstream neighbour (for cells next to a route).
        func nearestUpstream(_ c: Int, _ r: Int) -> Facing? {
            if let f = facingUpstream(c, r) { return f }
            for d in [(1, 0), (-1, 0), (0, 1), (0, -1)] where onPath(c + d.0, r + d.1) {
                return d == (1, 0) ? .right : d == (-1, 0) ? .left : d == (0, 1) ? .down : .up
            }
            return nil
        }

        /// Facing towards where enemies come from (the cell before this one on the busiest route through it).
        func facingUpstream(_ c: Int, _ r: Int) -> Facing? {
            for k in routes.indices.sorted(by: { routes[$0].weight > routes[$1].weight }) {
                guard let i = index(k, c, r), i > 0 else { continue }
                let p = routes[k].cells[i - 1]
                switch (p.0 - c, p.1 - r) {
                case (1, _): return .right
                case (-1, _): return .left
                case (_, -1): return .up
                case (_, 1): return .down
                default: continue
                }
            }
            return nil
        }

        /// Ally blockers inside a healer's range for one facing.
        func healCoverage(_ o: Operator, _ c: Int, _ r: Int, others: [(Operator, Int, Int)]) -> (Double, Facing) {
            var best = (0.0, Facing.right)
            for f in [Facing.right, .left, .up, .down] {
                let cells = Set(rangeCells(o).map { d -> String in let q = rotate(d, f); return "\(c + q.0),\(r + q.1)" })
                let v = others.reduce(0.0) { acc, x in acc + (cells.contains("\(x.1),\(x.2)") ? (role(x.0) == 0 ? 4 : role(x.0) == 1 ? 2 : 0.5) : 0) }
                if v > best.0 { best = (v, f) }
            }
            return best
        }

        /// Score of `o` standing at (c, r), its facing and the notes for the reason. `others`: where the rest of the team
        /// stands; `held`: the lanes' block points from the operators already placed in this pass (tanks go first).
        func score(_ o: Operator, _ c: Int, _ r: Int, others: [(Operator, Int, Int)], held: [Int?]) -> (Double, Facing, [String]) {
            let b = held
            let tile = map.tile(c, r)
            var notes: [String] = []
            var s: Double
            var facing: Facing
            switch role(o) {
            case 0:
                let (cov, f) = coverage(o, c, r, blocks: b)
                let (bv, bn) = onPath(c, r) ? blockValue(c, r, b: b) : (0, [])
                notes += bn
                s = bv + cov
                facing = f
                if tile == .infection { s -= 5 }
            case 1:
                // Melee damage: right behind / beside the block point, hitting the enemies it holds. In front of a
                // held block point it would become the front line itself.
                let (cov, f) = coverage(o, c, r, blocks: b)
                // A lane no tank holds is theirs to hold (blockValue weighs held lanes down).
                let lead = onPath(c, r) ? blockValue(c, r, b: b).0 * 0.6 : 0
                s = lead + 2 * cov - (exposed(c, r, blocks: b) && b.contains { $0 != nil } ? 1000 : 0)
                facing = f
                if tile == .infection { s += 1 }
            case 2:
                let (cov, f) = coverage(o, c, r, blocks: b)
                s = 3 * cov - (exposed(c, r, blocks: b) ? 1000 : onPath(c, r) ? 1 : 0) - (besideOpenPath(c, r, blocks: b) ? 8 : 0)
                facing = f
                if airCoverage(o, c, r) >= 2 { notes.append("air") }
                if tile == .infection { s += 4 }
                if tile == .hide { s += 1 }
            default:
                let (heal, f) = healCoverage(o, c, r, others: others)
                s = heal - (exposed(c, r, blocks: b) ? 1000 : onPath(c, r) ? 1 : 0)
                facing = f
                if tile == .infection { s -= 3 }
            }
            if tile == .speedup { s += role(o) == 3 ? 1 : 3 }
            if tile == .mire { s -= 5 }
            if let st = profiles[o.name]?.stack, st.kind == "adjacent" || st.kind == "grant" {
                let n = others.filter { abs($0.1 - c) + abs($0.2 - r) == 1 && !Set($0.0.allCovenants).isDisjoint(with: o.allCovenants) }.count
                s += 3 * Double(n)
                if n > 0 { notes.append("stack") }
            }
            if let tile { notes.append("tile:" + tile.rawValue) }
            return (s, facing, notes)
        }

        func reason(_ o: Operator, _ notes: [String], moving: Bool) -> String {
            var parts: [String]
            switch role(o) {
            case 0: parts = ["挡在敌人路线上"]
            case 1: parts = ["近战补伤害、接替挡人"]
            case 2: parts = ["射程罩住敌人被挡住停留的格子"]
            default: parts = ["奶得到挡路的人"]
            }
            if notes.contains("spot:merge") { parts = ["挡人：两路敌人在这里汇合，一个人挡两路"] }
            if notes.contains("spot:lane") { parts = ["挡人：守住一路，两路分开挡"] }
            if notes.contains("spot:backup") { parts = ["第二道防线：前面漏过来的敌人在这里接住"] }
            if notes.contains("spot:only") { parts = ["挡人：这回合只有这一路地面敌人"] }
            if let f = notes.first(where: { $0.hasPrefix("spot:front:") }), let t = MapTile(rawValue: String(f.dropFirst(11))) {
                parts = ["挡人：在\(t.short)前面拦住这一路，敌人踩过\(t.short)会变强"]
            }
            if notes.contains("merge") && !notes.contains(where: { $0.hasPrefix("spot:") }) { parts.append("两路敌人在这里汇合") }
            if notes.contains("stack") { parts.append("贴着同盟约队友叠层") }
            if notes.contains("air") { parts.append("顺带罩住飞行敌人的航线") }
            for n in notes where n.hasPrefix("tile:") {
                guard let t = MapTile(rawValue: String(n.dropFirst(5))) else { continue }
                switch t {
                case .infection: parts.append(role(o) == 2 ? "站红地板：攻击/攻速提升（会掉血）" : "站在红地板上会掉血")
                case .speedup: parts.append("站蓝箭头：攻速提升")
                case .hide: parts.append("隐匿格：敌人远程打不到")
                case .mire: parts.append("沼泽会降攻速")
                }
            }
            return (moving ? "移过去：" : "上场放这里：") + parts.joined(separator: "，")
        }
    }

    /// - Parameter current: where team members stand now (board cells); members without a cell are deploying.
    /// - Parameter enemy: this round's enemy routes (nil: the map's static lanes).
    static func advise(map: GarrisonMap, team: [Operator], current: [String: (Int, Int)], profiles: [String: OperatorProfile],
                       enemy: RoundRoutes? = nil) -> [Placement] {
        let ctx = Context(map: map, profiles: profiles, team: team, enemy: enemy)
        var cells: [(Int, Int)] = []
        for row in 0...3 { for col in -2...9 where map.canDeploy(col, row, melee: false) { cells.append((col, row)) } }
        var pos = current.filter { n, _ in team.contains { $0.name == n } }
        let onBoard = Set(pos.keys)
        var out: [Placement] = []
        var done = Set<String>()
        var held: [Int?] = ctx.routes.map { _ in nil }
        func hold(_ c: Int, _ r: Int) { for k in ctx.routes.indices { if let i = ctx.index(k, c, r), held[k].map({ i < $0 }) ?? true { held[k] = i } } }

        // 1. Block points: tanks first (higher tier first), then other melee by block count.
        let melee = team.filter(ctx.melee).sorted {
            (ctx.role($0), -(profiles[$0.name]?.blockCount ?? 1), -$0.tier) < (ctx.role($1), -(profiles[$1.name]?.blockCount ?? 1), -$1.tier)
        }
        for spot in ctx.blockPlan(melee: melee.count) {
            let free = melee.filter { !done.contains($0.name) }
            guard !free.isEmpty else { break }
            // Someone already standing on an equivalent cell (holds the same lanes, same side of the buff tiles) stays.
            func equivalent(_ here: (Int, Int)) -> Bool {
                if here == (spot.c, spot.r) { return true }
                guard spot.note != "backup", map.tile(here.0, here.1) != .mire else { return false }
                return spot.routes.allSatisfy { k in
                    guard let i = ctx.index(k, here.0, here.1), let j = ctx.index(k, spot.c, spot.r) else { return false }
                    let buff = ctx.routes[k].cells.firstIndex { map.tile($0.0, $0.1)?.buffsEnemies == true } ?? Int.max
                    return (i < buff) == (j < buff) && abs(i - j) <= 1 && (spot.routes.count == 1 || ctx.routes.indices.allSatisfy { ctx.index($0, here.0, here.1) != nil })
                }
            }
            let notes = ["spot:" + spot.note]
            if let o = free.first(where: { pos[$0.name].map(equivalent) ?? false }), let here = pos[o.name] {
                done.insert(o.name); hold(here.0, here.1)
                continue
            }
            let o = free[0]
            // Whoever stands on the spot now moves elsewhere (placed below).
            for (n, p) in pos where p == (spot.c, spot.r) && n != o.name && !done.contains(n) { pos[n] = nil }
            let facing = ctx.facingUpstream(spot.c, spot.r) ?? .right
            out.append(Placement(name: o.name, col: spot.c, row: spot.r, facing: facing, reason: ctx.reason(o, notes, moving: onBoard.contains(o.name))))
            pos[o.name] = (spot.c, spot.r)
            done.insert(o.name); hold(spot.c, spot.r)
        }

        // 2. Everyone else around the block points: melee damage, ranged, healers.
        for o in team.sorted(by: { (ctx.role($0), -$0.tier) < (ctx.role($1), -$1.tier) }) where !done.contains(o.name) {
            done.insert(o.name)
            let others = team.compactMap { t -> (Operator, Int, Int)? in t.name == o.name ? nil : pos[t.name].map { (t, $0.0, $0.1) } }
            let taken = Set(others.map { "\($0.1),\($0.2)" })
            var best: (Double, Int, Int, Facing, [String])?
            for (c, r) in cells where !taken.contains("\(c),\(r)") && map.canDeploy(c, r, melee: ctx.melee(o)) {
                let (sc, f, n) = ctx.score(o, c, r, others: others, held: held)
                if best == nil || sc > best!.0 { best = (sc, c, r, f, n) }
            }
            guard let b = best else { continue }
            if let here = pos[o.name] {
                let (now, _, _) = ctx.score(o, here.0, here.1, others: others, held: held)
                // Only clear improvements: a third better and at least 3 points (or off a 沼泽 tile).
                let offMire = map.tile(here.0, here.1) == .mire && map.tile(b.1, b.2) != .mire
                guard (b.0 > now * 1.33 && b.0 - now >= 3) || (offMire && b.0 > now) else { continue }
                out.append(Placement(name: o.name, col: b.1, row: b.2, facing: b.3, reason: ctx.reason(o, b.4, moving: true)))
            } else {
                out.append(Placement(name: o.name, col: b.1, row: b.2, facing: b.3, reason: ctx.reason(o, b.4, moving: onBoard.contains(o.name))))
            }
            pos[o.name] = (b.1, b.2)
        }
        return out
    }
}
