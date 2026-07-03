import Foundation

/// One-shot voice capture → transcription, for push-to-talk voice input. Warms the shared
/// whisper-server while the user speaks, then transcribes the buffered audio in a single request.
public final class DictationSession: @unchecked Sendable {
    private let config: Config
    private let serverManager: WhisperServerManager
    private var mic: MicCapture?
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var warmTask: Task<Void, Error>?

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
        warmTask = Task { try await manager.ensureRunning(config: cfg) }

        let mic = MicCapture(preferredDeviceName: config.micDeviceName, echoCancellation: echoCancellation) { [weak self] samples in
            guard let self else { return }
            self.lock.lock(); self.buffer.append(contentsOf: samples); self.lock.unlock()
        }
        try mic.start()
        self.mic = mic
    }

    /// Stop capturing, transcribe the buffered audio (biased by the vocabulary), and return the
    /// trimmed text — empty if the clip was too short.
    public func finish() async throws -> String {
        mic?.stop(); mic = nil
        lock.lock(); let samples = buffer; buffer.removeAll(); lock.unlock()
        guard samples.count >= Int(0.3 * Audio.targetRate) else { return "" }

        try await warmTask?.value
        let wav = Audio.wavData(samples)
        let client = WhisperClient(inferenceURL: config.inferenceURL)
        let language = config.micLanguage ?? config.language
        let text = try await client.transcribe(wav: wav, language: language, prompt: config.effectivePrompt())
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancel() {
        mic?.stop(); mic = nil
        warmTask?.cancel()
        lock.lock(); buffer.removeAll(); lock.unlock()
    }
}
