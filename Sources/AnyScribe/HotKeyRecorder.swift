import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A SwiftUI control to record a global hotkey. `name` selects which one ("toggle" or "ptt").
struct HotKeyRecorder: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> RecorderButton { RecorderButton(name: name) }
    func updateNSView(_ nsView: RecorderButton, context: Context) {}
}

/// Button that, while "recording", captures the next modifier+key press, persists it, and
/// re-registers the corresponding global hotkey. Esc cancels.
final class RecorderButton: NSButton {
    private let name: String
    private var monitor: Any?
    private var recording = false { didSet { refreshTitle() } }

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        refreshTitle()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }
    deinit { removeMonitor() }

    private func refreshTitle() {
        title = recording ? "Press keys… (Esc cancels)" : HotKeyStore.load(name).display
    }

    @objc private func clicked() {
        if recording { stopRecording(); return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if Int(event.keyCode) == kVK_Escape { self.stopRecording(); return nil }

            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else { return nil }   // require at least one modifier

            let combo = HotKeyCombo(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: HotKeyFormat.carbonModifiers(flags),
                display: HotKeyFormat.display(flags, key: Self.keyName(for: event))
            )
            HotKeyStore.save(self.name, combo)
            GlobalHotKey.shared.updateCombo(GlobalHotKey.id(forName: self.name), combo: combo)
            self.stopRecording()
            return nil
        }
    }

    private static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_ANSI_Grave: return "`"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }

    private func stopRecording() {
        removeMonitor()
        recording = false
    }
    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
