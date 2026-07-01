import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A SwiftUI control that records a global hotkey: click it, press a modifier+key combo, done.
struct HotKeyRecorder: NSViewRepresentable {
    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ nsView: RecorderButton, context: Context) {}
}

/// Button that, while "recording", captures the next modifier+key press, saves it, and
/// (re)registers the global hotkey. Esc cancels.
final class RecorderButton: NSButton {
    private var monitor: Any?
    private var recording = false { didSet { refreshTitle() } }

    init() {
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
        title = recording ? "Press keys… (Esc cancels)" : HotKeyStore.load().display
    }

    @objc private func clicked() {
        if recording { stopRecording(); return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if Int(event.keyCode) == kVK_Escape { self.stopRecording(); return nil }

            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else { return nil }   // require at least one modifier

            let key = event.charactersIgnoringModifiers ?? "?"
            let combo = HotKeyCombo(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: HotKeyFormat.carbonModifiers(flags),
                display: HotKeyFormat.display(flags, key: key)
            )
            HotKeyStore.save(combo)
            GlobalHotKey.shared.register(combo)
            self.stopRecording()
            return nil
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
