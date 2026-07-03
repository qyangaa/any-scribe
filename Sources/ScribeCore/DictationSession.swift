import Foundation

/// One-shot voice capture → transcription, for push-to-talk voice input. Warms the shared
/// whisper-server while the user speaks, streams a live preview of the growing transcript, then
/// transcribes the full clip once on release for a clean insert.
public final class DictationSession: @unchecked Sendable {
    private let config: Config
    private let serverManager: WhisperServerManager
    private var mic: MicCapture?
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var warmTask: Task<Void, Error>?
    private var previewTask: Task<Void, Never>?

    /// Called (off the main thread) with the growing transcript while recording, for a live preview.
    public var onPartial: (@Sendable (String) -> Void)?

    public init(config: Config, serverManager: WhisperServerManager) {
        self.config = config
        self.serverManager = serverManager
    }

    /// Start warming the server and capturing the mic (16 kHz mono accumulated in memory).
    public func start(echoCancellation: Bool) throws {
        guard FileManager.default.fileExists(atPath: config.modelPath.path) else {
            throw ScribeError.missingModel(config.model)
        }
        lock.lock(); buffer.removeAll(); lock.unlock()

        let manager = serverManager
        let cfg = config
        let warm = Task { try await manager.ensureRunning(config: cfg) }
        warmTask = warm

        let mic = MicCapture(preferredDeviceName: config.micDeviceName, echoCancellation: echoCancellation) { [weak self] samples in
            guard let self else { return }
            self.lock.lock(); self.buffer.append(contentsOf: samples); self.lock.unlock()
        }
        try mic.start()
        self.mic = mic
        startPreviewLoop(warm: warm)
    }

    /// Stop capturing, transcribe the full buffered audio (biased by vocabulary), return trimmed text.
    public func finish() async throws -> String {
        previewTask?.cancel(); previewTask = nil
        mic?.stop(); mic = nil
        lock.lock(); let samples = buffer; buffer.removeAll(); lock.unlock()
        guard samples.count >= Int(0.3 * Audio.targetRate) else { return "" }
        try await warmTask?.value
        return try await transcribe(samples)
    }

    public func cancel() {
        previewTask?.cancel(); previewTask = nil
        mic?.stop(); mic = nil
        warmTask?.cancel()
        lock.lock(); buffer.removeAll(); lock.unlock()
    }

    // MARK: - Private

    private func startPreviewLoop(warm: Task<Void, Error>) {
        guard onPartial != nil else { return }
        previewTask = Task { [weak self] in
            try? await warm.value   // wait for the server to be ready
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled, let self else { break }
                let snapshot = self.snapshot()
                guard snapshot.count >= Int(0.5 * Audio.targetRate) else { continue }
                if let text = try? await self.transcribe(snapshot), !text.isEmpty {
                    self.onPartial?(text)
                }
            }
        }
    }

    private func snapshot() -> [Float] {
        lock.lock(); let s = buffer; lock.unlock(); return s
    }

    private func transcribe(_ samples: [Float]) async throws -> String {
        let wav = Audio.wavData(samples)
        let client = WhisperClient(inferenceURL: config.inferenceURL)
        let language = config.micLanguage ?? config.language
        let text = try await client.transcribe(wav: wav, language: language, prompt: config.effectivePrompt())
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
