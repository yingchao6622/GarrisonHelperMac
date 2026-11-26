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
    func show(over windowFrame: CGRect, marks: [OverlayMark], lines: [OverlayLine] = [], questions: [OverlayQuestion] = []) {
        updateQuestions(over: windowFrame, suppressed ? [] : questions)
        guard !suppressed, !marks.isEmpty || !lines.isEmpty, let primary = NSScreen.screens.first else { hideMarks(); return }
        let cocoa = CGRect(x: windowFrame.minX, y: primary.frame.height - windowFrame.maxY, width: windowFrame.width, height: windowFrame.height)
        let p = panel ?? makePanel()
        panel = p
        if p.frame != cocoa { p.setFrame(cocoa, display: true) }
        if model.marks != marks { model.marks = marks }
        if model.lines != lines { model.lines = lines }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func hide() {
        hideMarks()
        updateQuestions(over: .zero, [])
    }

    private func hideMarks() {
        model.marks = []
        model.lines = []
        panel?.orderOut(nil)
    }

    // MARK: Clickable 「?」

    /// A pick from a 「?」 menu: unit id, chosen name.
    var onPick: ((UUID, String) -> Void)?
    private var questionPanels: [NSPanel] = []
    private var questions: [OverlayQuestion] = []
    private var questionsFrame: CGRect = .zero
    static let questionSize: CGFloat = 24

    /// One small clickable panel per unsure unit (the big overlay stays click-through, so the game keeps every other
    /// click). Clicking opens a menu with the candidates.
    func updateQuestions(over windowFrame: CGRect, _ qs: [OverlayQuestion]) {
        guard qs != questions || windowFrame != questionsFrame else { return }
        questions = qs
        questionsFrame = windowFrame
        guard let primary = NSScreen.screens.first else { return }
        while questionPanels.count < qs.count { questionPanels.append(makeQuestionPanel()) }
        for (i, p) in questionPanels.enumerated() {
            guard i < qs.count else { p.orderOut(nil); continue }
            let q = qs[i], d = Self.questionSize
            let x = windowFrame.minX + q.point.x - d / 2, yTop = windowFrame.minY + q.point.y - d / 2
            p.setFrame(CGRect(x: x, y: primary.frame.height - yTop - d, width: d, height: d), display: false)
            (p.contentView as? QuestionButton)?.question = q
            if !p.isVisible { p.orderFrontRegardless() }
        }
    }

    private func makeQuestionPanel() -> NSPanel {
        let d = Self.questionSize
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: d, height: d), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.becomesKeyOnlyIfNeeded = true
        let b = QuestionButton(frame: CGRect(x: 0, y: 0, width: d, height: d))
        b.onPick = { [weak self] id, name in self?.onPick?(id, name) }
        p.contentView = b
        return p
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
    /// Draw the outline / fill (off: only the label, for 站位 with the cell switched off).
    var shape = true

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
                if m.shape {
                    var path = Path()
                    path.move(to: m.points[0])
                    for p in m.points.dropFirst() { path.addLine(to: p) }
                    path.closeSubpath()
                    ctx.fill(path, with: .color(m.color.opacity(m.kind == .place ? 0.28 : 0.10)))
                    ctx.stroke(path, with: .color(m.color), style: StrokeStyle(lineWidth: m.kind == .place ? 2 : 3.5, dash: m.kind == .bench || m.kind == .sell ? [6, 4] : []))
                }
                guard !m.label.isEmpty else { continue }
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

/// A unit the recognition isn't sure about: where its 「?」 goes (window points) and the candidates to pick from.
struct OverlayQuestion: Hashable {
    let id: UUID
    let point: CGPoint
    /// Menu titles (name and confidence) and the names they pick.
    let options: [String]
    let names: [String]
}

/// The round 「?」 button in its own small panel; a click opens the candidate menu.
final class QuestionButton: NSView {
    var question: OverlayQuestion?
    var onPick: ((UUID, String) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let ring = NSBezierPath(ovalIn: r)
        ring.lineWidth = 1.5
        ring.stroke()
        let text = NSAttributedString(string: "?", attributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.black])
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let q = question else { return }
        let menu = NSMenu()
        let title = NSMenuItem(title: "这是谁？", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for (k, option) in q.options.enumerated() where k < q.names.count {
            let item = NSMenuItem(title: option, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = q.names[k]
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "都不是：在小助手的识别面板里改", action: nil, keyEquivalent: "")
        other.isEnabled = false
        menu.addItem(other)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: bounds.maxY + 2), in: self)
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard let q = question, let name = item.representedObject as? String else { return }
        onPick?(q.id, name)
    }
}
