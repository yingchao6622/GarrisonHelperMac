import AppKit
import SwiftUI

/// Click-through panel over the game window that highlights recommended actions.
@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private let model = OverlayModel()
    /// Hidden with the hide hotkey: nothing is drawn until it is pressed again.
    var suppressed = false

    /// - Parameters: marks and lines in window points (top-left origin of the game window).
    func show(over windowFrame: CGRect, marks: [OverlayMark], lines: [OverlayLine] = []) {
        guard !suppressed, !marks.isEmpty || !lines.isEmpty, let primary = NSScreen.screens.first else { hide(); return }
        let cocoa = CGRect(x: windowFrame.minX, y: primary.frame.height - windowFrame.maxY, width: windowFrame.width, height: windowFrame.height)
        let p = panel ?? makePanel()
        panel = p
        if p.frame != cocoa { p.setFrame(cocoa, display: true) }
        if model.marks != marks { model.marks = marks }
        if model.lines != lines { model.lines = lines }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func hide() {
        model.marks = []
        model.lines = []
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: OverlayView(model: model))
        return p
    }
}

struct OverlayMark: Identifiable, Hashable {
    let id = UUID()
    let kind: GameAction.Kind
    let label: String
    let points: [CGPoint]          // 4 corners (rect or cell quad), window points
    let order: Int

    var color: Color {
        switch kind {
        case .buy: .yellow
        case .upgrade: .green
        case .save: .gray
        case .refresh: .cyan
        case .freeze, .unfreeze: .blue
        case .deploy, .place: .mint
        case .bench: .orange
        case .sell: .red
        case .choose: .pink
        case .equip: .purple
        }
    }
}

/// An enemy route drawn on the board: polylines (a teleport splits a path) with an arrow at the end.
struct OverlayLine: Hashable {
    let segments: [[CGPoint]]
    let fly: Bool
    let boss: Bool
    /// Share of the busiest route's enemies (0…1): line width.
    let weight: Double
    let label: String

    var color: Color { boss ? .purple : fly ? .cyan : .red }
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var marks: [OverlayMark] = []
    @Published var lines: [OverlayLine] = []
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    var body: some View {
        Canvas { ctx, _ in
            // Enemy routes under the action marks.
            for l in model.lines {
                let width = 2 + 3 * min(1, max(0, l.weight))
                for seg in l.segments where seg.count >= 2 {
                    var path = Path()
                    path.move(to: seg[0])
                    for p in seg.dropFirst() { path.addLine(to: p) }
                    ctx.stroke(path, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: width + 2, lineCap: .round, lineJoin: .round))
                    ctx.stroke(path, with: .color(l.color.opacity(0.85)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: l.fly ? [8, 6] : []))
                    // Arrow head at the segment's end.
                    let a = seg[seg.count - 2], b = seg[seg.count - 1]
                    let ang = Double(atan2(b.y - a.y, b.x - a.x)), len = 8 + Double(width) * 1.5
                    var head = Path()
                    head.move(to: b)
                    head.addLine(to: CGPoint(x: b.x - len * cos(ang - 0.45), y: b.y - len * sin(ang - 0.45)))
                    head.addLine(to: CGPoint(x: b.x - len * cos(ang + 0.45), y: b.y - len * sin(ang + 0.45)))
                    head.closeSubpath()
                    ctx.fill(head, with: .color(l.color))
                }
                // Count at the spawn.
                if let start = l.segments.first?.first {
                    let resolved = ctx.resolve(Text(l.label).font(.system(size: 11, weight: .bold)).foregroundColor(.white))
                    let size = resolved.measure(in: CGSize(width: 200, height: 30))
                    let r = CGRect(x: start.x - size.width / 2 - 4, y: start.y - size.height - 6, width: size.width + 8, height: size.height + 2)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(l.color.opacity(0.9)))
                    ctx.draw(resolved, at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
                }
            }
            for m in model.marks where m.points.count == 4 {
                var path = Path()
                path.move(to: m.points[0])
                for p in m.points.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
                ctx.fill(path, with: .color(m.color.opacity(m.kind == .place ? 0.28 : 0.10)))
                ctx.stroke(path, with: .color(m.color), style: StrokeStyle(lineWidth: m.kind == .place ? 2 : 3.5, dash: m.kind == .bench || m.kind == .sell ? [6, 4] : []))
                let top = m.points.min { $0.y < $1.y }!
                let left = m.points.map(\.x).min()!
                let text = Text(m.order > 0 && m.kind == .buy ? "\(m.order). \(m.label)" : m.label)
                    .font(.system(size: 12, weight: .bold)).foregroundColor(.black)
                let resolved = ctx.resolve(text)
                let size = resolved.measure(in: CGSize(width: 400, height: 40))
                let origin = CGPoint(x: left, y: max(0, top.y - size.height - 4))
                ctx.fill(Path(roundedRect: CGRect(origin: origin, size: CGSize(width: size.width + 8, height: size.height + 2)), cornerRadius: 3),
                         with: .color(m.color))
                ctx.draw(resolved, at: CGPoint(x: origin.x + 4, y: origin.y + 1), anchor: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
