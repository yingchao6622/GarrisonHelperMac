// Portions adapted from StrongholdAssistant (Apache-2.0) and rewritten in Swift for this Mac app; the upstream files are listed
// in REFERENCES.md and their licenses / NOTICEs are in licenses/.
import SwiftUI

/// Small board in the side window: terrain, this round's enemy routes, the units on the field and the suggested cells
/// (StrongholdAssistant shows the same mini map with routes next to its placement advice). Useful when the in-game
/// overlay is off or the helper sits beside the game.
struct MiniBoard: View {
    let map: GarrisonMap
    let routes: RoundRoutes?
    /// Units standing on the board: (name, col, row, low confidence).
    let units: [(name: String, col: Int, row: Int, unsure: Bool)]
    /// Suggested cells: (name, col, row, facing arrow).
    let suggestions: [(name: String, col: Int, row: Int, facing: String)]
    /// Click on a deployable cell (补录 / correct the unit there).
    var onTap: ((Int, Int) -> Void)? = nil

    /// Columns that hold anything (deployable ground, spawn, defence point).
    private var cols: ClosedRange<Int> {
        var used: [Int] = []
        for r in 0..<map.cells.count { for c in GarrisonMap.firstColumn...9 where map.type(c, r) != "X" { used.append(c) } }
        return (used.min() ?? -2)...(used.max() ?? 9)
    }
    private var rows: Int { (0..<map.cells.count).last { r in cols.contains { map.type($0, r) != "X" } }.map { $0 + 1 } ?? 4 }

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
            .frame(height: min(30, 340 / Double(cols.count)) * Double(rows))
            .clipped()
            .overlay {
                if let onTap {
                    GeometryReader { g in
                        Color.clear.contentShape(Rectangle()).onTapGesture { p in
                            let side = min(g.size.width / Double(cols.count), g.size.height / Double(rows))
                            let ox = (g.size.width - side * Double(cols.count)) / 2
                            let c = Int(((p.x - ox) / side).rounded(.down)) + cols.lowerBound, r = Int((p.y / side).rounded(.down))
                            if cols.contains(c), (0..<rows).contains(r), "GTH".contains(map.type(c, r)) { onTap(c, r) }
                        }
                    }
                }
            }
            .accessibilityLabel("战场小地图")
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let cols = cols, rows = rows
        let side = min(size.width / Double(cols.count), size.height / Double(rows))
        let ox = (size.width - side * Double(cols.count)) / 2
        func pt(_ c: Double, _ r: Double) -> CGPoint { CGPoint(x: ox + (c - Double(cols.lowerBound)) * side, y: r * side) }
        // Cells.
        for r in 0..<rows {
            for c in cols {
                let rect = CGRect(origin: pt(Double(c), Double(r)), size: CGSize(width: side, height: side)).insetBy(dx: 1, dy: 1)
                let t = map.type(c, r)
                let fill: Color = switch t {
                case "G", "T": Color(white: 0.55).opacity(0.35)
                case "H": Color.indigo.opacity(0.35)
                case "S": Color.red.opacity(0.55)
                case "D": Color.blue.opacity(0.6)
                default: Color.clear
                }
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(fill))
                if let tile = map.tile(c, r) {
                    let tint: Color = switch tile {
                    case .infection: .red
                    case .speedup: .cyan
                    case .airflowDown: .yellow
                    case .mire: .brown
                    case .hide: .purple
                    }
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 2), with: .color(tint.opacity(0.9)), lineWidth: 2)
                    if tile == .airflowDown {
                        // Which way the air blows.
                        ctx.draw(Text("↓").font(.system(size: side * 0.42, weight: .bold)).foregroundColor(tint.opacity(0.8)),
                                 at: CGPoint(x: rect.midX, y: rect.midY))
                    }
                }
            }
        }
        // Routes (nudged apart where they overlap).
        if let rr = routes {
            let top = Double(rr.routes.map(\.count).max() ?? 1)
            for (k, r) in rr.routes.sorted(by: { ($0.fly ? 1 : 0, -$0.count) < ($1.fly ? 1 : 0, -$1.count) }).enumerated() {
                let nudge = (Double(k % 4) - 1.5) * 0.06
                let color: Color = r.boss ? .purple : r.fly ? .cyan : .red
                for seg in r.segments where seg.count >= 2 {
                    var path = Path()
                    path.move(to: pt(seg[0].x + nudge, seg[0].y + nudge))
                    for p in seg.dropFirst() { path.addLine(to: pt(p.x + nudge, p.y + nudge)) }
                    ctx.stroke(path, with: .color(color.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1 + 2.5 * Double(r.count) / top, lineCap: .round, lineJoin: .round, dash: r.fly ? [4, 3] : []))
                }
            }
        }
        // Units on the field.
        for u in units {
            let rect = CGRect(origin: pt(Double(u.col), Double(u.row)), size: CGSize(width: side, height: side)).insetBy(dx: side * 0.14, dy: side * 0.14)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color.orange.opacity(0.9)))
            let label = Text(String(u.name.prefix(1)) + (u.unsure ? "?" : "")).font(.system(size: side * 0.36, weight: .bold)).foregroundColor(.black)
            ctx.draw(label, at: CGPoint(x: rect.midX, y: rect.midY))
        }
        // Suggested cells.
        for s in suggestions {
            let rect = CGRect(origin: pt(Double(s.col), Double(s.row)), size: CGSize(width: side, height: side)).insetBy(dx: 1, dy: 1)
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(.mint), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            let label = Text(String(s.name.prefix(1)) + s.facing).font(.system(size: side * 0.3, weight: .bold)).foregroundColor(.mint)
            ctx.draw(label, at: CGPoint(x: rect.midX, y: rect.maxY - side * 0.2))
        }
    }
}
