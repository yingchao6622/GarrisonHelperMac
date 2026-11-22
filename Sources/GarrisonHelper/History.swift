// Portions adapted from StrongholdAssistant (Apache-2.0) and rewritten in Swift for this Mac app; the upstream files are listed
// in REFERENCES.md and their licenses / NOTICEs are in licenses/.
import SwiftUI

// Match history and stats (StrongholdAssistant keeps a 对局记录 with per-match lineups and a stats page). A match is
// archived when the helper sees a new one start (round back to 1) or the player presses 「开始新的一局」; matches that
// never reached round 3 are skipped. Stored in UserDefaults (no files); self-tests never write it.

struct MatchRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var started: Date
    var ended: Date
    var mode: String?
    var strategy: String?
    var map: String?
    var boss: String?
    /// Highest round seen.
    var rounds: Int
    var level: Int?
    var lineup: [String]
    /// Active covenants on the bar at the last reading (「坚守Ⅱ」).
    var covenants: [String]
    var route: String?
    /// 名次 the player entered (1–8).
    var rank: Int?
}

@MainActor
final class MatchHistory: ObservableObject {
    static let key = "history.matches"
    static let limit = 300
    @Published private(set) var records: [MatchRecord] = []
    /// Self-tests turn this off so replays never add matches.
    var enabled = true

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let r = try? JSONDecoder().decode([MatchRecord].self, from: data) { records = r }
    }

    func add(_ r: MatchRecord) {
        guard enabled, r.rounds >= 3 else { return }
        records.insert(r, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        save()
    }

    func setRank(_ id: UUID, _ rank: Int?) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].rank = rank
        save()
    }

    func delete(_ id: UUID) { records.removeAll { $0.id == id }; save() }

    private func save() {
        guard enabled, let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    struct Stats {
        var matches = 0
        var averageRounds = 0.0
        var ranked = 0
        var averageRank: Double?
        var top4: Double?
        /// Covenant (without Ⅰ/Ⅱ) → matches, average rank of those matches.
        var covenants: [(name: String, count: Int, rank: Double?)] = []
        var strategies: [(name: String, count: Int, rank: Double?)] = []
    }

    var stats: Stats {
        var s = Stats()
        s.matches = records.count
        guard !records.isEmpty else { return s }
        s.averageRounds = Double(records.map(\.rounds).reduce(0, +)) / Double(records.count)
        let ranks = records.compactMap(\.rank)
        s.ranked = ranks.count
        if !ranks.isEmpty {
            s.averageRank = Double(ranks.reduce(0, +)) / Double(ranks.count)
            s.top4 = Double(ranks.filter { $0 <= 4 }.count) / Double(ranks.count)
        }
        func group(_ key: (MatchRecord) -> [String]) -> [(name: String, count: Int, rank: Double?)] {
            var by: [String: [MatchRecord]] = [:]
            for r in records { for k in Set(key(r)) { by[k, default: []].append(r) } }
            return by.map { k, rs in
                let rk = rs.compactMap(\.rank)
                return (k, rs.count, rk.isEmpty ? nil : Double(rk.reduce(0, +)) / Double(rk.count))
            }.sorted { ($0.count, -($0.rank ?? 9)) > ($1.count, -($1.rank ?? 9)) }
        }
        s.covenants = group { $0.covenants.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "ⅠⅡ")) } }
        s.strategies = group { $0.strategy.map { [$0] } ?? [] }
        return s
    }
}

struct HistoryView: View {
    @EnvironmentObject var history: MatchHistory

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let s = history.stats
                SectionHeader(title: "统计")
                if s.matches == 0 {
                    Text("还没有对局记录。开着「实时」打完一局（打到第 3 回合以上），新的一局开始或点「开始新的一局」时会自动记下。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 16) {
                        stat("对局", "\(s.matches)")
                        stat("平均回合", String(format: "%.1f", s.averageRounds))
                        stat("平均名次", s.averageRank.map { String(format: "%.1f", $0) } ?? "-")
                        stat("前四率", s.top4.map { String(format: "%.0f%%", $0 * 100) } ?? "-")
                    }
                    if s.ranked < s.matches {
                        Text("名次要自己填（下面每局右边的菜单），填了才算平均名次和前四率。").font(.caption2).foregroundStyle(.secondary)
                    }
                    table("盟约", s.covenants.prefix(10))
                    table("策略", s.strategies.prefix(6))
                }
                Divider()
                SectionHeader(title: "对局记录")
                ForEach(history.records) { r in row(r) }
            }
            .padding(12)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func table(_ title: String, _ rows: ArraySlice<(name: String, count: Int, rank: Double?)>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(Array(rows), id: \.name) { r in
                HStack {
                    Text(r.name).font(.caption)
                    Spacer()
                    Text("\(r.count) 局").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    Text(r.rank.map { String(format: "平均第 %.1f", $0) } ?? "").font(.caption2).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                }
            }
        }
    }

    private func summary(_ r: MatchRecord) -> String {
        var parts = ["打到第 \(r.rounds) 回合"]
        if let l = r.level { parts.append("等级 \(l)") }
        if let x = r.route { parts.append("路线 \(x)") }
        if let b = r.boss { parts.append("领袖 \(b)") }
        return parts.joined(separator: " · ")
    }

    private func row(_ r: MatchRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(r.started.formatted(date: .abbreviated, time: .shortened)).font(.caption.weight(.semibold))
                Text([r.mode, r.strategy].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu(r.rank.map { "第 \($0) 名" } ?? "名次") {
                    ForEach(1...8, id: \.self) { k in Button("第 \(k) 名") { history.setRank(r.id, k) } }
                    Button("清除") { history.setRank(r.id, nil) }
                    Divider()
                    Button("删除这条记录", role: .destructive) { history.delete(r.id) }
                }
                .fixedSize().font(.caption)
            }
            Text(summary(r)).font(.caption2).foregroundStyle(.secondary)
            if !r.covenants.isEmpty { Text("盟约：" + r.covenants.joined(separator: "、")).font(.caption2) }
            if !r.lineup.isEmpty { Text("阵容：" + r.lineup.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
