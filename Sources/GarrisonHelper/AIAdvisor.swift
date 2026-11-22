import AppKit
import Foundation

// MARK: - Providers

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case deepseek, claude, qwen, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .claude: "Claude（Anthropic）"
        case .qwen: "通义千问（阿里云百炼）"
        case .custom: "自定义（OpenAI 兼容）"
        }
    }
    var defaultBase: String {
        switch self {
        case .deepseek: "https://api.deepseek.com"
        case .claude: "https://api.anthropic.com"
        case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .custom: "http://localhost:11434/v1"
        }
    }
    var defaultModel: String {
        switch self {
        case .deepseek: "deepseek-chat"
        case .claude: "claude-opus-5-5"
        case .qwen: "qwen-plus"
        case .custom: "qwen2.5:7b"
        }
    }
    var isAnthropic: Bool { self == .claude }
    var keyHint: String {
        switch self {
        case .deepseek: "platform.deepseek.com 申请"
        case .claude: "console.anthropic.com 申请"
        case .qwen: "阿里云百炼控制台申请"
        case .custom: "本地模型可留空"
        }
    }
}

/// API keys in a file only this user can read: `~/Library/Application Support/卫戍协议小助手/api-keys.json` (0600).
/// Not the Keychain: the app is signed ad hoc, so every rebuild is a new app to the Keychain and macOS asked for the
/// login password again (the user asked for no Keychain prompts, 2026-11-22). Keys saved in the Keychain by older
/// builds are not read back (that read is exactly the prompt); enter them again once.
enum APIKeyStore {
    private static func account(_ p: AIProvider) -> String { p == .claude ? "anthropic-api-key" : "api-key-\(p.rawValue)" }

    private static var file: URL {
        // Tests point this elsewhere so they never touch the player's own keys.
        if let p = ProcessInfo.processInfo.environment["GH_KEYS_FILE"] { return URL(fileURLWithPath: p) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("卫戍协议小助手", isDirectory: true).appendingPathComponent("api-keys.json")
    }

    private static func all() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return dict
    }

    static func load(_ p: AIProvider) -> String? {
        let key = all()[account(p)]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    static func save(_ key: String, for p: AIProvider) {
        var dict = all()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        dict[account(p)] = trimmed.isEmpty ? nil : trimmed
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        // Created with owner-only permissions before the key is written.
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try? data.write(to: file)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// How hard the AI coach works on one question: one setting instead of separate detail / thinking / effort switches.
enum AIStrength: String, CaseIterable, Identifiable {
    case fast, standard, deep
    var id: String { rawValue }
    var title: String {
        switch self { case .fast: "快"; case .standard: "标准"; case .deep: "深入" }
    }
    var explain: String {
        switch self {
        case .fast: "快：精简局面 + 最多约 100 字的回答，不让模型先思考。作战中用这个，一般几秒内出结果"
        case .standard: "标准：附带完整资料（盟约、干员特性），回答更全，约 300 字；慢一些，费用多一些"
        case .deep: "深入：完整资料，并允许模型先思考（DeepSeek 打开思考，Claude 用 high）；最慢、最贵，适合休整期慢慢想"
        }
    }
    /// Full reference in the prompt and the longer answer format.
    var detailed: Bool { self != .fast }
    var thinking: Bool { self == .deep }
    var claudeEffort: String {
        switch self { case .fast: "low"; case .standard: "medium"; case .deep: "high" }
    }
}

struct AIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AITiming { var firstToken: Double?; var total: Double }

struct AIConfig {
    var provider: AIProvider
    var baseURL: String
    var model: String
    var key: String?
    var claudeEffort = "low"
    var claudeFast = false
    /// Let OpenAI-compatible thinking models think (slower; DeepSeek is asked not to by default).
    var thinking = false
}

/// Streams one request to either the Claude Messages API or an OpenAI-compatible Chat Completions API.
struct AIClient {
    let config: AIConfig

    func stream(system: String, cachedContext: String?, user: String, image: CGImage? = nil, maxTokens: Int,
                json: Bool = false, onText: @escaping @MainActor (String) -> Void) async throws -> (String, AITiming) {
        let start = CFAbsoluteTimeGetCurrent()
        var first: Double?
        var text = ""
        let request = try config.provider.isAnthropic
            ? anthropicRequest(system: system, cached: cachedContext, user: user, image: image, maxTokens: maxTokens)
            : openAIRequest(system: system, cached: cachedContext, user: user, image: image, maxTokens: maxTokens, json: json)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var raw = ""
            for try await line in bytes.lines { raw += line; if raw.count > 2000 { break } }
            let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            let msg = (obj?["error"] as? [String: Any])?["message"] as? String ?? (obj?["message"] as? String)
            throw AIError(message: "HTTP \(http.statusCode)：\(msg ?? String(raw.prefix(300)))")
        }
        var stop: String?
        var thought = 0           // reasoning characters (thinking models stream them in reasoning_content)
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
            var piece: String?
            if config.provider.isAnthropic {
                switch obj["type"] as? String {
                case "content_block_delta":
                    if let d = obj["delta"] as? [String: Any], d["type"] as? String == "text_delta" { piece = d["text"] as? String }
                case "message_delta":
                    stop = (obj["delta"] as? [String: Any])?["stop_reason"] as? String
                case "error":
                    throw AIError(message: (obj["error"] as? [String: Any])?["message"] as? String ?? "未知错误")
                default: break
                }
            } else if let choice = (obj["choices"] as? [[String: Any]])?.first {
                let delta = choice["delta"] as? [String: Any]
                piece = delta?["content"] as? String
                if let r = delta?["reasoning_content"] as? String { thought += r.count }
                if let f = choice["finish_reason"] as? String { stop = f }
            } else if let e = obj["error"] as? [String: Any] {
                throw AIError(message: e["message"] as? String ?? "未知错误")
            }
            if let p = piece, !p.isEmpty {
                if first == nil { first = (CFAbsoluteTimeGetCurrent() - start) * 1000 }
                text += p
                await onText(p)
            }
        }
        if stop == "refusal" { throw AIError(message: "模型拒绝了这次请求") }
        // Never end silently: say why nothing came back.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if thought > 0 {
                throw AIError(message: "模型（\(config.model)）只输出了思考过程（\(thought) 字），没来得及给出回答" + (stop == "length" ? "：输出上限被思考用完了" : "") + "。换不带思考的模型，或在设置里关掉思考")
            }
            throw AIError(message: "没有收到回答（结束原因：\(stop ?? "连接提前结束")，模型 \(config.model)）")
        }
        return (text, AITiming(firstToken: first, total: (CFAbsoluteTimeGetCurrent() - start) * 1000))
    }

    private func base(_ path: String) throws -> URL {
        var b = config.baseURL.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        guard let url = URL(string: b + path) else { throw AIError(message: "接口地址无效") }
        // The key travels in a request header: never over plain http, except to a model running on this Mac.
        let local = ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        if config.key != nil, url.scheme?.lowercased() != "https", !local {
            throw AIError(message: "接口地址不是 https，API Key 会被明文发送；请改成 https:// 开头（本机模型用 localhost 不受限）")
        }
        return url
    }

    private func anthropicRequest(system: String, cached: String?, user: String, image: CGImage?, maxTokens: Int) throws -> URLRequest {
        guard let key = config.key else { throw AIError(message: "请先在设置里填写 API Key") }
        var sys: [[String: Any]] = [["type": "text", "text": system]]
        if let cached { sys.append(["type": "text", "text": cached, "cache_control": ["type": "ephemeral"]]) }
        var content: [[String: Any]] = []
        if let image, let b64 = AIClient.jpegBase64(image) {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]])
        }
        content.append(["type": "text", "text": user])
        var body: [String: Any] = [
            "model": config.model, "max_tokens": maxTokens, "stream": true,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": config.claudeEffort],
            "fallbacks": "default",
            "system": sys,
            "messages": [["role": "user", "content": content]],
        ]
        if config.claudeFast { body["speed"] = "fast" }
        var req = URLRequest(url: try base("/v1/messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func openAIRequest(system: String, cached: String?, user: String, image: CGImage?, maxTokens: Int, json: Bool) throws -> URLRequest {
        // Stable prefix first (system + catalog) so providers with automatic prefix caching (DeepSeek, 百炼) can reuse it.
        var messages: [[String: Any]] = [["role": "system", "content": system + (cached.map { "\n\n" + $0 } ?? "")]]
        if let image, let b64 = AIClient.jpegBase64(image) {
            messages.append(["role": "user", "content": [
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]],
                ["type": "text", "text": user],
            ]])
        } else {
            messages.append(["role": "user", "content": user])
        }
        var body: [String: Any] = ["model": config.model, "messages": messages, "stream": true, "max_tokens": maxTokens, "temperature": 0.3]
        if json { body["response_format"] = ["type": "json_object"] }
        // DeepSeek's current models (deepseek-flash …) think by default; the coach wants a fast, short answer.
        if config.provider == .deepseek && !config.thinking { body["thinking"] = ["type": "disabled"] }
        // A thinking model needs room for the reasoning before the answer.
        if config.thinking { body["max_tokens"] = max(maxTokens, 4000) }
        var req = URLRequest(url: try base("/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key = config.key { req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func jpegBase64(_ image: CGImage, maxSide: Int = 1280) -> String? {
        let k = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = Int(Double(image.width) * k), h = Int(Double(image.height) * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage(),
              let jpg = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        return jpg.base64EncodedString()
    }
}

// MARK: - Prompts

enum AIPrompts {
    static let system = """
    你是《明日方舟》「卫戍协议·规程」（自走棋）的运营教练。玩家正在对局中，时间很紧：
    - 直接给结论，不寒暄、不复述局面、不解释规则。
    - 只用给出的干员、盟约、装备名称；不确定就说"不确定"，不要编造。
    要点：终端 N 本时商店最高刷 N 阶；三张同名合精锐；盟约按场上不同名干员人数激活（核心 3/6，附加见资料），调和给每个在场核心 +1；转职装备让干员额外获得盟约；叠层让已激活盟约成长。
    """

    /// Full reference (only for the detailed mode; cached by the provider when possible).
    static func catalog(_ c: Catalog) -> String {
        var lines: [String] = ["# 资料（规程 V3_1）", "## 盟约（名称｜类型｜激活人数｜效果）"]
        for cov in c.covenants {
            let eff = (c.covenantEffects[cov.name] ?? []).map { ($0.condition.isEmpty ? "" : "<\($0.condition)>") + $0.text }.joined(separator: "；")
            lines.append("\(cov.name)｜\(cov.isCore ? "核心" : "附加")｜\(cov.activateCount)｜\(eff)")
        }
        lines.append("## 干员（名称｜阶｜核心｜附加｜定位｜普通特性）")
        for o in c.operators where !o.isSelfSelected {
            let p = c.profiles[o.name]
            let cls = [p?.profession, p?.position].compactMap { $0 }.joined(separator: "/") + (p.map { $0.roleText.isEmpty ? "" : " " + $0.roleText } ?? "")
            lines.append("\(o.name)｜\(o.tier)｜\(o.coreCovenants.joined(separator: ","))｜\(o.additionalCovenants.joined(separator: ","))｜\(cls)｜\(o.normal.traits.map(\.traitDescription).joined(separator: "；"))")
        }
        return lines.joined(separator: "\n")
    }
}
