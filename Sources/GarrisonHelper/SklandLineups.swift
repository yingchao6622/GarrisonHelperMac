import AppKit
import Foundation
import SwiftUI

// 森空岛阵容攻略导入. Idea and field meanings from StrongholdAssistant (Apache-2.0):
// src/StrongholdAssistant.Host/SklandParser.cs (NormalizeGuideUrl, ParseGuideContent: tabs, tabType 1 = 成型阵容,
// recChars / mergeLevel, recItems, activeBonds, operationIdea). SA reads the page in a hidden browser; the guide's
// `garrison/guide/info` endpoint answers without signing in, so it is read directly here. See REFERENCES.md.

/// A lineup guide from 森空岛, ids already turned into names.
struct SklandLineup: Codable, Identifiable, Hashable {
    struct Op: Codable, Hashable { var name: String; var elite: Bool }
    struct Stage: Codable, Hashable {
        /// 成型阵容 (tabType 1); else a stage for rounds `start`…`end`.
        var final: Bool
        var start: Int
        var end: Int
        var ops: [Op]
        var equipment: [String]
        var covenants: [String]
        var notes: String
        var title: String { final ? "成型阵容" : start == end ? "第 \(start) 回合" : "第 \(start)–\(end) 回合" }
    }
    var id: String
    var title: String
    var author: String
    var strategies: [String]
    var version: String
    var imported: Date
    var stages: [Stage]
    var url: URL { URL(string: "https://game.skland.com/arknights/stronghold-guide/detail?guideId=" + id)! }
    var formation: Stage? { stages.first(where: \.final) ?? stages.last }

    /// The stage for this round: the one whose rounds include it, else the 成型阵容.
    func stage(round: Int?) -> Stage? {
        if let r = round, let s = stages.first(where: { !$0.final && $0.start <= r && r <= $0.end }) { return s }
        return formation
    }
}

extension SklandParse {
    /// The guide id in a 森空岛 link or share text, or a bare id.
    static func guideID(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count >= 6, t.count <= 30, t.allSatisfy({ $0.isASCII && $0.isNumber }) { return t }
        guard let r = t.range(of: #"https://game\.skland\.com/arknights/stronghold-guide/detail\?[^\s]*"#, options: .regularExpression),
              let comps = URLComponents(string: String(t[r])),
              let id = comps.queryItems?.first(where: { $0.name == "guideId" })?.value,
              !id.isEmpty, id.count <= 30, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return id
    }

    /// `garrison/guide/info` → lineup.
    static func lineup(_ json: Any, id: String, now: Date = Date()) throws -> SklandLineup {
        let data = try data(json)
        guard let wrap = data["guide"] as? [String: Any], let g = wrap["guide"] as? [String: Any] else {
            throw SklandError.message("森空岛攻略的格式有变化，暂时读不了。")
        }
        if int(wrap["invalid"]) != 0 { throw SklandError.message("这篇攻略不存在或已失效。") }
        let season = g["seasonId"] as? String ?? "", version = g["versionId"] as? String ?? ""
        let res = (((data["seasonResourceMap"] as? [String: Any])?[season] as? [String: Any])?["versionResourceMap"] as? [String: Any])?[version]
            as? [String: Any] ?? [:]
        func name(_ table: String, _ key: String) -> String {
            ((res[table] as? [String: Any])?[key] as? [String: Any])?["name"] as? String ?? key
        }
        func bond(_ key: String) -> String {
            if let n = ((res["bonds"] as? [String: Any])?[key] as? [String: Any])?["name"] as? String { return n }
            return key.hasSuffix("Ship") ? String(key.dropLast(4)) : key
        }
        let stages = (g["tabs"] as? [[String: Any]] ?? []).map { t -> SklandLineup.Stage in
            let bonds = t["activeBonds"] as? [String: Any] ?? [:]
            let ids = (bonds["seasonBondIds"] as? [String] ?? []) + (bonds["regularBondIds"] as? [String] ?? [])
            return SklandLineup.Stage(
                final: int(t["tabType"]) == 1, start: int(t["startRound"]) ?? 0, end: int(t["endRound"]) ?? 0,
                ops: (t["recChars"] as? [[String: Any]] ?? []).compactMap { c in
                    (c["charId"] as? String).map { SklandLineup.Op(name: name("chars", $0), elite: int(c["mergeLevel"]) == 1) }
                },
                equipment: (t["recItems"] as? [[String: Any]] ?? []).compactMap { ($0["itemId"] as? String).map { name("items", $0) } },
                covenants: ids.map(bond),
                notes: (t["operationIdea"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !stages.isEmpty else { throw SklandError.message("这篇攻略里没有阵容。") }
        let author = ((wrap["poster"] as? [String: Any])?["nickname"] as? String) ?? ""
        return SklandLineup(id: id, title: (g["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "森空岛攻略 \(id)",
                            author: author, strategies: (g["strategyIds"] as? [String] ?? []).map { name("strategies", $0) },
                            version: version, imported: now,
                            stages: stages.sorted { ($0.final ? 1 : 0, $0.start) < ($1.final ? 1 : 0, $1.start) })
    }
}

extension SklandClient {
    /// A public lineup guide (no sign-in needed).
    func guide(id: String) async throws -> SklandLineup {
        try SklandParse.lineup(try await fetch("/web/v1/game/garrison/guide/info", query: "guideId=" + id), id: id)
    }
}

/// Imported lineups, kept in UserDefaults.
@MainActor
final class SklandLineupLibrary: ObservableObject {
    static let shared = SklandLineupLibrary()
    static let key = "lineups.skland"
    @Published private(set) var lineups: [SklandLineup] = []
    @Published var selectedID: String? { didSet { UserDefaults.standard.set(selectedID, forKey: Self.key + ".selected") } }
    @Published private(set) var busy = false
    @Published var message: String?

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let l = try? JSONDecoder().decode([SklandLineup].self, from: d) { lineups = l }
        selectedID = UserDefaults.standard.string(forKey: Self.key + ".selected")
        if selectedID != nil, !lineups.contains(where: { $0.id == selectedID }) { selectedID = nil }
    }

    var selected: SklandLineup? { lineups.first { $0.id == selectedID } }

    private func save() {
        if let d = try? JSONEncoder().encode(lineups) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    func importGuide(_ text: String) async {
        guard let id = SklandParse.guideID(text) else {
            message = "没认出森空岛攻略链接：在森空岛的阵容攻略页点分享，复制链接贴进来。"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let l = try await SklandClient().guide(id: id)
            lineups.removeAll { $0.id == id }
            lineups.insert(l, at: 0)
            save()
            selectedID = id
            message = "已导入「\(l.title)」"
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "导入失败，请稍后再试。"
        }
    }

    func remove(_ id: String) {
        lineups.removeAll { $0.id == id }
        if selectedID == id { selectedID = lineups.first?.id }
        save()
    }

    /// The operators 「照这套打」 sets as 必带: the 成型阵容 minus operators the planner can't take (自选 not picked,
    /// only obtainable some other way, not in the catalog), at most `people` of them (the planner finds no route with
    /// more 必带 than places; non-elite operators are left out first).
    static func lockable(_ l: SklandLineup, catalog: Catalog, selfSelected: Set<String>, people: Int)
        -> (lock: [String], skipped: [String], over: [String]) {
        let byName = Dictionary(catalog.operators.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var ok: [SklandLineup.Op] = [], skipped: [String] = []
        for op in l.formation?.ops ?? [] where !ok.contains(where: { $0.name == op.name }) && !skipped.contains(op.name) {
            if let o = byName[op.name], o.obtain == nil, !o.isSelfSelected || selfSelected.contains(o.name) { ok.append(op) } else { skipped.append(op.name) }
        }
        let cap = max(1, min(people, 9))
        guard ok.count > cap else { return (ok.map(\.name), skipped, []) }
        let order = ok.enumerated().sorted { ($0.element.elite ? 0 : 1, $0.offset) < ($1.element.elite ? 0 : 1, $1.offset) }.map(\.element)
        let keep = Set(order.prefix(cap).map(\.name))
        return (ok.map(\.name).filter(keep.contains), skipped, ok.map(\.name).filter { !keep.contains($0) })
    }
}

// MARK: - Views

/// One stage of a lineup: operators (★ elite, ✓ held), equipment, covenants, the author's notes.
struct LineupStageView: View {
    let label: String
    let stage: SklandLineup.Stage
    let owned: Set<String>
    var showNotes = true
    @State private var notesOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            opsLine
            if !stage.equipment.isEmpty { Text("装备：" + stage.equipment.joined(separator: "、")).font(.caption2).fixedSize(horizontal: false, vertical: true) }
            if !stage.covenants.isEmpty { Text("盟约：" + stage.covenants.joined(separator: "、")).font(.caption2) }
            if showNotes, !stage.notes.isEmpty {
                DisclosureGroup(isExpanded: $notesOpen) {
                    Text(stage.notes).font(.caption2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("作者思路").font(.caption2) }
            }
        }
    }

    private var opsLine: some View {
        var t = Text(label + "：").bold()
        for (k, o) in stage.ops.enumerated() {
            if k > 0 { t = t + Text("、") }
            let have = owned.contains(o.name)
            t = t + Text(o.name + (o.elite ? "★" : "") + (have ? "✓" : "")).foregroundColor(have ? .green : .primary)
        }
        return t.font(.caption2).fixedSize(horizontal: false, vertical: true)
    }
}

private func lineupMeta(_ l: SklandLineup) -> String {
    [l.author.isEmpty ? nil : "作者 " + l.author, l.strategies.isEmpty ? nil : "策略 " + l.strategies.joined(separator: "、"), l.version]
        .compactMap { $0 }.joined(separator: " · ")
}

/// 顶栏「阵容」: import 森空岛 lineup guides and manage them.
struct LineupLibraryView: View {
    @EnvironmentObject var run: RunState
    @ObservedObject private var lib = SklandLineupLibrary.shared
    @State private var link = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "从森空岛导入阵容", trailing: lib.busy ? AnyView(ProgressView().controlSize(.small)) : nil)
                HStack {
                    TextField("贴上森空岛阵容攻略的分享链接", text: $link)
                        .textFieldStyle(.roundedBorder).font(.caption)
                        .onSubmit(load)
                    Button("导入", action: load).disabled(lib.busy || link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(lib.message ?? "在森空岛的「卫戍协议 · 阵容攻略」里点分享，复制链接贴进来。攻略内容是公开的，不用登录。")
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
                SectionHeader(title: "我的阵容（\(lib.lineups.count)）")
                if lib.lineups.isEmpty {
                    Text("还没有导入的阵容。导入后可以在「本局」页选一套来打。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(lib.lineups) { l in card(l) }
            }
            .padding(12)
        }
    }

    private func load() {
        let text = link
        Task {
            await lib.importGuide(text)
            if lib.message?.hasPrefix("已导入") == true { link = "" }
        }
    }

    private func card(_ l: SklandLineup) -> some View {
        let owned = Set(run.owned)
        let current = lib.selectedID == l.id
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(l.title).font(.caption.weight(.semibold)).lineLimit(2)
                if current { Text("本局在用").font(.caption2).foregroundStyle(.teal) }
                Spacer()
            }
            Text(lineupMeta(l)).font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(l.stages.enumerated()), id: \.offset) { _, s in LineupStageView(label: s.title, stage: s, owned: owned) }
            HStack(spacing: 10) {
                Button(current ? "本局不用" : "本局用这套") { lib.selectedID = current ? nil : l.id }
                Button("打开原文") { NSWorkspace.shared.open(l.url) }
                Button("重新读取") { Task { await lib.importGuide(l.id) } }.disabled(lib.busy)
                Button("删除", role: .destructive) { lib.remove(l.id) }
                Spacer()
            }
            .font(.caption).buttonStyle(.link)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// 本局 → 阵容: pick an imported lineup, see its stage for this round, play it (必带). Importing is on the 阵容 tab.
struct SklandLineupCard: View {
    @EnvironmentObject var run: RunState
    @EnvironmentObject var scanner: Scanner
    @EnvironmentObject var catalog: Catalog
    @ObservedObject private var lib = SklandLineupLibrary.shared
    @AppStorage("tab") private var tab: Tab = .run

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "阵容", trailing: AnyView(HStack(spacing: 6) {
                if lib.lineups.isEmpty {
                    Button("去「阵容」页导入") { tab = .lineups }.buttonStyle(.link)
                } else {
                    Picker("", selection: $lib.selectedID) {
                        Text("不用").tag(String?.none)
                        ForEach(lib.lineups) { l in Text(l.title).tag(Optional(l.id)) }
                    }
                    .labelsHidden().fixedSize().frame(maxWidth: 220)
                }
            }.font(.caption)))
            if let l = lib.selected { detail(l) }
        }
    }

    private func detail(_ l: SklandLineup) -> some View {
        let owned = Set(run.owned)
        let round = scanner.hud.round
        let stage = l.stage(round: round)
        let plan = SklandLineupLibrary.lockable(l, catalog: catalog, selfSelected: Set(run.selfSelected), people: run.deployCap)
        let following = !plan.lock.isEmpty && Set(run.locked) == Set(plan.lock)
        return VStack(alignment: .leading, spacing: 5) {
            Text(lineupMeta(l)).font(.caption2).foregroundStyle(.secondary)
            if let s = stage {
                if !s.final, let f = l.formation { LineupStageView(label: "成型", stage: f, owned: owned, showNotes: false) }
                LineupStageView(label: s.final ? "成型" : s.title + (round != nil ? "（本回合）" : ""), stage: s, owned: owned)
            }
            HStack(spacing: 10) {
                Button(following ? "取消必带" : "照这套打（成型阵容设为必带）") { run.locked = following ? [] : plan.lock }
                    .help("把成型阵容的干员设为必带，路线会围绕它们规划")
                Button("打开原文") { NSWorkspace.shared.open(l.url) }
                Spacer()
            }
            .font(.caption).buttonStyle(.link)
            if !plan.over.isEmpty {
                Text("超出上场 \(run.deployCap) 人，没设为必带：" + plan.over.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary)
            }
            if !plan.skipped.isEmpty {
                Text("没设为必带：" + plan.skipped.joined(separator: "、") + "（自选干员要先在「本局设定」里选上；其他是规划器用不了的）")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
