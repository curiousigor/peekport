import AppKit
import Carbon.HIToolbox

/// The system-wide shortcut. Carbon's RegisterEventHotKey is still the supported way to do
/// this; a global NSEvent monitor would need Accessibility permission. The key press is
/// consumed, so it never reaches the frontmost app.
enum GlobalHotKey {
    struct Shortcut: Equatable {
        let keyCode: UInt32
        /// Carbon modifier flags (`controlKey | optionKey`).
        let modifiers: UInt32
        /// As recorded, "⌃⌥P"; translating a key code back needs the keyboard layout.
        let display: String

        /// ⌃⌥P. ⌥⌘P is Finder's Show Path Bar, and a global hotkey would steal it.
        static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥P")
    }

    static var shortcut: Shortcut {
        let defaults = UserDefaults.standard
        guard let display = defaults.string(forKey: "hotKeyDisplay") else { return .standard }
        return Shortcut(keyCode: UInt32(defaults.integer(forKey: "hotKeyCode")),
                        modifiers: UInt32(defaults.integer(forKey: "hotKeyModifiers")), display: display)
    }

    static var display: String { shortcut.display }

    private static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            GlobalHotKey.action?()
            return noErr
        }, 1, &spec, nil, nil)
        if !enable(shortcut) { _ = enable(.standard) }
    }

    /// Switches to `new` and saves it. False, with the old shortcut still active, when
    /// macOS refuses it (another app already holds it).
    static func change(to new: Shortcut) -> Bool {
        let old = shortcut
        pause()
        guard enable(new) else {
            _ = enable(old)
            return false
        }
        let defaults = UserDefaults.standard
        defaults.set(Int(new.keyCode), forKey: "hotKeyCode")
        defaults.set(Int(new.modifiers), forKey: "hotKeyModifiers")
        defaults.set(new.display, forKey: "hotKeyDisplay")
        return true
    }

    /// While recording a new shortcut, the old one must not open the panel.
    static func pause() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    static func resume() {
        if ref == nil { _ = enable(shortcut) }
    }

    private static func enable(_ shortcut: Shortcut) -> Bool {
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: OSType(0x7065_656B), id: 1), // "peek"
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr else { return false }
        ref = newRef
        return true
    }

    /// The shortcut a key press in the recorder stands for, or nil without ⌘, ⌃ or ⌥:
    /// a plain letter as a global hotkey would swallow that letter everywhere.
    static func shortcut(from event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var modifiers = 0
        var symbols = ""
        if flags.contains(.control) { modifiers |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { modifiers |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { modifiers |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { modifiers |= cmdKey; symbols += "⌘" }
        let key = keyNames[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers), display: symbols + key)
    }

    /// Keys whose character is invisible or misleading.
    private static let keyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
