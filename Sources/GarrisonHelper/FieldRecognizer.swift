import Accelerate
import AppKit
import CoreML
import Foundation

// 场上认人. Badge search and sprite-crop geometry ported from StrongholdAssistant (Apache-2.0):
// FieldReader.cs (ReadBadges / Sample / Normalize / Dot, IV/VI badge redraw), FieldReader.Sprites.cs
// (foot point and 180×204 crop), FieldReader.Camera.cs (BadgeScale), FieldReader.Viewport.cs (non-16:9),
// SpriteModelMatcher.cs (model input). The ONNX sprite model is converted to Core ML
// (scripts/convert-sprite-model.py) and runs on the Neural Engine. See REFERENCES.md.

struct FieldUnit: Identifiable, Hashable {
    let id = UUID()
    var bench: Bool
    let x: Double, y: Double            // badge centre in 1920×1080 frame
    /// Board cell [col, row] when the board camera is known.
    var cell: [Int]? = nil
    /// Foot position in board coordinates (fractional col, row): stays put when the camera moves, so the badge can be
    /// looked for again under the next camera.
    var grid: CGPoint? = nil
    let tier: Int
    let badgeScore: Double
    var candidates: [(name: String, p: Double)]
    var chosen: String?                 // user pick or top candidate
    var name: String? { chosen ?? candidates.first?.name }
    var confident: Bool { (candidates.first?.p ?? 0) >= 0.6 }
    static func == (a: FieldUnit, b: FieldUnit) -> Bool { a.id == b.id && a.chosen == b.chosen }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct FieldReading {
    var units: [FieldUnit]

    /// Classifies units with the recognised board: foot in rows 0–3 → board cell, row 4 (equipment row) → dropped,
    /// beyond → bench. Foot = badge + (35, 112) as in StrongholdAssistant FieldReader.
    mutating func place(on projection: BoardProjection) {
        units = units.compactMap { u in
            var u = u
            guard let g = projection.unproject(CGPoint(x: (u.x + 35) / 1920, y: (u.y + 112) / 1080)) else { return u }
            if g.row < 4 && g.row > -0.5 && g.col > -2.5 && g.col < 9.5 {
                u.bench = false
                u.cell = [Int(floor(g.col)), max(0, Int(floor(g.row)))]
                u.grid = CGPoint(x: g.col, y: g.row)
            } else if g.row >= 4 && g.row < 4.8 {
                return nil          // equipment row: items, not operators
            } else if g.row >= 4.8 {
                u.bench = true
            }
            return u
        }
    }
    var millis: (badges: Double, model: Double)
    var computeUnits: String
    /// Size of the viewport image the reading came from (for mapping back to the screen).
    var sourceSize: CGSize = .zero
}

final class FieldRecognizer: @unchecked Sendable {
    private struct BadgeTemplate { let tier: Int; let size: Int; let coarse: [Float]; let fine: [Float] }
    private var templates: [BadgeTemplate] = []
    private var model: MLModel?
    private var classes: [String] = []
    private var classIndex: [String: Int] = [:]
    /// Model classes that are another look of an operator: the shop stand-in Pith is drawn with char_509_acast
    /// (StrongholdAssistant SpriteMatcher.Prototypes.AppearanceName).
    static let classAliases: [String: String] = ["char_509_acast": "Pith"]
    /// Name → every class index that shows it.
    private var classIndices: [String: [Int]] = [:]
    private let root: URL
    private(set) var loadError: String?

    init(resourceRoot: URL) {
        root = resourceRoot
        loadTemplates()
        loadModel()
    }

    var isReady: Bool { model != nil && !templates.isEmpty }

    // MARK: Loading

    private func loadTemplates() {
        func image(_ n: Int) -> CGImage? {
            NSImage(contentsOf: root.appendingPathComponent("field/tier-\(n).png"))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        for tier in 1...6 {
            guard var img = image(tier) else { loadError = "缺少角标模板 tier-\(tier).png"; return }
            // IV / VI originals are dark-framed icons: redraw the glyph inside the shared bright frame of tier 3.
            if tier == 4 || tier == 6, let border = image(3) {
                let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(border, in: CGRect(x: 0, y: 0, width: 40, height: 40))
                if let glyph = img.cropping(to: CGRect(x: 8, y: 8, width: 24, height: 24)) {
                    ctx.draw(glyph, in: CGRect(x: 5, y: 40 - 5 - 30, width: 30, height: 30))
                }
                img = ctx.makeImage()!
            }
            for size in [34, 40, 44] {
                let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
                let g = GrayFrame(ctx.makeImage()!)
                var coarse = g.sample(0, 0, size, 10); zNormalize(&coarse)
                var fine = g.sample(0, 0, size, 20); zNormalize(&fine)
                templates.append(BadgeTemplate(tier: tier, size: size, coarse: coarse, fine: fine))
            }
        }
    }

    /// Batch prediction; if the Neural Engine refuses (it can get stuck like Vision's text model), the model is
    /// reloaded on CPU + GPU once and kept there.
    private func predict(_ m: MLModel, _ providers: [MLFeatureProvider]) -> MLBatchProvider? {
        let batch = MLArrayBatchProvider(array: providers)
        if let out = try? autoreleasepool(invoking: { try m.predictions(from: batch, options: MLPredictionOptions()) }) { return out }
        guard m.configuration.computeUnits == .all, let url = compiledURL else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        guard let fallback = try? MLModel(contentsOf: url, configuration: config) else { return nil }
        model = fallback
        return try? autoreleasepool(invoking: { try fallback.predictions(from: batch, options: MLPredictionOptions()) })
    }
    private var compiledURL: URL?

    private func loadModel() {
        let pkg = root.appendingPathComponent("model/SpriteModel.mlpackage")
        do {
            classes = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("model/sprite-model-classes.json")))
            classIndex = Dictionary(classes.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            classIndices = Dictionary(grouping: classes.indices, by: { Self.classAliases[classes[$0]] ?? classes[$0] })
            // Compile once and cache the .mlmodelc in Application Support.
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GarrisonHelper", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let compiled = support.appendingPathComponent("SpriteModel.mlmodelc")
            let stamp = (try? FileManager.default.attributesOfItem(atPath: pkg.appendingPathComponent("Manifest.json").path)[.modificationDate] as? Date) ?? .distantPast
            let compiledDate = (try? FileManager.default.attributesOfItem(atPath: compiled.path)[.modificationDate] as? Date) ?? .distantPast
            if !FileManager.default.fileExists(atPath: compiled.path) || compiledDate < stamp {
                let tmp = try MLModel.compileModel(at: pkg)
                try? FileManager.default.removeItem(at: compiled)
                try FileManager.default.moveItem(at: tmp, to: compiled)
            }
            let config = MLModelConfiguration()
            // Neural Engine when available. SPRITE_UNITS=ane|gpu|cpu picks one for speed tests.
            switch ProcessInfo.processInfo.environment["SPRITE_UNITS"] {
            case "ane": config.computeUnits = .cpuAndNeuralEngine
            case "gpu": config.computeUnits = .cpuAndGPU
            case "cpu": config.computeUnits = .cpuOnly
            default: config.computeUnits = .all
            }
            model = try MLModel(contentsOf: compiled, configuration: config)
            compiledURL = compiled
        } catch {
            loadError = "小人模型加载失败：\(error.localizedDescription)"
        }
    }

    // MARK: Recognition

    /// - Parameters:
    ///   - viewport: the game area (any aspect; normalised to 1920×1080 like FieldReader.Viewport).
    ///   - eligible: tier → operator names that can appear this run (mode pool, bans, 自选).
    ///   - prior: names the player is known to hold (purchases), slightly preferred.
    ///   - operatorNames: every operator in the catalog (other model classes are summons).
    /// A unit seen on the last good reading: its badge (1920×1080 frame), tier and the names it may show as
    /// (the operator and its stand-in model). A faint badge there is looked for again with a lower bar.
    struct BadgeHint: Sendable { let x: Double; let y: Double; let tier: Int; let names: Set<String> }

    func read(_ viewport: CGImage, eligible: [Int: [String]], prior: Set<String>, operatorNames: Set<String>,
              hints: [BadgeHint] = []) -> FieldReading {
        guard let frame = normalize(viewport) else { return FieldReading(units: [], millis: (0, 0), computeUnits: "") }
        let t0 = CFAbsoluteTimeGetCurrent()
        let gray = GrayFrame(frame)
        var badges = readBadges(gray)
        badges += hintedBadges(gray, hints: hints, existing: badges)
        let t1 = CFAbsoluteTimeGetCurrent()
        let units = classify(frame, gray, badges, eligible: eligible, prior: prior, operatorNames: operatorNames)
        let t2 = CFAbsoluteTimeGetCurrent()
        let cu: String
        switch model?.configuration.computeUnits { case .all: cu = "CPU+GPU+神经网络引擎"; case .cpuAndNeuralEngine: cu = "CPU+神经网络引擎"; case .cpuAndGPU: cu = "CPU+GPU"; default: cu = "CPU" }
        return FieldReading(units: units, millis: ((t1 - t0) * 1000, (t2 - t1) * 1000), computeUnits: cu,
                            sourceSize: CGSize(width: viewport.width, height: viewport.height))
    }

    /// Looks only where `hints` say a unit should be (after the camera moved: positions predicted from the units'
    /// board coordinates through the new camera). Returns the units confirmed there.
    func recheck(_ viewport: CGImage, hints: [BadgeHint], eligible: [Int: [String]], prior: Set<String>, operatorNames: Set<String>) -> [FieldUnit] {
        guard !hints.isEmpty, let frame = normalize(viewport) else { return [] }
        let gray = GrayFrame(frame)
        return classify(frame, gray, hintedBadges(gray, hints: hints, existing: []), eligible: eligible, prior: prior, operatorNames: operatorNames)
    }

    private func classify(_ frame: CGImage, _ gray: GrayFrame, _ found: [Badge], eligible: [Int: [String]], prior: Set<String>,
                          operatorNames: Set<String>) -> [FieldUnit] {
        var badges = found
        let scale = badgeScale(gray, badges)
        var units: [FieldUnit] = []
        guard let model, let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else { return units }
        // Crops for the model, drawn straight into its 160×192 BGRA input buffer.
        let tc = CFAbsoluteTimeGetCurrent()
        var inputs: [(Int, CVPixelBuffer)] = []
        for (i, b) in badges.enumerated() {
            let bench = b.y > 570
            let footX = b.x + 35 * scale, footY = b.y + 112 * scale + (bench ? 20 : 0)
            let rect = CGRect(x: (footX - 90).rounded(), y: (footY + (bench ? 0 : 24) - 180).rounded(), width: 180, height: 204)
            guard rect.minX >= 0, rect.minY >= 0, rect.maxX <= 1920, rect.maxY <= 1080,
                  let crop = frame.cropping(to: rect), let input = modelInput(crop, constraint.pixelsWide, constraint.pixelsHigh) else { continue }
            badges[i].bench = bench
            inputs.append((i, input))
        }
        if !inputs.isEmpty {
            let tp = CFAbsoluteTimeGetCurrent()
            let providers: [MLFeatureProvider] = inputs.compactMap { _, pb in
                try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
            }
            let ti = CFAbsoluteTimeGetCurrent()
            let predicted = providers.count == inputs.count ? predict(model, providers) : nil
            if ProcessInfo.processInfo.environment["SPRITE_TIMING"] != nil {
                print(String(format: "sprite: %d crops · crop+draw %.1f ms · to model input %.1f ms · inference %.1f ms", inputs.count,
                             (tp - tc) * 1000, (ti - tp) * 1000, (CFAbsoluteTimeGetCurrent() - ti) * 1000))
            }
            if let out = predicted {
                for k in 0..<out.count {
                    guard let logits = out.features(at: k).featureValue(for: "logits")?.multiArrayValue else { continue }
                    let b = badges[inputs[k].0]
                    let values = (0..<logits.count).map { Float(truncating: logits[$0]) }
                    // A summon (a model class that is not an operator) dominating the crop is not a unit to identify.
                    if let top = values.indices.max(by: { values[$0] < values[$1] }),
                       !operatorNames.contains(Self.classAliases[classes[top]] ?? classes[top]), softmaxTop(values) > 0.8 {
                        if ProcessInfo.processInfo.environment["BADGE_DEBUG"] != nil { print("skip \(Int(b.x)),\(Int(b.y)) as summon \(classes[top])") }
                        continue
                    }
                    let names = (eligible[b.tier] ?? []).filter { classIndices[$0] != nil }
                    guard !names.isEmpty else { continue }
                    let scored = names.map { n -> (String, Double) in
                        (n, Double(classIndices[n]!.map { values[$0] }.max()!) + (prior.contains(n) ? 1.0 : 0))
                    }
                    let mx = scored.map(\.1).max()!
                    let sum = scored.reduce(0) { $0 + exp($1.1 - mx) }
                    let ranked = scored.map { ($0.0, exp($0.1 - mx) / sum) }.sorted { $0.1 > $1.1 }
                    // A badge found only through a hint counts only when the unit is still the one seen there.
                    if let h = b.hint, !(h.names.contains(ranked[0].0) && ranked[0].1 >= 0.6) { continue }
                    units.append(FieldUnit(bench: b.bench, x: b.x, y: b.y, tier: b.tier, badgeScore: b.score,
                                           candidates: Array(ranked.prefix(3)).map { (name: $0.0, p: $0.1) }, chosen: nil))
                }
            }
        }
        units.sort { ($0.bench ? 1 : 0, $0.bench ? $0.x : $0.y, $0.x) < ($1.bench ? 1 : 0, $1.bench ? $1.x : $1.y, $1.x) }
        return units
    }

    private func softmaxTop(_ v: [Float]) -> Double {
        let m = v.max() ?? 0
        let s = v.reduce(0) { $0 + exp(Double($1 - m)) }
        return 1 / s
    }

    // MARK: Badges (FieldReader.ReadBadges)

    private struct Badge { var x: Double; var y: Double; var tier: Int; var score: Double; var size: Int; var bench = false; var hint: BadgeHint? = nil }

    /// BADGE_PROBE=x,y (1920×1080 frame): prints why no badge was found there.
    nonisolated(unsafe) static let probe: CGPoint? = ProcessInfo.processInfo.environment["BADGE_PROBE"].flatMap { s in
        let v = s.split(separator: ",").compactMap { Double($0) }
        return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
    }

    /// Equipment floats at the cell bottom; a unit has head/body edges below-right of its badge.
    private func edges(_ px: GrayFrame, _ b: Badge) -> Int {
        var edges = 0
        var yy = Int(b.y) + 55
        while yy < min(px.height - 2, Int(b.y) + 75) {
            var xx = Int(b.x) + 18
            while xx < min(px.width - 2, Int(b.x) + 65) {
                if abs(px.gray(xx, yy) - px.gray(xx + 2, yy)) > 32 { edges += 1 }
                xx += 2
            }
            yy += 2
        }
        return edges
    }

    /// Units seen before whose badge isn't among `existing`: look again right there, same tier only, with a lower bar
    /// (a badge dims a little with effects around it: 薇薇安娜 0.83 → below 0.75 on the same screen). The classifier
    /// still has to see the same operator (classify()).
    private func hintedBadges(_ px: GrayFrame, hints: [BadgeHint], existing: [Badge]) -> [Badge] {
        var out: [Badge] = []
        for h in hints where !(existing + out).contains(where: { abs($0.x - h.x) < 25 && abs($0.y - h.y) < 25 }) {
            var best: Badge?
            for size in [34, 40, 44] {
                let ts = templates.filter { $0.size == size && $0.tier == h.tier }
                guard !ts.isEmpty else { continue }
                let mid = size / 2
                for yy in (Int(h.y) - mid - 8)...(Int(h.y) - mid + 8) {
                    for xx in (Int(h.x) - mid - 8)...(Int(h.x) - mid + 8) {
                        guard xx >= 0, yy >= 0, xx + size < px.width - 1, yy + size < px.height - 1 else { continue }
                        var fine = px.sample(xx, yy, size, 20); zNormalize(&fine)
                        let score = Double(ts.map { vDot($0.fine, fine) }.max() ?? -1)
                        if score > (best?.score ?? 0) {
                            best = Badge(x: Double(xx + mid), y: Double(yy + mid), tier: h.tier, score: score, size: size, hint: h)
                        }
                    }
                }
            }
            if let b = best, b.score >= 0.62, edges(px, b) >= 22 {
                if ProcessInfo.processInfo.environment["BADGE_DEBUG"] != nil { print("hinted badge \(Int(b.x)),\(Int(b.y)) T\(b.tier) \(String(format: "%.2f", b.score))") }
                out.append(b)
            }
        }
        return out
    }

    private func readBadges(_ px: GrayFrame) -> [Badge] {
        var found: [Badge] = []
        let lock = NSLock()
        for size in [34, 40, 44] {
            let ts = templates.filter { $0.size == size }
            let step = size == 40 ? 2 : 3
            let rows = Array(stride(from: 70, to: Int(Double(px.height) * 0.82) - size, by: step))
            DispatchQueue.concurrentPerform(iterations: rows.count) { ri in
                let y = rows[ri]
                var local: [Badge] = []
                var x = px.width / 10
                while x < Int(Double(px.width) * 0.9) - size {
                    defer { x += step }
                    let mid = size / 2
                    let probe = Self.probe.map { abs($0.x - Double(x + mid)) <= 4 && abs($0.y - Double(y + mid)) <= 4 } ?? false
                    // The bright frame is lighter than the badge interior on both sides.
                    if px.gray(x + 2, y + mid) < px.gray(x + 7, y + mid) + 18
                        || px.gray(x + size - 3, y + mid) < px.gray(x + size - 8, y + mid) + 18 {
                        if probe { print("probe \(x + mid),\(y + mid) size \(size) frame L \(px.gray(x + 2, y + mid))-\(px.gray(x + 7, y + mid)) R \(px.gray(x + size - 3, y + mid))-\(px.gray(x + size - 8, y + mid))") }
                        continue
                    }
                    var values = px.sample(x, y, size, 10); zNormalize(&values)
                    var coarse: Float = -1
                    for t in ts { coarse = max(coarse, vDot(t.coarse, values)) }
                    if probe {
                        var fine = px.sample(x, y, size, 20); zNormalize(&fine)
                        let best = ts.map { (vDot($0.fine, fine), $0.tier) }.max { $0.0 < $1.0 }
                        print("probe \(x + mid),\(y + mid) size \(size) coarse \(coarse) fine \(best.map { "\($0.0) T\($0.1)" } ?? "-")")
                    }
                    if coarse < 0.60 { continue }
                    for yy in (y - 1)...(y + 1) {
                        for xx in (x - 1)...(x + 1) {
                            var fine = px.sample(xx, yy, size, 20); zNormalize(&fine)
                            var score: Float = -1, tier = 0
                            for t in ts { let v = vDot(t.fine, fine); if v > score { score = v; tier = t.tier } }
                            if score >= 0.75 { local.append(Badge(x: Double(xx + mid), y: Double(yy + mid), tier: tier, score: Double(score), size: size)) }
                        }
                    }
                }
                if !local.isEmpty { lock.lock(); found += local; lock.unlock() }
            }
        }
        var result: [Badge] = []
        for b in found.sorted(by: { $0.score > $1.score }) {
            if result.contains(where: { abs($0.x - b.x) < 25 && abs($0.y - b.y) < 25 }) { continue }
            let e = edges(px, b)
            if ProcessInfo.processInfo.environment["BADGE_DEBUG"] != nil { print("badge \(Int(b.x)),\(Int(b.y)) T\(b.tier) \(String(format: "%.2f", b.score)) edges \(e)") }
            if e >= 22 { result.append(b) }
        }
        return result
    }

    /// UI scale from the badges' frame width (FieldReader.BadgeScale with zoom 1).
    private func badgeScale(_ px: GrayFrame, _ badges: [Badge]) -> Double {
        var widths: [Int] = []
        for b in badges {
            let x = Int(b.x), y = Int(b.y)
            func edge(_ side: Int) -> Int {
                var strongest = 0, best = 0
                for d in 13..<24 {
                    var contrast = 0
                    for row in stride(from: -4, through: 4, by: 4) {
                        contrast += px.gray(x + side * (d + 1), y + row) * 3 - px.gray(x + side * (d - 2), y + row) * 3
                    }
                    if contrast > strongest { strongest = contrast; best = d }
                }
                return best
            }
            let l = edge(-1), r = edge(1)
            if l > 0 && r > 0 { widths.append(l + r) }
        }
        guard !widths.isEmpty else { return 1 }
        let w = Double(widths.sorted()[widths.count / 2])
        return w > 36 ? w / 34 : 1
    }

    // MARK: Image helpers

    /// Scale by max(1920/w, 1080/h) and centre-crop to 1920×1080 (FieldReader.Viewport).
    private func normalize(_ img: CGImage) -> CGImage? {
        let w = Double(img.width), h = Double(img.height)
        if img.width == 1920 && img.height == 1080 { return img }
        let s = max(1920 / w, 1080 / h)
        let sw = w * s, sh = h * s
        let ctx = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        ctx?.interpolationQuality = .high
        ctx?.draw(img, in: CGRect(x: -(sw - 1920) / 2, y: -(sh - 1080) / 2, width: sw, height: sh))
        return ctx?.makeImage()
    }

    /// The crop scaled to the model's input size and drawn straight into a 32BGRA pixel buffer, in the same colour space
    /// and with the same interpolation as the old CGImage path. Handing Core ML a CGImage (MLFeatureValue(cgImage:)) cost
    /// ~10 ms per crop for its own conversion (2026-11-22: 90–125 ms for 11 units, inference itself 2–3 ms).
    private func modelInput(_ crop: CGImage, _ w: Int, _ h: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                     kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let pb = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }

}

/// 8-bit luminance frame (top-left origin), same weights as StrongholdAssistant's Pixels.Gray.
struct GrayFrame {
    let width: Int, height: Int
    private let data: [UInt8]

    init(_ image: CGImage) {
        width = image.width; height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        rgba.withUnsafeMutableBytes { p in
            let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var g = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Int(rgba[i * 4]), gg = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            g[i] = UInt8((b * 29 + gg * 150 + r * 77) >> 8)
        }
        data = g
    }

    @inline(__always) func gray(_ x: Int, _ y: Int) -> Int {
        let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
        return Int(data[cy * width + cx])
    }

    func sample(_ x: Int, _ y: Int, _ size: Int, _ count: Int) -> [Float] {
        var v = [Float](repeating: 0, count: count * count)
        for r in 0..<count {
            let yy = y + Int((Double(r) + 0.5) * Double(size) / Double(count))
            for c in 0..<count {
                v[r * count + c] = Float(gray(x + Int((Double(c) + 0.5) * Double(size) / Double(count)), yy))
            }
        }
        return v
    }
}

@inline(__always) private func zNormalize(_ a: inout [Float]) {
    var mean: Float = 0
    vDSP_meanv(a, 1, &mean, vDSP_Length(a.count))
    var neg = -mean
    vDSP_vsadd(a, 1, &neg, &a, 1, vDSP_Length(a.count))
    var ss: Float = 0
    vDSP_svesq(a, 1, &ss, vDSP_Length(a.count))
    let n = sqrt(ss)
    if n > 0 { var inv = 1 / n; vDSP_vsmul(a, 1, &inv, &a, 1, vDSP_Length(a.count)) }
}

@inline(__always) private func vDot(_ a: [Float], _ b: [Float]) -> Float {
    var r: Float = 0
    vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(a.count))
    return r
}
