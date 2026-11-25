import AppKit
import SwiftUI

@main
struct GarrisonHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var catalog: Catalog
    @StateObject private var run: RunState
    @StateObject private var scanner: Scanner
    @StateObject private var coach: Coach

    init() {
        SelfTest.runIfRequested()
        let c = Catalog()
        let r = RunState()
        _catalog = StateObject(wrappedValue: c)
        _run = StateObject(wrappedValue: r)
        let s = Scanner(catalog: c, run: r)
        _scanner = StateObject(wrappedValue: s)
        let coach = Coach(catalog: c, run: r, scanner: s)
        _coach = StateObject(wrappedValue: coach)
        HideHotKey.shared.action = { [weak coach] in coach?.toggleHidden() }
        HideHotKey.shared.reopen = { [weak coach] in
            guard let coach, coach.hidden else { return false }
            coach.toggleHidden()
            return true
        }
        HideHotKey.shared.setEnabled(coach.hideHotKey)
    }

    var body: some Scene {
        WindowGroup("卫戍协议小助手") {
            RootView()
                .environmentObject(catalog)
                .environmentObject(run)
                .environmentObject(scanner)
                .environmentObject(coach)
                .environmentObject(coach.history)
                .environmentObject(coach.music)
                .frame(minWidth: 380, idealWidth: 420, minHeight: 560, idealHeight: 760)
                .background(WindowAccessor { win in
                    scanner.sidebarWindow = win
                    win.level = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true ? .floating : .normal
                    win.collectionBehavior.insert(.fullScreenAuxiliary)
                })
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        // Floating guide (攻略悬浮窗), opened from the routes card.
        Window("攻略", id: "guide") {
            GuideView()
                .environmentObject(catalog)
                .environmentObject(run)
                .environmentObject(scanner)
                .environmentObject(coach)
        }
        .defaultSize(width: 320, height: 420)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    /// Dock icon while hidden with the hotkey: show the existing window again (not a second one).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let reopen = MainActor.assumeIsolated({ HideHotKey.shared.reopen }), reopen() { return false }
        return true
    }
}

/// Gives access to the hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
