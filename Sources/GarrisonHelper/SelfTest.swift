import AppKit
import Foundation
import SwiftUI

/// `GarrisonHelper --selftest <image> [tracked names…]` runs recognition on a saved screenshot
/// (a whole game-window capture) and prints the results. Used for tuning without the game.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        // --trackertest: purchase reports arriving before / after the board shows the unit.
        if args.contains("--trackertest") {
            func unit(_ n: String) -> FieldUnit { FieldUnit(bench: true, x: 0, y: 0, tier: 3, badgeScore: 1, candidates: [(name: n, p: 0.99)]) }
            func run(_ title: String, _ steps: [(buy: Bool, board: Int)]) {
                var t = LineupTracker(), out: [Int] = []
                for s in steps {
                    if s.buy { t.purchased("极光") }
                    out.append(t.update(Array(repeating: unit("极光"), count: s.board)).filter { $0 == "极光" }.count)
                }
                print("\(title): " + out.map(String.init).joined(separator: " "))
            }
            run("board first, report late (want 0 1 1 1 1)", [(false, 1), (false, 1), (false, 1), (true, 1), (false, 1)])
            run("report first (want 1 1 1 1)", [(true, 0), (false, 1), (false, 1), (false, 1)])
            run("second copy bought later (want 1 1 … 2 2 2)", [(false, 1), (false, 1), (false, 1), (false, 1), (false, 1), (false, 1), (false, 1),
                                                                 (false, 1), (true, 1), (false, 2), (false, 2)])
            do {
                // 补录: a unit added by hand stays although the board never shows it; once the board shows it, no double.
                var t = LineupTracker(), out: [Int] = []
                t.addManual("极光")
                for board in [0, 0, 0, 0, 1, 1, 1] { out.append(t.update(Array(repeating: unit("极光"), count: board)).filter { $0 == "极光" }.count) }
                t.removeManual("极光")
                out.append(t.update([]).filter { $0 == "极光" }.count)
                print("manual add (want 1 1 1 1 1 1 1 1): " + out.map(String.init).joined(separator: " "))
            }
            exit(0)
        }
        if args.contains("--sklandtest") { runSklandTest(); exit(0) }
        if let i = args.firstIndex(of: "--sklandguide"), i + 1 < args.count { runSklandGuide(args[i + 1]); exit(0) }
        // GH_KEYS_FILE=/tmp/x.json --keytest: save / load / delete round trip of the API key file.
        if args.contains("--musictest") {
            // When the music plays for each phase (default: 联防 only), and which files a folder yields.
            MainActor.assumeIsolated {
                func hud(_ f: (inout HudReading) -> Void) -> HudReading { var h = HudReading(); f(&h); return h }
                let cases: [(String, HudReading, Bool)] = [
                    ("休整期", hud { $0.isRest = true }, false), ("作战中", hud { $0.inBattle = true }, false),
                    ("联防", hud { $0.inBattle = true; $0.coDefense = true; $0.otherBoard = true }, false),
                    ("首领", hud { $0.inBattle = true; $0.bossRound = true }, false), ("出局", HudReading(), true)]
                for set in [[MusicPlayer.Moment.coDefense], [.rest, .boss], [.battle, .eliminated]] {
                    print(set.map(\.label).joined(separator: "+") + ": " + cases.map { c in
                        "\(c.0)=\(MusicPlayer.wanted(Set(set), hud: c.1, eliminated: c.2) ? 1 : 0)" }.joined(separator: " "))
                }
                if let dir = args.firstIndex(of: "--musictest").map({ $0 + 1 }).flatMap({ args.indices.contains($0) ? args[$0] : nil }) {
                    let m = MusicPlayer(); let old = m.folder
                    m.folder = dir
                    print("tracks: " + m.tracks.map(\.lastPathComponent).joined(separator: ", ") + (m.error.map { "  (\($0))" } ?? ""))
                    m.folder = old
                }
            }
            exit(0)
        }
        if args.contains("--keytest") {
            APIKeyStore.save(" sk-test-123 ", for: .deepseek)
            APIKeyStore.save("claude-key", for: .claude)
            print("deepseek=\(APIKeyStore.load(.deepseek) ?? "nil") claude=\(APIKeyStore.load(.claude) ?? "nil") qwen=\(APIKeyStore.load(.qwen) ?? "nil")")
            APIKeyStore.save("", for: .deepseek)
            print("after delete deepseek=\(APIKeyStore.load(.deepseek) ?? "nil") claude=\(APIKeyStore.load(.claude) ?? "nil")")
            exit(0)
        }
        if let i = args.firstIndex(of: "--plan") { runPlan(Array(args.dropFirst(i + 1))); exit(0) }
        if let i = args.firstIndex(of: "--field"), i + 1 < args.count { runField(args[i + 1]); exit(0) }
        if let i = args.firstIndex(of: "--strategy") {
            // `--strategy a.png b.png …`: the strategy portrait read on each screenshot.
            let catalog = Catalog()
            guard let r = StrategyRecognizer(resourceRoot: catalog.resourceRoot) else { print("no portraits"); exit(1) }
            let names = Dictionary(catalog.strategies.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            for path in args.dropFirst(i + 1) {
                guard let img = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let vp = img.cropped(Viewport.find(PixelBuffer(img), insets: CropInsets())) else { print("\(path): cannot open"); continue }
                let t0 = Date()
                let m = r.read(vp)
                let ms = Date().timeIntervalSince(t0) * 1000
                print(String(format: "%@  %@ score %.2f margin %.2f (top %@)%@", (path as NSString).lastPathComponent, m.id.map { names[$0] ?? $0 } ?? "-", m.score, m.margin, m.top.map { names[$0] ?? $0 } ?? "-", ProcessInfo.processInfo.environment["STRATEGY_TIMING"] != nil ? String(format: " %.0fms", ms) : ""))
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--board"), i + 2 < args.count { runBoard(args[i + 1], out: args[i + 2]); exit(0) }
        if let i = args.firstIndex(of: "--hud") { runHud(Array(args.dropFirst(i + 1))); exit(0) }
        if let i = args.firstIndex(of: "--place") { runPlace(Array(args.dropFirst(i + 1))); exit(0) }
        if let i = args.firstIndex(of: "--miniboard") { runMiniBoard(Array(args.dropFirst(i + 1))); exit(0) }
        if let i = args.firstIndex(of: "--aitest"), i + 2 < args.count {
            // `--aitest 接口地址 模型`：DeepSeek 格式的流式请求（给本地模拟服务器测解析用，不带 Key）。
            let base = args[i + 1], model = args[i + 2]
            let sem = DispatchSemaphore(value: 0)
            Task {
                do {
                    // AI_TEST_KEY: a fake key, to check that it is never sent over plain http to another host.
                    let key = ProcessInfo.processInfo.environment["AI_TEST_KEY"]
                    let (text, t) = try await AIClient(config: AIConfig(provider: .deepseek, baseURL: base, model: model, key: key))
                        .stream(system: "s", cachedContext: nil, user: "u", maxTokens: 700) { _ in }
                    print("TEXT: \(text) first=\(t.firstToken.map { String(format: "%.0f", $0) } ?? "nil")")
                } catch { print("ERROR: \(error.localizedDescription)") }
                sem.signal()
            }
            while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--stripcheck") {
            // Shop cards from the separate strip OCR vs from the full-screen OCR, per frame.
            let catalog = Catalog()
            var same = 0, diff = 0
            for p in args.dropFirst(i + 1) {
                guard let img = NSImage(contentsOfFile: p)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let size = CGSize(width: img.width, height: img.height)
                let strip = ShopRecognizer.stripRect(viewport: size)
                guard let stripImage = img.cropped(strip), let st = try? OCR.recognize(stripImage, minHeight: 120),
                      let full = try? OCR.recognize(img, minHeight: 1080) else { continue }
                let a = ShopRecognizer.find(texts: st, stripOrigin: strip.origin, viewport: size, tracked: nil, catalog: catalog.shopNames,
                                            labels: catalog.covenants.map(\.name)).map { "\($0.slot(viewport: size))\($0.name)" }
                let b = ShopRecognizer.find(texts: OCR.within(full, strip), stripOrigin: strip.origin, viewport: size, tracked: nil,
                                            catalog: catalog.shopNames, labels: catalog.covenants.map(\.name)).map { "\($0.slot(viewport: size))\($0.name)" }
                if a == b { same += 1 } else { diff += 1; print("\((p as NSString).lastPathComponent) strip=\(a) full=\(b)") }
            }
            print("same \(same), different \(diff)")
            exit(0)
        }
        if let i = args.firstIndex(of: "--sigdiff") {
            // Screen-change distance between consecutive frames (calibrates the "unchanged" threshold).
            var prev: ScreenSignature?
            for p in args.dropFirst(i + 1) {
                guard let img = NSImage(contentsOfFile: p)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                // BOARD_SIG=1: the board-area signature (camera changes) instead of the whole screen.
                let s = ProcessInfo.processInfo.environment["BOARD_SIG"] != nil ? ScreenSignature(img, region: ScreenSignature.boardRegion) : ScreenSignature(img)
                print(String(format: "%@ %.2f", (p as NSString).lastPathComponent, prev.map { s.distance($0) } ?? -1))
                prev = s
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--prepbench"), i + 1 < args.count {
            // Per-tick image preparation on a Retina-sized window capture (2× the saved frame).
            guard let small = NSImage(contentsOfFile: args[i + 1])?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let img = OCR.upscale(small, by: 2) else { exit(1) }
            for k in 1...3 {
                var t = Date(); let px = PixelBuffer(img); let a = Date().timeIntervalSince(t) * 1000
                t = Date(); let vp = Viewport.find(px, insets: CropInsets()); let b = Date().timeIntervalSince(t) * 1000
                t = Date(); let crop = img.cropped(vp)!; let down = OCR.downscale(crop, maxHeight: Scanner.workHeight); let c = Date().timeIntervalSince(t) * 1000
                print(String(format: "prep %d (%dx%d): PixelBuffer %.0f ms · Viewport.find %.0f ms · crop+downscale %.0f ms → %dx%d", k, img.width, img.height, a, b, c, down.width, down.height))
            }
            exit(0)
        }
        // --ocrdump image [maxHeight]: full-screen OCR lines (optionally after downscaling like the live work image).
        if let i = args.firstIndex(of: "--ocrdump"), i + 1 < args.count {
            guard var img = NSImage(contentsOfFile: args[i + 1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
            if i + 2 < args.count, let h = Int(args[i + 2]), let d = OCR.downscale(img, maxHeight: h) as CGImage? { img = d }
            print("image \(img.width)x\(img.height)")
            for t in (try? OCR.recognizeScreen(img)) ?? [] { print("\(Int(t.box.minX)),\(Int(t.box.minY)) \(t.text)") }
            exit(0)
        }
        if let i = args.firstIndex(of: "--ocrbench"), i + 1 < args.count {
            // Full-screen OCR timing (first call includes loading Vision's text model).
            guard let img = NSImage(contentsOfFile: args[i + 1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
            for k in 1...6 {
                let t = Date(); let n = (try? OCR.recognize(img, minHeight: 1080).count) ?? -1
                print(String(format: "ocr %d: %.0f ms, %d lines", k, Date().timeIntervalSince(t) * 1000, n))
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--make-level-templates"), i + 1 < args.count { makeLevelTemplates(out: args[i + 1], Array(args.dropFirst(i + 2))); exit(0) }
        if let i = args.firstIndex(of: "--replay") {
            let paths = Array(args.dropFirst(i + 1))
            Task { @MainActor in await runReplay(paths); exit(0) }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--actions"), i + 2 < args.count { runActions(args[i + 1], out: args[i + 2], Array(args.dropFirst(i + 3))); exit(0) }
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return }
        let path = args[i + 1]
        let tracked = Array(args.dropFirst(i + 2))
        guard let img = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("cannot open \(path)"); exit(1)
        }
        let catalog = Catalog()
        let px = PixelBuffer(img)
        let vp = Viewport.find(px, insets: CropInsets())
        print("image \(img.width)x\(img.height) viewport \(vp)")
        guard let vpImage = img.cropped(vp), let texts = try? OCR.recognize(vpImage, minHeight: 1080) else { print("ocr failed"); exit(1) }
        print("--- OCR (viewport coords)")
        for t in texts { print(String(format: "%5.0f,%5.0f %4.0fx%3.0f  %@", t.box.minX, t.box.minY, t.box.width, t.box.height, t.text)) }

        let strip = ShopRecognizer.stripRect(viewport: vp.size)
        if let stripImg = img.cropped(strip.offsetBy(dx: vp.minX, dy: vp.minY)), let st = try? OCR.recognize(stripImg, minHeight: 120) {
            print("--- shop strip \(strip): " + st.map(\.text).joined(separator: " | "))
            let names = tracked.isEmpty ? catalog.shopNames : tracked
            for h in ShopRecognizer.find(texts: st, stripOrigin: strip.origin, viewport: vp.size, tracked: names, catalog: catalog.shopNames, labels: catalog.covenants.map(\.name)) {
                print("SHOP HIT \(h.name) at \(h.rect.integral)")
            }
        }
        let prep = PreparationRecognizer.analyze(texts: texts, pixels: px, viewport: vp, covenants: catalog.covenants, bosses: catalog.bosses)
        print("--- preparation page=\(prep.isPreparationPage) boss=\(prep.boss ?? "-")")
        print("banned: \(prep.banned)\navailable: \(prep.available)\nuncertain: \(prep.uncertain)")
        let hud = HudReader.refine(HudReader.read(texts: texts, viewport: vp.size), texts: texts, image: vpImage)
        print("--- hud round=\(hud.round.map(String.init) ?? "-") money=\(hud.money.map(String.init) ?? "-") level=\(hud.level.map(String.init) ?? "-") deploy=\(hud.remainingDeploy.map(String.init) ?? "-") rest=\(hud.isRest) battle=\(hud.inBattle) other=\(hud.otherBoard) boss=\(hud.bossRound)")
        if ProcessInfo.processInfo.environment["HUD_DEBUG"] != nil {
            let s = HudReader.scale(vp.size)
            let mr = CGRect(x: vp.width - 220 * s, y: vp.height - 330 * s, width: 205 * s, height: 100 * s)
            print("money rect \(mr.integral) gold=\(HudReader.goldBox(vpImage, in: mr).map { "\($0.integral)" } ?? "nil")")
            let known = CGRect(x: 735, y: 327, width: 62, height: 26)
            print("known rect \(known) → \(OCR.readNumber(vpImage, in: known).map(String.init) ?? "nil")")
        }
        let bar = CovenantBarReader.read(texts: texts, image: vpImage, covenants: catalog.covenants)
        print("--- covenant bar: " + bar.map { "\($0.name)\($0.active ? "" : "(未激活)") lv\($0.level.map(String.init) ?? "-") 层\($0.layers.map(String.init) ?? "?")" }.joined(separator: ", "))
        exit(0)
    }

    /// `--plan 禁用盟约,… 持有干员,… [策略id] [终端等级] [敌方领袖] [特训敌人,…]`
    static func runPlan(_ rest: [String]) {
        let catalog = Catalog()
        func list(_ i: Int) -> [String] { rest.count > i ? rest[i].split(separator: ",").map(String.init) : [] }
        let banned = Set(list(0)), owned = list(1)
        let strategy = rest.count > 2 ? catalog.strategies.first { $0.id == rest[2] } : nil
        let level = rest.count > 3 ? Int(rest[3]) : nil
        var needs = EnemyNeeds()
        if rest.count > 4, let b = catalog.bosses.first(where: { $0.name == rest[4] }) {
            if (b.abilityList ?? []).joined().contains("无人机") { needs.antiAir = true }
        }
        for n in list(5) where catalog.enemies.first(where: { $0.name == n })?.motion == "FLY" { needs.antiAir = true }
        let mods = StrategyModifiers.from(strategy, coreNames: Set(catalog.coreCovenants.map(\.name)))
        let data = PlannerData(ops: catalog.operators, covenants: catalog.covenants, profiles: catalog.profiles,
                               unavailable: banned, strategy: mods, enemy: needs, jobChangeEquipment: catalog.jobChangeEquipment)
        var req = PlanRequest()
        req.unavailable = banned
        req.bannedOperators = Set(catalog.operators.filter { op in
            if !op.coreCovenants.isEmpty { return op.coreCovenants.allSatisfy(banned.contains) }
            return !op.additionalCovenants.isEmpty && op.additionalCovenants.allSatisfy(banned.contains)
        }.map(\.name))
        req.owned = owned
        // PLAN_CONTESTED="阿戈尔:2,叙拉古:1": other players building these 本家.
        for kv in (ProcessInfo.processInfo.environment["PLAN_CONTESTED"] ?? "").split(separator: ",") {
            let p = kv.split(separator: ":"); if p.count == 2, let n = Double(p[1]) { req.contested[String(p[0])] = n }
        }
        req.currentLevel = level
        // PLAN_LOCKED="蓝毒,瑰盐,…": 必带 operators (as set by a 森空岛 lineup's 「照这套打」).
        req.locked = (ProcessInfo.processInfo.environment["PLAN_LOCKED"] ?? "").split(separator: ",").map(String.init)
        let counts = data.count(Array(Set(owned)))
        req.keepSmall = Array(catalog.additionalCovenants.compactMap { c -> PlannerGoal? in
            let n = counts[c.name, default: 0]
            guard n >= c.activateCount, !PlanRules.noAdditionalScore.contains(c.name) else { return nil }
            return PlanRules.goal(c, level: n >= 3 && PlanRules.peopleSecond.contains(c.name) ? 2 : 1)
        }.prefix(3))
        print("keepSmall: " + req.keepSmall.map(\.label).joined(separator: " "))
        print("strategy=\(mods.name) piece=\(mods.piece) favored=\(mods.favoredCores) antiAir=\(needs.antiAir)")
        let t0 = Date()
        let cands = AutoPlanner(d: data).candidates(req)
        print(String(format: "candidates: %d in %.2fs", cands.count, Date().timeIntervalSince(t0)))
        for c in cands.prefix(8) {
            print("■ \(c.title) score=\(Int(c.score)) \(c.mainGoal.label) \(c.style.rawValue) — \(c.styleReason)")
            print("  final: " + c.final.operators.map { n in n + (c.final.transforms[n].map { "→\($0)" } ?? "") }.joined(separator: " ")
                  + (c.final.mech.isEmpty ? "" : "  铁皮→\(c.final.mech)"))
            print("  small: " + c.smallGoals.map(\.label).joined(separator: " ") + "  notes: " + c.notes.joined(separator: "；"))
        }
        // AI_ANSWER="- 路线：R3 …": which tile gets the blue AI badge (the AI sees the first 12 as R1…R12).
        if let answer = ProcessInfo.processInfo.environment["AI_ANSWER"] {
            let shown = Array(cands.prefix(12))
            print("AI pick: " + (Coach.routePick(in: answer, routes: shown).map { "R\($0.index + 1) \(shown[$0.index].title)  ← \($0.line)" } ?? "none"))
        }
        let pick = ProcessInfo.processInfo.environment["PLAN_PICK"].flatMap(Int.init) ?? 0
        guard cands.indices.contains(pick) else { return }
        let top = cands[pick]
        print("route for \(top.title)")
        let t1 = Date()
        let route = RoutePlanner(d: data).plan(top, style: top.style, req: req, state: RouteState(owned: Set(owned), level: level, money: 10))
        print(String(format: "route in %.2fs  equipment: %@", Date().timeIntervalSince(t1), route.equipment.joined(separator: "; ")))
        for s in route.stages {
            print("  [\(s.def.name) \(s.def.terminal)本] " + s.ops.map { "\($0.name)\($0.tier)\($0.owned ? "✓" : "")" }.joined(separator: " "))
            print("     \(s.focus) | 激活: " + s.active.map { "\($0.0)\($0.1)" }.joined(separator: " ") + (s.warnings.isEmpty ? "" : " ⚠️" + s.warnings.joined(separator: ",")))
            for a in s.advice {
                print("     · \(a.level)本 [\(a.pace.rawValue)] " + a.buy.map { "\($0.reason)：\($0.names.joined(separator: "、"))" }.joined(separator: " | "))
                print("       \(a.upgrade)" + (a.reserve.isEmpty ? "" : "  留：\(a.reserve.joined(separator: "、"))"))
            }
        }
        for x in route.substitutes { print("  替补 " + x.text) }
    }

    /// `--field 截图.png`：场上认人（角标 + Core ML）。
    static func runField(_ path: String) {
        guard let img = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("cannot open"); return }
        let catalog = Catalog()
        let t0 = Date()
        let r = FieldRecognizer(resourceRoot: catalog.resourceRoot)
        print(String(format: "load %.2fs %@", Date().timeIntervalSince(t0), r.loadError ?? "ok"))
        var eligible: [Int: [String]] = [:]
        for o in catalog.operators where o.obtain == nil && !o.isSelfSelected { eligible[o.tier, default: []].append(o.name) }
        for (shown, slots) in catalog.prototypes { for t in Set(slots.map(\.tier)) { eligible[t, default: []].append(shown) } }
        for pass in 1...2 {
            let reading = r.read(img, eligible: eligible, prior: [], operatorNames: Set(catalog.operators.map(\.name)).union(catalog.prototypes.keys))
            print(String(format: "pass %d: badges %.0fms model %.0fms (%@) units %d", pass, reading.millis.badges, reading.millis.model, reading.computeUnits, reading.units.count))
            if pass == 2 {
                for u in reading.units {
                    print(String(format: "  %@ (%4.0f,%4.0f) T%d badge %.2f → ", u.bench ? "整备" : "场上", u.x, u.y, u.tier, u.badgeScore)
                          + u.candidates.map { String(format: "%@ %.0f%%", $0.name, $0.p * 100) }.joined(separator: ", "))
                }
            }
        }
    }

    /// `--actions 截图.png 输出.png [main=本家] [owned=a,b] [map=m01] [strategy=id] [money=N]`
    static func runActions(_ path: String, out: String, _ opts: [String]) {
        guard let img = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("cannot open"); return }
        var o: [String: String] = [:]
        for a in opts { let kv = a.split(separator: "=", maxSplits: 1).map(String.init); if kv.count == 2 { o[kv[0]] = kv[1] } }
        let catalog = Catalog()
        let px = PixelBuffer(img)
        let vp = Viewport.find(px, insets: CropInsets())
        guard let vpImage = img.cropped(vp), let texts = try? OCR.recognize(vpImage, minHeight: 1080) else { return }
        let size = CGSize(width: vpImage.width, height: vpImage.height)
        var hud = HudReader.refine(HudReader.read(texts: texts, viewport: size), texts: texts, image: vpImage)
        if let m = o["money"].flatMap(Int.init) { hud.money = m }
        var controls = GameControls.read(texts: texts, image: vpImage)
        let strip = ShopRecognizer.stripRect(viewport: size)
        let stripTexts = (try? OCR.recognize(vpImage.cropped(strip)!, minHeight: 120)) ?? []
        let hits = ShopRecognizer.find(texts: stripTexts, stripOrigin: strip.origin, viewport: size, tracked: nil, catalog: catalog.shopNames, labels: catalog.covenants.map(\.name))
        let shopRead = ShopPriceReader.read(vpImage, cards: hits, levelX: controls.levelX, levelY: controls.levelY)
        controls.upgradeCost = shopRead.upgradeCost
        let cards = hits.map { h -> ShopCard in
            var r = h.rect
            return ShopCard(name: h.name, slot: h.slot(viewport: size), rect: r, price: shopRead.prices[h.slot(viewport: size)])
        }
        print("hud money=\(hud.money.map(String.init) ?? "-") level=\(hud.level.map(String.init) ?? "-") deploy=\(hud.remainingDeploy.map(String.init) ?? "-")")
        print("controls refresh=\(controls.refresh.map { "\($0.integral)" } ?? "-") cost=\(controls.refreshCost.map(String.init) ?? "-") freeze=\(controls.freeze.map { "\($0.integral)" } ?? "-") frozen=\(controls.frozen) level=\(controls.level.map { "\($0.integral)" } ?? "-") upgradeCost=\(controls.upgradeCost.map(String.init) ?? "-")")
        print("cards: " + cards.map { "\($0.name)[\($0.slot)] ¥\($0.price.map(String.init) ?? "?")" }.joined(separator: ", "))
        let owned = (o["owned"] ?? "").split(separator: ",").map(String.init)
        let strategy = catalog.strategies.first { $0.id == o["strategy"] }
        let mods = StrategyModifiers.from(strategy, coreNames: Set(catalog.coreCovenants.map(\.name)))
        let data = PlannerData(ops: catalog.operators, covenants: catalog.covenants, profiles: catalog.profiles, strategy: mods,
                               jobChangeEquipment: catalog.jobChangeEquipment)
        var req = PlanRequest(); req.owned = owned; req.currentLevel = hud.level
        let cands = AutoPlanner(d: data).candidates(req)
        guard let cand = cands.first(where: { $0.main == o["main"] }) ?? cands.first else { return }
        let route = RoutePlanner(d: data).plan(cand, style: cand.style, req: req, state: RouteState(owned: Set(owned), level: hud.level, money: hud.money))
        let current = RoutePlanner(d: data).currentStageIndex(level: hud.level)
        print("route: \(cand.main) \(cand.style.rawValue); stage \(route.stages[current ?? 0].def.name) keys=\(route.stages[current ?? 0].advice.first?.keyCards ?? [])")
        let recognizer = FieldRecognizer(resourceRoot: catalog.resourceRoot)
        var eligible: [Int: [String]] = [:]
        for op in catalog.operators where op.obtain == nil && !op.isSelfSelected { eligible[op.tier, default: []].append(op.name) }
        for (shown, slots) in catalog.prototypes { for t in Set(slots.map(\.tier)) { eligible[t, default: []].append(shown) } }
        var field = recognizer.read(vpImage, eligible: eligible, prior: Set(owned).union(owned.compactMap(catalog.prototype(of:))),
                                    operatorNames: Set(catalog.operators.map(\.name)).union(catalog.prototypes.keys))
        // Stand-ins (Pith …) → the held operator of that tier, else the first one (the live path also weighs the route).
        for i in field.units.indices {
            let u = field.units[i]
            guard let shown = u.candidates.first?.name, let slots = catalog.prototypes[shown] else { continue }
            let atTier = slots.filter { $0.tier == u.tier }.map(\.name)
            if let real = atTier.first(where: owned.contains) ?? atTier.first { field.units[i].candidates[0].name = real }
        }
        let mapFile = try? JSONDecoder().decode(GarrisonMapFile.self, from: Data(contentsOf: catalog.resourceRoot.appendingPathComponent("data/garrison_maps.json")))
        let boardMatch = BoardRecognizer(resourceRoot: catalog.resourceRoot).recognize(vpImage, mapId: hud.bossRound ? o["map"] : nil, boss: hud.bossRound)
        if let b = boardMatch { field.place(on: b.projection) }
        let proj = boardMatch?.projection
        print("board: \(boardMatch.map { "\($0.mapId) expanded=\($0.expanded) score=\(String(format: "%.1f", $0.score))" } ?? "none")")
        for u in field.units { print("  unit \(u.bench ? "整备" : "场上") cell=\(u.cell.map { "\($0)" } ?? "-") T\(u.tier) " + u.candidates.prefix(2).map { "\($0.name) \(Int($0.p * 100))%" }.joined(separator: ", ")) }
        let shopOpen = !hits.isEmpty || controls.refresh != nil
        _ = shopOpen
        let input = AdvisorInput(cards: cards, controls: controls, hud: hud, owned: owned + field.units.compactMap(\.name), route: route,
                                 currentStage: current, deployCap: 8, field: field.units.isEmpty ? nil : field,
                                 map: mapFile?.maps.first { $0.id == (o["map"] ?? boardMatch?.mapId) }, projection: proj, viewport: size,
                                 catalog: (tier: { n in catalog.op(n)?.tier ?? catalog.equipment.first(where: { $0.name == n })?.tier },
                                           isOperator: { n in catalog.op(n) != nil }, op: { n in catalog.op(n) }),
                                 profiles: catalog.profiles, eliteFocus: mods.eliteFocus,
                                 elites: Set((o["elite"] ?? "").split(separator: ",").map(String.init)),
                                 equipment: Dictionary(catalog.equipment.map { ($0.name, (catalog.equipmentCategories[$0.name] ?? [], $0.normal.effectDescription)) }, uniquingKeysWith: { a, _ in a }),
                                 round: hud.round)
        let actions = ActionAdvisor.advise(input)
        for a in actions { print("ACTION [\(a.kind.rawValue)] \(a.title) — \(a.reason) \(a.rect.map { "\($0.integral)" } ?? (a.quad != nil ? "cell" : ""))") }
        // Annotated image.
        let ctx = CGContext(data: nil, width: vpImage.width, height: vpImage.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(vpImage, in: CGRect(x: 0, y: 0, width: vpImage.width, height: vpImage.height))
        ctx.translateBy(x: 0, y: CGFloat(vpImage.height)); ctx.scaleBy(x: 1, y: -1)
        let colors: [GameAction.Kind: CGColor] = [.buy: CGColor(red: 1, green: 0.85, blue: 0, alpha: 1), .upgrade: CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                                                  .refresh: CGColor(red: 0, green: 1, blue: 1, alpha: 1), .freeze: CGColor(red: 0.2, green: 0.4, blue: 1, alpha: 1),
                                                  .place: CGColor(red: 0.4, green: 1, blue: 0.7, alpha: 1), .deploy: CGColor(red: 0.4, green: 1, blue: 0.7, alpha: 1),
                                                  .sell: CGColor(red: 1, green: 0, blue: 0, alpha: 1), .bench: CGColor(red: 1, green: 0.5, blue: 0, alpha: 1)]
        ctx.setLineWidth(3)
        for a in actions {
            ctx.setStrokeColor(colors[a.kind] ?? CGColor(gray: 1, alpha: 1))
            if let r = a.rect { ctx.stroke(r) }
            if let q = a.quad { ctx.addLines(between: q + [q[0]]); ctx.strokePath() }
        }
        // 「?」 where the live overlay puts its clickable button (same rule as Coach.overlayQuestions).
        for u in field.units where u.chosen == nil && !u.confident && u.candidates.count >= 2 {
            let c = field.toViewport(CGRect(x: u.x + 34, y: u.y, width: 0, height: 0)).origin, r = 13.0
            ctx.setFillColor(CGColor(red: 1, green: 0.6, blue: 0, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        if let p = proj {   // board grid for reference
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.3)); ctx.setLineWidth(1)
            for r in 0...3 { for c in -2...9 { let q = p.cell(c, r, in: size); ctx.addLines(between: q + [q[0]]); ctx.strokePath() } }
        }
        if let outImg = ctx.makeImage() { try? NSBitmapImageRep(cgImage: outImg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)) }
    }

    /// `--board 截图.png 输出.png`：地图识别 + 镜头拟合，输出画了格子的图。
    static func runBoard(_ path: String, out: String) {
        guard let img = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let catalog = Catalog()
        // Frames from 卫戍助手调试 are already the game view at the live size; window screenshots are cropped first.
        let recorded = img.height <= Scanner.workHeight
        let vp = Viewport.find(PixelBuffer(img), insets: CropInsets())
        guard let full = recorded ? img : img.cropped(vp) else { return }
        let vpImage = OCR.downscale(full, maxHeight: Scanner.workHeight)   // the size the live path recognises
        print("image \(img.width)×\(img.height) recorded=\(recorded) → \(vpImage.width)×\(vpImage.height)")
        let rec = BoardRecognizer(resourceRoot: catalog.resourceRoot)
        let t0 = Date()
        let m = rec.recognize(vpImage, mapId: ProcessInfo.processInfo.environment["MAP"])
        print(String(format: "board %.0fms ", Date().timeIntervalSince(t0) * 1000) + (m.map { "map=\($0.mapId) expanded=\($0.expanded) score=\(String(format: "%.1f", $0.score)) gap=\($0.gap.map { String(format: "%.1f", $0) } ?? "-")" } ?? "no match"))
        let size = CGSize(width: vpImage.width, height: vpImage.height)
        let ctx = CGContext(data: nil, width: vpImage.width, height: vpImage.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(vpImage, in: CGRect(x: 0, y: 0, width: vpImage.width, height: vpImage.height))
        ctx.translateBy(x: 0, y: CGFloat(vpImage.height)); ctx.scaleBy(x: 1, y: -1)
        if let p = m?.projection {
            let maps = (try? JSONDecoder().decode(GarrisonMapFile.self, from: Data(contentsOf: catalog.resourceRoot.appendingPathComponent("data/garrison_maps.json"))))?.maps ?? []
            let map = maps.first { $0.id == m?.mapId }
            for r in 0...4 { for c in -2...9 {
                let q = p.cell(c, r, in: size)
                let t = map?.type(c, r) ?? "X"
                let color: CGColor = t == "S" ? CGColor(red: 1, green: 0, blue: 0, alpha: 0.9) : t == "D" ? CGColor(red: 0, green: 0.5, blue: 1, alpha: 0.9)
                    : t == "H" ? CGColor(red: 1, green: 0.8, blue: 0, alpha: 0.8) : t == "G" || t == "T" ? CGColor(red: 0, green: 1, blue: 0.4, alpha: 0.6) : CGColor(gray: 1, alpha: 0.15)
                ctx.setStrokeColor(color); ctx.setLineWidth(t == "X" ? 1 : 2)
                ctx.addLines(between: q + [q[0]]); ctx.strokePath()
            } }
            // ROUND=n (MODE=终极模拟): this round's enemy routes (ground red, flying cyan) instead of the static lanes.
            let env = ProcessInfo.processInfo.environment
            if let mapId = m?.mapId, let round = env["ROUND"].flatMap(Int.init),
               let rr = EnemyRouteData(resourceRoot: catalog.resourceRoot).routes(map: mapId, round: round, mode: env["MODE"] ?? "终极模拟", bossEnemyId: env["BOSS"]) {
                print(rr.summary + "  level \(rr.level)")
                for r in rr.routes {
                    print("  \(r.fly ? "fly " : "walk") ×\(r.count)\(r.boss ? " boss" : "") cells " + r.cells.map { "\($0.0),\($0.1)" }.joined(separator: " "))
                    ctx.setStrokeColor(r.fly ? CGColor(red: 0, green: 0.9, blue: 1, alpha: 1) : CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1))
                    ctx.setLineWidth(r.fly ? 2 : 4)
                    ctx.setLineDash(phase: 0, lengths: r.fly ? [8, 6] : [])
                    for seg in r.segments { ctx.addLines(between: seg.map { p.point($0.x, $0.y, in: size) }); ctx.strokePath() }
                }
                ctx.setLineDash(phase: 0, lengths: [])
            } else if let map {
                ctx.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.8, alpha: 1)); ctx.setLineWidth(3)
                for route in map.routes {
                    let pts = route.cells.map { p.point(Double($0[0]) + 0.5, Double($0[1]) + 0.5, in: size) }
                    ctx.addLines(between: pts); ctx.strokePath()
                }
            }
        }
        if let o = ctx.makeImage() { try? NSBitmapImageRep(cgImage: o).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)) }
    }

    /// `--place map=m04 team=折桠,烈夏,… [at=折桠@0,3;烈夏@1,2]`：打印站位建议（格子、朝向、理由）和地图上的特殊格。
    static func runPlace(_ opts: [String]) {
        var o: [String: String] = [:]
        for a in opts { let kv = a.split(separator: "=", maxSplits: 1).map(String.init); if kv.count == 2 { o[kv[0]] = kv[1] } }
        let catalog = Catalog()
        guard let file = try? JSONDecoder().decode(GarrisonMapFile.self, from: Data(contentsOf: catalog.resourceRoot.appendingPathComponent("data/garrison_maps.json"))),
              let map = file.maps.first(where: { $0.id == (o["map"] ?? "m04") }) else { print("no map"); return }
        let team = (o["team"] ?? "").split(separator: ",").compactMap { catalog.op(String($0)) }
        var current: [String: (Int, Int)] = [:]
        for p in (o["at"] ?? "").split(separator: ";") {
            let kv = p.split(separator: "@"); guard kv.count == 2 else { continue }
            let cr = kv[1].split(separator: ",").compactMap { Int($0) }; if cr.count == 2 { current[String(kv[0])] = (cr[0], cr[1]) }
        }
        print("map \(map.id) \(map.name)  terrain: " + (map.terrain ?? [:]).map { "\($0.key) \($0.value)" }.joined(separator: "; "))
        for row in 0...4 {
            print((-2...9).map { c -> String in
                if let n = current.first(where: { $0.value == (c, row) })?.key { return String(n.prefix(1)) }
                if let t = map.tile(c, row) { return String(t.short.prefix(1)) }
                return String(map.type(c, row))
            }.joined(separator: " "))
        }
        // round=n (mode=终极模拟): place against this round's enemy routes instead of the map's static lanes.
        let enemy = o["round"].flatMap(Int.init).flatMap {
            EnemyRouteData(resourceRoot: catalog.resourceRoot).routes(map: map.id, round: $0, mode: o["mode"] ?? "终极模拟", bossEnemyId: o["boss"])
        }
        if let enemy { print(enemy.summary + "  level \(enemy.level)") }
        for p in PlacementHeuristic.advise(map: map, team: team, current: current, profiles: catalog.profiles, enemy: enemy) {
            print("  \(p.name) → (\(p.col),\(p.row)) \(p.facing.rawValue)  \(p.reason)")
        }
    }

    /// `--replay a.png b.png …`：按顺序把窗口截图送进实时识别流程（Scanner → Coach），打印每帧的结果。
    /// `--miniboard map=m04 round=8 team=摆渡人,能天使 at=摆渡人@4,2 out=a.png`：把侧栏小地图画成图片。
    static func runMiniBoard(_ opts: [String]) {
        var o: [String: String] = [:]
        for a in opts { let kv = a.split(separator: "=", maxSplits: 1).map(String.init); if kv.count == 2 { o[kv[0]] = kv[1] } }
        let catalog = Catalog()
        guard let file = try? JSONDecoder().decode(GarrisonMapFile.self, from: Data(contentsOf: catalog.resourceRoot.appendingPathComponent("data/garrison_maps.json"))),
              let map = file.maps.first(where: { $0.id == (o["map"] ?? "m04") }) else { print("no map"); return }
        let routes = EnemyRouteData(resourceRoot: catalog.resourceRoot).routes(map: map.id, round: Int(o["round"] ?? "8") ?? 8, mode: o["mode"] ?? "终极模拟", bossEnemyId: o["boss"])
        var current: [String: (Int, Int)] = [:]
        for p in (o["at"] ?? "").split(separator: ";") {
            let kv = p.split(separator: "@"); guard kv.count == 2 else { continue }
            let cr = kv[1].split(separator: ",").compactMap { Int($0) }; if cr.count == 2 { current[String(kv[0])] = (cr[0], cr[1]) }
        }
        let team = (o["team"] ?? "").split(separator: ",").compactMap { catalog.op(String($0)) }
        let place = PlacementHeuristic.advise(map: map, team: team, current: current, profiles: catalog.profiles, enemy: routes).prefix(3)
        let view = MiniBoard(map: map, routes: routes,
                             units: current.map { ($0.key, $0.value.0, $0.value.1, $0.key.hasPrefix("?")) },
                             suggestions: place.map { ($0.name, $0.col, $0.row, $0.facing.rawValue) })
            .frame(width: 340).padding(8).background(Color(white: 0.15))
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.cgImage, let out = o["out"] {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print(routes?.summary ?? "no routes", "→", out)
        }
    }

    static func runReplay(_ paths: [String]) async {
        let catalog = Catalog()
        let run = RunState()
        run.newRun()
        run.mode = "终极模拟"
        run.strategyID = "band_amiya"
        let scanner = Scanner(catalog: catalog, run: run)
        let coach = Coach(catalog: catalog, run: run, scanner: scanner)
        coach.overlayEnabled = false
        // DEBUG_RECORD=1 records like the app's debug mode (into 卫戍助手调试/ next to this executable).
        let record = ProcessInfo.processInfo.environment["DEBUG_RECORD"] != nil
        coach.recordOverride = record   // never the saved setting: parallel test runs would pick it up
        coach.history.enabled = false   // replays never add matches to the player's history
        defer { if record { DebugRecorder.flush() } }
        while coach.recognizerReady == false { try? await Task.sleep(nanoseconds: 100_000_000) }
        for path in paths {
            guard var img = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            // REPLAY_RETINA=1 doubles the frame like a Retina window capture (the live path then downscales it).
            if ProcessInfo.processInfo.environment["REPLAY_RETINA"] != nil, let big = OCR.upscale(img, by: 2) { img = big }
            let t0 = Date()
            await scanner.replay(img)
            await coach.plan()
            await scanner.replay(img)   // second reading of the same frame (stability)
            let h = scanner.hud
            print("=== \((path as NSString).lastPathComponent)  \(String(format: "%.1fs", Date().timeIntervalSince(t0)))")
            print("hud 回合\(h.round.map(String.init) ?? "?") 资金\(h.money.map(String.init) ?? "?") \(h.level.map { "\($0)本" } ?? "?") rest=\(h.isRest) battle=\(h.inBattle) other=\(h.otherBoard) 联防=\(h.coDefense) tag=\(h.boardTag ?? "-") boss=\(h.bossRound)  [\(scanner.status)]")
            if let f = coach.forecast { print("forecast: next \(f.nextMoney.map(String.init) ?? "-") extra \(f.extra) upgrade \(f.nextUpgradeCost.map(String.init) ?? "-") wait \(f.roundsToUpgrade.map(String.init) ?? "-")") }
            print("bar: " + scanner.bar.filter(\.active).map { "\($0.name)\($0.level == 2 ? "Ⅱ" : "")\($0.layers.map { " \($0)层" } ?? "")" }.joined(separator: "、"))
            print("map: \(coach.board?.mapId ?? "-")  owned(\(run.owned.count)): \(run.owned.joined(separator: "、"))"
                  + (run.selfSelected.isEmpty ? "" : "  自选: " + run.selfSelected.joined(separator: "、")))
            if !coach.roundEnemies.enemies.isEmpty || !coach.roundEnemies.bounty.isEmpty {
                print("enemy panel (round \(coach.roundEnemies.round.map(String.init) ?? "-")): " + coach.roundEnemies.enemies.map(coach.enemyTraits).joined(separator: "、")
                      + (coach.roundEnemies.bounty.isEmpty ? "" : "  悬赏: " + coach.roundEnemies.bounty.joined(separator: "、")))
            }
            if let r = coach.enemyRoutes { print("routes: " + r.summary + " level \(r.level)") }
            print("route: \(coach.route.map { "\($0.candidate.main) \($0.style.rawValue)" } ?? "-")  note: \(coach.liveNote ?? "-")" + (coach.newMatchNote.map { "  NEW: \($0)" } ?? "")
                  + (coach.contestedCovenants.isEmpty ? "" : "  contested: " + coach.contestedCovenants.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: ",")))
            print("shop: " + scanner.cards.map { "\($0.name)\($0.price.map { p in "(\(p))" } ?? "(?)")" }.joined(separator: " "))
            for a in coach.actions { print("  [\(a.kind.rawValue)] \(a.title) — \(a.reason)" + (a.rect.map { "  @\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "")) }
            if ProcessInfo.processInfo.environment["AI_PROMPT"] != nil {
                print("AI state:\n" + coach.stateSummary())
                if let c = coach.choice { print("AI prompt:\n" + coach.choicePrompt(c)) }
            }
            if let c = coach.choice {
                print("choice \(c.kind.rawValue):")
                for card in c.cards { print("  \(card.best ? "★" : " ") \(card.name) \(String(format: "%.2f", card.score)) — \(card.reason)  @\(Int(card.rect.minX)),\(Int(card.rect.minY)) \(Int(card.rect.width))x\(Int(card.rect.height))") }
            }
        }
    }

    /// Prints the HUD reading (round, funds, level) for each image; BADGE_DEBUG=dir saves the funds digit crop.
    static func runHud(_ paths: [String]) {
        for p in paths {
            guard let img = NSImage(contentsOfFile: p)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let vp = Viewport.find(PixelBuffer(img), insets: CropInsets())
            guard let full = img.cropped(vp) else { continue }
            let v = OCR.downscale(full, maxHeight: Scanner.workHeight)
            guard let texts = try? OCR.recognize(v, minHeight: 1080) else { continue }
            let size = CGSize(width: v.width, height: v.height)
            let h = HudReader.refine(HudReader.read(texts: texts, viewport: size), texts: texts, image: v)
            let badge = HudReader.moneyBadge(v).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
            print("\((p as NSString).lastPathComponent) round=\(h.round.map(String.init) ?? "-") money=\(h.money.map(String.init) ?? "-") level=\(h.level.map(String.init) ?? "-") rest=\(h.isRest) battle=\(h.inBattle) other=\(h.otherBoard) badge=\(badge)")
        }
    }

    /// `--make-level-templates out.json 4:a.png 4:b.png 5:c.png …` (images: window captures or saved debug frames).
    static func makeLevelTemplates(out: String, _ items: [String]) {
        var rows: [[String: Any]] = []
        for it in items {
            let parts = it.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let lv = Int(parts[0]),
                  let img = NSImage(contentsOfFile: parts[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let vp = Viewport.find(PixelBuffer(img), insets: CropInsets())
            guard let v = img.cropped(vp), let texts = try? OCR.recognize(v, minHeight: 1080),
                  let a = HudReader.levelAnchor(texts, CGSize(width: v.width, height: v.height)),
                  let m = HudReader.levelGlyphMask(v, art: HudReader.levelArt(v, anchor: a)) else { print("skip \(it)"); continue }
            let classified = LevelGlyphs.classify(m)
            print("\(lv) \((parts[1] as NSString).lastPathComponent) current=\(classified.map(String.init) ?? "-")")
            rows.append(["level": lv, "mask": LevelGlyphs.encode(m)])
        }
        if let d = try? JSONSerialization.data(withJSONObject: rows) { try? d.write(to: URL(fileURLWithPath: out)) }
        print("wrote \(rows.count) templates")
    }

    /// --sklandtest: 森空岛 request signature, history parsing and merging with local matches (synthetic data, no network).
    static func runSklandTest() {
        print("sign: " + SklandParse.sign(path: "/api/v1/game/player/binding", query: "", timestamp: "1700000000", token: "test-token"))
        print("sign query: " + SklandParse.sign(path: "/web/v1/game/garrison/guide/history-log", query: "seasonId=act3autochess",
                                                 timestamp: "1700000000", token: "test-token"))
        let catalogJSON: [String: Any] = ["code": 0, "data": [
            "chars": [["charId": "char_a", "name": "极光"], ["charId": "char_b", "name": "艾丝黛尔"]],
            "items": [["itemId": "i1", "name": "维式重锤"]],
            "strategies": [["strategyId": "band_x", "name": "众志合一"]],
            "bonds": [["bondId": "yanShip", "name": "炎"]],
            "versionInfo": ["seasonId": "act3autochess", "versionId": "V3_1"]]]
        let t0 = 1_700_000_000
        func rec(_ id: String, start: Int, end: Int, round: Int, done: Int) -> [String: Any] {
            ["id": id, "gameStartTs": String(start), "gameEndTs": String(end), "modeType": "MULTI", "modeDifficulty": "NORMAL",
             "passRound": round, "completeState": done, "bandId": "band_x", "coinCost": 120, "killCnt": 300,
             "chessSquad": [["charId": "char_a", "chessId": "c_a_b", "chessInfo": ["goldenChessId": "c_a_b"]],
                            ["charId": "char_b", "chessId": "c_b", "chessInfo": ["goldenChessId": "c_b_b"]]],
             "bondInfo": [["bondId": "yanShip", "layer": 3]],
             "acBossInfo": [["bossId": "boss_1", "isKilled": true]]]
        }
        let historyJSON: [String: Any] = ["code": 0, "data": ["records": [
            rec("r1", start: t0, end: t0 + 1800, round: 14, done: 1),
            rec("r2", start: t0 + 7200, end: t0 + 8000, round: 6, done: 0),
            rec("r1", start: t0, end: t0 + 1800, round: 14, done: 1)]]]
        do {
            let cat = try SklandCatalog(json: catalogJSON)
            let ms = try SklandParse.history(historyJSON, cat) { $0 == "enemy_9013_acstmk" ? "假想敌：胄" : nil }
            for m in ms {
                print("match \(m.id): \(m.multiplayer ? "联机" : "单人") \(m.mode) rounds=\(m.rounds) success=\(m.success) strategy=\(m.strategy ?? "-") "
                      + "lineup=\(m.lineup.joined(separator: "、")) elites=\(m.elites.joined(separator: "、")) covenants=\(m.covenants.joined(separator: "、")) "
                      + "bosses=\(m.bosses.joined(separator: "、"))")
            }
            MainActor.assumeIsolated {
                let h = MatchHistory()
                h.enabled = false
                let local = MatchRecord(started: Date(timeIntervalSince1970: TimeInterval(t0 + 20)), ended: Date(timeIntervalSince1970: TimeInterval(t0 + 1700)),
                                        mode: "险境模拟", strategy: "众志合一", map: "m05", rounds: 13, lineup: ["极光"], covenants: ["炎Ⅰ"],
                                        route: "炎", rank: 2)
                h.useForTest([local])
                let a = h.merge(ms), b = h.merge(ms)
                print("merge (want added 1 merged 1, then unchanged 2): added \(a.added) merged \(a.merged) unchanged \(a.unchanged); again unchanged \(b.unchanged)")
                for (days, after) in [(7, 2), (7, 10), (30, 10)] {
                    let st = h.stats(days: days, now: Date(timeIntervalSince1970: TimeInterval(t0 + after * 86400)))
                    let rate = st.clearRate.map { String(format: "%.0f%%", $0 * 100) } ?? "-", spent = st.averageSpent.map { String(format: "%.0f", $0) } ?? "-"
                    print("stats \(days)d at day \(after): matches \(st.matches) clear \(rate) spent \(spent)")
                }
                for r in h.records {
                    print("record \(r.sklandId ?? "-"): rounds=\(r.rounds) rank=\(r.rank.map(String.init) ?? "-") map=\(r.map ?? "-") route=\(r.route ?? "-") lineup=\(r.lineup.joined(separator: "、")) boss=\(r.boss ?? "-")")
                }
            }
            do { _ = try SklandParse.data(["code": 10002, "message": "x"]) } catch { print("expired: " + (error.localizedDescription)) }
            // Lineup guides: links, share text, bare ids; tabs → stages (成型 last), names from seasonResourceMap.
            for t in ["https://game.skland.com/arknights/stronghold-guide/detail?guideId=2120358988790611711",
                      "【森空岛】巫王驾到！ https://game.skland.com/arknights/stronghold-guide/detail?guideId=123456789&from=share 复制打开",
                      "2120358988790611711", "https://example.com/detail?guideId=1", "guideId=abc"] {
                print("guide id: \(SklandParse.guideID(t) ?? "-")")
            }
            let res: [String: Any] = ["chars": ["char_a": ["name": "极光"], "char_b": ["name": "艾丝黛尔"]], "items": ["i1": ["name": "维式重锤"]],
                                      "strategies": ["band_x": ["name": "众志合一"]], "bonds": ["yanShip": ["name": "炎"]]]
            let guideJSON: [String: Any] = ["code": 0, "data": [
                "guide": ["invalid": 0, "poster": ["nickname": "作者"], "guide": [
                    "title": "测试阵容", "seasonId": "s1", "versionId": "V3_1", "strategyIds": ["band_x"],
                    "tabs": [["tabType": 1, "startRound": 0, "endRound": 0, "recChars": [["charId": "char_a", "mergeLevel": 1], ["charId": "char_b", "mergeLevel": 0]],
                              "recItems": [["itemId": "i1"]], "activeBonds": ["seasonBondIds": ["yanShip"], "regularBondIds": ["jingShip"]], "operationIdea": "思路"],
                             ["tabType": 2, "startRound": 1, "endRound": 7, "recChars": [["charId": "char_b"], ["charId": "char_c"]], "recItems": [], "operationIdea": ""]]]],
                "seasonResourceMap": ["s1": ["versionResourceMap": ["V3_1": res]]]]]
            let l = try SklandParse.lineup(guideJSON, id: "42", now: Date(timeIntervalSince1970: 0))
            print("lineup \(l.title) by \(l.author) strategies=\(l.strategies.joined(separator: "、")) url=\(l.url.absoluteString)")
            for st in l.stages {
                let ops: String = st.ops.map { $0.name + ($0.elite ? "★" : "") }.joined(separator: "、")
                let eq: String = st.equipment.joined(separator: "、"), cov: String = st.covenants.joined(separator: "、")
                print("  \(st.title): \(ops) | 装备 \(eq) | 盟约 \(cov) | \(st.notes)")
            }
            print("stage for round 3: \(l.stage(round: 3)?.title ?? "-"); round 9: \(l.stage(round: 9)?.title ?? "-"); unknown: \(l.stage(round: nil)?.title ?? "-")")
            do { _ = try SklandParse.lineup(["code": 0, "data": ["guide": ["invalid": 1, "guide": [:]]]], id: "1") } catch { print("invalid: " + error.localizedDescription) }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }

    /// --sklandguide <guideId | link | saved info JSON>: a real 森空岛 lineup guide (network unless a file), and what
    /// 「照这套打」 would lock. Manual check only.
    static func runSklandGuide(_ arg: String) { MainActor.assumeIsolated { sklandGuide(arg) } }

    @MainActor private static func sklandGuide(_ arg: String) {
        do {
            let catalog = Catalog()
            var l: SklandLineup?
            if FileManager.default.fileExists(atPath: arg), let d = FileManager.default.contents(atPath: arg), let j = try? JSONSerialization.jsonObject(with: d) {
                l = try? SklandParse.lineup(j, id: "file")
            } else if let id = SklandParse.guideID(arg) {
                let sem = DispatchSemaphore(value: 0)
                Task.detached { l = try? await SklandClient().guide(id: id); sem.signal() }
                while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            }
            guard let l else { print("读不到"); return }
            print("\(l.title) · 策略 \(l.strategies.joined(separator: "、"))")
            let names = Set(catalog.operators.map(\.name))
            for st in l.stages {
                let ops: [String] = st.ops.map { o in o.name + (o.elite ? "★" : "") + (names.contains(o.name) ? "" : "(不在图鉴)") }
                print("  \(st.title): \(ops.joined(separator: "、"))")
            }
            let p = SklandLineupLibrary.lockable(l, catalog: catalog, selfSelected: [], people: 8)
            let lock: String = p.lock.joined(separator: ","), skip: String = p.skipped.joined(separator: ","), over: String = p.over.joined(separator: ",")
            print("必带: \(lock)  跳过: \(skip)  超员: \(over)")
        }
    }
}
