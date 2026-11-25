import AVFoundation
import AppKit
import Foundation
import SwiftUI

/// Background music from a local folder the player picks, played at chosen moments of a match (联防 by default).
/// Nothing is bundled: game music is copyrighted. Files are shuffled; a new phase fades in, leaving it fades out after a
/// short grace period so one misread frame doesn't stop the song. Play / pause by hand overrides the automation until the
/// phase changes.
@MainActor
final class MusicPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// When the music plays.
    enum Moment: String, CaseIterable, Identifiable {
        case coDefense, battle, rest, boss, eliminated
        var id: String { rawValue }
        var label: String {
            switch self {
            case .coDefense: "联防"
            case .battle: "作战中（不含联防）"
            case .rest: "休整期"
            case .boss: "首领回合"
            case .eliminated: "出局后"
            }
        }
    }

    static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf"]

    @Published var enabled: Bool { didSet { save(); if !enabled { fadeOut() } } }
    @Published var folder: String? { didSet { save(); reload() } }
    @Published var moments: Set<Moment> { didSet { save() } }
    @Published var volume: Double { didSet { save(); if playing { player?.volume = Float(volume) } } }
    @Published private(set) var tracks: [URL] = []
    @Published private(set) var nowPlaying: String?
    @Published private(set) var playing = false
    @Published private(set) var error: String?

    private var player: AVAudioPlayer?
    private var queue: [URL] = []
    /// Set by the play / pause buttons; cleared when the match phase changes.
    private var manual: Bool?
    private var lastWanted: Bool?
    private var unwantedSince: Date?
    private var lastUpdate = Date.distantPast
    private var watchdog: Timer?
    private let defaults = UserDefaults.standard
    static let grace: TimeInterval = 4
    static let fade: TimeInterval = 1.5

    override init() {
        enabled = defaults.bool(forKey: "music.enabled")
        folder = defaults.string(forKey: "music.folder")
        let saved = defaults.stringArray(forKey: "music.moments") ?? [Moment.coDefense.rawValue]
        moments = Set(saved.compactMap(Moment.init(rawValue:)))
        volume = defaults.object(forKey: "music.volume") as? Double ?? 0.5
        super.init()
        reload()
        // No frames for a while (game closed, scanning stopped): fade out.
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playing, self.manual != true, Date().timeIntervalSince(self.lastUpdate) > 15 else { return }
                self.fadeOut()
            }
        }
    }

    private func save() {
        defaults.set(enabled, forKey: "music.enabled")
        defaults.set(folder, forKey: "music.folder")
        defaults.set(moments.map(\.rawValue).sorted(), forKey: "music.moments")
        defaults.set(volume, forKey: "music.volume")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "用这个文件夹"
        panel.message = "选一个放音乐的文件夹（mp3 / m4a / flac / wav…，包括子文件夹）"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    func reload() {
        guard let folder else { tracks = []; return }
        let root = URL(fileURLWithPath: folder)
        var found: [URL] = []
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in e where Self.extensions.contains(url.pathExtension.lowercased()) { found.append(url) }
        }
        tracks = found.sorted { $0.path < $1.path }
        queue = []
        error = tracks.isEmpty ? "这个文件夹里没有能播放的音乐文件" : nil
    }

    /// Whether the music should play in this phase of the match.
    static func wanted(_ moments: Set<Moment>, hud: HudReading, eliminated: Bool) -> Bool {
        if eliminated { return moments.contains(.eliminated) }
        if hud.coDefense && moments.contains(.coDefense) { return true }
        if hud.bossRound && moments.contains(.boss) { return true }
        if hud.inBattle && !hud.coDefense && moments.contains(.battle) { return true }
        if hud.isRest && !hud.otherBoard && moments.contains(.rest) { return true }
        return false
    }

    /// Called for every frame the helper reads.
    func update(hud: HudReading, eliminated: Bool) {
        lastUpdate = Date()
        guard enabled, !tracks.isEmpty else { return }
        let want = Self.wanted(moments, hud: hud, eliminated: eliminated)
        if want != lastWanted { manual = nil }
        lastWanted = want
        if manual != nil { return }
        if want {
            unwantedSince = nil
            if !playing { start() }
        } else if playing {
            if let since = unwantedSince {
                if Date().timeIntervalSince(since) >= Self.grace { fadeOut() }
            } else {
                unwantedSince = Date()
            }
        }
    }

    // MARK: Controls

    func togglePlay() {
        if playing { manual = false; fadeOut() } else { manual = true; start() }
    }

    func next() {
        player?.stop()
        player = nil
        playing = false
        start()
        if manual == nil, lastWanted != true { manual = true }
    }

    private func start() {
        guard !tracks.isEmpty else { return }
        if let p = player, !p.isPlaying, nowPlaying != nil {
            // Resume the paused song.
            p.volume = 0
            p.play()
            p.setVolume(Float(volume), fadeDuration: Self.fade)
            playing = true
            return
        }
        for _ in 0..<min(5, tracks.count) {
            if queue.isEmpty { queue = tracks.shuffled() }
            let url = queue.removeFirst()
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.volume = 0
                p.prepareToPlay()
                p.play()
                p.setVolume(Float(volume), fadeDuration: Self.fade)
                player = p
                nowPlaying = url.deletingPathExtension().lastPathComponent
                playing = true
                error = nil
                return
            } catch {
                self.error = "放不了：\(url.lastPathComponent)"
            }
        }
    }

    private func fadeOut() {
        guard let p = player, playing else { return }
        playing = false
        unwantedSince = nil
        p.setVolume(0, fadeDuration: Self.fade)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade) { [weak self] in
            guard let self, !self.playing, self.player === p else { return }
            p.pause()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player, self.playing else { return }
            self.player = nil
            self.playing = false
            self.nowPlaying = nil
            self.start()
        }
    }
}

// MARK: - Views

/// 设置 → 音乐.
struct MusicSettingsSection: View {
    @EnvironmentObject var music: MusicPlayer

    var body: some View {
        Section("音乐") {
            Toggle("对局中自动放音乐", isOn: $music.enabled)
            HStack {
                Text(music.folder.map { URL(fileURLWithPath: $0).lastPathComponent + "（\(music.tracks.count) 首）" } ?? "还没选文件夹")
                    .lineLimit(1).truncationMode(.middle)
                    .help(music.folder ?? "")
                Spacer()
                Button("选择文件夹…") { music.chooseFolder() }
                if music.folder != nil { Button("重新扫描") { music.reload() } }
            }
            Text("什么时候放（离开这个阶段几秒后淡出）").font(.caption).foregroundStyle(.secondary)
            ForEach(MusicPlayer.Moment.allCases) { m in
                Toggle(m.label, isOn: Binding(get: { music.moments.contains(m) },
                                              set: { on in if on { music.moments.insert(m) } else { music.moments.remove(m) } }))
            }
            HStack {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $music.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            if let e = music.error { Text(e).font(.caption).foregroundStyle(.orange) }
            Text("只放你自己文件夹里的音乐（mp3、m4a、flac、wav 等，含子文件夹），随机顺序。小助手不带任何音乐。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One line at the top of the sidebar while music is on: song, play / pause, next.
struct MusicMiniBar: View {
    @EnvironmentObject var music: MusicPlayer

    var body: some View {
        if music.enabled && !music.tracks.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: music.playing ? "music.note" : "music.note.list").foregroundStyle(music.playing ? .pink : .secondary)
                Text(music.nowPlaying.map { (music.playing ? "" : "已暂停：") + $0 } ?? "音乐：等到「\(music.moments.map(\.label).sorted().joined(separator: "、"))」时自动放")
                    .font(.caption).lineLimit(1).truncationMode(.tail)
                Spacer()
                Button { music.togglePlay() } label: { Image(systemName: music.playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(.borderless).help(music.playing ? "暂停（到下个阶段再自动控制）" : "现在就放")
                Button { music.next() } label: { Image(systemName: "forward.fill") }
                    .buttonStyle(.borderless).help("下一首")
            }
        }
    }
}
