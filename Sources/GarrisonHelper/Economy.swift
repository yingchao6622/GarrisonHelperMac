// Portions adapted from StrongholdAssistant (Apache-2.0) and rewritten in Swift for this Mac app; the upstream files are listed
// in REFERENCES.md and their licenses / NOTICEs are in licenses/.
import Foundation

// Round economy and the next-round forecast.
// Rules measured on the user's debug matches (2026-11-21/22, 7 matches): unspent funds do NOT carry over (a round that
// ended with 5 left started the next with 12 = 11 base + 1 bounty); each round pays data/round_income.json (4, 5, 6 …
// 11) plus extras (bounty rewards, income equipment); the upgrade price drops by 1 for every round spent at a level
// (2→3: 8, 7, 6, 5, 4, 3). Strategy rules after StrongholdAssistant Host/HostApi.Economy.cs (EconomyRule / Predict):
// 利滚利 carries funds (+1 when 5 or more are left), 得闲饮茶 pays rounds 1–2 in round 3, some strategies add random funds.

struct EconomyForecast: Equatable {
    /// Funds expected at the start of next round (nil when the strategy makes it unknowable).
    var nextMoney: Int?
    /// This round's funds above the base income (bounties, income equipment) — assumed to repeat next round.
    var extra: Int
    /// Leftover funds carry over (利滚利).
    var carries: Bool
    /// Upgrade price next round (one lower if not upgraded now).
    var nextUpgradeCost: Int?
    /// Rounds until the upgrade is affordable without spending anything else (0 = now).
    var roundsToUpgrade: Int?
    /// Strategy note (随机资金 …).
    var note: String?
}

enum Economy {
    /// Strategies whose funds don't follow the base table (StrongholdAssistant EconomyRule).
    static func rule(_ strategy: String?) -> String? {
        switch strategy {
        case "band_cannot": "carry"
        case "band_lmlee": "deferred"
        case "band_mlynar": "kazimier"
        case "band_fund", "band_protect", "band_treasure", "band_ducklord", "band_siracusa": "random"
        default: nil
        }
    }

    static func base(_ round: Int, table: [(round: Int, income: Int)]) -> Int? {
        table.first { $0.round == round }?.income ?? (round > (table.last?.round ?? 0) ? table.last?.income : nil)
    }

    /// - Parameters:
    ///   - startMoney: funds read at the start of this round's rest (before buying); nil when not seen.
    ///   - money: funds now.
    static func forecast(round: Int?, money: Int?, startMoney: Int?, level: Int?, upgradeCost: Int?, strategy: String?,
                         table: [(round: Int, income: Int)]) -> EconomyForecast? {
        guard let round else { return nil }
        let rule = rule(strategy)
        let carries = rule == "carry"
        let extra = startMoney.flatMap { s in base(round, table: table).map { max(0, s - $0 - (carries ? 0 : 0)) } } ?? 0
        var next = base(round + 1, table: table).map { $0 + extra }
        if rule == "deferred" {
            if round == 1 { next = nil }
            if round == 2 { next = [1, 2, 3].compactMap { base($0, table: table) }.reduce(0, +) }
        }
        if carries, let m = money, next != nil { next! += m + (m >= 5 ? 1 : 0) }
        let maxed = (level ?? 0) >= 6
        let nextCost = maxed ? nil : upgradeCost.map { max(0, $0 - 1) }
        // Rounds until affordable: funds of that round (no carry: its own income; carry: accumulated) vs the price then.
        var wait: Int?
        if !maxed, let cost = upgradeCost, let m = money {
            if m >= cost { wait = 0 } else {
                var acc = carries ? m : 0
                for k in 1...6 {
                    guard let b = base(round + k, table: table) else { break }
                    acc = (carries ? acc + (acc >= 5 ? 1 : 0) : 0) + b + extra
                    if acc >= max(0, cost - k) { wait = k; break }
                }
            }
        }
        let note: String? = switch rule {
        case "random": "本局策略有随机资金，下回合可能更多"
        case "deferred": round < 3 ? "得闲饮茶：前两回合的钱第 3 回合一起发" : nil
        case "kazimier": "业务指标：每买 1 名卡西米尔下回合 +1（至多 3）"
        default: nil
        }
        return EconomyForecast(nextMoney: next, extra: extra, carries: carries, nextUpgradeCost: nextCost, roundsToUpgrade: wait, note: note)
    }
}

/// First funds seen in each round's rest phase (the start of the round, before buying): the max of the first two reads
/// of a new round on our own board (StrongholdAssistant waits for a repeated read too).
struct RoundStartTracker {
    private(set) var round: Int?
    private(set) var startMoney: Int?
    private var reads = 0

    mutating func observe(round r: Int?, money: Int?, ownRest: Bool) {
        guard ownRest, let r, let money else { return }
        if r != round { round = r; startMoney = money; reads = 1; return }
        if reads < 2 { startMoney = max(startMoney ?? money, money); reads += 1 }
    }

    mutating func reset() { round = nil; startMoney = nil; reads = 0 }
}
