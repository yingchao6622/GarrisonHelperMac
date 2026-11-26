import AppKit
import CryptoKit
import Foundation
import SwiftUI
import WebKit

// Ported from ASP_Assistant (Apache-2.0): src/ASPAssistant.Core/Services/GarrisonHistory.cs, GarrisonHistoryClient.cs and
// src/ASPAssistant.App/Services/HypergryphPassport.cs (passport sign-in, one-use code → Skland credential, request
// signature, role binding, season catalog and history-log). Record fields (elite = goldenChessId, bondInfo, acBossInfo,
// completeState) follow StrongholdAssistant src/StrongholdAssistant.Host/SklandParser.cs (Apache-2.0). See REFERENCES.md.
//
// The player signs in on the official Hypergryph page inside a web view; the helper never sees the password. Only the
// one-use code is taken from the page. The Skland credential lives in memory for this import only and is never saved.

/// One match from 森空岛 history-log, with ids already turned into names.
struct SklandMatch: Equatable {
    var id: String
    var started: Date?
    var ended: Date?
    var multiplayer: Bool
    var mode: String
    var rounds: Int
    var success: Bool
    var strategy: String?
    var lineup: [String]
    var elites: [String]
    var covenants: [String]
    var bosses: [String]
    var coinSpent: Int?
    var kills: Int?
}

enum SklandError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// Names for the ids in history-log, from the public season catalog (`resource`).
struct SklandCatalog {
    var operators: [String: String] = [:]
    var items: [String: String] = [:]
    var strategies: [String: String] = [:]
    var covenants: [String: String] = [:]
    var seasonId: String?

    init() {}

    init(json: Any) throws {
        let data = try SklandParse.data(json)
        func names(_ key: String, _ id: String) -> [String: String] {
            var out: [String: String] = [:]
            for x in data[key] as? [[String: Any]] ?? [] {
                if let i = x[id] as? String, let n = x["name"] as? String, !i.isEmpty, !n.isEmpty { out[i] = n }
            }
            return out
        }
        operators = names("chars", "charId")
        items = names("items", "itemId")
        strategies = names("strategies", "strategyId")
        covenants = names("bonds", "bondId")
        seasonId = (data["versionInfo"] as? [String: Any])?["seasonId"] as? String
        if operators.isEmpty || strategies.isEmpty { throw SklandError.message("森空岛的赛季数据格式有变化，暂时读不了。") }
    }
}

enum SklandParse {
    /// Difficulty codes (StrongholdAssistant history.svelte.ts) → our mode names.
    static let difficulty = ["FUNNY": "标准模拟", "NORMAL": "险境模拟", "HARD": "绝境模拟", "ABYSS": "终极模拟"]
    /// boss_N → enemyId (activity_table autoChessData.bossInfoDict, as listed in StrongholdAssistant SklandParser.cs).
    static let bossIds = [
        "boss_1": "enemy_9013_acstmk", "boss_2": "enemy_9017_achunt", "boss_3": "enemy_9021_acduml", "boss_4": "enemy_1521_dslily",
        "boss_6": "enemy_9032_aclionk", "boss_7": "enemy_9033_acdeer", "boss_8": "enemy_9013_acstmk", "boss_9": "enemy_9017_achunt",
        "boss_10": "enemy_9021_acduml", "boss_11": "enemy_9029_acfnc", "boss_12": "enemy_9035_acspider", "boss_13": "enemy_9037_aceel",
        "boss_14": "enemy_9029_acfnc", "boss_15": "enemy_9035_acspider", "boss_16": "enemy_9037_aceel", "boss_17": "enemy_2124_dyjsfg",
    ]

    static func data(_ json: Any) throws -> [String: Any] {
        guard let root = json as? [String: Any] else { throw SklandError.message("森空岛的返回格式有变化，暂时读不了。") }
        let code = int(root["code"])
        if code == 10002 || code == 10001 { throw SklandError.message("森空岛授权已失效，请重新登录。") }
        guard code == 0, let data = root["data"] as? [String: Any] else {
            let msg = (root["message"] as? String).map { "（\($0)）" } ?? ""
            throw SklandError.message("森空岛没有返回数据\(msg)，请稍后再试。")
        }
        return data
    }

    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func date(_ v: Any?) -> Date? {
        guard let t = int(v), t > 0, t < 253_402_300_799 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(t))
    }

    /// history-log → matches, newest first.
    static func history(_ json: Any, _ cat: SklandCatalog, bossName: (String) -> String?) throws -> [SklandMatch] {
        let data = try data(json)
        guard let records = data["records"] as? [[String: Any]] else { throw SklandError.message("森空岛的战绩格式有变化，暂时读不了。") }
        var seen = Set<String>(), out: [SklandMatch] = []
        for r in records {
            guard let id = (r["id"] as? String) ?? int(r["id"]).map(String.init), !id.isEmpty, seen.insert(id).inserted else { continue }
            var lineup: [String] = [], elites: [String] = []
            for o in r["chessSquad"] as? [[String: Any]] ?? [] {
                guard let cid = o["charId"] as? String, !cid.isEmpty else { continue }
                let name = cat.operators[cid] ?? cid
                lineup.append(name)
                if let chess = o["chessId"] as? String, let golden = (o["chessInfo"] as? [String: Any])?["goldenChessId"] as? String,
                   chess == golden { elites.append(name) }
            }
            let covenants = (r["bondInfo"] as? [[String: Any]] ?? []).compactMap { b -> String? in
                guard var bid = b["bondId"] as? String else { return nil }
                if let n = cat.covenants[bid] { return n }
                if bid.hasSuffix("Ship") { bid.removeLast(4) }
                return bid
            }
            let bosses = (r["acBossInfo"] as? [[String: Any]] ?? []).compactMap { b -> String? in
                guard let bid = b["bossId"] as? String else { return nil }
                let name = bossIds[bid].flatMap(bossName) ?? bid
                return name + ((b["isKilled"] as? Bool) == true ? "（击败）" : "")
            }
            let band = (r["bandId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let diff = r["modeDifficulty"] as? String ?? ""
            out.append(SklandMatch(
                id: id, started: date(r["gameStartTs"]), ended: date(r["gameEndTs"]),
                multiplayer: (r["modeType"] as? String) == "MULTI", mode: difficulty[diff] ?? diff,
                rounds: int(r["passRound"]) ?? 0, success: int(r["completeState"]) == 1,
                strategy: band.map { cat.strategies[$0] ?? $0 }, lineup: lineup, elites: elites, covenants: covenants,
                bosses: bosses, coinSpent: int(r["coinCost"]), kills: int(r["killCnt"])))
        }
        return out.sorted { ($0.ended ?? .distantPast) > ($1.ended ?? .distantPast) }
    }

    /// Request signature: MD5 of the hex HMAC-SHA256 (key: the Skland token) over path + query + timestamp + header JSON.
    static func sign(path: String, query: String, timestamp: String, token: String) -> String {
        let headers = "{\"platform\":\"3\",\"timestamp\":\"\(timestamp)\",\"dId\":\"\",\"vName\":\"1.0.0\"}"
        let message = path + query + timestamp + headers
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(token.utf8)))
        let hex = Data(mac).map { String(format: "%02x", $0) }.joined()
        return Insecure.MD5.hash(data: Data(hex.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Talks to zonai.skland.com: code → credential, role binding, season catalog, history-log.
struct SklandClient {
    struct Role { let uid: String; let gameId: Int; let isDefault: Bool; var header: String { "\(gameId)_\(uid)_0" } }

    private static let base = "https://zonai.skland.com"
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    private func request(_ path: String, query: String = "", method: String = "GET", body: Data? = nil,
                         signedBy auth: (cred: String, token: String)? = nil, role: Role? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: Self.base + path + (query.isEmpty ? "" : "?" + query))!)
        r.httpMethod = method
        let ts = String(Int(Date().timeIntervalSince1970))
        r.setValue("3", forHTTPHeaderField: "platform")
        r.setValue("1.0.0", forHTTPHeaderField: "vName")
        r.setValue(ts, forHTTPHeaderField: "timestamp")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let auth {
            r.setValue(auth.cred, forHTTPHeaderField: "cred")
            r.setValue(SklandParse.sign(path: path, query: query, timestamp: ts, token: auth.token), forHTTPHeaderField: "sign")
        }
        if let role { r.setValue(role.header, forHTTPHeaderField: "sk-game-role") }
        return r
    }

    private func json(_ r: URLRequest) async throws -> Any {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: r) } catch { throw SklandError.message("连不上森空岛，检查一下网络再试。") }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw SklandError.message("森空岛授权已失效，请重新登录。") }
        if status == 403 { throw SklandError.message("森空岛拒绝了这次请求，请稍后再试。") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw SklandError.message("森空岛的返回格式有变化（HTTP \(status)），暂时读不了。")
        }
        return obj
    }

    /// One-use passport code → (cred, token), then the bound Arknights role (the default one first).
    func authorize(code: String) async throws -> (cred: String, token: String, role: Role) {
        let body = try JSONSerialization.data(withJSONObject: ["kind": 1, "code": code])
        let grant = try SklandParse.data(try await json(request("/web/v1/user/auth/generate_cred_by_code", method: "POST", body: body)))
        guard let cred = grant["cred"] as? String, let token = grant["token"] as? String, !cred.isEmpty, !token.isEmpty,
              cred.count < 4096, !cred.contains(where: { $0.isNewline }) else {
            throw SklandError.message("没拿到森空岛授权，请重新登录鹰角账号再试。")
        }
        let binding = try SklandParse.data(try await json(request("/api/v1/game/player/binding", signedBy: (cred, token))))
        var roles: [Role] = []
        for game in binding["list"] as? [[String: Any]] ?? [] where game["appCode"] as? String == "arknights" {
            for b in game["bindingList"] as? [[String: Any]] ?? [] {
                let uid = (b["uid"] as? String) ?? SklandParse.int(b["uid"]).map(String.init) ?? ""
                guard !uid.isEmpty, uid.allSatisfy(\.isASCII), uid.allSatisfy(\.isNumber) else { continue }
                roles.append(Role(uid: uid, gameId: SklandParse.int(b["gameId"]) ?? 1, isDefault: b["isDefault"] as? Bool ?? false))
            }
        }
        guard let role = roles.first(where: \.isDefault) ?? roles.first else {
            throw SklandError.message("这个鹰角账号在森空岛还没有绑定明日方舟角色，先在森空岛 App 里绑定。")
        }
        return (cred, token, role)
    }

    func catalog() async throws -> SklandCatalog {
        try SklandCatalog(json: try await json(request("/web/v1/game/garrison/guide/resource")))
    }

    func history(cred: String, token: String, role: Role, season: String) async throws -> Any {
        let q = "seasonId=" + (season.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? season)
        return try await json(request("/web/v1/game/garrison/guide/history-log", query: q, signedBy: (cred, token), role: role))
    }
}

// MARK: - Sign-in window

/// The 「从森空岛导入」 flow: a window with the official Hypergryph sign-in page; once signed in, the season's matches are
/// read and merged into 对局记录.
@MainActor
final class SklandImporter: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSWindowDelegate {
    static let shared = SklandImporter()
    static let loginURL = URL(string: "https://user.hypergryph.com/login")!
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    private var window: NSWindow?
    private var web: WKWebView?
    private weak var history: MatchHistory?
    private var bossName: (String) -> String? = { _ in nil }
    private var done = false

    func open(history: MatchHistory, catalog: Catalog) {
        self.history = history
        let names = Dictionary(catalog.bosses.map { ($0.enemyId, $0.name) }, uniquingKeysWith: { a, _ in a })
        bossName = { names[$0] }
        if let window { window.makeKeyAndOrderFront(nil); return }
        done = false
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Tell the app when the passport page has saved a session (same signal ASP_Assistant waits for).
        let hook = """
        (() => {
          const ping = () => { try { window.webkit.messageHandlers.passport.postMessage('session') } catch (e) {} };
          const hit = (u, m, s) => /^https:\\/\\/web-api\\.hypergryph\\.com\\/account\\/info\\/hg/.test(String(u)) && String(m).toUpperCase() === 'POST' && s >= 200 && s < 300;
          const f = window.fetch;
          if (f) window.fetch = async (...a) => { const r = await f(...a); try { const req = a[0]; const m = (a[1] && a[1].method) || (req && req.method) || 'GET'; if (hit(r.url, m, r.status)) ping() } catch (e) {} return r };
          const open = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function (m, u, ...rest) { this.addEventListener('load', () => { if (hit(u, m, this.status)) ping() }); return open.call(this, m, u, ...rest) };
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(self, name: "passport")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 640), configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        self.web = web
        let root = NSHostingView(rootView: SklandWindowView(importer: self, web: web))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 720), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "从森空岛导入战绩"
        w.contentView = root
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.level = .floating
        w.center()
        window = w
        status = "在下面的鹰角官网登录（密码只在官网页面里输入，小助手碰不到）。登录好会自动读取。"
        w.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: Self.loginURL))
    }

    /// Forgets the Hypergryph / Skland sign-in kept by the web view.
    func signOut() {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let mine = records.filter { $0.displayName.contains("hypergryph") || $0.displayName.contains("skland") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine) {
                Task { @MainActor in
                    self.status = "已退出鹰角账号。"
                    self.web?.load(URLRequest(url: Self.loginURL))
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "passport")
        web = nil
        window = nil
        busy = false
    }

    private static func isPassport(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == loginURL.host && url.port == nil && url.user == nil
    }

    // Only the passport site may load in the main frame (as in ASP_Assistant); sub-frames (captcha) may load.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.targetFrame?.isMainFrame == false { return .allow }
        return Self.isPassport(action.request.url) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if Self.isPassport(action.request.url) { webView.load(action.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { Task { await pull(quiet: true) } }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadFailed(error) }
    private func loadFailed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled || (error as NSError).code == 102 { return }
        status = "鹰角官网打不开，检查一下网络再试。"
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in await self.pull(quiet: true) }
    }

    /// Asks the official sign-in SDK for a one-use Skland code (no code when nobody is signed in), then imports.
    func pull(quiet: Bool) async {
        guard let web, !busy, !done || !quiet, Self.isPassport(web.url) else { return }
        busy = true
        defer { busy = false }
        let script = """
        if (location.origin !== "https://user.hypergryph.com") return null;
        for (let i = 0; i < 40 && !window.HG_ACCOUNT_SDK?.User?.UI; i++) await new Promise(r => setTimeout(r, 250));
        const ui = window.HG_ACCOUNT_SDK?.User?.UI;
        if (typeof ui?.inheritSession !== "function") return { sdkReady: false };
        return await new Promise(resolve => {
          const t = setTimeout(() => resolve({ timeout: true }), 90000);
          ui.inheritSession({ oauth: { appCode: "4ca99fa6b56cc2ba", grantType: 0 } }, (status, data) => {
            clearTimeout(t);
            resolve({ code: status === 0 ? (data?.oauthInfo?.code ?? null) : null });
          });
        });
        """
        let value: Any?
        do { value = try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) } catch {
            if !quiet { status = "鹰角登录组件出错了，刷新页面再试。" }
            return
        }
        guard Self.isPassport(self.web?.url), let v = value as? [String: Any] else { return }
        if v["sdkReady"] as? Bool == false { if !quiet { status = "鹰角登录组件还在加载，稍等再试。" }; return }
        if v["timeout"] != nil { status = "鹰角授权超时了，点「读取战绩」再试。"; return }
        guard let code = v["code"] as? String, !code.isEmpty else {
            if !quiet { status = "还没登录：先在下面的页面登录鹰角账号。" }
            return
        }
        await importHistory(code: code)
    }

    private func importHistory(code: String) async {
        status = "正在读取森空岛战绩…"
        let client = SklandClient()
        do {
            let auth = try await client.authorize(code: code)
            let cat = try await client.catalog()
            guard let season = cat.seasonId else { throw SklandError.message("森空岛没有给出当前赛季，请稍后再试。") }
            let raw = try await client.history(cred: auth.cred, token: auth.token, role: auth.role, season: season)
            let matches = try SklandParse.history(raw, cat, bossName: bossName)
            guard let history else { return }
            let r = history.merge(matches)
            done = true
            status = matches.isEmpty ? "森空岛上本赛季还没有战绩。" :
                "读到本赛季 \(matches.count) 局：新增 \(r.added) 局，补全本机记录 \(r.merged) 局，\(r.unchanged) 局已经导入过。名次森空岛不提供，还是要自己填。"
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? "读取失败，请稍后再试。"
        }
    }
}

private struct SklandWindowView: View {
    @ObservedObject var importer: SklandImporter
    let web: WKWebView

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text(importer.status ?? "").font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if importer.busy { ProgressView().controlSize(.small) }
                Button("读取战绩") { Task { await importer.pull(quiet: false) } }.disabled(importer.busy)
                Button("退出登录") { importer.signOut() }.disabled(importer.busy)
            }
            .padding(8)
            Divider()
            WebViewHost(web: web)
        }
        .frame(minWidth: 400, minHeight: 560)
    }
}

private struct WebViewHost: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
