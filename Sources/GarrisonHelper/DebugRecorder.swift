import AppKit
import Foundation

/// 调试模式：实时识别时把画面和识别结果存到小助手所在文件夹下的「卫戍助手调试/」，每局一个文件夹（开局日期_时间）。
/// - Only what changed is kept: while the readings stay the same (and the screen doesn't change a lot) one frame per
///   30 s, and fights (the board moves all the time) are sampled every 10 s.
/// - At most `maxPerMatch` frames per match; nothing is saved below `minFreeGB` of free disk (a nearly full disk makes
///   macOS purge the caches OCR depends on).
/// - The 「保存当前截图」 button writes to 「卫戍助手调试/手动截图/」.
enum DebugRecorder {
    /// 「卫戍助手调试」 next to 卫戍协议小助手.app (command-line runs: next to the executable).
    static var folder: URL {
        let bundle = Bundle.main.bundleURL
        let base = bundle.pathExtension == "app" ? bundle.deletingLastPathComponent()
                                                 : (Bundle.main.executableURL?.deletingLastPathComponent() ?? bundle)
        return base.appendingPathComponent("卫戍助手调试", isDirectory: true)
    }
    static var snapshotFolder: URL { folder.appendingPathComponent("手动截图", isDirectory: true) }

    static let maxPerMatch = 1000
    /// Between battles at most one frame this often (every tick is read now, ~1 s apart).
    static let restInterval: TimeInterval = 2
    static let minFreeGB = 15.0
    static let battleInterval: TimeInterval = 10
    static let unchangedInterval: TimeInterval = 30
    /// A save after this long a pause, or with the round number going back, starts a new match folder.
    static let newMatchGap: TimeInterval = 15 * 60

    private static let queue = DispatchQueue(label: "debug-recorder", qos: .utility, autoreleaseFrequency: .workItem)
    // Recorder state (only touched on `queue`).
    nonisolated(unsafe) private static var matchDir: URL?
    nonisolated(unsafe) private static var savedInMatch = 0
    nonisolated(unsafe) private static var lastSave: Date?
    nonisolated(unsafe) private static var lastRound: Int?
    nonisolated(unsafe) private static var lastBattleSave: Date?
    nonisolated(unsafe) private static var lastInfo: String?
    nonisolated(unsafe) private static var lastThumb: [UInt8] = []

    /// Why the last frame wasn't saved (no space, folder not writable, cap reached); nil when saving works.
    nonisolated(unsafe) static var problem: String?

    /// Free space on the data volume in GB (nil when unknown).
    static func freeGB() -> Double? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else { return nil }
        return Double(v) / 1_000_000_000
    }

    /// Waits for queued frames to be written (self-test before exit).
    static func flush() { queue.sync {} }

    /// 开始新的一局: the next frame opens a new match folder.
    static func newMatch() { queue.async { matchDir = nil } }

    static func save(image: CGImage, info: [String: Any]) {
        queue.async {
            if let free = freeGB(), free < minFreeGB {
                problem = String(format: "磁盘只剩 %.0f GB，低于 %.0f GB 时不保存", free, minFreeGB); return
            }
            let now = Date()
            let hud = info["hud"] as? [String: Any]
            let round = hud?["round"] as? Int
            let battle = (hud?["battle"] as? Bool) == true
            // Same screen and same readings as the last saved frame: nothing new to look at.
            let infoKey = signature(info)
            // The game animates a little all the time, so an unchanged reading keeps one frame per 30 s unless the
            // screen changed a lot (a popup the helper doesn't know yet is exactly what's worth seeing).
            let thumb = thumbnail(image)
            let screenChanged = thumb.count != lastThumb.count
                || zip(thumb, lastThumb).reduce(0, { $0 + abs(Int($1.0) - Int($1.1)) }) > thumb.count * 8
            if infoKey == lastInfo, !screenChanged, let last = lastSave, now.timeIntervalSince(last) < unchangedInterval { return }
            // Fights: one frame every 10 s is enough.
            if battle, let last = lastBattleSave, now.timeIntervalSince(last) < battleInterval { return }
            if !battle, !screenChanged, let last = lastSave, now.timeIntervalSince(last) < restInterval { return }
            // New match: 「开始新的一局」 or the coach's new-match detection (newMatch()), or a long pause. (A round read
            // going "back" isn't enough: 19 misread for 9 split one match in two.)
            if let last = lastSave, now.timeIntervalSince(last) > newMatchGap { matchDir = nil }
            if matchDir == nil {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd_HHmm"
                let dir = folder.appendingPathComponent(f.string(from: now), isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch {
                    problem = "小助手所在的文件夹不能写入（\(folder.deletingLastPathComponent().path)），调试记录没有保存"; return
                }
                matchDir = dir
                savedInMatch = 0
            }
            guard let dir = matchDir else { return }
            guard savedInMatch < maxPerMatch else { problem = "这一局已经存满 \(maxPerMatch) 帧"; return }
            let t = DateFormatter()
            t.dateFormat = "HHmmss-SSS"
            let base = dir.appendingPathComponent(t.string(from: now))
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  (try? png.write(to: base.appendingPathExtension("png"))) != nil else {
                problem = "写入失败：\(dir.path)"; return
            }
            if let json = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: base.appendingPathExtension("json"))
            }
            problem = nil
            savedInMatch += 1
            lastSave = now
            if battle { lastBattleSave = now }
            if let round { lastRound = round }
            lastInfo = infoKey
            lastThumb = thumb
        }
    }

    /// 「保存当前截图」: the whole window capture plus its OCR text, in 手动截图/. Returns the png's URL.
    static func saveSnapshot(image: CGImage, text: String) throws -> URL {
        try FileManager.default.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let png = snapshotFolder.appendingPathComponent("截图-\(f.string(from: Date())).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "DebugRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "图像编码失败"])
        }
        try data.write(to: png)
        try text.write(to: png.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        return png
    }

    /// Match folders and total size of everything under 「卫戍助手调试」.
    static func usage() -> (matches: Int, bytes: Int64) {
        let fm = FileManager.default
        let matches = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != "手动截图" && !$0.hasPrefix(".") }.count
        var bytes: Int64 = 0
        if let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in e { bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return (matches, bytes)
    }

    /// Moves everything under 「卫戍助手调试」 to the Trash (recoverable).
    static func clearAll() {
        queue.async {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
                try? fm.trashItem(at: folder.appendingPathComponent(name), resultingItemURL: nil)
            }
            matchDir = nil
        }
    }

    static func openFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// The readings that matter when comparing frames: HUD, shop, lineup, units on the field (names in any order), map,
    /// advice and popups. Board-fit scores, model percentages and the order units were found in are noise.
    private static func signature(_ info: [String: Any]) -> String {
        var key: [String: Any] = [:]
        if let h = info["hud"] as? [String: Any] {
            key["hud"] = ["round", "money", "level", "rest", "battle", "otherBoard", "coDefense", "boardTag"].map { "\(h[$0] ?? "-")" }
        }
        key["cards"] = info["cards"] ?? []
        key["owned"] = ((info["owned"] as? [String]) ?? []).sorted()
        key["actions"] = ((info["actions"] as? [String]) ?? []).map { $0.components(separatedBy: " — ").first ?? $0 }
        key["choice"] = info["choice"] ?? "-"
        key["route"] = info["route"] ?? "-"
        key["field"] = ((info["field"] as? [[String: Any]]) ?? []).map { u in
            "\((u["bench"] as? Bool) == true ? "B" : "F"):" + (((u["candidates"] as? [String])?.first ?? "?").components(separatedBy: " ").first ?? "?")
        }.sorted()
        if let b = info["board"] as? [String: Any] { key["board"] = "\(b["map"] ?? "-")/\(b["expanded"] ?? "-")" }
        key["bar"] = ((info["bar"] as? [[String: Any]]) ?? []).map { "\($0["name"] ?? "")\(($0["active"] as? Bool) == true ? "+" : "")" }.sorted()
        let data = (try? JSONSerialization.data(withJSONObject: key, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// 32×18 grey thumbnail for spotting an unchanged screen.
    private static func thumbnail(_ image: CGImage) -> [UInt8] {
        let w = 32, h = 18
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return px
    }
}

/// Per-stage timing of a live tick (TICK_TIMING=1 prints it; the debug json keeps the last tick's stages).
enum TickTiming {
    nonisolated(unsafe) static var enabled = ProcessInfo.processInfo.environment["TICK_TIMING"] != nil
    nonisolated(unsafe) private static var start = CFAbsoluteTimeGetCurrent()
    nonisolated(unsafe) private static var last = CFAbsoluteTimeGetCurrent()
    nonisolated(unsafe) private(set) static var stages: [(String, Double)] = []
    private static let lock = NSLock()

    nonisolated(unsafe) private static var counters: [String: Int] = [:]
    static func begin() { lock.lock(); start = CFAbsoluteTimeGetCurrent(); last = start; stages = []; counters = [:]; lock.unlock() }
    static func count(_ name: String) { lock.lock(); counters[name, default: 0] += 1; lock.unlock() }
    /// Time since the previous mark, under `name`.
    static func mark(_ name: String) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        stages.append((name, (now - last) * 1000)); last = now
        lock.unlock()
    }
    static func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        let total = (last - start) * 1000
        return String(format: "%.0f ms: ", total) + stages.map { String(format: "%@ %.0f", $0.0, $0.1) }.joined(separator: " · ")
            + (counters.isEmpty ? "" : " | " + counters.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
    }
}

/// Version of the running build (scripts/build-app.sh writes VERSION, the commit count and the commit into Info.plist;
/// command-line builds show 「开发版」).
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let v = info["CFBundleShortVersionString"] as? String else { return "开发版" }
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["GHGitCommit"] as? String
        return "v\(v) (\(build)" + (commit.map { " · \($0)" } ?? "") + ")"
    }
}
