import CoreGraphics
import Foundation
import Vision

// Text recognition in its own process. On a nearly full disk macOS purges the Neural Engine's compiled-model cache;
// a process already using Vision's text model then fails every request (e5rtError 13 / CRImageReaderError 1) until it
// exits. The app runs OCR here and starts a fresh worker when that happens (see OCRWorkerClient).
//
// Protocol (stdin → stdout, little-endian):
//   request:  "OCR1", width u32, height u32, bytesPerRow u32, then height × bytesPerRow bytes of RGBA (premultiplied last)
//   response: length u32, then JSON {"ok":true,"lines":[{"t":text,"b":[x,y,w,h],"c":[[x,y,w,h],…]}]} or {"ok":false,"error":…}
//   Boxes are pixels with a top-left origin; "c" holds one box per character (for sub-string boxes).

setvbuf(stdout, nil, _IONBF, 0)
let input = FileHandle.standardInput
let output = FileHandle.standardOutput

func readExactly(_ n: Int) -> Data? {
    var data = Data()
    while data.count < n {
        let chunk = input.readData(ofLength: n - data.count)
        if chunk.isEmpty { return nil }
        data.append(chunk)
    }
    return data
}

func u32(_ d: Data, _ at: Int) -> Int {
    Int(d[d.startIndex + at]) | Int(d[d.startIndex + at + 1]) << 8 | Int(d[d.startIndex + at + 2]) << 16 | Int(d[d.startIndex + at + 3]) << 24
}

func reply(_ object: [String: Any]) {
    let json = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"ok\":false,\"error\":\"json\"}".utf8)
    var n = UInt32(json.count).littleEndian
    output.write(Data(bytes: &n, count: 4))
    output.write(json)
}

func pixels(_ r: CGRect, _ w: Double, _ h: Double) -> [Double] {
    [r.minX * w, (1 - r.maxY) * h, r.width * w, r.height * h]
}

while let header = readExactly(16) {
    guard header.prefix(4) == Data("OCR1".utf8) else { exit(2) }
    let width = u32(header, 4), height = u32(header, 8), bytesPerRow = u32(header, 12)
    guard width > 0, height > 0, bytesPerRow >= width * 4, let body = readExactly(height * bytesPerRow) else { exit(3) }
    autoreleasepool {
        guard let provider = CGDataProvider(data: body as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            reply(["ok": false, "error": "bad image"]); return
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            reply(["ok": false, "error": "\(error)"]); return
        }
        let w = Double(width), h = Double(height)
        var lines: [[String: Any]] = []
        for obs in request.results ?? [] {
            guard let top = obs.topCandidates(1).first else { continue }
            let s = top.string
            var chars: [[Double]] = []
            var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(after: i)
                if let r = try? top.boundingBox(for: i..<j)?.boundingBox { chars.append(pixels(r, w, h)) } else { chars.append([]) }
                i = j
            }
            lines.append(["t": s, "b": pixels(obs.boundingBox, w, h), "c": chars])
        }
        reply(["ok": true, "lines": lines])
    }
}
