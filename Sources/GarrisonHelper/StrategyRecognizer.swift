import CoreGraphics
import ImageIO
import Foundation

// Method ported from StrongholdAssistant src/ASPAssistant.Core/Services/MatchStrategyReader.cs (Apache-2.0): the strategy
// portrait in the top-right corner of the match screen, compared with the 61 strategy icons by the grey levels inside the
// central circle (32×32, correlation). The references are built here from icons/strategies with the same sampling (the
// precomputed Windows data matched the Mac client poorly), and the position is searched around the Windows layout.
// See REFERENCES.md.

/// Reads this run's strategy from its portrait on the match screen.
struct StrategyRecognizer {
    struct Match { let id: String?; let score: Double; let margin: Double; var top: String? = nil }

    private let portraits: [String: [Double]]

    init?(resourceRoot: URL) {
        let dir = resourceRoot.appendingPathComponent("icons/strategies")
        var refs: [String: [Double]] = [:]
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "png" {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let v = Self.sample(img, CGRect(x: 0, y: 0, width: img.width, height: img.height)) else { continue }
            refs[url.deletingPathExtension().lastPathComponent] = Self.normalize(v)
        }
        guard !refs.isEmpty else { return nil }
        portraits = refs
    }

    static func normalize(_ v: [Double]) -> [Double] {
        let mean = v.reduce(0, +) / Double(max(1, v.count))
        let c = v.map { $0 - mean }
        let len = c.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return len == 0 ? c : c.map { $0 / len }
    }

    /// `image`: the game area (16:9). The portrait sits 124 px from the right edge, 259 px from the top, 112 px across on
    /// a 1920×1080 screen; UI scale 90 % / 100 % are both tried.
    func read(_ image: CGImage) -> Match {
        let base = min(Double(image.width) / 1920, Double(image.height) / 1080)
        var best = Match(id: nil, score: -1, margin: 0)
        // The Mac client's portrait sits a few pixels off the Windows layout: search small shifts and sizes around it.
        for k in [1.0, 100.0 / 90] {
            let s = base * k
            let cx = Double(image.width) - 68 * s, cy = 315 * s
            for size in [104.0, 112, 120] {
                for dy in stride(from: -12.0, through: 12, by: 4) {
                    for dx in stride(from: -12.0, through: 12, by: 4) {
                        let r = size * s / 2
                        let rect = CGRect(x: cx + dx * s - r, y: cy + dy * s - r, width: 2 * r, height: 2 * r)
                        let m = match(image, rect)
                        if (m.id != nil ? 1 : 0, m.score) > (best.id != nil ? 1 : 0, best.score) { best = m }
                    }
                }
            }
        }
        return best
    }

    /// Grey levels inside the central circle (radius 12 of 32) of `rect`, scaled to 32×32.
    static func sample(_ image: CGImage, _ rect: CGRect) -> [Double]? {
        guard let crop = image.cropping(to: rect.integral),
              let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32 * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        var pixels: [Double] = []
        pixels.reserveCapacity(448)
        for y in 0..<32 {
            for x in 0..<32 {
                let dx = Double(x) - 15.5, dy = Double(y) - 15.5
                guard dx * dx + dy * dy < 144 else { continue }
                let i = (y * 32 + x) * 4
                pixels.append(0.299 * Double(buf[i]) + 0.587 * Double(buf[i + 1]) + 0.114 * Double(buf[i + 2]))
            }
        }
        return pixels
    }

    private func match(_ image: CGImage, _ rect: CGRect) -> Match {
        guard let pixels = Self.sample(image, rect) else { return Match(id: nil, score: -1, margin: 0) }
        let sample = Self.normalize(pixels)
        let scores = portraits.map { (id: $0.key, score: zip($0.value, sample).reduce(0) { $0 + $1.0 * $1.1 }) }
            .sorted { $0.score > $1.score }
        guard scores.count >= 2 else { return Match(id: nil, score: -1, margin: 0) }
        let margin = scores[0].score - scores[1].score
        return Match(id: scores[0].score >= 0.65 && margin >= 0.15 ? scores[0].id : nil, score: scores[0].score, margin: margin, top: scores[0].id)
    }
}
