import Foundation
import Combine
import ScribeCore

/// Observable wrapper around `Recorder` for the menu-bar UI.
@MainActor
final class RecorderViewModel: ObservableObject {
    enum State: Equatable { case idle, starting, recording, stopping }

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
    private var startTask: Task<Void, Never>?
    private var pendingStop = false
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
        case .starting, .recording: stop()
        case .stopping: break
        }
    }

    func start() {
        guard state == .idle else { return }
        state = .starting
        lines = []
        savedPath = nil
        lastError = nil
        pendingStop = false

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

        startTask = Task { @MainActor in
            do {
                try await recorder.start()
                if self.pendingStop {                 // user pressed stop during model load
                    await recorder.stop()
                    self.finishStopped(path: nil)
                    return
                }
                self.startDate = Date()
                self.state = .recording
                self.startTimer()
            } catch {
                let wasCancel = self.pendingStop
                await recorder.stop()                 // clean up any partial capture (mic/system)
                self.finishStopped(path: nil)
                if !(error is CancellationError) && !wasCancel { self.lastError = "\(error)" }
            }
        }
    }

    func stop() {
        switch state {
        case .starting:
            // Model still loading; can't cleanly interrupt it — stop as soon as startup finishes.
            pendingStop = true
            state = .stopping
        case .recording:
            state = .stopping                          // immediate feedback; teardown is async
            timer?.invalidate(); timer = nil
            let rec = recorder
            Task { @MainActor in
                let path = await rec?.stop()
                self.finishStopped(path: path)
            }
        case .idle, .stopping:
            break
        }
    }

    private func finishStopped(path: String?) {
        timer?.invalidate(); timer = nil
        recorder = nil
        startTask = nil
        pendingStop = false
        elapsed = 0
        if let path { savedPath = path }
        state = .idle
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
