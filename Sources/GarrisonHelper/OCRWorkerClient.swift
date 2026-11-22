import CoreGraphics
import Foundation

/// Runs Vision text recognition in the OCRWorker process (next to the app's executable) and restarts it when it fails.
/// Why: on a nearly full disk macOS purges the Neural Engine's compiled-model cache, and a process that is already using
/// Vision's text model then fails every request (e5rtError 13 / CRImageReaderError 1) until it exits — retries, the GPU
/// and the older model don't help. A fresh process recompiles the model (a few seconds) and works again.
final class OCRWorkerClient: @unchecked Sendable {
    static let shared = OCRWorkerClient()

    private let lock = NSLock()
    private var process: Process?
    private var toWorker: FileHandle?
    private var fromWorker: FileHandle?
    /// Worker restarts so far (shown in the status when OCR keeps failing).
    private(set) var restarts = 0

    private var workerURL: URL? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let url = exe.deletingLastPathComponent().appendingPathComponent("OCRWorker")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The app uses the worker when it ships next to the executable; command-line self-tests stay in-process unless
    /// OCR_WORKER=1.
    var enabled: Bool {
        guard workerURL != nil else { return false }
        return Bundle.main.bundleURL.pathExtension == "app" || ProcessInfo.processInfo.environment["OCR_WORKER"] != nil
    }

    struct WorkerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func recognize(_ image: CGImage) throws -> [OCRText] {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try exchange(image)
        } catch {
            // Whatever went wrong (Vision refused, the worker died or hung), the next request gets a fresh worker.
            stop()
            restarts += 1
            throw error
        }
    }

    private func start() throws {
        guard let url = workerURL else { throw WorkerError(message: "找不到 OCRWorker") }
        let p = Process()
        p.executableURL = url
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        toWorker = inPipe.fileHandleForWriting
        fromWorker = outPipe.fileHandleForReading
    }

    private func stop() {
        if let p = process, p.isRunning { p.terminate() }
        try? toWorker?.close()
        process = nil; toWorker = nil; fromWorker = nil; answered = false
    }
    /// The current worker has answered once (its model is compiled).
    private var answered = false

    /// Starts the worker and lets it compile Vision's text model in the background, so the first real frame is fast.
    func warmUp() {
        guard enabled else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            if let img = ctx.makeImage() { _ = try? recognize(img) }
        }
    }

    private func exchange(_ image: CGImage) throws -> [OCRText] {
        if process?.isRunning != true { stop(); try start() }
        guard let toWorker, let fromWorker, let p = process else { throw WorkerError(message: "OCRWorker 没有启动") }
        // Pixels as RGBA (premultiplied last), the layout the worker expects.
        let w = image.width, h = image.height, bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        let drawn = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw WorkerError(message: "图像转换失败") }
        var header = Data("OCR1".utf8)
        for v in [w, h, bpr] { var x = UInt32(v).littleEndian; header.append(Data(bytes: &x, count: 4)) }
        // A hung worker is killed so the blocking read below returns. A new worker's first request compiles Vision's
        // text model (20 s or more on a busy machine), so it gets much longer.
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + (answered ? 20 : 240), execute: timeout)
        defer { timeout.cancel() }
        do {
            try toWorker.write(contentsOf: header)
            try toWorker.write(contentsOf: Data(bytes))
        } catch {
            throw WorkerError(message: "OCRWorker 已退出")
        }
        guard let lenData = read(fromWorker, 4) else { throw WorkerError(message: "OCRWorker 没有回应") }
        let len = lenData.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard len > 0, len < 64 << 20, let body = read(fromWorker, len),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw WorkerError(message: "OCRWorker 回应不完整") }
        guard json["ok"] as? Bool == true, let lines = json["lines"] as? [[String: Any]] else {
            throw WorkerError(message: json["error"] as? String ?? "文字识别失败")
        }
        let size = CGSize(width: w, height: h)
        func rect(_ a: Any?) -> CGRect? {
            guard let v = a as? [Double], v.count == 4 else { return nil }
            return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        answered = true
        return lines.compactMap { l in
            guard let t = l["t"] as? String, let b = rect(l["b"]) else { return nil }
            let chars = (l["c"] as? [Any])?.map { rect($0) }
            return OCRText(text: t, box: b, observation: nil, imageSize: size, charBoxes: chars)
        }
    }

    private func read(_ h: FileHandle, _ n: Int) -> Data? {
        var data = Data()
        while data.count < n {
            guard let chunk = try? h.read(upToCount: n - data.count), !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }
}
