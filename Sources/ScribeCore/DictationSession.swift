import Foundation

/// Voice capture → transcription for push-to-talk. Transcribes the speech in fixed chunks *while*
/// you hold the key (in the background, no on-screen preview), so on release only the short final
/// tail is left — the text is ready almost immediately.
public final class DictationSession: @unchecked Sendable {
    private let config: Config
    private let serverManager: WhisperServerManager
    private var mic: MicCapture?

    private let lock = NSLock()
    private var buffer: [Float] = []       // samples from `baseIndex` onward
    private var baseIndex = 0              // absolute index of buffer[0]
    private var emittedIndex = 0          // absolute index transcribed up to
    private var segments: [String] = []    // chunk transcripts, in order

    private var warmTask: Task<Void, Error>?
    private var chunkTask: Task<Void, Never>?
    private let chunkSamples = Int(6.0 * Audio.targetRate)   // ~6s chunks; long enough to rarely split a word

    public init(config: Config, serverManager: WhisperServerManager) {
        self.config = config
        self.serverManager = serverManager
    }

    /// Start warming the server, capturing the mic, and transcribing completed chunks in the background.
    public func start(echoCancellation: Bool) throws {
        guard FileManager.default.fileExists(atPath: config.modelPath.path) else {
            throw ScribeError.missingModel(config.model)
        }
        lock.lock(); buffer.removeAll(); baseIndex = 0; emittedIndex = 0; segments.removeAll(); lock.unlock()

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
        startChunkLoop(warm: warm)
    }

    /// Stop capturing, transcribe only the remaining tail, and return the full stitched transcript.
    public func finish() async throws -> String {
        chunkTask?.cancel(); chunkTask = nil
        mic?.stop(); mic = nil

        lock.lock()
        let localStart = max(0, emittedIndex - baseIndex)
        let tail = localStart < buffer.count ? Array(buffer[localStart...]) : []
        buffer.removeAll()
        lock.unlock()

        if tail.count >= Int(0.3 * Audio.targetRate) {
            try await warmTask?.value
            if let text = try? await transcribe(tail), !text.isEmpty {
                lock.lock(); segments.append(text); lock.unlock()
            }
        }
        lock.lock(); let result = segments.joined(separator: " "); lock.unlock()
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancel() {
        chunkTask?.cancel(); chunkTask = nil
        mic?.stop(); mic = nil
        warmTask?.cancel()
        lock.lock(); buffer.removeAll(); segments.removeAll(); lock.unlock()
    }

    // MARK: - Private

    private func startChunkLoop(warm: Task<Void, Error>) {
        chunkTask = Task { [weak self] in
            try? await warm.value   // wait for the server to be ready
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, let self else { break }
                guard let chunk = self.nextChunk() else { continue }
                if let text = try? await self.transcribe(chunk), !text.isEmpty {
                    self.lock.lock(); self.segments.append(text); self.lock.unlock()
                }
            }
        }
    }

    /// Pull the next full chunk of unprocessed audio, advancing the cursor and trimming the buffer.
    private func nextChunk() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        let available = baseIndex + buffer.count
        guard available - emittedIndex >= chunkSamples else { return nil }
        let localStart = emittedIndex - baseIndex
        let chunk = Array(buffer[localStart..<(localStart + chunkSamples)])
        emittedIndex += chunkSamples
        let drop = emittedIndex - baseIndex
        if drop > 0, drop <= buffer.count { buffer.removeFirst(drop); baseIndex = emittedIndex }
        return chunk
    }

    private func transcribe(_ samples: [Float]) async throws -> String {
        let wav = Audio.wavData(samples)
        let client = WhisperClient(inferenceURL: config.inferenceURL)
        let language = config.micLanguage ?? config.language
        let text = try await client.transcribe(wav: wav, language: language, prompt: config.effectivePrompt())
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
