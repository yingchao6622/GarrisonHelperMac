import SwiftUI

// MARK: - 干员

struct OperatorListView: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var run: RunState
    @State private var query = ""
    @State private var tiers: Set<Int> = []
    @State private var cores: Set<String> = []
    @State private var additionals: Set<String> = []
    @State private var traitTypes: Set<String> = []
    @State private var status = 0   // 0 all, 1 available, 2 banned
    @AppStorage("showSelfSelected") private var showSelfSelected = false
    @State private var showFilters = true
    @State private var expanded: String?

    private var allTraitTypes: [String] {
        Array(Set(catalog.operators.flatMap(\.traitTypes))).sorted()
    }

    private var filtered: [Operator] {
        catalog.operators.filter { op in
            (showSelfSelected || !op.isSelfSelected)
                && (query.isEmpty || op.name.localizedCaseInsensitiveContains(query) || op.normal.traits.contains { $0.traitDescription.contains(query) })
                && (tiers.isEmpty || tiers.contains(op.tier))
                && (cores.isEmpty || !cores.isDisjoint(with: op.coreCovenants))
                && (additionals.isEmpty || !additionals.isDisjoint(with: op.additionalCovenants))
                && (traitTypes.isEmpty || !traitTypes.isDisjoint(with: op.traitTypes))
                && (status == 0 || (status == 1) != run.isBanned(op))
        }
        .sorted { ($0.tier, $0.name) < ($1.tier, $1.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("搜索干员名或效果", text: $query).textFieldStyle(.roundedBorder)
                    Button { showFilters.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle" + (showFilters ? ".fill" : "")) }
                        .buttonStyle(.plain).help("筛选")
                }
                if showFilters { filters }
            }
            .padding(10)
            Divider()
            List(filtered) { op in
                OperatorRow(op: op, expanded: expanded == op.name) { expanded = expanded == op.name ? nil : op.name }
            }
            .listStyle(.plain)
            Text("\(filtered.count) 名干员").font(.caption2).foregroundStyle(.secondary).padding(4)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 5) {
            FlowLayout(spacing: 4) {
                ForEach(1...6, id: \.self) { t in FilterTag(title: "\(t)阶", on: tiers.contains(t)) { tiers.toggle(t) } }
                FilterTag(title: "可用", on: status == 1) { status = status == 1 ? 0 : 1 }
                FilterTag(title: "禁用", on: status == 2) { status = status == 2 ? 0 : 2 }
                FilterTag(title: "含自选干员", on: showSelfSelected) { showSelfSelected.toggle() }
            }
            FlowLayout(spacing: 4) {
                ForEach(catalog.coreCovenants) { c in FilterTag(title: c.name, on: cores.contains(c.name), icon: c.iconPath) { cores.toggle(c.name) } }
            }
            FlowLayout(spacing: 4) {
                ForEach(catalog.additionalCovenants) { c in FilterTag(title: c.name, on: additionals.contains(c.name), icon: c.iconPath) { additionals.toggle(c.name) } }
            }
            FlowLayout(spacing: 4) {
                ForEach(allTraitTypes, id: \.self) { t in FilterTag(title: t, on: traitTypes.contains(t)) { traitTypes.toggle(t) } }
                if !(tiers.isEmpty && cores.isEmpty && additionals.isEmpty && traitTypes.isEmpty && status == 0) {
                    Button("重置") { tiers = []; cores = []; additionals = []; traitTypes = []; status = 0 }.font(.caption)
                }
            }
        }
    }
}

struct OperatorRow: View {
    @EnvironmentObject var run: RunState
    let op: Operator
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let banned = run.isBanned(op)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IconView(path: op.iconPath, size: 40).opacity(banned ? 0.35 : 1).grayscale(banned ? 1 : 0)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(op.name).font(.system(size: 13, weight: .semibold)).strikethrough(banned)
                        TierBadge(tier: op.tier)
                        if op.isSelfSelected { Text("自选").font(.system(size: 9)).foregroundStyle(.secondary) }
                        if banned { Text("禁用").font(.system(size: 9, weight: .bold)).foregroundStyle(.red) }
                    }
                    FlowLayout(spacing: 3) { ForEach(op.allCovenants, id: \.self) { CovenantChip(name: $0) } }
                }
                Spacer(minLength: 0)
                Button { if let i = run.owned.firstIndex(of: op.name) { run.owned.remove(at: i) } else { run.owned.append(op.name) } } label: {
                    Image(systemName: run.owned.contains(op.name) ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
                }.buttonStyle(.plain).help("加入 / 移出当前阵容")
                Button { run.toggleManualBan(op) } label: {
                    Image(systemName: banned ? "nosign" : "circle").foregroundStyle(banned ? .red : .secondary)
                }.buttonStyle(.plain).help("手动标记禁用")
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if expanded {
                traitBlock("普通", op.normal.traits)
                traitBlock("精锐", op.elite.traits)
                if let o = op.obtain { Text("获取：\(o)").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func traitBlock(_ title: String, _ traits: [Trait]) -> some View {
        if !traits.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.bold()).foregroundStyle(title == "精锐" ? .orange : .secondary)
                ForEach(Array(traits.enumerated()), id: \.offset) { _, t in
                    Text("【\(t.traitType)】\(t.traitDescription)").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 48)
        }
    }
}

// MARK: - 装备

struct EquipmentListView: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var run: RunState
    @State private var query = ""
    @State private var tiers: Set<Int> = []

    private var filtered: [Equipment] {
        catalog.equipment.filter {
            (query.isEmpty || $0.name.contains(query) || $0.normal.effectDescription.contains(query))
                && (tiers.isEmpty || tiers.contains($0.tier))
        }.sorted { ($0.tier, $0.name) < ($1.tier, $1.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("搜索装备名或效果", text: $query).textFieldStyle(.roundedBorder)
                FlowLayout(spacing: 4) {
                    ForEach(1...6, id: \.self) { t in FilterTag(title: "\(t)阶", on: tiers.contains(t)) { tiers.toggle(t) } }
                }
            }.padding(10)
            Divider()
            List(filtered) { e in
                HStack(alignment: .top, spacing: 8) {
                    IconView(path: e.iconPath, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(e.name).font(.system(size: 13, weight: .semibold))
                            TierBadge(tier: e.tier)
                            if let c = catalog.jobChangeEquipment[e.name] { Text("转职→").font(.caption2); CovenantChip(name: c) }
                        }
                        Text("普通：" + e.normal.effectDescription).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Text("精锐：" + e.elite.effectDescription).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - 盟约

struct CovenantListView: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var run: RunState

    var body: some View {
        List {
            Section("核心盟约") { ForEach(catalog.coreCovenants) { row($0) } }
            Section("附加盟约") { ForEach(catalog.additionalCovenants) { row($0) } }
        }
        .listStyle(.plain)
    }

    private func row(_ c: Covenant) -> some View {
        let members = catalog.operators.filter { !$0.isSelfSelected && $0.allCovenants.contains(c.name) }.sorted { $0.tier < $1.tier }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                IconView(path: c.iconPath, size: 22)
                Text(c.name).font(.system(size: 14, weight: .bold)).strikethrough(run.bannedCovenants.contains(c.name))
                Text("\(c.activateCount) 人激活").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(members.count) 名干员").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array((catalog.covenantEffects[c.name] ?? []).enumerated()), id: \.offset) { _, eff in
                Text((eff.condition.isEmpty ? "" : "<\(eff.condition)> ") + eff.text)
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 2) {
                ForEach(members) { op in
                    IconView(path: op.iconPath, size: 24).help("\(op.name)（\(op.tier)阶）").opacity(run.isBanned(op) ? 0.35 : 1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 策略 / 敌人

struct StrategyListView: View {
    @EnvironmentObject var catalog: Catalog
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索策略 / 发起人 / 效果", text: $query).textFieldStyle(.roundedBorder).padding(10)
            Divider()
            List(catalog.strategies.filter { query.isEmpty || $0.name.contains(query) || $0.initiator.contains(query) || $0.description.contains(query) }) { s in
                HStack(alignment: .top, spacing: 8) {
                    IconView(path: s.iconPath, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(s.name).font(.system(size: 13, weight: .semibold))
                            Text(s.initiator).font(.caption).foregroundStyle(.secondary)
                            if let hp = s.initialHp { Text("初始生命 \(hp)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Text(s.description).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        if let u = s.unlockRequirement, !u.isEmpty { Text("解锁：\(u)").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .padding(.vertical, 3)
            }
            .listStyle(.plain)
        }
    }
}

struct EnemyListView: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var run: RunState
    var body: some View {
        List(catalog.bosses) { b in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    IconView(path: b.iconPath, size: 40)
                    Text(b.name).font(.system(size: 14, weight: .bold))
                    if let i = b.enemyIndex { Text(i).font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button(run.bossName == b.name ? "本局领袖 ✓" : "设为本局领袖") { run.bossName = run.bossName == b.name ? nil : b.name }
                        .font(.caption)
                }
                ForEach(Array((b.abilityList ?? []).enumerated()), id: \.offset) { _, a in
                    Text("• " + stripMarkup(a)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
        .listStyle(.plain)
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var scanner: Scanner
    @EnvironmentObject var coach: Coach
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true

    var body: some View {
        Form {
            AISettingsSection()
            Section("窗口") {
                Toggle("侧栏总在最前", isOn: $alwaysOnTop)
                    .onChange(of: alwaysOnTop) { _, v in scanner.sidebarWindow?.level = v ? .floating : .normal }
                Toggle("截图时把侧栏贴到游戏窗口右侧", isOn: $scanner.dockSidebar)
                Toggle("全局快捷键 \(HideHotKey.label)：隐藏 / 显示小助手和游戏内高亮", isOn: $coach.hideHotKey)
                    .onChange(of: coach.hideHotKey) { _, v in HideHotKey.shared.setEnabled(v) }
            }
            Section("识别") {
                HStack {
                    Text("实时识别间隔")
                    Slider(value: $scanner.scanInterval, in: 0.5...3, step: 0.25)
                    Text(String(format: "%.2fs", scanner.scanInterval)).monospacedDigit()
                }
                Text("游戏画面裁切（点）：自动识别 16:9 区域失败时，手动去掉窗口标题栏 / 侧边工具栏").font(.caption).foregroundStyle(.secondary)
                insetField("上", $scanner.insets.top)
                insetField("下", $scanner.insets.bottom)
                insetField("左", $scanner.insets.left)
                insetField("右", $scanner.insets.right)
                Button("保存当前截图和 OCR 结果（排查识别问题，存到 卫戍助手调试/手动截图）") { Task { await scanner.saveDebugCapture() } }
                DebugToggle()
                Button("打开屏幕录制权限设置") { ScreenCapture.openSettings() }
            }
            Section("关于") {
                Text("卫戍协议小助手 for Mac \(AppVersion.display) · 干员 \(catalog.operators.count) / 装备 \(catalog.equipment.count) / 策略 \(catalog.strategies.count)")
                    .textSelection(.enabled)
                Text("作者：6622")
                Text("开源项目衍生作品，代码以 Apache-2.0 发布，许可与来源见应用内的 NOTICE、ASSETS.md 和 licenses 目录。游戏美术与数据归上海鹰角网络所有，不在该许可范围内；本工具与鹰角网络无关，只读取屏幕画面，不修改游戏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func insetField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 20)
            Slider(value: value, in: 0...200, step: 1)
            Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 32)
        }
    }
}

extension Set {
    mutating func toggle(_ e: Element) { if contains(e) { remove(e) } else { insert(e) } }
}

struct AISettingsSection: View {
    @EnvironmentObject var coach: Coach
    @State private var keyDraft = ""
    @State private var base = ""
    @State private var model = ""
    @State private var vision = false

    var body: some View {
        Section("AI") {
            Picker("服务", selection: $coach.provider) {
                ForEach(AIProvider.allCases) { p in Text(p.title).tag(p) }
            }
            .onChange(of: coach.provider) { _, _ in load() }
            HStack {
                SecureField(APIKeyStore.load(coach.provider) != nil ? "已保存（输入新的可替换）" : "API Key（\(coach.provider.keyHint)）", text: $keyDraft)
                Button("保存") { APIKeyStore.save(keyDraft, for: coach.provider); keyDraft = ""; coach.keyVersion += 1 }.disabled(keyDraft.isEmpty)
                if APIKeyStore.load(coach.provider) != nil { Button("删除") { APIKeyStore.save("", for: coach.provider); coach.keyVersion += 1 } }
            }
            .id(coach.keyVersion)
            TextField("接口地址", text: $base, prompt: Text(coach.provider.defaultBase))
                .onSubmit { UserDefaults.standard.set(base, forKey: "ai.base.\(coach.provider.rawValue)") }
            TextField("模型", text: $model, prompt: Text(coach.provider.defaultModel))
                .onSubmit { UserDefaults.standard.set(model, forKey: "ai.model.\(coach.provider.rawValue)") }
            Picker("回答强度", selection: $coach.strength) {
                ForEach(AIStrength.allCases) { s in Text(s.title).tag(s) }
            }
            .pickerStyle(.segmented)
            Text(coach.strength.explain).font(.caption).foregroundStyle(.secondary)
            if coach.provider.isAnthropic {
                Toggle("Fast 模式（输出更快，价格 2 倍，仅 claude-opus-5-5）", isOn: $coach.claudeFast)
            } else {
                Toggle("模型支持图片（如 qwen-vl 系列）", isOn: $vision)
                    .onChange(of: vision) { _, v in UserDefaults.standard.set(v, forKey: "ai.vision.\(coach.provider.rawValue)") }
            }
            Button("保存地址和模型") {
                UserDefaults.standard.set(base, forKey: "ai.base.\(coach.provider.rawValue)")
                UserDefaults.standard.set(model, forKey: "ai.model.\(coach.provider.rawValue)")
            }
            Text("Key 存在本机「~/资源库/Application Support/卫戍协议小助手/api-keys.json」（只有你的账户能读），只通过 https 发给上面的接口地址（本机模型除外）。回答强度在上面和「本局」页的 AI 教练里都能调；DeepSeek / 百炼会自动缓存相同的前缀。作战中用「这回合怎么做」（⌘↩）。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: load)
    }

    private func load() {
        let d = UserDefaults.standard
        base = d.string(forKey: "ai.base.\(coach.provider.rawValue)") ?? ""
        model = d.string(forKey: "ai.model.\(coach.provider.rawValue)") ?? ""
        vision = d.bool(forKey: "ai.vision.\(coach.provider.rawValue)")
    }
}

struct DebugToggle: View {
    @EnvironmentObject var coach: Coach
    @State private var usage: (matches: Int, bytes: Int64) = (0, 0)
    @State private var confirmClear = false

    var body: some View {
        Toggle("调试模式：实时识别时自动保存画面和识别结果", isOn: $coach.debugCapture)
        VStack(alignment: .leading, spacing: 4) {
            Text("保存在小助手同一个文件夹里：" + DebugRecorder.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption).textSelection(.enabled)
            Text("每局一个文件夹；休整期最多 2 秒一帧，识别结果没变时 30 秒一帧（画面大变比如弹窗照存），作战中每 10 秒一帧，每局最多 \(DebugRecorder.maxPerMatch) 帧；磁盘剩余不到 \(Int(DebugRecorder.minFreeGB)) GB 时不存。「保存当前截图」放在 手动截图/ 里。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let p = DebugRecorder.problem { Text(p).font(.caption).foregroundStyle(.orange) }
            HStack {
                Text("已存 \(usage.matches) 局 · " + ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
                     + (DebugRecorder.freeGB().map { String(format: " · 磁盘剩 %.0f GB", $0) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("打开文件夹") { DebugRecorder.openFolder() }
                Button("清空…") { confirmClear = true }.disabled(usage.bytes == 0)
            }
        }
        .onAppear { refresh() }
        .confirmationDialog("把所有调试记录移到废纸篓？", isPresented: $confirmClear) {
            Button("移到废纸篓", role: .destructive) {
                DebugRecorder.clearAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refresh() }
            }
        } message: {
            Text("\(usage.matches) 局、\(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))。在废纸篓里还能找回，清倒废纸篓后才真正腾出空间。")
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let u = DebugRecorder.usage()
            DispatchQueue.main.async { usage = u }
        }
    }
}
