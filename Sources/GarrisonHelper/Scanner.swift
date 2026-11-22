// Portions adapted from StrongholdAssistant (Apache-2.0) and rewritten in Swift for this Mac app; the upstream files are listed
// in REFERENCES.md and their licenses / NOTICEs are in licenses/.
import AppKit
import Foundation
import SwiftUI

/// Drives capture → OCR → recognition, and the on-screen overlay.
@MainActor
final class Scanner: ObservableObject {
    @Published var windows: [GameWindow] = []
    @Published var selectedWindowID: CGWindowID? {
        didSet { UserDefaults.standard.set(selectedWindowLabel, forKey: "lastWindowLabel") }
    }
    @Published var status = "未开始"
    /// 实时识别：回合/资金/终端等级/顶栏盟约 + 购买记录。
    @Published var live = false { didSet { live ? startShopLoop() : stopShopLoop() } }
    @Published var lastPrep: PreparationResult?
    @Published var busy = false
    @Published var dockSidebar = UserDefaults.standard.bool(forKey: "dockSidebar") {
        didSet { UserDefaults.standard.set(dockSidebar, forKey: "dockSidebar") }
    }
    @Published var scanInterval = max(0.5, UserDefaults.standard.double(forKey: "scanInterval").nonZero ?? 1.0) {
        didSet { UserDefaults.standard.set(scanInterval, forKey: "scanInterval") }
    }
    @Published var insets: CropInsets = {
        if let d = UserDefaults.standard.data(forKey: "cropInsets"), let v = try? JSONDecoder().decode(CropInsets.self, from: d) { return v }
        return CropInsets()
    }() {
        didSet { if let d = try? JSONEncoder().encode(insets) { UserDefaults.standard.set(d, forKey: "cropInsets") } }
    }

    private let catalog: Catalog
    private let run: RunState
    private var loop: Task<Void, Never>?
    var sidebarWindow: NSWindow?

    init(catalog: Catalog, run: RunState) {
        self.catalog = catalog
        self.run = run
    }

    var selectedWindowLabel: String? { windows.first { $0.id == selectedWindowID }?.label }

    /// No screen-recording permission: the run view shows how to grant it. Nothing asks the system on its own.
    @Published var needsPermission = !ScreenCapture.hasPermission
    /// Settings shows the app ticked, but the tick belongs to an earlier build (capture refused anyway).
    @Published var permissionStale = false

    private func notePermissionError(_ error: Error) -> Bool {
        guard !ScreenCapture.hasPermission || ScreenCapture.isDeclined(error) else { return false }
        needsPermission = true
        permissionStale = ScreenCapture.hasPermission
        return true
    }

    func refreshWindows() async {
        needsPermission = !ScreenCapture.hasPermission
        if needsPermission { status = ScreenCapture.permissionHint; return }
        do {
            windows = try await ScreenCapture.listWindows()
            if selectedWindowID == nil || !windows.contains(where: { $0.id == selectedWindowID }) {
                let last = UserDefaults.standard.string(forKey: "lastWindowLabel")
                selectedWindowID = windows.first(where: { $0.label == last })?.id ?? windows.first?.id
            }
            if ScreenCapture.hasPermission { status = "找到 \(windows.count) 个窗口" }
        } catch {
            status = notePermissionError(error) ? ScreenCapture.permissionHint : "无法列出窗口：\(error.localizedDescription)"
        }
    }

    private struct Frame {
        let image: CGImage
        let pixels: PixelBuffer
        let viewport: CGRect
        let windowFrame: CGRect
    }

    private func grab() async throws -> Frame {
        guard ScreenCapture.hasPermission else { needsPermission = true; throw ScreenCapture.permissionError() }
        guard let id = selectedWindowID else {
            throw NSError(domain: "Scanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先选择游戏窗口"])
        }
        let image: CGImage, frame: CGRect
        do {
            (image, frame) = try await ScreenCapture.capture(windowID: id)
        } catch {
            if notePermissionError(error) { throw ScreenCapture.permissionError() }
            throw error
        }
        let px = PixelBuffer(image)
        let vp = Viewport.find(px, insets: insets.scaled(by: Double(image.width) / max(1, frame.width)))
        if dockSidebar { dock(to: frame) }
        return Frame(image: image, pixels: px, viewport: vp, windowFrame: frame)
    }

    // MARK: 准备页识别

    func scanPreparation() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        status = "正在识别准备页…"
        do {
            let f = try await grab()
            guard let full = f.image.cropped(f.viewport) else { throw NSError(domain: "Scanner", code: 2) }
            let vpImage = OCR.downscale(full, maxHeight: Scanner.workHeight)
            let texts = try await Task.detached { try OCR.recognizeScreen(vpImage) }.value
            let (r, specials) = applyPreparation(texts: texts, image: vpImage)
            if r.isPreparationPage {
                status = "识别完成：禁用 \(r.banned.count) 个，可用 \(r.available.count) 个" + (r.uncertain.isEmpty ? "" : "，\(r.uncertain.count) 个无法判断（可手动点选）")
                    + (specials.isEmpty ? "" : "，特训敌人 \(specials.count) 个")
            } else {
                status = "没找到“核心盟约 / 附加盟约”。请停在「确认本局信息」页再试" + (r.boss != nil ? "（已识别敌方领袖）" : "")
            }
        } catch {
            status = "识别失败：\(error.localizedDescription)"
        }
    }

    /// Reads the 「确认本局信息」 page (bans, 敌方领袖, 特训敌人) into the run. Used by 截屏录入本局 and by the live loop.
    @discardableResult
    func applyPreparation(texts: [OCRText], image: CGImage) -> (PreparationResult, [String]) {
        let r = PreparationRecognizer.analyze(texts: texts, pixels: PixelBuffer(image), viewport: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                                              covenants: catalog.covenants, bosses: catalog.bosses)
        lastPrep = r
        if let boss = r.boss { run.bossName = boss }
        let variantNames = Set(catalog.enemyTypes.flatMap { $0.variants.map(\.enemyName) }).filter { $0.count >= 2 }
        let specials = variantNames.filter { n in texts.contains { $0.text.contains(n) } }.sorted()
        if !specials.isEmpty { run.specialEnemies = specials }
        if r.isPreparationPage { run.bannedCovenants = Set(r.banned) }
        return (r, specials)
    }

    // MARK: 实时识别（商店高亮 + 回合/资金/终端等级 + 顶栏盟约 + 购买记录）

    @Published var hud = HudReading()
    /// Round read on the last full read itself (nil when not visible), unlike `hud.round`, which keeps the last value.
    var frameRound: Int?
    /// Funds at the start of the current round (for the next-round forecast).
    var roundStart = RoundStartTracker()
    /// A round read far above the last one, waiting to be confirmed: the value, when it was first read, how many reads agree.
    private var roundJump: (value: Int, since: Date, reads: Int)?
    /// Called with the work image when a full read starts (the coach reads units and the board in parallel).
    var onFullRead: ((CGImage) -> Void)?
    /// Screen-change detection.
    static let changeThreshold = 0.8
    private var lastSignature: ScreenSignature?
    private var lastFullRead = Date.distantPast
    /// Last processed frame (as a non-full read), reused while the screen doesn't change.
    private var lastFrame: LiveFrame?
    @Published var bar: [BarReading] = []
    @Published var lastPurchase: String?
    private var purchases = PurchaseTracker()
    private var tick = 0
    /// Slower ticks while nothing needs reading (eliminated: only watch for the next match).
    var idleInterval: Double?

    private func startShopLoop() {
        loop?.cancel()
        tick = 0
        lastSignature = nil
        lastFrame = nil
        lastFullRead = .distantPast
        OCRWorkerClient.shared.warmUp()
        OCR.warmUp()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.scanShopOnce()
                try? await Task.sleep(nanoseconds: UInt64((self.idleInterval ?? self.scanInterval) * 1_000_000_000))
            }
        }
    }

    var onStop: (() -> Void)?

    private func stopShopLoop() {
        loop?.cancel()
        loop = nil
        onStop?()
        status = "实时识别已停止"
    }

    /// Last frame's controls and shop, for action highlights.
    @Published var controls = GameControls()
    @Published var cards: [ShopCard] = []
    private var shopKey = ""
    private var shopRead = ShopPriceReader.Result()
    /// Called after each live tick with the frame (viewport image, geometry); the coach computes actions.
    var onFrame: ((LiveFrame) async -> Void)?

    struct LiveFrame {
        let image: CGImage           // game area, downscaled work image
        let windowFrame: CGRect      // points
        let viewport: CGRect         // pixels inside the window capture (full resolution)
        let pxPerPt: Double          // work-image pixels per point
        let originPt: CGPoint        // game area origin inside the window, points
        let fullRead: Bool           // HUD/controls were re-read this tick
        var shopOpen: Bool
        func toWindow(_ p: CGPoint) -> CGPoint { CGPoint(x: originPt.x + p.x / pxPerPt, y: originPt.y + p.y / pxPerPt) }
        /// Same frame, window moved (the overlay follows the window).
        func with(windowFrame w: CGRect) -> LiveFrame {
            LiveFrame(image: image, windowFrame: w, viewport: viewport, pxPerPt: pxPerPt, originPt: originPt, fullRead: fullRead, shopOpen: shopOpen)
        }
    }

    /// Full-screen OCR of the last full read (for the choice-popup readers and debug capture).
    var lastTexts: [OCRText] = []
    /// A purchase was confirmed (name may be an operator or equipment).
    var onPurchase: ((String) -> Void)?

    func scanShopOnce() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await process(try await grab())
        } catch {
            if needsPermission || notePermissionError(error) {
                // Stop instead of retrying every tick: each attempt could bring the system prompt up again.
                if live { live = false }
                status = ScreenCapture.permissionHint
                return
            }
            status = "截图失败：\(error.localizedDescription)"
        }
    }

    /// Offline replay of a saved window capture through the live pipeline (self-test).
    func replay(_ image: CGImage) async {
        replaying = true
        replayClock += 0.5   // replays read every frame twice: about one second of game time per frame
        if ProcessInfo.processInfo.environment["REPLAY_LIVE"] == nil { tick = 0 }     // every replayed frame is a full read
        let f = Frame(image: image, pixels: PixelBuffer(image), viewport: Viewport.find(PixelBuffer(image), insets: CropInsets()),
                      windowFrame: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        try? await process(f)
    }
    private var replaying = false
    /// Time as replays see it (they run at whatever speed the machine allows), so time-based rules give the same result
    /// on every run.
    private var replayClock = Date(timeIntervalSince1970: 0)
    /// Now, as replays see it (time-based rules elsewhere use this too).
    var clock: Date { replaying ? replayClock : Date() }
    var isReplaying: Bool { replaying }

    private func process(_ f: Frame) async throws {
        do {
            TickTiming.begin()
            guard let fullVp = f.image.cropped(f.viewport) else { return }
            let vpImage = OCR.downscale(fullVp, maxHeight: Scanner.workHeight)
            let vpSize = CGSize(width: vpImage.width, height: vpImage.height)
            let workScale = Double(fullVp.width) / Double(vpImage.width)   // full px per work px
            // Read when the screen changed: every tick between battles (decisions happen then), every third tick in a
            // fight. An unchanged screen (idle frames differ by < 0.6, any real change by > 1) reuses the last reading,
            // with a safety read every few seconds.
            let sig = ScreenSignature(vpImage)
            let changed = lastSignature.map { sig.distance($0) >= Scanner.changeThreshold } ?? true
            let sinceFull = Date().timeIntervalSince(lastFullRead)
            // REPLAY_LIVE=1: a replay follows the live scheduling (to test it); otherwise every replayed frame is read.
            let forceFull = replaying && ProcessInfo.processInfo.environment["REPLAY_LIVE"] == nil
            let full = forceFull || (changed && (hud.isRest || tick % 3 == 0)) || sinceFull >= (hud.isRest ? 6 : 4)
            if !full && !changed && !forceFull, let frame = lastFrame?.with(windowFrame: f.windowFrame) {
                // Nothing new on screen: refresh the advice and overlay from what is already known.
                tick += 1
                TickTiming.mark("画面没变")
                await onFrame?(frame)
                return
            }
            lastSignature = sig
            // The shop strip is read in this process at the same time as the full-screen text in the worker; if the
            // local read fails (Vision stuck in this process) it goes through the worker afterwards.
            let strip = ShopRecognizer.stripRect(viewport: vpSize)
            guard let stripImage = vpImage.cropped(strip) else { return }
            let stripTask = Task.detached { try? OCR.recognizeLocal(stripImage, minHeight: 120) }
            if full {
                lastFullRead = Date()
                // Units and the board are read alongside the text (Neural Engine / CPU while the OCR worker runs).
                onFullRead?(vpImage)
                let texts = try await Task.detached { try OCR.recognizeScreen(vpImage) }.value
                TickTiming.mark("全屏OCR")
                var h = HudReader.refine(HudReader.read(texts: texts, viewport: vpSize), texts: texts, image: vpImage)
                decideBoardOwner(&h, texts: texts, image: vpImage)
                // Rounds go up one at a time: a jump of more than two (9 read as 19) counts only after three agreeing reads
                // over at least 5 s. Two reads weren't enough: 2026-11-22 20:01:58 the frame left of 「5」 was read as a 1
                // on two frames in a row and round 5 became 15 for 5 s.
                if let r = h.round, let prev = hud.round, r > prev + 2 {
                    let now = replaying ? replayClock : Date()
                    if let j = roundJump, j.value == r {
                        roundJump = (r, j.since, j.reads + 1)
                    } else {
                        roundJump = (r, now, 1)
                    }
                    if let j = roundJump, j.reads >= 3, now.timeIntervalSince(j.since) >= 5 { roundJump = nil } else { h.round = nil }
                } else { roundJump = nil }
                frameRound = h.round
                TickTiming.mark("HUD")
                // Keep the last confirmed value when a field is unreadable this frame.
                // Funds and level only count on our own board between battles (the badge is covered or shows garbage otherwise).
                let own = h.isRest && !h.inBattle && !h.otherBoard
                hud = HudReading(round: h.round ?? (h.bossRound ? nil : hud.round), money: own ? h.money ?? ((h.round ?? hud.round) == hud.round ? hud.money : nil) : hud.money,
                                 level: own ? h.level ?? hud.level : hud.level,
                                 remainingDeploy: h.remainingDeploy ?? hud.remainingDeploy, isRest: h.isRest,
                                 bossRound: h.bossRound, otherBoard: h.otherBoard,
                                 coDefense: h.coDefense, boardTag: h.boardTag, inBattle: h.inBattle)
                hud.playerList = h.playerList
                roundStart.observe(round: hud.round, money: h.money, ownRest: own)
                lastTexts = texts
                // In 联防 the bar shows the board owner's covenants with stacking disabled: keep the rest-phase reading.
                if !h.otherBoard && !h.coDefense {
                    let b = CovenantBarReader.read(texts: texts, image: vpImage, covenants: catalog.covenants)
                    if !b.isEmpty { bar = b }
                }
                TickTiming.mark("顶栏")
                let c = await Task.detached { GameControls.read(texts: texts, image: vpImage) }.value
                TickTiming.mark("按钮")
                controls = GameControls(refresh: c.refresh, freeze: c.freeze, frozen: c.frozen, level: c.level, levelX: c.levelX, levelY: c.levelY, maxed: c.maxed,
                                        upgradeCost: c.level != nil && c.level == controls.level ? controls.upgradeCost : nil,
                                        refreshCost: c.refreshCost ?? controls.refreshCost)
            }
            tick += 1
            // The strip is in work-image pixels (cropped from the work image: a Retina capture is 2× larger).
            let texts: [OCRText]
            if let local = await stripTask.value { texts = local }
            else { texts = try await Task.detached { try OCR.recognize(stripImage, minHeight: 120) }.value }
            TickTiming.mark("商店OCR")
            if ProcessInfo.processInfo.environment["STRIP_DEBUG"] != nil { print("strip \(stripImage.width)x\(stripImage.height): " + texts.map { "\(Int($0.box.minX)),\(Int($0.box.minY)) \($0.text)" }.joined(separator: " | ")) }
            var all = ShopRecognizer.find(texts: texts, stripOrigin: strip.origin, viewport: vpSize,
                                          tracked: nil, catalog: catalog.shopNames, labels: catalog.covenants.map(\.name))
            resolvePrototypes(&all, viewport: vpSize)
            guard live || replaying else { return }
            // Prices and card centres: re-read when the cards change; upgrade cost with the controls.
            let key = all.map { "\($0.slot(viewport: vpSize))-\($0.name)" }.joined(separator: "|")
            if key != shopKey || (full && controls.levelX != nil) {
                let levelX = controls.levelX, levelY = controls.levelY
                let r = await Task.detached { ShopPriceReader.read(vpImage, cards: all, levelX: levelX, levelY: levelY) }.value
                shopRead = r
                shopKey = key
                if let u = r.upgradeCost { controls.upgradeCost = u }
            }
            cards = Scanner.sanePrices(all.map { h in
                let slot = h.slot(viewport: vpSize)
                return ShopCard(name: h.name, slot: slot, rect: h.rect, price: shopRead.prices[slot], shownAs: h.shownAs)
            }, tier: { [catalog] n in catalog.op(n)?.tier })
            // Purchases → 持有干员
            let slots = Dictionary(all.map { ($0.slot(viewport: vpSize), $0.name) }, uniquingKeysWith: { a, _ in a })
            let ownBoard = !hud.otherBoard && !hud.inBattle
            for name in purchases.update(cards: slots, money: hud.money, shopVisible: ownBoard && !all.isEmpty) {
                lastPurchase = name
                onPurchase?(name)
            }
            var parts: [String] = []
            if let r = hud.round { parts.append("第\(r)回合") }
            if let m = hud.money { parts.append("资金\(m)") }
            if let l = hud.level { parts.append("\(l)本") }
            if let p = lastPurchase { parts.append("刚买入 \(p)") }
            status = "实时识别中 · " + (parts.isEmpty ? "等待画面" : parts.joined(separator: " · "))
            let pxPerPt = Double(f.image.width) / max(1, f.windowFrame.width)
            let frame = LiveFrame(image: vpImage, windowFrame: f.windowFrame, viewport: f.viewport,
                                  pxPerPt: pxPerPt / workScale, originPt: CGPoint(x: f.viewport.minX / pxPerPt, y: f.viewport.minY / pxPerPt),
                                  fullRead: full, shopOpen: !all.isEmpty || controls.refresh != nil)
            TickTiming.mark("卡价")
            lastFrame = LiveFrame(image: frame.image, windowFrame: frame.windowFrame, viewport: frame.viewport, pxPerPt: frame.pxPerPt,
                                  originPt: frame.originPt, fullRead: false, shopOpen: frame.shopOpen)
            await onFrame?(frame)
            if TickTiming.enabled { print("tick " + TickTiming.summary()) }
        } catch {
            // Capture already worked here: what fails is Vision's text reader. Once it is stuck it stays stuck inside
            // this process, so after a few failed ticks in a row say that restarting helps.
            ocrFailures += 1
            let low = DebugRecorder.freeGB().flatMap { $0 < 30 ? $0 : nil }
            status = (ocrFailures >= 5 ? "文字识别连续出错，正在重启识别进程" : "文字识别出错，已重启识别进程，下一轮重试")
                + (low.map { String(format: "。磁盘只剩 %.0f GB，系统会清掉识别模型的缓存：清理出 30 GB 以上能根治", $0) } ?? "")
            return
        }
        ocrFailures = 0
    }

    /// Ticks in a row whose text recognition failed.
    private var ocrFailures = 0

    /// Operator price by tier, from every shop read in the user's debug matches (2026-11-22: T1 2 ×549, T2 3 ×781,
    /// T3 3 ×520, T4 3 ×286, T5 4 ×117; the stray 1 / 11 / 12 reads were misreads). 0 = the free card after a 3-merge.
    nonisolated static let operatorPrice: [Int: Int] = [1: 2, 2: 3, 3: 3, 4: 3, 5: 4]

    /// An operator card whose price disagrees with its tier was misread (a grey "can't afford" badge read 3 as 1) and gets
    /// the tier price — unless most operator cards disagree the same way (a real discount from a strategy or covenant).
    static func sanePrices(_ cards: [ShopCard], tier: (String) -> Int?) -> [ShopCard] {
        let checked = cards.compactMap { c -> (Int, Int)? in
            guard let t = tier(c.name), let want = operatorPrice[t], let p = c.price, p != 0 else { return nil }
            return (p, want)
        }
        guard !checked.isEmpty else { return cards }
        let agree = checked.filter { $0.0 == $0.1 }.count
        guard agree * 2 >= checked.count else { return cards }
        return cards.map { c in
            guard let t = tier(c.name), let want = operatorPrice[t], c.price != 0, c.price != want else { return c }
            var fixed = c
            fixed.price = want
            return fixed
        }
    }

    /// slot-stand-in → real operator, kept while the same stand-in card stays in that slot.
    private var protoCache: [String: String] = [:]

    /// A card showing a stand-in model (Pith, Sharp, 郁金香 …) is an operator the player doesn't own; the covenant labels
    /// printed above its name (full-screen OCR) and the terminal level tell which one (StrongholdAssistant
    /// RosterReader.Prototypes / PrototypeCatalog.Resolve do the same with the card's covenant icons).
    func resolvePrototypes(_ hits: inout [ShopHit], viewport: CGSize) {
        let covNames = catalog.covenants.map(\.name)
        var keep: [String: String] = [:]
        for i in hits.indices where catalog.prototypes[hits[i].name] != nil {
            let shown = hits[i].name, r = hits[i].rect
            let key = "\(hits[i].slot(viewport: viewport))-\(shown)"
            if let real = protoCache[key] {
                keep[key] = real
                hits[i].shownAs = shown; hits[i].name = real
                continue
            }
            let inCard = lastTexts.filter { $0.box.midX > r.minX && $0.box.midX < r.maxX && $0.box.midY > r.minY + r.height * 0.35 && $0.box.midY < r.maxY }
            // The full read must show this very card (not the one that was in the slot before a refresh / purchase).
            guard inCard.contains(where: { OCR.normalize($0.text).contains(OCR.normalize(shown)) }) else { continue }
            let labels = Set(inCard.flatMap { t in covNames.filter { t.text.contains($0) } })
            if let real = catalog.resolvePrototype(shown, labels: labels, maxTier: hud.level) {
                keep[key] = real
                hits[i].shownAs = shown; hits[i].name = real
            }
        }
        protoCache = keep
    }

    /// 联防 board owner from the last tag seen this round (frames around 「联防开始」 / the end show no tag).
    private var coDefenseOwner: (round: Int?, own: Bool)?

    /// In 联防 the board shown may be ours or the partner's. The tag under the board says which; without one, the top bar
    /// (it shows the board owner's covenants) is compared with ours, then the last tag of this round is used.
    func decideBoardOwner(_ h: inout HudReading, texts: [OCRText], image: CGImage) {
        guard h.coDefense else { return }
        let round = h.round ?? hud.round
        if let tag = h.boardTag {
            coDefenseOwner = (round, tag == "自己")
            return
        }
        let shown = Set(CovenantBarReader.read(texts: texts, image: image, covenants: catalog.covenants).map(\.name))
        let mine = Set(bar.map(\.name))
        if shown.count >= 2 && mine.count >= 2 {
            let same = Double(shown.intersection(mine).count) / Double(shown.union(mine).count)
            h.otherBoard = same < 0.6
        } else if let last = coDefenseOwner, last.round == round {
            h.otherBoard = !last.own
        }
    }

    /// One capture of the game area (for AI analysis).
    func captureViewport() async throws -> CGImage {
        let f = try await grab()
        guard let img = f.image.cropped(f.viewport) else { throw NSError(domain: "Scanner", code: 3) }
        return OCR.downscale(img, maxHeight: Scanner.workHeight)
    }

    /// Recognition runs on the game area downscaled to at most this height (Retina captures are 2× larger).
    static let workHeight = 1200

    /// Reads HUD + covenant bar once (button in the route page).
    func readStateOnce() async {
        do {
            let img = try await captureViewport()
            let texts = try await Task.detached { try OCR.recognizeScreen(img) }.value
            let size = CGSize(width: img.width, height: img.height)
            var h = HudReader.refine(HudReader.read(texts: texts, viewport: size), texts: texts, image: img)
            decideBoardOwner(&h, texts: texts, image: img)
            hud = HudReading(round: h.round ?? hud.round, money: h.money ?? hud.money, level: h.level ?? hud.level,
                             remainingDeploy: h.remainingDeploy ?? hud.remainingDeploy, isRest: h.isRest,
                             bossRound: h.bossRound, otherBoard: h.otherBoard,
                             coDefense: h.coDefense, boardTag: h.boardTag, inBattle: h.inBattle)
            if !h.otherBoard && !h.coDefense { bar = CovenantBarReader.read(texts: texts, image: img, covenants: catalog.covenants) }
            status = "已读取局面：" + [hud.round.map { "第\($0)回合" }, hud.money.map { "资金\($0)" }, hud.level.map { "\($0)本" }]
                .compactMap { $0 }.joined(separator: " · ") + (bar.isEmpty ? "" : " · 顶栏盟约 \(bar.count) 个")
        } catch {
            status = "读取失败：系统文字识别暂时忙，过一秒再点一次" + (live ? "（实时识别开着时不用手动读）" : "")
        }
    }

    // MARK: Debug

    func saveDebugCapture() async {
        do {
            let f = try await grab()
            let texts = try OCR.recognizeScreen(f.image.cropped(f.viewport) ?? f.image)
            let lines = ["window=\(f.windowFrame) image=\(f.image.width)x\(f.image.height) viewport=\(f.viewport)"]
                + texts.map { "\(Int($0.box.minX)),\(Int($0.box.minY)) \(Int($0.box.width))x\(Int($0.box.height))\t\($0.text)" }
            let png = try DebugRecorder.saveSnapshot(image: f.image, text: lines.joined(separator: "\n"))
            status = "已保存到 卫戍助手调试/手动截图/\(png.lastPathComponent)（含 OCR 文本）"
        } catch {
            status = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: Sidebar docking

    private func dock(to gameFrame: CGRect) {
        guard let win = sidebarWindow, let primary = NSScreen.screens.first else { return }
        let cocoaTop = primary.frame.height - gameFrame.minY
        var origin = CGPoint(x: gameFrame.maxX + 4, y: cocoaTop - win.frame.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: gameFrame.midX, y: primary.frame.height - gameFrame.midY)) }),
           origin.x + win.frame.width > screen.visibleFrame.maxX {
            origin.x = screen.visibleFrame.maxX - win.frame.width  // no room: overlap the game's right edge
        }
        if abs(win.frame.origin.x - origin.x) > 2 || abs(win.frame.origin.y - origin.y) > 2 {
            win.setFrameOrigin(origin)
        }
    }
}

extension Double { var nonZero: Double? { self == 0 ? nil : self } }

extension CropInsets {
    func scaled(by k: Double) -> CropInsets { CropInsets(top: top * k, bottom: bottom * k, left: left * k, right: right * k) }
}

