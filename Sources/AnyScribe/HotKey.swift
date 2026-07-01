import AppKit
import Carbon.HIToolbox

/// A recorded global hotkey: a virtual key code + Carbon modifier flags, plus a display string.
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    static let defaultCombo = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_R),
        carbonModifiers: UInt32(optionKey | cmdKey),
        display: "⌥⌘R"
    )
}

/// Persists the chosen hotkey in UserDefaults (no resource bundle needed).
enum HotKeyStore {
    private static let d = UserDefaults.standard
    static func load() -> HotKeyCombo {
        guard d.object(forKey: "hotKeyCode") != nil else { return .defaultCombo }
        return HotKeyCombo(
            keyCode: UInt32(d.integer(forKey: "hotKeyCode")),
            carbonModifiers: UInt32(d.integer(forKey: "hotKeyModifiers")),
            display: d.string(forKey: "hotKeyDisplay") ?? HotKeyCombo.defaultCombo.display
        )
    }
    static func save(_ c: HotKeyCombo) {
        d.set(Int(c.keyCode), forKey: "hotKeyCode")
        d.set(Int(c.carbonModifiers), forKey: "hotKeyModifiers")
        d.set(c.display, forKey: "hotKeyDisplay")
    }
}

/// Registers a single system-wide hotkey via Carbon `RegisterEventHotKey` (no Accessibility
/// permission required). Fires its handler on the main thread.
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onFire: (() -> Void)?
    private let hotKeyID = EventHotKeyID(signature: 0x41535352 /* 'ASSR' */, id: 1)

    /// Install the Carbon handler and register the saved hotkey.
    func start(handler: @escaping () -> Void) {
        onFire = handler
        installHandlerIfNeeded()
        register(HotKeyStore.load())
    }

    /// Register (replacing any previous) the given combo. Requires at least one modifier.
    func register(_ combo: HotKeyCombo) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        guard combo.carbonModifiers != 0 else { return }
        var ref: EventHotKeyRef?
        if RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                               GetApplicationEventTarget(), 0, &ref) == noErr {
            hotKeyRef = ref
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            Unmanaged<GlobalHotKey>.fromOpaque(userData!).takeUnretainedValue().onFire?()
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
    }
}

/// NSEvent modifier flags → Carbon mask + a human display string (⌃⌥⇧⌘KEY).
enum HotKeyFormat {
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }
    static func display(_ flags: NSEvent.ModifierFlags, key: String) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }
}
