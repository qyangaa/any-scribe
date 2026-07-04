import AppKit
import ScribeCore

/// Drives a push-to-talk voice-input session: hold the hotkey → speak → release → paste at cursor.
@MainActor
final class PushToTalkController {
    private let serverManager: WhisperServerManager
    private let hud = ListeningHUD()
    private var session: DictationSession?
    private var active = false

    /// The app sets this so PTT is ignored while a meeting recording is running (single mic).
    var isMeetingRecording: () -> Bool = { false }

    init(serverManager: WhisperServerManager) {
        self.serverManager = serverManager
    }

    /// Hotkey pressed — start listening.
    func begin() {
        guard !active, !isMeetingRecording() else { return }
        let config = Config.loadOrDefaults()
        let session = DictationSession(config: config, serverManager: serverManager)
        do {
            try session.start(echoCancellation: config.echoCancellationOn)
        } catch let error as ScribeError {
            if case .missingModel = error { hud.show("No model — open Settings") }
            else { hud.show("Mic unavailable") }
            autoHide()
            return
        } catch {
            hud.show("Mic unavailable"); autoHide(); return
        }
        self.session = session
        active = true
        hud.show("🎙 Listening…")
    }

    /// Hotkey released — transcribe and paste.
    func end() {
        guard active, let session else { return }
        active = false
        hud.update("Transcribing…")
        Task {
            do {
                let text = try await session.finish()
                self.session = nil
                self.deliver(text)
            } catch {
                self.session = nil
                self.hud.show("Transcription failed")
                self.autoHide()
            }
        }
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else { hud.hide(); return }
        guard TextInserter.isTrusted else {
            TextInserter.requestTrust()
            TextInserter.openAccessibilitySettings()
            hud.show("Enable Accessibility, then try again")
            autoHide(3)
            return
        }
        hud.hide()
        TextInserter.paste(text)
    }

    private func autoHide(_ seconds: Double = 1.6) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.hud.hide() }
    }
}
