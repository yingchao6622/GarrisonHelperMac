import CoreGraphics
import Foundation

// Map + camera recognition ported from StrongholdAssistant (Apache-2.0) Services/BoardRecognizer.cs with
// data/garrison_board_refs.json (colour fingerprints from bingyunhe/asp-assistant-arknights). The frame is
// normalised like FieldReader.Viewport (scale by max(1920/w, 1080/h), centre crop) and sampled at 400×225.
// Boss rounds: the mirrored "right side" cameras and changed terrain cells are handled as upstream.

struct BoardMatch {
    let mapId: String
    let expanded: Bool
    let side: String?             // boss rounds: which board is the player's
    let projection: BoardProjection   // grid → normalised 1920×1080 frame
    let score: Double
    let gap: Double?
}

final class BoardRecognizer: @unchecked Sendable {
    private struct Refs: Decodable {
        let cameras: [String: [[[Double]]]]
        let bossCameras: [String: [[[Double]]]]
        let maps: [String: [String: [[Double]]]]
        let bossTerrain: [String: [String: [[Int]]]]
    }
    private let refs: Refs?

    init(resourceRoot: URL) {
        refs = try? JSONDecoder().decode(Refs.self, from: Data(contentsOf: resourceRoot.appendingPathComponent("data/garrison_board_refs.json")))
    }

    var mapIds: [String] { refs.map { Array($0.maps.keys).sorted() } ?? [] }

    /// - Parameters:
    ///   - mapId: known map (later rounds) — only the camera is fitted.
    ///   - boss: boss round (both mirrored boards are on screen).
    func recognize(_ viewport: CGImage, mapId: String? = nil, boss: Bool = false) -> BoardMatch? {
        guard let refs, let px = Self.normalised(viewport) else { return nil }
        struct Fit { let map: String; let camera: String; let projection: BoardProjection; let full: Double; let trimmed: Double; let scale: Double; let x: Double; let y: Double; let side: String? }
        var candidates: [Fit] = []
        let useBoss = boss && mapId != nil
        for side in (useBoss ? ["left", "right"] : [String?.none]) {
            for camera in ["collapsed", "expanded"] {
                guard let corners = (side == "right" ? refs.bossCameras : refs.cameras)[camera] else { continue }
                let excluded: Set<String>? = useBoss ? Self.changedCells(refs.bossTerrain[mapId!], side: side!) : nil
                var best: Fit?
                func evaluate(_ scale: Double, _ dx: Double, _ dy: Double) {
                    let moved = corners.map { c in [c[0], [(c[1][0] - 0.5) * scale + 0.5 + dx, (c[1][1] - 0.5) * scale + 0.5 + dy]] }
                    guard let proj = BoardProjection(corners: moved) else { return }
                    let samples = Self.sample(px, proj, excluded)
                    for (map, cams) in refs.maps where mapId == nil || map == mapId {
                        guard let ref = cams[camera] ?? cams.values.first else { continue }
                        let (full, trimmed) = Self.distance(samples, ref)
                        let fit = Fit(map: map, camera: camera, projection: proj, full: full, trimmed: trimmed, scale: scale, x: dx, y: dy, side: side)
                        candidates.append(fit)
                        let rank = mapId == nil ? full : trimmed
                        if best == nil || rank < (mapId == nil ? best!.full : best!.trimmed) { best = fit }
                    }
                }
                if useBoss {
                    for x in -1...1 { for y in -1...1 { evaluate(1, Double(x) * 0.005 / 3, Double(y) * 0.005 / 3) } }
                } else {
                    for s in -1...2 { for x in -1...1 { for y in -1...1 { evaluate(1 + Double(s) * 0.08, Double(x) * 0.025, Double(y) * 0.03) } } }
                    for step in [0.02, 0.005] {
                        guard let c = best else { break }
                        for s in -1...1 { for x in -1...1 { for y in -1...1 {
                            evaluate(c.scale + Double(s) * step, c.x + Double(x) * step / 3, c.y + Double(y) * step / 3)
                        } } }
                    }
                }
            }
        }
        func rank(_ f: Fit) -> Double { mapId == nil ? f.full : f.trimmed }
        guard let winner = candidates.min(by: { rank($0) < rank($1) }) else { return nil }
        let gap = mapId == nil ? (candidates.filter { $0.map != winner.map }.map(\.full).min() ?? 99) - winner.full : nil
        let limit = useBoss ? 40.0 : 14.0
        if ProcessInfo.processInfo.environment["BOARD_DEBUG"] != nil {
            print("board winner \(winner.map) \(winner.camera) full \(winner.full) trimmed \(winner.trimmed) gap \(gap ?? -1)")
        }
        guard winner.trimmed <= limit, gap.map({ $0 >= 3 }) ?? true else { return nil }
        return BoardMatch(mapId: winner.map, expanded: winner.camera == "expanded", side: winner.side,
                          projection: winner.projection, score: winner.trimmed, gap: gap)
    }

    // MARK: Helpers

    /// Cover-crop to 16:9 and downscale to 400×225 (sampling area as upstream).
    private static func normalised(_ img: CGImage) -> PixelBuffer? {
        let w = Double(img.width), h = Double(img.height)
        let s = max(1920 / w, 1080 / h)
        let k = 400.0 / 1920
        guard let ctx = CGContext(data: nil, width: 400, height: 225, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let sw = w * s * k, sh = h * s * k
        ctx.draw(img, in: CGRect(x: -(sw - 400) / 2, y: -(sh - 225) / 2, width: sw, height: sh))
        return ctx.makeImage().map(PixelBuffer.init)
    }

    private static func sample(_ px: PixelBuffer, _ p: BoardProjection, _ excluded: Set<String>?) -> [[Double]?] {
        var out: [[Double]?] = []
        for r in 0...4 {
            for c in -1...7 {
                for (sx, sy) in [(0.32, 0.72), (0.72, 0.32)] {
                    if excluded?.contains("\(c),\(r)") == true { out.append(nil); continue }
                    let q = p.project(Double(c) + sx, Double(r) + sy)
                    let q2 = p.project(Double(c) + sx + 0.1, Double(r) + sy)
                    let radius = max(2, Int(abs(q2.x - q.x) * Double(px.width)))
                    out.append(mean(px, Int(q.x * Double(px.width)), Int(q.y * Double(px.height)), radius))
                }
            }
        }
        return out
    }

    private static func mean(_ px: PixelBuffer, _ x: Int, _ y: Int, _ radius: Int) -> [Double] {
        var r = 0, g = 0, b = 0, n = 0
        for yy in max(0, y - radius)...min(px.height - 1, y + radius) where yy >= 0 {
            for xx in max(0, x - radius)...min(px.width - 1, x + radius) where xx >= 0 {
                let c = px.rgb(xx, yy); r += c.r; g += c.g; b += c.b; n += 1
            }
        }
        return n == 0 ? [0, 0, 0] : [Double(r / n), Double(g / n), Double(b / n)]
    }

    private static func distance(_ a: [[Double]?], _ ref: [[Double]]) -> (Double, Double) {
        var d: [Double] = []
        for (i, s) in a.enumerated() where i < ref.count {
            guard let s else { continue }
            let e = ref[i]
            d.append(min(45, ((s[0] - e[0]) * (s[0] - e[0]) + (s[1] - e[1]) * (s[1] - e[1]) + (s[2] - e[2]) * (s[2] - e[2])).squareRoot()))
        }
        guard !d.isEmpty else { return (99, 99) }
        let full = d.reduce(0, +) / Double(d.count)
        let sorted = d.sorted()
        let keep = max(1, Int(Double(sorted.count) * 0.7))
        return (full, sorted.prefix(keep).reduce(0, +) / Double(keep))
    }

    /// Cells whose terrain differs between the normal and the boss board (rows −1..4, columns −1..7).
    private static func changedCells(_ terrain: [String: [[Int]]]?, side: String) -> Set<String> {
        guard let t = terrain, let normal = t["normal"], let boss = t[side] else { return [] }
        var out = Set<String>()
        for r in 0..<min(6, normal.count) { for c in 0..<min(9, normal[r].count) {
            let a = normal[r][c], b = boss[r][c]
            if a != b || ((a | b) & 2) != 0 { out.insert("\(c - 1),\(r - 1)") }
        } }
        return out
    }
}

/// Maps the normalised 16:9 board frame back to viewport pixels (inverse of the cover crop).
struct CoverTransform {
    let viewport: CGSize
    var scale: Double { max(1920 / viewport.width, 1080 / viewport.height) }
    func toViewport(_ p: CGPoint) -> CGPoint {   // p normalised in the 1920×1080 frame
        let s = scale, ox = (viewport.width * s - 1920) / 2, oy = (viewport.height * s - 1080) / 2
        return CGPoint(x: (p.x * 1920 + ox) / s, y: (p.y * 1080 + oy) / s)
    }
    func fromViewport(_ p: CGPoint) -> CGPoint {
        let s = scale, ox = (viewport.width * s - 1920) / 2, oy = (viewport.height * s - 1080) / 2
        return CGPoint(x: (p.x * s - ox) / 1920, y: (p.y * s - oy) / 1080)
    }
}
