import Foundation
import Combine
import ScribeCore

/// Observable wrapper around `Recorder` for the menu-bar UI.
@MainActor
final class RecorderViewModel: ObservableObject {
    enum State: Equatable { case idle, starting, recording }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lines: [Recorder.Line] = []
    @Published var lastError: String?
    @Published private(set) var savedPath: String?
    @Published private(set) var micLabel = "Me"
    @Published private(set) var systemLabel = "Them"

    private var recorder: Recorder?
    private var timer: Timer?
    private var startDate: Date?
    /// Shared with push-to-talk so the whisper-server stays warm across both modes.
    private let serverManager: WhisperServerManager

    init(serverManager: WhisperServerManager) {
        self.serverManager = serverManager
    }

    /// Called on app quit — stop the warm whisper-server so it doesn't outlive the app.
    func shutdownServer() {
        serverManager.shutdown()
    }

    func toggle() {
        switch state {
        case .idle: start()
        case .recording: stop()
        case .starting: break
        }
    }

    func start() {
        guard state == .idle else { return }
        state = .starting
        lines = []
        savedPath = nil
        lastError = nil

        let config = Config.loadOrDefaults()
        micLabel = config.micLabel
        systemLabel = config.systemLabel

        serverManager.idleSeconds = config.serverIdleSeconds
        let recorder = Recorder(config: config, serverManager: serverManager)
        recorder.onLine = { [weak self] line in
            guard let self else { return }
            Task { @MainActor in self.appendOrMerge(line) }
        }
        self.recorder = recorder

        Task { @MainActor in
            do {
                try await recorder.start()
                self.startDate = Date()
                self.state = .recording
                self.startTimer()
            } catch {
                self.recorder = nil
                self.state = .idle
                self.lastError = "\(error)"
            }
        }
    }

    func stop() {
        guard state == .recording || state == .starting else { return }
        let rec = recorder
        timer?.invalidate(); timer = nil
        Task { @MainActor in
            let path = await rec?.stop()
            self.recorder = nil
            self.savedPath = path
            self.elapsed = 0
            self.state = .idle
        }
    }

    /// Merge sliding-window overlap: if a new line on the same stream overlaps the previous one
    /// (one contains the other), refine that line in place instead of appending a duplicate.
    private func appendOrMerge(_ line: Recorder.Line) {
        if let i = lines.lastIndex(where: { $0.label == line.label
            && abs($0.time.timeIntervalSince(line.time)) <= 6
            && TranscriptText.isRedundant($0.text, line.text) }) {
            if line.text.count > lines[i].text.count { lines[i] = line }
            // else: shorter partial duplicate — drop
        } else {
            lines.append(line)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
