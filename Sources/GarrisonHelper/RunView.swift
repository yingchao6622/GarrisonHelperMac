import SwiftUI

/// 本局：本局设定（模式 / 策略 / 禁用 / 敌人 / 自选）→ 当前阵容（场上认人）→ 能玩的路线 → AI 教练。
struct RunView: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var run: RunState
    @EnvironmentObject var scanner: Scanner
    @EnvironmentObject var coach: Coach
    @AppStorage("ui.setupOpen") private var setupOpen = true
    @State private var addingOwned = false
    @Environment(\.openWindow) private var openWindow
    @State private var boardCell: BoardCell?
    @State private var pickingSelf = false
    @State private var pickingWatch = false
    /// The route list shows the first 16; the rest behind 「显示全部」.
    @State private var showAllRoutes = false
    static let routesShown = 16

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                topBar
                MusicMiniBar()
                actionsCard
                Divider()
                DisclosureGroup(isExpanded: $setupOpen) { setup.padding(.top, 6) } label: { setupLabel }
                Divider()
                lineupCard
                Divider()
                routesCard
                Divider()
                aiCard
                Button(role: .destructive) { coach.archiveMatch(); run.newRun(); coach.resetRun(); coach.schedulePlan() } label: {
                    Label("开始新的一局（清空禁用、敌人和阵容，保留模式与策略）", systemImage: "arrow.counterclockwise")
                }
                .font(.caption)
            }
            .padding(12)
        }
        .task {
            if scanner.windows.isEmpty { await scanner.refreshWindows() }
            if coach.candidates.isEmpty { await coach.plan() }
        }
        .onChange(of: run.bannedCovenants) { _, _ in coach.schedulePlan() }
        .onChange(of: run.owned) { _, _ in coach.schedulePlan() }
        .onChange(of: run.locked) { _, _ in coach.schedulePlan() }
        .onChange(of: run.mode) { _, _ in coach.applyMode(); coach.schedulePlan() }
        .onChange(of: run.strategyID) { _, _ in coach.schedulePlan() }
        .onChange(of: run.mechElite) { _, _ in coach.schedulePlan() }
        .onChange(of: run.bossName) { _, _ in coach.schedulePlan() }
        .onChange(of: run.specialEnemies) { _, _ in coach.schedulePlan() }
        .onChange(of: run.selfSelected) { _, _ in coach.schedulePlan() }
        .onChange(of: scanner.hud.level) { _, _ in coach.schedulePlan() }
        .onChange(of: run.deployCap) { _, _ in coach.schedulePlan() }
    }

    // MARK: Top

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $scanner.selectedWindowID) {
                    Text("选择游戏窗口").tag(CGWindowID?.none)
                    ForEach(scanner.windows) { w in Text(w.label).tag(CGWindowID?.some(w.id)) }
                }
                .labelsHidden()
                Button { Task { await scanner.refreshWindows() } } label: { Image(systemName: "arrow.clockwise") }.help("刷新窗口列表")
                Toggle("实时", isOn: $scanner.live).toggleStyle(.switch).controlSize(.small)
                    .help("持续读取回合、资金、终端等级、顶栏盟约，并记录商店购买")
            }
            HStack(spacing: 14) {
                stat("回合", scanner.hud.round.map(String.init))
                stat("资金", scanner.hud.money.map(String.init))
                HStack(spacing: 2) {
                    stat("终端", scanner.hud.level.map { "\($0)本" })
                    Stepper("", value: Binding(get: { scanner.hud.level ?? 1 }, set: { scanner.hud.level = $0 }), in: 1...6).labelsHidden()
                }
                Spacer()
                Button("读一次") { Task { await scanner.readStateOnce() } }.font(.caption)
            }
            if let f = coach.forecast, f.nextMoney != nil || f.nextUpgradeCost != nil || f.note != nil {
                // Funds don't carry over (except 利滚利); the upgrade price drops by 1 each round.
                Text([f.nextMoney.map { "下回合约 \($0) 资金" + (f.extra > 0 ? "（含本回合多拿的 \(f.extra)）" : "") },
                      f.nextUpgradeCost.map { "升本价 \($0)" },
                      f.carries ? "剩的钱能留到下回合" : "剩的钱留不到下回合",
                      f.note].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !scanner.bar.isEmpty {
                FlowLayout(spacing: 3) {
                    // Active covenants (blue ring in the game) in green with their level; inactive ones in grey.
                    ForEach(scanner.bar) { b in
                        if b.active {
                            chip("\(b.name)" + (b.level == 2 ? "Ⅱ" : b.level == 3 ? "Ⅲ" : "Ⅰ") + (b.layers.map { " \($0)层" } ?? ""),
                                 icon: "icons/covenants/\(b.name).png", color: .green)
                        } else {
                            chip("\(b.name) 未激活" + (b.layers.flatMap { $0 > 0 ? " \($0)层" : nil } ?? ""),
                                 icon: "icons/covenants/\(b.name).png", color: .secondary)
                        }
                    }
                }
            }
            if scanner.needsPermission {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scanner.permissionStale ? "系统设置里勾着，但截图被拒绝" : "没有屏幕录制权限，读不到游戏画面").font(.caption.bold())
                    Text(scanner.permissionStale
                         ? "系统设置里的这条记录和当前这份小助手对不上（更新小助手后常见）。点「清除旧授权」，再点「打开设置」重新勾选「卫戍协议小助手」，最后点「重新打开」。"
                         : "系统设置 → 隐私与安全性 → 屏幕与系统录音，勾选「卫戍协议小助手」，再点「重新打开」。每次更新小助手后要再勾一次。")
                        .font(.caption2).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if scanner.permissionStale {
                            Button("清除旧授权") { ScreenCapture.resetPermission(); scanner.permissionStale = false }
                                .help("只删除本应用在「屏幕与系统录音」里的旧记录（tccutil reset ScreenCapture），之后要重新勾选")
                        }
                        Button("打开设置") { ScreenCapture.openSettings() }
                        Button("重新打开") { ScreenCapture.relaunch() }
                    }
                    .controlSize(.small)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(scanner.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "–").font(.system(size: 15, weight: .semibold, design: .rounded))
        }
    }

    private func chip(_ text: String, icon: String? = nil, color: Color = .secondary) -> some View {
        HStack(spacing: 2) {
            if let icon { IconView(path: icon, size: 14) }
            Text(text).font(.system(size: 11))
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(color.opacity(0.15)).clipShape(Capsule())
    }

    // MARK: 推荐操作

    @ViewBuilder private var actionsCard: some View {
        if scanner.live || !coach.actions.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader(title: "推荐操作", trailing: AnyView(HStack(spacing: 6) {
                    Toggle("游戏内高亮", isOn: $coach.overlayEnabled)
                    Menu("显示…") {
                        Toggle("购买", isOn: $coach.showBuy)
                        Toggle("升本", isOn: $coach.showUpgrade)
                        Toggle("刷新", isOn: $coach.showRefresh)
                        Toggle("冻结", isOn: $coach.showFreeze)
                        Toggle("上场 / 站位 / 出售", isOn: $coach.showPlace)
                        Toggle("本回合敌人路线", isOn: $coach.showRoutes)
                    }
                    .fixedSize()
                }.font(.caption)))
                if let note = coach.newMatchNote { Text(note).font(.caption).foregroundStyle(.blue) }
                if let note = coach.liveNote { Text(note).font(.caption).foregroundStyle(.orange) }
                if coach.actions.isEmpty && coach.liveNote == nil {
                    Text(scanner.live ? "等待商店和休整期画面…" : "开启「实时」后，这里会给出买谁、升不升本、刷不刷新、冻不冻结、谁上场站哪，弹出悬赏 / 道具 / 战术选择时推荐选哪个。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(coach.actions) { a in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(a.kind.rawValue).font(.system(size: 10, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(actionColor(a.kind).opacity(0.3)).clipShape(Capsule())
                        Text(a.title).font(.system(size: 12, weight: .semibold))
                        Text(a.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if coach.showPlace && coach.board == nil && coach.liveField != nil {
                    Text("还没认出战场（需要休整期看到完整棋盘），暂不给站位格子。").font(.caption2).foregroundStyle(.secondary)
                }
                battlefield
            }
            .padding(8)
            .background(Color.yellow.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// This round's enemies (ground / flying routes, next round's too) and the mini board with routes, units and
    /// suggested cells.
    @ViewBuilder private var battlefield: some View {
        let listed = coach.roundEnemies.round == scanner.hud.round ? coach.roundEnemies : RoundEnemies()
        if scanner.live, coach.enemyRoutes != nil || !listed.enemies.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let routes = coach.enemyRoutes {
                    HStack(spacing: 6) {
                        Text(routes.summary).font(.caption.weight(.semibold))
                        if let n = coach.nextEnemyRoutes {
                            Text("下回合 \(n.kinds)" + (n.boss && !routes.boss ? "（领袖）" : ""))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(routes.sourceNote).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !listed.enemies.isEmpty {
                    Text("敌人列表：" + listed.enemies.map(coach.enemyTraits).joined(separator: "、")
                         + (listed.bounty.isEmpty ? "" : "；悬赏：" + listed.bounty.joined(separator: "、")))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let note = coach.antiAirNote { Text(note).font(.caption2).foregroundStyle(.orange) }
                if let map = coach.currentMap, let routes = coach.enemyRoutes {
                    MiniBoard(map: map, routes: routes,
                              units: (coach.liveField?.units ?? []).compactMap { u in
                                  guard !u.bench, let n = u.name, let c = u.cell, c.count == 2 else { return nil }
                                  return (n, c[0], c[1], u.chosen == nil && !u.confident)
                              },
                              suggestions: coach.actions.compactMap { a in
                                  guard a.kind == .place, let c = a.cell, c.count == 2 else { return nil }
                                  return (a.title.components(separatedBy: " ").first ?? a.title, c[0], c[1], a.facing ?? "")
                              },
                              onTap: { c, r in boardCell = BoardCell(col: c, row: r) })
                        .popover(item: $boardCell) { cell in
                            let unit = coach.liveField?.units.first { !$0.bench && $0.cell == [cell.col, cell.row] }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(unit.map { "(\(cell.col),\(cell.row)) 现在认成「\($0.name ?? "?")」，改成：" } ?? "(\(cell.col),\(cell.row)) 没认出人：补录").font(.caption)
                                OperatorPicker { name in
                                    if let unit { coach.correctLive(unit, name) } else { coach.addMissed(name) }
                                    boardCell = nil
                                }
                            }
                            .padding(8)
                        }
                    Text("点小地图上的格子：补录没认出的干员，或改正认错的").font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        legend(.red, "地面路线"); legend(.cyan, "飞行路线"); legend(.orange, "场上干员"); legend(.mint, "建议站位")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) { RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 3); Text(text) }
    }

    private func actionColor(_ k: GameAction.Kind) -> Color {
        switch k {
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

    // MARK: 本局设定

    private var setupLabel: some View {
        HStack {
            Text("本局设定").font(.system(size: 13, weight: .bold))
            Text([run.mode, coach.strategy?.name, run.bossName].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("模式", selection: $run.mode) {
                    Text("不限").tag(String?.none)
                    ForEach(catalog.modes, id: \.name) { m in Text(m.name).tag(String?.some(m.name)) }
                }
                .frame(maxWidth: 200)
                Picker("战场", selection: $run.mapID) {
                    Text("自动识别").tag(String?.none)
                    ForEach(coach.maps) { m in Text(m.name).tag(String?.some(m.id)) }
                }
                .frame(maxWidth: 220)
                .help("休整期棋盘可见时会按地砖颜色自动识别，一般不用手选")
                if let b = coach.board { Text("已识别").font(.caption2).foregroundStyle(.green).help("匹配差异 \(String(format: "%.1f", b.score))") }
                Spacer()
                Button { Task { await scanner.scanPreparation() } } label: { Label("截屏录入本局", systemImage: "text.viewfinder") }
                    .help("停在「确认本局信息」页：识别禁用盟约、敌方领袖和特训敌人")
                    .disabled(scanner.busy)
            }
            if let m = coach.maps.first(where: { $0.id == (coach.board?.mapId ?? run.mapID) }) {
                let tiles = MapTile.allCases.filter { (m.terrain?[$0.rawValue]?.isEmpty == false) }
                if !tiles.isEmpty {
                    // Special tiles change where to stand: the positioning advice already weighs them.
                    Text("特殊格：" + tiles.map { "\($0.name)——\($0.effect)" }.joined(separator: "；"))
                        .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            strategyPicker
            VStack(alignment: .leading, spacing: 4) {
                Text("禁用盟约（点击切换；灰色为本模式没有）").font(.caption).foregroundStyle(.secondary)
                covenantGrid(catalog.coreCovenants)
                covenantGrid(catalog.additionalCovenants)
            }
            enemies
            watchlistRow
            HStack {
                Text("自选干员：\(run.selfSelected.isEmpty ? "无" : run.selfSelected.joined(separator: "、"))").font(.caption).lineLimit(2)
                Spacer()
                Button("选择…") { pickingSelf = true }.font(.caption)
                    .popover(isPresented: $pickingSelf) { SelfSelectedPicker() }
            }
            selfPickSuggestions
        }
    }

    /// 自选编队 recommendations from the current routes (the game lets you pick up to two per row).
    /// 自选 is chosen once, on the 自选编队 screen before round 1: after that (or once picked) the list only distracts.
    private var selfPickPhase: Bool {
        run.selfSelected.isEmpty && (scanner.hud.round ?? 0) <= 1 && !(scanner.hud.isRest && scanner.hud.round != nil && !scanner.cards.isEmpty)
    }

    @ViewBuilder private var selfPickSuggestions: some View {
        let top = coach.selfPickScores.filter { $0.value.0 > 0 }.sorted { $0.value.0 > $1.value.0 || ($0.value.0 == $1.value.0 && $0.key < $1.key) }.prefix(4)
        if selfPickPhase && !top.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("推荐自选（按当前可走路线）").font(.caption2).foregroundStyle(.secondary)
                ForEach(Array(top), id: \.key) { name, v in
                    HStack(spacing: 4) {
                        IconView(path: catalog.op(name)?.iconPath ?? "", size: 18)
                        Text(name).font(.system(size: 11, weight: .semibold))
                        Text(v.1).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        let on = run.selfSelected.contains(name)
                        Button(on ? "已选" : "选用") { if on { run.selfSelected.removeAll { $0 == name } } else { run.selfSelected.append(name) } }
                            .font(.caption2)
                    }
                }
            }
        }
    }

    /// 特别关注: operators the player wants pointed out whenever they show up in the shop.
    private var watchlistRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("特别关注").font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 4) {
                ForEach(coach.watchlist, id: \.self) { n in
                    HStack(spacing: 2) {
                        Text(n).font(.system(size: 11))
                        Button { coach.setWatchlist(coach.watchlist.filter { $0 != n }) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2).background(Color.yellow.opacity(0.2)).clipShape(Capsule())
                }
                Button { pickingWatch = true } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.plain)
                    .help("商店出现这些干员时高亮并提示音（不管推荐买不买）")
                    .popover(isPresented: $pickingWatch) {
                        OperatorPicker { n in
                            if !coach.watchlist.contains(n) { coach.setWatchlist(coach.watchlist + [n]) }
                            pickingWatch = false
                        }
                    }
            }
        }
    }

    private var strategyPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("策略", selection: $run.strategyID) {
                    Text("未选择").tag(String?.none)
                    ForEach(catalog.strategies) { s in Text("\(s.name)（\(s.initiator)）").tag(String?.some(s.id)) }
                }
                .frame(maxWidth: 280)
                if coach.modifiers.piece == .mech { Toggle("铁皮已精锐", isOn: $run.mechElite).font(.caption) }
            }
            if let n = coach.strategyNote { Text(n).font(.caption2).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true) }
            if let s = coach.strategy {
                Text(s.description).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                let m = coach.modifiers
                ForEach(m.notes + (m.economyNote.map { [$0] } ?? []), id: \.self) { n in
                    Text("→ " + n).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private func covenantGrid(_ list: [Covenant]) -> some View {
        FlowLayout(spacing: 4) {
            ForEach(list) { c in
                let off = run.outOfMode.contains(c.name)
                let banned = run.bannedCovenants.contains(c.name)
                Button {
                    if banned { run.bannedCovenants.remove(c.name) } else { run.bannedCovenants.insert(c.name) }
                } label: {
                    HStack(spacing: 2) {
                        IconView(path: c.iconPath, size: 15).saturation(banned || off ? 0 : 1)
                        Text(c.name).font(.system(size: 11)).strikethrough(banned)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(off ? Color.secondary.opacity(0.08) : banned ? Color.red.opacity(0.18) : Color.green.opacity(0.12))
                    .clipShape(Capsule())
                    .opacity(off ? 0.4 : banned ? 0.75 : 1)
                }
                .buttonStyle(.plain)
                .disabled(off)
            }
        }
    }

    private var enemies: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("敌方领袖", selection: $run.bossName) {
                    Text("未知").tag(String?.none)
                    ForEach(catalog.bosses) { b in Text(b.name).tag(String?.some(b.name)) }
                }
                .frame(maxWidth: 260)
                Menu("＋特训敌人") {
                    ForEach(catalog.enemyTypes, id: \.typeCode) { t in
                        Menu(t.typeName) {
                            ForEach(Array(Set(t.variants.map(\.enemyName))).sorted(), id: \.self) { n in
                                Button(n) { if !run.specialEnemies.contains(n) { run.specialEnemies.append(n) } }
                            }
                        }
                    }
                }
                .fixedSize()
            }
            if let line = coach.bossStatsLine { Text(line).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !run.specialEnemies.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(run.specialEnemies, id: \.self) { n in
                        HStack(spacing: 2) {
                            Text(n).font(.system(size: 11))
                            Button { run.specialEnemies.removeAll { $0 == n } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Color.red.opacity(0.12)).clipShape(Capsule())
                        .help(coach.enemyStats(n) ?? n)
                    }
                }
            }
            let needs = coach.enemyNeeds()
            ForEach(needs.notes, id: \.self) { n in Text("• " + n).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    // MARK: 当前阵容

    /// Covenants of the held lineup: count, the next threshold (activation, then Ⅱ), who counts, and the layers the top
    /// bar shows. Active first, core before additional.
    private var covenantStatus: [(name: String, n: Int, target: Int, note: String, members: [String], active: Bool)] {
        let d = PlannerData(ops: catalog.operators, covenants: catalog.covenants, profiles: catalog.profiles,
                            selfSelected: Set(run.selfSelected), strategy: coach.modifiers)
        let held = Array(Set(run.owned))
        let counts = d.count(held)
        let harmony = held.filter { catalog.op($0)?.allCovenants.contains(PlanRules.harmony) == true }
        return counts.filter { $0.value > 0 && $0.key != PlanRules.harmony }.map { name, n in
            let act = d.activate(name), second = d.secondCount(name)
            let target = n < act ? act : (second != Int.max && n < second ? second : (second != Int.max ? second : act))
            let note = n < act ? "差 \(act - n) 人激活" : (second != Int.max && n < second ? "差 \(second - n) 人到Ⅱ" : (second != Int.max ? "Ⅱ" : "已激活"))
            var members = held.filter { catalog.op($0)?.allCovenants.contains(name) == true }.sorted()
            if d.isCore(name) && !members.isEmpty { members += harmony.map { $0 + "（调和）" } }
            return (name, n, target, note, members, n >= act)
        }
        .sorted { ($0.active ? 0 : 1, d.isCore($0.name) ? 0 : 1, -$0.n) < ($1.active ? 0 : 1, d.isCore($1.name) ? 0 : 1, -$1.n) }
    }

    private var lineupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "当前阵容（\(run.owned.count)）", trailing: AnyView(HStack(spacing: 8) {
                Button { Task { await coach.recognizeField() } } label: {
                    Label(coach.fieldBusy ? "识别中…" : "识别场上", systemImage: "person.crop.rectangle.stack")
                }
                .disabled(coach.fieldBusy || scanner.selectedWindowID == nil)
                .help("本地识别棋盘和整备区的干员（Core ML，M 系列芯片神经网络引擎加速）")
                Button { addingOwned.toggle() } label: { Image(systemName: "plus") }
                    .popover(isPresented: $addingOwned) { OperatorPicker { run.owned.append($0) } }
                if !run.owned.isEmpty { Button("清空") { run.owned = [] } }
            }.font(.caption)))
            if let e = coach.fieldError { Text(e).font(.caption).foregroundStyle(.orange) }
            if let f = coach.field { fieldReview(f) }
            else if scanner.live, let lf = coach.liveField {
                let board = lf.units.filter { !$0.bench }.count
                Text("实时：场上 \(board) · 整备区 \(lf.units.count - board)" + (coach.autoSyncField ? " · 自动同步到下面的阵容" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 4) {
                ForEach(Array(run.owned.enumerated()), id: \.offset) { i, name in
                    let locked = run.locked.contains(name)
                    HStack(spacing: 2) {
                        IconView(path: catalog.op(name)?.iconPath ?? "", size: 16)
                        Text(name).font(.system(size: 11, weight: locked ? .bold : .regular))
                        Text("\(catalog.op(name)?.tier ?? 0)").font(.system(size: 9)).foregroundStyle(.secondary)
                        Button { coach.removeOwned(at: i) } label: { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .help(locked ? "必带（右键取消）" : "右键：设为必带")
                    .background(locked ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contextMenu {
                        Button(locked ? "取消必带" : "设为必带（路线一定保留）") {
                            if locked { run.locked.removeAll { $0 == name } } else { run.locked.append(name) }
                        }
                        Button("移除") { coach.removeOwned(at: i) }
                    }
                }
            }
            if !run.owned.isEmpty {
                // Each covenant: who counts and how many are missing for the next level; layers from the top bar.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(covenantStatus, id: \.name) { c in
                        let bar = scanner.bar.first { $0.name == c.name }
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            IconView(path: "icons/covenants/\(c.name).png", size: 13)
                            Text("\(c.name) \(c.n)/\(c.target)").font(.system(size: 11, weight: c.active ? .semibold : .regular))
                                .foregroundStyle(c.active ? .green : .secondary)
                            Text(c.note).font(.system(size: 10)).foregroundStyle(c.active ? Color.secondary : Color.orange)
                            if let l = bar?.layers, l > 0 { Text("\(l)层").font(.system(size: 10)).foregroundStyle(.secondary) }
                            Text(c.members.joined(separator: "、")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .help("\(c.name)：\(c.members.joined(separator: "、"))；\(c.note)")
                    }
                }
            } else {
                Text("休整期点「识别场上」，或开启实时识别自动记录购买，或手动添加。路线会尽量保留你已有的干员。").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("实时识别时自动记录购买", isOn: $run.autoRecordPurchases).font(.caption)
        }
    }

    /// Manual 识别场上 result: one compact row of chips (uncertain ones in orange, tap for candidates).
    private func fieldReview(_ f: FieldReading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("识别到 \(f.units.filter { !$0.bench }.count) 场上 + \(f.units.filter(\.bench).count) 整备").font(.caption.bold())
                Text(String(format: "%.0f ms", f.millis.badges + f.millis.model)).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("采用") { coach.applyField() }.buttonStyle(.borderedProminent).controlSize(.mini)
                Button("放弃") { coach.field = nil }.controlSize(.mini)
            }
            FlowLayout(spacing: 3) {
                ForEach(f.units.sorted { ($0.bench ? 1 : 0, $0.x) < ($1.bench ? 1 : 0, $1.x) }) { u in
                    Menu {
                        ForEach(u.candidates, id: \.name) { c in
                            Button(String(format: "%@  %.0f%%", c.name, c.p * 100)) { coach.choose(u, c.name) }
                        }
                    } label: {
                        Text((u.bench ? "备·" : "") + (u.name ?? "?") + (!u.confident && u.chosen == nil ? "?" : "")).font(.system(size: 10))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background((u.confident || u.chosen != nil ? Color.green : Color.orange).opacity(0.15))
                    .clipShape(Capsule())
                }
            }
        }
        .padding(6)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: 路线

    /// The first 16 routes, plus the followed, 推荐 and AI routes wherever they sit in the list.
    private var visibleRoutes: [PlanCandidate] {
        if showAllRoutes { return coach.candidates }
        let keep: Set<String> = Set([coach.selected, coach.bestID, coach.aiPickID].compactMap { $0 })
        return coach.candidates.enumerated().filter { $0.offset < Self.routesShown || keep.contains($0.element.id) }.map(\.element)
    }

    private var routesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "能玩的路线", trailing: AnyView(HStack(spacing: 6) {
                Text("上场 \(run.deployCap) 人 · 转职次数自动").foregroundStyle(.secondary)
                    .help("上场人数从游戏读取（场上人数 + 剩余可放置）；转职次数由规划器在策略允许的范围内自动选最少的")
                Button { openWindow(id: "guide") } label: { Image(systemName: "rectangle.on.rectangle") }
                    .buttonStyle(.borderless).help("攻略悬浮窗：当前阶段的建议和自己写的攻略，浮在游戏上面")
                if coach.planning { ProgressView().controlSize(.small) }
            }.font(.caption)))
            if let e = coach.planError { Text(e).font(.caption).foregroundStyle(.red) }
            if !coach.contestedCovenants.isEmpty {
                Text("其他玩家在做：" + coach.contestedCovenants.sorted { $0.value > $1.value }
                        .map { $0.value >= 1 ? "\($0.key)×\(Int($0.value.rounded()))" : "\($0.key)（有牌）" }.joined(separator: "、")
                     + "（同一个本家的牌被分走，这些路线分数打了折）")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // Wrapping grid (a sidebar is too narrow to show a horizontal strip, and mouse wheels don't scroll it).
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 120), spacing: 6)], spacing: 6) {
                ForEach(visibleRoutes) { c in
                    let held = coach.heldCount(c)
                    Button { Task { await coach.select(c.id, style: nil) } } label: {
                        VStack(spacing: 1) {
                            if c.smallRoute {
                                HStack(spacing: 0) {
                                    ForEach(c.pair, id: \.name) { g in IconView(path: "icons/covenants/\(g.name).png", size: 20) }
                                }
                                Text(c.pair.map { $0.name + ($0.level == 2 ? "Ⅱ" : "Ⅰ") }.joined(separator: "+")).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                                Text("小盟约 · \(c.main)Ⅰ").font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.8)
                            } else {
                                IconView(path: "icons/covenants/\(c.main).png", size: 24)
                                Text(c.main).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                                Text("\(c.mainGoal.level == 2 ? "Ⅱ" : "Ⅰ") · \(c.style.rawValue)").font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.8)
                                    .help(c.style.explain)
                            }
                            HStack(spacing: 3) {
                                if held > 0 { Text("已有\(held)").foregroundStyle(.green) }
                                if c.id == coach.bestID { Text("推荐").foregroundStyle(.orange) }
                                if c.id == coach.aiPickID { Text("AI").foregroundStyle(.blue) }
                            }
                            .font(.system(size: 9, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(coach.selected == c.id ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help([held > 0 ? "你已经有 \(held) 名这条路线要用的干员" : nil, c.id == coach.aiPickID ? coach.aiPickNote : nil]
                            .compactMap { $0 }.joined(separator: "\n"))
                }
            }
            let hidden = coach.candidates.count - visibleRoutes.count
            if hidden > 0 || showAllRoutes && coach.candidates.count > Self.routesShown {
                Button(showAllRoutes ? "收起（只看前 \(Self.routesShown) 条）" : "显示全部（还有 \(hidden) 条）") { showAllRoutes.toggle() }
                    .buttonStyle(.link).font(.caption)
                    .help("排在后面的多是小盟约路线，分数较低")
            }
            if let route = coach.route {
                let c = route.candidate
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(c.smallRoute ? "小盟约路线 · 本家 \(c.mainGoal.label)" : "本家 \(c.mainGoal.label)").font(.system(size: 13, weight: .bold))
                        Spacer()
                        Picker("", selection: Binding(get: { coach.style ?? c.style }, set: { s in Task { await coach.select(c.id, style: s) } })) {
                            ForEach(PlanStyle.allCases) { s in Text(s.rawValue + (s == c.style ? "（推荐）" : "")).tag(s) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                        .help(PlanStyle.allCases.map(\.explain).joined(separator: "\n"))
                    }
                    Text(c.styleReason).font(.caption)
                    if !c.smallGoals.isEmpty {
                        // Small covenants are goals of the route, not footnotes: show them with their icons.
                        FlowLayout(spacing: 4) {
                            Text("小盟约").font(.caption2).foregroundStyle(.secondary)
                            ForEach(c.smallGoals, id: \.name) { g in
                                chip(g.label, icon: "icons/covenants/\(g.name).png", color: g.level == 2 ? .purple : .secondary)
                            }
                        }
                    }
                    if !c.notes.isEmpty { Text(c.notes.joined(separator: "；")).font(.caption).foregroundStyle(.orange) }
                    let holders = coach.gearHolders
                    if !holders.isEmpty {
                        Text("装备给谁：" + holders.map(\.label).joined(separator: "、")).font(.caption2)
                            .help("主C 拿攻击 / 技力装备，前排拿防御 / 生存装备；攻击随盟约层数涨的干员（如蓝毒）最吃装备")
                    }
                    let usages = coach.itemUsages
                    let assign = coach.gearAssignments.filter { a in !usages.contains { $0.item == a.item } }
                    if !assign.isEmpty {
                        Text("已有装备：" + assign.map { "\($0.item) → \($0.to)" }.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(usages, id: \.item) { u in
                        Text("道具 \(u.item)：\(u.use)").font(.caption2).fixedSize(horizontal: false, vertical: true)
                            .help("装上就会销毁，效果立刻生效")
                    }
                    if !route.equipment.isEmpty { Text("转职装备：" + route.equipment.joined(separator: "；")).font(.caption2).foregroundStyle(.secondary) }
                    if !route.substitutes.isEmpty {
                        // Final-lineup operators not held yet: who covers the same covenants until they come.
                        Text("替补：" + route.substitutes.map(\.text).joined(separator: "\n")).font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                            .help("成型阵容里还没到手的干员，先用盟约相同的人顶上（优先已有的，其次当前终端刷得到的）")
                    }
                    if !c.stackers.isEmpty {
                        Text("叠层手：" + c.stackers.prefix(6).map { "\($0.name)(\($0.tier)阶 \(String(format: "%g", $0.perRound))层/回合)" }.joined(separator: "、"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                let current = coach.currentStageIndex
                ForEach(Array(route.stages.enumerated()), id: \.offset) { i, s in
                    StageCard(stage: s, isCurrent: i == current && !s.isFinal, startOpen: current == nil ? i == 0 : i == current)
                }
                Text("叠层为普通特性的理论估算，不计站位、装备和实际战斗。").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: AI

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "AI 教练（\(coach.provider.title)）", trailing: AnyView(HStack(spacing: 8) {
                Picker("强度", selection: $coach.strength) {
                    ForEach(AIStrength.allCases) { s in Text(s.title).tag(s) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                .help(AIStrength.allCases.map(\.explain).joined(separator: "\n"))
                if coach.supportsImages { Toggle("截图", isOn: $coach.includeScreenshot).help("附带当前画面（会变慢）") }
            }.font(.caption)))
            HStack {
                Button { coach.askAdvice() } label: { Label(coach.aiBusy ? "思考中…" : "这回合怎么做", systemImage: "bolt.fill") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                if coach.aiBusy { Button("停止") { coach.stopAI() }.font(.caption) }
                if let t = coach.aiTiming {
                    Text(String(format: "首字 %.1fs · 总 %.1fs", (t.firstToken ?? t.total) / 1000, t.total / 1000)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let e = coach.aiError { Text(e).font(.caption).foregroundStyle(.red) }
            if !coach.aiText.isEmpty {
                MarkdownText(text: coach.aiText)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
        }
    }
}

struct StageCard: View {
    @EnvironmentObject var catalog: Catalog
    let stage: RouteStage
    let isCurrent: Bool
    @State private var open: Bool

    init(stage: RouteStage, isCurrent: Bool, startOpen: Bool) {
        self.stage = stage
        self.isCurrent = isCurrent
        _open = State(initialValue: startOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            Text(stage.focus).font(.caption)
            opsRow
            if open { details }
        }
        .padding(8)
        .background(isCurrent ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        let miss = stage.ops.filter { !$0.owned }.count
        return Button { open.toggle() } label: {
            HStack {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption)
                Text(stage.def.name).font(.system(size: 13, weight: .bold))
                Text(stage.isFinal ? stage.def.rounds : "\(stage.def.terminal)本 · \(stage.def.rounds)").font(.caption).foregroundStyle(.secondary)
                if isCurrent {
                    Text("当前").font(.system(size: 10, weight: .bold)).padding(.horizontal, 5)
                        .background(Color.accentColor).foregroundColor(.white).clipShape(Capsule())
                }
                Spacer()
                Text(miss == 0 ? "齐了" : "缺 \(miss)").font(.caption).foregroundStyle(miss == 0 ? Color.green : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var opsRow: some View {
        FlowLayout(spacing: 3) {
            ForEach(stage.ops) { o in OpTile(op: o) }
        }
    }

    @ViewBuilder private var details: some View {
        if !stage.active.isEmpty {
            Text("激活：" + stage.active.map { "\($0.0) \($0.1)" }.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary)
        }
        if !stage.removed.isEmpty { Text("下场 / 卖：" + stage.removed.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary) }
        if !stage.warnings.isEmpty { Text("⚠️ " + stage.warnings.joined(separator: "；")).font(.caption2).foregroundStyle(.orange) }
        ForEach(stage.advice) { a in levelAdvice(a) }
    }

    private func levelAdvice(_ a: LevelAdvice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(stage.isFinal ? "Boss 前" : "\(a.level) 本").font(.caption.bold())
                Text(a.pace.rawValue).font(.system(size: 10, weight: .bold)).padding(.horizontal, 4)
                    .background(paceColor(a.pace).opacity(0.25)).clipShape(Capsule())
                if a.level == 5 && !stage.isFinal { Text(a.focus).font(.caption2).lineLimit(1) }
            }
            ForEach(Array(a.buy.enumerated()), id: \.offset) { _, g in
                Text("· \(g.reason)：\(g.names.joined(separator: "、"))").font(.caption2).fixedSize(horizontal: false, vertical: true)
            }
            if !a.reserve.isEmpty { Text("· 见到就留：" + a.reserve.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary) }
            Text("→ " + a.upgrade).font(.caption2)
            Text(a.economy).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.leading, 6)
        .padding(.top, 2)
    }

    private func paceColor(_ p: Pace) -> Color {
        switch p { case .rush: .orange; case .stay: .yellow; case .steady: .green; case .max: .purple }
    }
}

struct OpTile: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var run: RunState
    @EnvironmentObject var scanner: Scanner
    let op: RouteOp

    /// How to get this operator now: held copies toward 精锐, or whether the current terminal level can roll it.
    private var how: (text: String, color: Color, tip: String) {
        let o = catalog.op(op.name)
        if let obtain = o?.obtain { return ("赠送", .purple, obtain) }
        if o?.isSelfSelected == true { return ("自选", .purple, "开局自选干员，商店不刷") }
        let copies = run.owned.filter { $0 == op.name }.count
        if copies > 0 && run.elites.contains(op.name) { return ("已精锐", .orange, "已合成精锐，不能再合成，不用再买（右键可取消标记）") }
        if copies >= 2 { return ("\(copies)/3 差1精锐", .green, "再买 1 张合成精锐；合成后得到晋升调配特许：商店刷出几名比当前终端高一阶的干员，免费选 1 名") }
        if copies == 1 { return ("1/3", .green, "已有 1 张；3 张合成精锐") }
        guard let level = scanner.hud.level else { return ("\(op.tier)本起", .secondary, "终端 \(op.tier) 本及以上才刷得到") }
        if op.tier <= level { return ("现在能刷", .blue, "当前 \(level) 本，商店刷得到 \(op.tier) 阶") }
        if op.tier == level + 1 { return ("精锐奖励/升本", .orange, "高一阶：合成精锐后的晋升调配特许会随机刷出几名高一阶干员（不一定有它），或升到 \(op.tier) 本再刷") }
        return ("\(op.tier)本才出", .secondary, "当前 \(level) 本，要升到 \(op.tier) 本才刷得到")
    }

    var body: some View {
        let h = how
        let sub = "\(op.tier)阶" + (op.transform.map { "→\($0)" } ?? "") + (op.isTank ? " 盾" : "") + (op.isHealer ? " 奶" : "")
        let tip = "\(op.name)" + (op.isFinal ? "（成型阵容）" : "（过渡）") + "：" + h.tip
            + (op.layers > 0 ? String(format: "；每回合约叠 %.1f 层", op.layers) : "")
        return VStack(spacing: 0) {
            IconView(path: catalog.op(op.name)?.iconPath ?? "", size: 30)
                .overlay(alignment: .topTrailing) {
                    if op.owned { Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green) }
                }
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(op.isFinal ? Color.yellow.opacity(0.8) : Color.clear, lineWidth: 1.5))
                .opacity(op.owned ? 1 : 0.75)
            Text(op.name).font(.system(size: 9)).lineLimit(1).frame(width: 46)
            Text(sub).font(.system(size: 8)).foregroundStyle(.secondary)
            Text(h.text).font(.system(size: 8, weight: .semibold)).foregroundStyle(h.color).lineLimit(1)
        }
        .frame(width: 50)
        .help(tip)
        .contextMenu {
            // Merges the helper didn't see (晋升调配特许, 升精锐 items, before it was running) are marked by hand.
            if run.owned.contains(op.name) {
                Button(run.elites.contains(op.name) ? "取消精锐标记" : "标记为已精锐") {
                    if let i = run.elites.firstIndex(of: op.name) { run.elites.remove(at: i) } else { run.elites.append(op.name) }
                }
            }
        }
    }
}

/// Multi-select for this run's 自选干员.
struct SelfSelectedPicker: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var run: RunState
    @State private var query = ""
    var body: some View {
        VStack(spacing: 6) {
            TextField("搜索自选干员", text: $query).textFieldStyle(.roundedBorder)
            List(catalog.operators.filter { $0.isSelfSelected && (query.isEmpty || $0.name.contains(query)) }.sorted { ($0.tier, $0.name) < ($1.tier, $1.name) }) { o in
                Toggle(isOn: Binding(get: { run.selfSelected.contains(o.name) },
                                     set: { on in if on { run.selfSelected.append(o.name) } else { run.selfSelected.removeAll { $0 == o.name } } })) {
                    HStack {
                        IconView(path: o.iconPath, size: 20)
                        Text(o.name)
                        TierBadge(tier: o.tier)
                        Text(o.allCovenants.joined(separator: "/")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
        }
        .padding(8)
        .frame(width: 320, height: 400)
    }
}

/// Search-and-pick list for adding a held operator.
struct OperatorPicker: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var run: RunState
    @State private var query = ""
    let onPick: (String) -> Void

    var body: some View {
        VStack(spacing: 6) {
            TextField("搜索干员", text: $query).textFieldStyle(.roundedBorder)
            List(catalog.operators.filter { !run.isBanned($0) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
                .sorted { ($0.tier, $0.name) < ($1.tier, $1.name) }) { o in
                Button { onPick(o.name) } label: {
                    HStack {
                        IconView(path: o.iconPath, size: 22)
                        Text(o.name)
                        TierBadge(tier: o.tier)
                        Spacer()
                        Text(o.allCovenants.joined(separator: "/")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .padding(8)
        .frame(width: 320, height: 380)
    }
}

/// Minimal Markdown: headings, bullets and inline emphasis.
struct MarkdownText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") {
                    Text(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))).font(.system(size: 13, weight: .bold)).padding(.top, 3)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 4) { Text("•"); Text(inline(String(line.dropFirst(2)))) }.font(.system(size: 12))
                } else if !line.isEmpty {
                    Text(inline(line)).font(.system(size: 12))
                }
            }
        }
    }
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// A mini-board cell the player clicked (popover item).
struct BoardCell: Identifiable, Hashable {
    let col: Int, row: Int
    var id: String { "\(col),\(row)" }
}
