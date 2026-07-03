import AppKit
import Carbon.HIToolbox

/// A recorded hotkey: a virtual key code + Carbon modifier flags, plus a display string.
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    static let defaultToggle = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(optionKey | cmdKey), display: "⌥⌘R")
    static let defaultPTT = HotKeyCombo(
        keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥Space")
}

/// Persists hotkeys in UserDefaults, namespaced by name ("toggle", "ptt").
enum HotKeyStore {
    private static let d = UserDefaults.standard
    static func load(_ name: String) -> HotKeyCombo {
        guard d.object(forKey: "hotKeyCode.\(name)") != nil else {
            return name == "ptt" ? .defaultPTT : .defaultToggle
        }
        return HotKeyCombo(
            keyCode: UInt32(d.integer(forKey: "hotKeyCode.\(name)")),
            carbonModifiers: UInt32(d.integer(forKey: "hotKeyModifiers.\(name)")),
            display: d.string(forKey: "hotKeyDisplay.\(name)") ?? "?"
        )
    }
    static func save(_ name: String, _ c: HotKeyCombo) {
        d.set(Int(c.keyCode), forKey: "hotKeyCode.\(name)")
        d.set(Int(c.carbonModifiers), forKey: "hotKeyModifiers.\(name)")
        d.set(c.display, forKey: "hotKeyDisplay.\(name)")
    }
}

/// Registers system-wide hotkeys via Carbon (no Accessibility permission). Supports press and
/// release callbacks (release enables push-to-talk). Handlers fire on the main thread.
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    enum ID: UInt32 { case toggle = 1, ptt = 2 }
    static func id(forName name: String) -> ID { name == "ptt" ? .ptt : .toggle }

    private struct Reg { var ref: EventHotKeyRef?; var onDown: () -> Void; var onUp: (() -> Void)? }
    private var regs: [UInt32: Reg] = [:]
    private var handlerRef: EventHandlerRef?

    /// Register (replacing any prior) a hotkey with the given press/release handlers.
    func register(_ id: ID, combo: HotKeyCombo, onDown: @escaping () -> Void, onUp: (() -> Void)? = nil) {
        installHandlerIfNeeded()
        if let existing = regs[id.rawValue]?.ref { UnregisterEventHotKey(existing) }
        var ref: EventHotKeyRef?
        if combo.carbonModifiers != 0 {
            let hkID = EventHotKeyID(signature: 0x41535352 /* 'ASSR' */, id: id.rawValue)
            RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hkID,
                                GetApplicationEventTarget(), 0, &ref)
        }
        regs[id.rawValue] = Reg(ref: ref, onDown: onDown, onUp: onUp)
    }

    /// Re-register only the key combo for an already-registered id (keeps its handlers).
    func updateCombo(_ id: ID, combo: HotKeyCombo) {
        guard let existing = regs[id.rawValue] else { return }
        register(id, combo: combo, onDown: existing.onDown, onUp: existing.onUp)
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        let specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            guard let reg = me.regs[hkID.id] else { return noErr }
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { reg.onDown() }
            else { reg.onUp?() }
            return noErr
        }, 2, specs, selfPtr, &handlerRef)
    }
}

/// NSEvent modifier flags → Carbon mask + a display string (⌃⌥⇧⌘KEY).
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
        return s + key
    }
}
