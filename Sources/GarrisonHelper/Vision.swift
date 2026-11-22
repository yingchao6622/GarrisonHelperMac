// Portions adapted from ASP Assistant and StrongholdAssistant (Apache-2.0) and rewritten in Swift for this Mac app; the upstream files are listed
// in REFERENCES.md and their licenses / NOTICEs are in licenses/.
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

// MARK: - Window capture (ScreenCaptureKit)

struct GameWindow: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let app: String
    let frame: CGRect   // global display points, top-left origin
    var label: String { title.isEmpty ? app : "\(app) — \(title)" }
}

enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static let permissionHint = "需要“屏幕录制”权限：系统设置 → 隐私与安全性 → 屏幕与系统录音，勾选「卫戍协议小助手」后重新打开本应用"

    /// Only when the user asks (the 打开设置 buttons): registers the app in the Screen Recording list (macOS shows its own
    /// prompt the first time) and opens that settings page. Never called automatically: without the permission every
    /// ScreenCaptureKit call can bring the system prompt up again, so captures are skipped instead (`capture` throws).
    static func openSettings() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// The permission is read when the process starts, so after ticking it the app has to be reopened.
    @MainActor static func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// ScreenCaptureKit refused although the preflight says yes: the Screen Recording entry belongs to an earlier build
    /// (ad-hoc signatures change on every rebuild), shown as 「用户拒绝了应用程序、窗口、显示器捕捉的 TCC」.
    static func isDeclined(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == SCStreamErrorDomain && e.code == SCStreamError.Code.userDeclined.rawValue
    }

    /// Removes this app's own Screen Recording entry (`tccutil reset ScreenCapture <bundle id>`), only when the user
    /// clicks 清除旧授权: the stale entry stays ticked in Settings but no longer matches the rebuilt app.
    static func resetPermission() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", id]
        try? p.run()
        p.waitUntilExit()
    }

    static func permissionError() -> NSError {
        NSError(domain: "Capture", code: 2, userInfo: [NSLocalizedDescriptionKey: permissionHint])
    }

    static func listWindows() async throws -> [GameWindow] {
        guard hasPermission else { throw permissionError() }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let myPID = ProcessInfo.processInfo.processIdentifier
        return content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width >= 320 && $0.frame.height >= 200 }
            .filter { $0.owningApplication?.processID != myPID }
            .map { GameWindow(id: $0.windowID, title: $0.title ?? "", app: $0.owningApplication?.applicationName ?? "?", frame: $0.frame) }
            .sorted { score($0) > score($1) }
    }

    /// Put likely game windows first (MuMu, PlayCover, the iOS client, etc.).
    private static func score(_ w: GameWindow) -> Int {
        let s = (w.app + w.title).lowercased()
        let keys = ["明日方舟", "arknights", "mumu", "playcover", "android", "模拟器", "bluestacks", "ldplayer", "雷电"]
        return keys.contains { s.contains($0) } ? 1 : 0
    }

    /// Captures one frame of the window at native pixel resolution. Returns the image and the
    /// window's current frame in points.
    static func capture(windowID: CGWindowID) async throws -> (CGImage, CGRect) {
        guard hasPermission else { throw permissionError() }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到游戏窗口（可能已关闭或最小化）"])
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, window.frame)
    }
}

// MARK: - Pixels

struct PixelBuffer {
    let width: Int
    let height: Int
    private let data: [UInt8]

    /// Hash of the pixels (number-read cache key).
    func hash(into h: inout Hasher) { h.combine(width); h.combine(height); h.combine(data) }

    init(_ image: CGImage) {
        let width = image.width, height = image.height
        self.width = width
        self.height = height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        buf.withUnsafeMutableBytes { ptr in
            if let ctx = CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: width * 4, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        data = buf
    }

    /// (x, y) with top-left origin.
    func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    func fraction(in rect: CGRect, _ predicate: (Int, Int, Int) -> Bool) -> Double {
        let r = rect.integral
        guard r.minX >= 0, r.minY >= 0, r.maxX <= CGFloat(width), r.maxY <= CGFloat(height), r.width > 0, r.height > 0 else { return 0 }
        var hits = 0, total = 0
        var y = Int(r.minY)
        while y < Int(r.maxY) {
            var x = Int(r.minX)
            while x < Int(r.maxX) {
                let c = rgb(x, y)
                total += 1
                if predicate(c.r, c.g, c.b) { hits += 1 }
                x += 2
            }
            y += 2
        }
        return total == 0 ? 0 : Double(hits) / Double(total)
    }

    /// True when a row is a flat colour (letterbox / blank margin).
    func rowIsUniform(_ y: Int) -> Bool {
        guard y >= 0, y < height else { return false }
        let ref = rgb(width / 2, y)
        for i in 1..<16 {
            let c = rgb(width * i / 16, y)
            if abs(c.r - ref.r) > 12 || abs(c.g - ref.g) > 12 || abs(c.b - ref.b) > 12 { return false }
        }
        return true
    }
}

// MARK: - OCR (Apple Vision)

struct OCRText {
    let text: String
    let box: CGRect             // pixels, top-left origin, relative to the OCR'd image
    let observation: VNRecognizedText?
    let imageSize: CGSize
    /// One box per character (from the OCR worker, which can't hand over Vision's observation).
    var charBoxes: [CGRect?]? = nil

    /// Pixel box of a substring (for labels OCR merged into one line).
    func box(of range: Range<String.Index>) -> CGRect {
        if let rect = try? observation?.boundingBox(for: range)?.boundingBox {
            return OCR.toPixels(rect, imageSize)
        }
        if let chars = charBoxes, chars.count == text.count {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            let boxes = chars[start..<end].compactMap { $0 }
            if let first = boxes.first { return boxes.dropFirst().reduce(first) { $0.union($1) } }
        }
        // Fall back to proportional split by character count.
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let len = text.distance(from: range.lowerBound, to: range.upperBound)
        let n = max(1, text.count)
        return CGRect(x: box.minX + box.width * CGFloat(start) / CGFloat(n), y: box.minY,
                      width: box.width * CGFloat(len) / CGFloat(n), height: box.height)
    }
}

/// Cheap "did the screen change" check: a 64×40 grey thumbnail of the game area without its right fifth (the animated
/// mascot and monitor live there) and without the top strip (FPS / ping readout).
struct ScreenSignature {
    let pixels: [UInt8]
    /// Board area only (fractions of the game view): moves with the camera, but not with the HUD, the shop strip,
    /// the 「已就绪」 banner or popups at the edges.
    static let boardRegion = CGRect(x: 0.14, y: 0.20, width: 0.58, height: 0.40)

    init(_ image: CGImage, region: CGRect? = nil) {
        let w = 64, h = 40
        var px = [UInt8](repeating: 0, count: w * h)
        let r = region ?? CGRect(x: 0, y: 0.12, width: 0.8, height: 0.88)
        let src = image.cropped(CGRect(x: Int(Double(image.width) * r.minX), y: Int(Double(image.height) * r.minY),
                                       width: Int(Double(image.width) * r.width), height: Int(Double(image.height) * r.height))) ?? image
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        pixels = px
    }
    /// Mean absolute difference (0–255) to another signature.
    func distance(_ o: ScreenSignature) -> Double {
        guard o.pixels.count == pixels.count else { return 255 }
        return Double(zip(pixels, o.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(pixels.count)
    }
}

enum OCR {
    /// OCR with optional upscaling (small labels read much better at ≥ 2x). Boxes are returned in
    /// the coordinates of the original `image`.
    static func recognize(_ image: CGImage, minHeight: Int) throws -> [OCRText] {
        let k = Double(minHeight) / Double(max(1, image.height))
        guard k > 1.05, let up = upscale(image, by: min(k, 4)) else { return try recognize(image) }
        let size = CGSize(width: image.width, height: image.height)
        return try recognize(up).map { t in
            let f = Double(image.width) / Double(up.width)
            return OCRText(text: t.text, box: CGRect(x: t.box.minX * f, y: t.box.minY * f, width: t.box.width * f, height: t.box.height * f),
                           observation: t.observation, imageSize: size,
                           charBoxes: t.charBoxes?.map { $0.map { CGRect(x: $0.minX * f, y: $0.minY * f, width: $0.width * f, height: $0.height * f) } })
        }
    }

    /// Full-screen read. Vision sometimes misjudges the script of a whole frame and returns a handful of garbage lines
    /// (2026-11-22 23:32, a snowy map with the shop open: 22 lines, 「休息一下」 read as 「して」, no 「回合」, no 冻结 / 刷新),
    /// while each half of the same frame reads normally. Such a frame is read again as two overlapping halves.
    static func recognizeScreen(_ image: CGImage, minHeight: Int = 1080) throws -> [OCRText] {
        let texts = try recognize(image, minHeight: minHeight)
        guard looksGarbled(texts, height: Double(image.height)) else { return texts }
        let h = image.height, overlap = h / 10
        var merged: [OCRText] = []
        for (y0, y1) in [(0, h / 2 + overlap), (h / 2 - overlap, h)] {
            guard let crop = image.cropping(to: CGRect(x: 0, y: y0, width: image.width, height: y1 - y0)) else { continue }
            let part = try recognize(crop, minHeight: max(1, minHeight * crop.height / h))
            for t in part {
                // Lines cut by the crop edge are read whole by the other half.
                if y0 > 0 && t.box.minY < 3 { continue }
                if y1 < h && t.box.maxY > Double(crop.height) - 3 { continue }
                let s = shifted(t, dy: Double(y0), fullSize: CGSize(width: image.width, height: h))
                if merged.contains(where: { $0.text == s.text && abs($0.box.midX - s.box.midX) < 12 && abs($0.box.midY - s.box.midY) < 12 }) { continue }
                merged.append(s)
            }
        }
        if ProcessInfo.processInfo.environment["OCR_DEBUG"] != nil { print("OCR garbled (\(texts.count) lines) → halves \(merged.count) lines") }
        return merged.count > texts.count ? merged : texts
    }

    /// None of the words found on nearly every game screen (top bar, shop buttons, popup titles), and either very few
    /// lines or several lines in Japanese kana (the game shows none). The garbled 23:32 frame had none of these words.
    static func looksGarbled(_ texts: [OCRText], height: Double) -> Bool {
        let anchors = ["回合", "休息", "准备就绪", "冻结", "刷新", "收起", "交流", "悬赏", "补给", "机密", "战术", "自选", "本局", "敌人", "查看", "升级"]
        if texts.contains(where: { t in anchors.contains { t.text.contains($0) } }) { return false }
        let kana = texts.filter { $0.text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) } }.count
        return texts.count < 25 || kana >= 2
    }

    /// A text read from a crop, moved into the full frame. Substring boxes go through `charBoxes` (Vision's observation
    /// only knows the crop).
    private static func shifted(_ t: OCRText, dy: Double, fullSize: CGSize) -> OCRText {
        var chars = t.charBoxes
        if chars == nil, let obs = t.observation {
            chars = t.text.indices.map { i in
                (try? obs.boundingBox(for: i..<t.text.index(after: i)))?.map { OCR.toPixels($0.boundingBox, t.imageSize) }
            }
        }
        return OCRText(text: t.text, box: t.box.offsetBy(dx: 0, dy: dy), observation: nil, imageSize: fullSize,
                       charBoxes: chars?.map { $0?.offsetBy(dx: 0, dy: dy) })
    }

    /// Loads Vision's text models in this process in the background (the first request compiles them, which can take
    /// tens of seconds), so the first real frame isn't the one that waits.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            guard let ctx = CGContext(data: nil, width: 96, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 48))
            guard let img = ctx.makeImage() else { return }
            for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = level
                req.recognitionLanguages = ["en-US"]
                req.usesLanguageCorrection = false
                autoreleasepool { try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req]) }
            }
        }
    }

    /// Texts inside `rect`, with boxes moved to the rect's own coordinates (as if `rect` had been OCR'd alone).
    static func within(_ texts: [OCRText], _ rect: CGRect) -> [OCRText] {
        texts.filter { rect.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }.map { t in
            OCRText(text: t.text, box: t.box.offsetBy(dx: -rect.minX, dy: -rect.minY), observation: t.observation,
                    imageSize: rect.size, charBoxes: t.charBoxes?.map { $0?.offsetBy(dx: -rect.minX, dy: -rect.minY) })
        }
    }

    /// Reads a short number from a small region. Vision's detector ignores a lone digit, so the crop is
    /// tiled four times side by side ("4 4 4 4") and the value most tiles agree on is returned.
    static func readNumber(_ image: CGImage, in rect: CGRect, inks: [DigitReader.Ink] = [.white, .gold]) -> Int? {
        for ink in inks { if let n = DigitReader.read(image, in: rect, ink: ink) { return n } }
        guard let crop = image.cropped(rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))),
              crop.width > 2, crop.height > 2 else { return nil }
        // The same digits give the same number: Vision's tiled read (~60 ms) runs once per distinct glyph. The key is the
        // ink (bright or gold pixels), not every pixel: the badges sit on animated art that changes every frame.
        let key = inkKey(crop)
        if let hit = numberCache.get(key) { return hit }
        TickTiming.count("数字Vision")
        let n = visionNumber(crop)
        numberCache.set(key, n)
        return n
    }

    private static func inkKey(_ crop: CGImage) -> Int {
        let px = PixelBuffer(crop)
        var bits = [UInt8](repeating: 0, count: (px.width * px.height + 7) / 8)
        for y in 0..<px.height {
            for x in 0..<px.width {
                let c = px.rgb(x, y)
                let ink = min(c.r, c.g, c.b) > 185 || (c.r > 170 && c.g > 115 && c.b < 90 && c.r - c.b > 100)
                if ink { let i = y * px.width + x; bits[i >> 3] |= 1 << UInt8(i & 7) }
            }
        }
        var h = Hasher()
        h.combine(px.width); h.combine(px.height); h.combine(bits)
        return h.finalize()
    }

    private static let numberCache = NumberCache()
    final class NumberCache: @unchecked Sendable {
        private var map: [Int: Int?] = [:]
        private let lock = NSLock()
        func get(_ k: Int) -> Int?? { lock.lock(); defer { lock.unlock() }; return map[k] }
        func set(_ k: Int, _ v: Int?) {
            lock.lock(); defer { lock.unlock() }
            if map.count > 256 { map.removeAll() }
            map[k] = .some(v)
        }
    }

    /// Vision on a number crop tiled four times (the detector ignores a lone digit); the value most tiles agree on.
    private static func visionNumber(_ crop: CGImage) -> Int? {
        // Variants: white glyph binarised (ring / badge art behind it), gold glyph binarised, raw on black, raw on border colour.
        var variants: [(CGImage, Double)] = []
        if let w = binarize(crop, { r, g, b in min(r, g, b) > 190 && max(r, g, b) - min(r, g, b) < 70 }) { variants.append((w, 1)) }
        if let y = binarize(crop, { r, g, b in r > 170 && g > 115 && b < 90 && r - b > 100 }) { variants.append((y, 1)) }
        let border = PixelBuffer(crop).rgb(1, 1)
        variants.append((crop, 0))
        variants.append((crop, Double(border.r + border.g + border.b) / 765))
        for (img, gray) in variants {
            guard let big = tiled(img, background: gray) else { continue }
            for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = level
                req.recognitionLanguages = ["en-US"]
                req.usesLanguageCorrection = false
                autoreleasepool { try? VNImageRequestHandler(cgImage: big, options: [:]).perform([req]) }
                let tokens = (req.results ?? []).flatMap { $0.topCandidates(1).first?.string.split(separator: " ").map(String.init) ?? [] }
                let numbers = tokens.compactMap { HudReader.number($0) }
                let votes = Dictionary(grouping: numbers, by: { $0 }).mapValues(\.count)
                if let best = votes.max(by: { $0.value < $1.value }), best.value >= 2 { return best.key }
            }
        }
        return nil
    }

    /// Black glyph on white from the pixels matching `ink` (nil if almost nothing matches).
    static func binarize(_ img: CGImage, _ ink: (Int, Int, Int) -> Bool) -> CGImage? {
        let px = PixelBuffer(img)
        var out = [UInt8](repeating: 255, count: px.width * px.height)
        var hits = 0
        for y in 0..<px.height { for x in 0..<px.width { let c = px.rgb(x, y); if ink(c.r, c.g, c.b) { out[y * px.width + x] = 0; hits += 1 } } }
        guard hits >= 6, Double(hits) < Double(px.width * px.height) * 0.6 else { return nil }
        let data = Data(out) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: px.width, height: px.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: px.width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func tiled(_ crop: CGImage, background: Double, copies n: Int = 4) -> CGImage? {
        let k = 96.0 / Double(crop.height)
        let w = Int(Double(crop.width) * k), h = 96, pad = 40
        guard let ctx = CGContext(data: nil, width: n * w + (n + 1) * pad, height: h + 2 * pad, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: background, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.interpolationQuality = .high
        for i in 0..<n { ctx.draw(crop, in: CGRect(x: pad + i * (w + pad), y: pad, width: w, height: h)) }
        return ctx.makeImage()
    }

    /// Downscales big Retina captures so OCR and pixel work stay fast (keeps small images as they are).
    static func downscale(_ image: CGImage, maxHeight: Int) -> CGImage {
        guard image.height > maxHeight else { return image }
        let k = Double(maxHeight) / Double(image.height)
        let w = Int(Double(image.width) * k)
        guard let ctx = CGContext(data: nil, width: w, height: maxHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: maxHeight))
        return ctx.makeImage() ?? image
    }

    static func upscale(_ image: CGImage, by k: Double) -> CGImage? {
        let w = Int(Double(image.width) * k), h = Int(Double(image.height) * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// OCR in this process even when the app uses the worker (to run next to a worker request); upscales like
    /// `recognize(_:minHeight:)`.
    static func recognizeLocal(_ image: CGImage, minHeight: Int) throws -> [OCRText] {
        let k = Double(minHeight) / Double(max(1, image.height))
        guard k > 1.05, let up = upscale(image, by: min(k, 4)) else { return try local(image) }
        let size = CGSize(width: image.width, height: image.height)
        let f = Double(image.width) / Double(up.width)
        return try local(up).map { t in
            OCRText(text: t.text, box: CGRect(x: t.box.minX * f, y: t.box.minY * f, width: t.box.width * f, height: t.box.height * f),
                    observation: t.observation, imageSize: size)
        }
    }

    static func recognize(_ image: CGImage) throws -> [OCRText] {
        // The app reads text in a worker process it can restart (OCRWorkerClient explains why).
        if OCRWorkerClient.shared.enabled { return try OCRWorkerClient.shared.recognize(image) }
        return try local(image)
    }

    private static func local(_ image: CGImage) throws -> [OCRText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        do {
            try autoreleasepool { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        } catch {
            // Vision refused the request (CRImageReaderError 1 / e5rtError 13): retry once. When the Neural Engine's
            // model cache was purged it keeps failing in this process (OCRWorkerClient handles that for the app).
            if ProcessInfo.processInfo.environment["OCR_DEBUG"] != nil { print("OCR fail \(image.width)x\(image.height): \(error)") }
            Thread.sleep(forTimeInterval: 0.12)
            try autoreleasepool { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        }
        return texts(request, image)
    }

    private static func texts(_ request: VNRecognizeTextRequest, _ image: CGImage) -> [OCRText] {
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return OCRText(text: top.string, box: toPixels(obs.boundingBox, size), observation: top, imageSize: size)
        }
    }

    static func toPixels(_ normalized: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width, y: (1 - normalized.maxY) * size.height,
               width: normalized.width * size.width, height: normalized.height * size.height)
    }

    /// Same normalisation as ASP Assistant's ShopRecognizer.
    static func normalize(_ s: String) -> String {
        var t = s
        for suffix in ["(卫戍协议)", "（卫戍协议）"] where t.hasSuffix(suffix) { t.removeLast(suffix.count) }
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

// MARK: - Game viewport

struct CropInsets: Codable, Equatable {
    var top: Double = 0, bottom: Double = 0, left: Double = 0, right: Double = 0
}

enum Viewport {
    /// Game content area of a captured window: drops the title bar and flat letterbox bars, keeps the game's own
    /// aspect (the Mac client is about 16:10; layouts anchor to the edges and scale by min(w/1920, h/1080)).
    static func find(_ px: PixelBuffer, insets: CropInsets) -> CGRect {
        var area = CGRect(x: insets.left, y: insets.top,
                          width: Double(px.width) - insets.left - insets.right,
                          height: Double(px.height) - insets.top - insets.bottom)
        guard area.width > 16, area.height > 16 else { return CGRect(x: 0, y: 0, width: px.width, height: px.height) }
        if insets.top == 0 {
            let title = titleBarHeight(px)
            area.origin.y += Double(title); area.size.height -= Double(title)
        }
        // Flat dark bars at the sides or bottom (window larger than the rendered game).
        func darkColumn(_ x: Int) -> Bool {
            var n = 0
            for i in 1..<16 { let c = px.rgb(x, Int(area.minY) + Int(area.height) * i / 16); if max(c.r, c.g, c.b) < 18 { n += 1 } }
            return n >= 15
        }
        var l = Int(area.minX), r = Int(area.maxX) - 1
        while l < Int(area.minX + area.width * 0.2) && darkColumn(l) { l += 1 }
        while r > Int(area.maxX - area.width * 0.2) && darkColumn(r) { r -= 1 }
        area = CGRect(x: Double(l), y: area.minY, width: Double(r - l + 1), height: area.height)
        return area
    }

    /// Rows at the top that look like a macOS title bar (near-uniform colour across the width).
    static func titleBarHeight(_ px: PixelBuffer) -> Int {
        func uniformity(_ y: Int) -> Double {
            var vals: [(Int, Int, Int)] = []
            for i in 1..<40 { vals.append(px.rgb(px.width * i / 40, y)) }
            let mr = vals.map(\.0).sorted()[vals.count / 2], mg = vals.map(\.1).sorted()[vals.count / 2], mb = vals.map(\.2).sorted()[vals.count / 2]
            return Double(vals.filter { abs($0.0 - mr) + abs($0.1 - mg) + abs($0.2 - mb) < 24 }.count) / Double(vals.count)
        }
        let limit = max(4, px.height / 12)
        guard uniformity(0) > 0.85 || uniformity(2) > 0.85 else { return 0 }
        for y in 1..<limit where uniformity(y) < 0.6 && uniformity(min(px.height - 1, y + 1)) < 0.6 && uniformity(min(px.height - 1, y + 2)) < 0.6 {
            return y
        }
        return 0
    }
}

extension CGImage {
    func cropped(_ rect: CGRect) -> CGImage? { cropping(to: rect.integral) }
}

// MARK: - Digit templates

/// Game-font digit matching (StrongholdAssistant CovenantBarReader: White mask, Components, 32×28 Vector,
/// Hamming distance with the same acceptance thresholds; templates from data/covenant_bar_digits.json).
enum DigitReader {
    enum Ink { case white, gold, cyan, darkOnCyan }
    private struct Template: Decodable { let digit: Int; let pixels: String }
    private static let templates: [(Int, [UInt8])] = {
        let url = Catalog.resourceRootURL.appendingPathComponent("data/covenant_bar_digits.json")
        guard let data = try? Data(contentsOf: url), let t = try? JSONDecoder().decode([Template].self, from: data) else { return [] }
        return t.map { ($0.digit, $0.pixels.utf8.map { $0 == 49 ? 1 : 0 }) }
    }()

    static func read(_ image: CGImage, in rect: CGRect, ink: Ink) -> Int? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !templates.isEmpty, r.width > 3, r.height > 6, let crop = image.cropped(r) else { return nil }
        let px = PixelBuffer(crop)
        let w = px.width, h = px.height
        var mask = [Bool](repeating: false, count: w * h)
        // Dark glyph inside a cyan box (round counter): limit to the cyan box's bounding rows/columns.
        var box = (0, 0, w - 1, h - 1)
        if ink == .darkOnCyan {
            var l = w, t = h, rr = -1, b = -1
            for y in 0..<h { for x in 0..<w { let c = px.rgb(x, y); if c.g > 160 && c.b > 170 && c.r < 120 { l = min(l, x); rr = max(rr, x); t = min(t, y); b = max(b, y) } } }
            guard rr > l + 4, b > t + 4 else { return nil }
            box = (l + 1, t + 1, rr - 1, b - 1)
        }
        for y in box.1...box.3 { for x in box.0...box.2 {
            let c = px.rgb(x, y)
            switch ink {
            case .white: let mn = min(c.r, c.g, c.b), mx = max(c.r, c.g, c.b); mask[y * w + x] = mn >= 145 && mx - mn < 80
            case .gold: mask[y * w + x] = c.r > 170 && c.g > 110 && c.b < 100 && c.r - c.b > 90
            case .cyan: mask[y * w + x] = c.g > 150 && c.b > 140 && c.r < 150 && c.g - c.r > 50
            case .darkOnCyan: mask[y * w + x] = max(c.r, c.g, c.b) < 90
            }
        } }
        // Connected components (8-neighbour).
        var seen = [Bool](repeating: false, count: w * h)
        var boxes: [(Int, Int, Int, Int)] = []   // left, top, right, bottom (inclusive)
        let minH = max(6, Int(Double(h) * 0.3))
        for y in 0..<h { for x in 0..<w where mask[y * w + x] && !seen[y * w + x] {
            var stack = [(x, y)]; seen[y * w + x] = true
            var l = x, rr = x, t = y, b = y, n = 0
            while let (cx, cy) = stack.popLast() {
                n += 1; l = min(l, cx); rr = max(rr, cx); t = min(t, cy); b = max(b, cy)
                for dy in -1...1 { for dx in -1...1 {
                    let ax = cx + dx, ay = cy + dy
                    guard ax >= 0, ay >= 0, ax < w, ay < h, mask[ay * w + ax], !seen[ay * w + ax] else { continue }
                    seen[ay * w + ax] = true; stack.append((ax, ay))
                } }
            }
            let bh = b - t + 1, bw = rr - l + 1
            if bh >= minH && n >= 12 && bw >= 2 && Double(bw) <= Double(bh) * 0.95 { boxes.append((l, t, rr, b)) }
        } }
        guard !boxes.isEmpty else { return nil }
        // Keep components on the main text line (similar height and baseline).
        let tallest = boxes.map { $0.3 - $0.1 + 1 }.max()!
        boxes = boxes.filter { Double($0.3 - $0.1 + 1) >= Double(tallest) * 0.7 }.sorted { $0.0 < $1.0 }
        guard boxes.count <= 3 else { return nil }
        var value = 0
        for (l, t, rr, b) in boxes {
            let bw = rr - l + 1, bh = b - t + 1
            // "1" is a lone narrow stroke.
            if Double(bw) < Double(bh) * 0.32 { value = value * 10 + 1; continue }
            let width = max(1, Int((Double(bw) * 24 / Double(bh)).rounded())), offset = (32 - width) / 2
            var v = [UInt8](repeating: 0, count: 896)
            for y in 0..<24 { for x in 0..<width where offset + x >= 0 && offset + x < 32 {
                let sx = l + min(bw - 1, Int((Double(x) + 0.5) * Double(bw) / Double(width)))
                let sy = t + min(bh - 1, Int((Double(y) + 0.5) * Double(bh) / 24))
                if mask[sy * w + sx] { v[(y + 2) * 32 + x + offset] = 1 }
            } }
            var best: [Int: Double] = [:]
            for (d, p) in templates {
                var diff = 0
                for i in 0..<896 where p[i] != v[i] { diff += 1 }
                best[d] = min(best[d] ?? 1, Double(diff) / 896)
            }
            let ranked = best.sorted { $0.value < $1.value }
            guard ranked[0].value <= 0.22, ranked.count < 2 || ranked[1].value - ranked[0].value >= 0.02 else { return nil }
            value = value * 10 + ranked[0].key
        }
        return value
    }
}
