// Portions adapted from StrongholdAssistant (Apache-2.0) and rewritten in Swift for this Mac app; the upstream files are listed
// in REFERENCES.md and their licenses / NOTICEs are in licenses/.
import AppKit
import Carbon.HIToolbox

/// Global ⌃⌥H: hides / shows the helper window and the in-game overlay (for screenshots or streaming). A Carbon hot
/// key needs no accessibility permission (StrongholdAssistant has a hide hotkey too).
@MainActor
final class HideHotKey {
    static let shared = HideHotKey()
    static let label = "⌃⌥H"
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    /// Dock icon clicked while hidden: shows the helper again; false when it wasn't hidden.
    var reopen: (() -> Bool)?

    func setEnabled(_ on: Bool) { on ? register() : unregister() }

    private func register() {
        guard ref == nil else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in HideHotKey.shared.action?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4748_4B31), id: 1)   // 'GHK1'
        RegisterEventHotKey(UInt32(kVK_ANSI_H), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
