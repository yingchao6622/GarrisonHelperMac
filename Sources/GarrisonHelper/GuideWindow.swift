import AppKit
import SwiftUI

// Idea from hongxue-stronghold-companion v1.9.8 「攻略讲解悬浮窗」 (Apache-2.0); written from scratch for the Mac app.

/// Floating guide: the followed route's advice for the current stage and the player's own notes, in a small window
/// that stays above the game. Notes are kept per route and stage.
struct GuideView: View {
    @EnvironmentObject var coach: Coach
    @EnvironmentObject var scanner: Scanner
    @AppStorage("guide.fontSize") private var fontSize = 13.0
    @AppStorage("guide.onTop") private var onTop = true
    @State private var stageID: String?
    @State private var note = ""
    @State private var window: NSWindow?

    private static let notesKey = "guide.notes"
    private func key(_ route: PlannedRoute, _ stage: RouteStage) -> String { "\(route.candidate.title)#\(stage.def.name)" }
    private func loadNote(_ k: String) -> String { (UserDefaults.standard.dictionary(forKey: Self.notesKey) as? [String: String])?[k] ?? "" }
    private func saveNote(_ k: String, _ text: String) {
        var all = (UserDefaults.standard.dictionary(forKey: Self.notesKey) as? [String: String]) ?? [:]
        all[k] = text.isEmpty ? nil : text
        UserDefaults.standard.set(all, forKey: Self.notesKey)
    }

    var body: some View {
        Group {
            if let route = coach.route, !route.stages.isEmpty {
                let current = min(coach.currentStageIndex ?? 0, route.stages.count - 1)
                let stage = route.stages.first { $0.id == stageID } ?? route.stages[current]
                content(route, stage, isCurrent: stage.id == route.stages[current].id)
            } else {
                Text("还没有路线：在小助手里选一条「能玩的路线」").foregroundStyle(.secondary).padding()
            }
        }
        .frame(minWidth: 260, minHeight: 200)
        .background(WindowAccessor { w in
            window = w
            w.level = onTop ? .floating : .normal
            w.collectionBehavior.insert(.fullScreenAuxiliary)
            w.isMovableByWindowBackground = true
        })
        .onChange(of: onTop) { _, v in window?.level = v ? .floating : .normal }
        .onChange(of: coach.hidden) { _, h in if h { window?.orderOut(nil) } else { window?.orderFrontRegardless() } }
    }

    private func content(_ route: PlannedRoute, _ stage: RouteStage, isCurrent: Bool) -> some View {
        let k = key(route, stage)
        let level = scanner.hud.level
        let advice = stage.advice.first { $0.level == level } ?? stage.advice.first
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(route.candidate.title).font(.system(size: fontSize, weight: .bold)).lineLimit(1)
                Spacer()
                Picker("", selection: Binding(get: { stage.id }, set: { stageID = $0 })) {
                    ForEach(route.stages) { s in Text(s.def.name).tag(s.id) }
                }
                .labelsHidden().fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stage.def.rounds + (isCurrent ? " · 当前阶段" : "")).foregroundStyle(.secondary)
                    Text(stage.focus)
                    Text("阵容：" + stage.ops.map { $0.name + ($0.owned ? "✓" : "") }.joined(separator: "、"))
                    if let a = advice {
                        Text("\(a.level)本 · \(a.pace.rawValue)").bold()
                        ForEach(Array(a.buy.enumerated()), id: \.offset) { _, b in Text("· \(b.reason)：\(b.names.joined(separator: "、"))") }
                        Text(a.upgrade)
                        if !a.reserve.isEmpty { Text("留：" + a.reserve.joined(separator: "、")) }
                    }
                    if stage.isFinal || isCurrent { ForEach(route.substitutes, id: \.self) { Text("替补 · " + $0.text) } }
                    if !stage.warnings.isEmpty { Text("⚠️ " + stage.warnings.joined(separator: "；")).foregroundStyle(.orange) }
                }
                .font(.system(size: fontSize))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("我的攻略（按路线和阶段保存）").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $note)
                .font(.system(size: fontSize))
                .frame(minHeight: 60)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: note) { _, v in saveNote(k, v) }
                .onAppear { note = loadNote(k) }
                .onChange(of: k) { _, nk in note = loadNote(nk) }
            HStack {
                Image(systemName: "textformat.size").foregroundStyle(.secondary)
                Slider(value: $fontSize, in: 10...22, step: 1).frame(maxWidth: 120)
                Spacer()
                Toggle("置顶", isOn: $onTop).toggleStyle(.checkbox)
            }
            .font(.caption)
        }
        .padding(10)
    }
}
