import Foundation

/// Voice capture → transcription for push-to-talk.
///
/// Local engine: audio is segmented **only at silence boundaries** (like server-side VAD, never
/// mid-word), each segment transcribes in the background in order, and release **awaits** all
/// in-flight work — nothing is ever cancelled/dropped. Short utterances (< min segment) are a
/// single whole-clip transcription, which is also the highest-quality path.
///
/// OpenAI engine: audio streams continuously over the Realtime API WebSocket (server VAD,
/// finalized segments — the architecture Codex uses natively), with a one-shot POST of the fully
/// buffered clip as fallback if the stream fails.
public final class DictationSession: @unchecked Sendable {
    private let config: Config
    private let serverManager: WhisperServerManager

    /// Fired once when the first audio actually arrives from the mic — UI can flip to "listening".
    public var onListening: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var buffer: [Float] = []          // the ENTIRE clip (kept for tail + fallback)
    private var emittedIndex = 0              // local engine: samples handed to segment tasks
    private var segmentTasks: [Task<String, Never>] = []   // ordered, chained; never cancelled

    private var warmTask: Task<Void, Error>?
    private var scanTask: Task<Void, Never>?
    private var realtime: RealtimeTranscriber?

    private let silenceRMS: Float = 0.005
    private let silenceWindow = Int(0.7 * Audio.targetRate)      // pause length that ends a segment
    private let minSegment = Int(8.0 * Audio.targetRate)         // don't segment before this much speech

    public init(config: Config, serverManager: WhisperServerManager) {
        self.config = config
        self.serverManager = serverManager
    }

    // MARK: - Lifecycle

    public func start(echoCancellation: Bool) throws {
        lock.lock(); buffer.removeAll(); emittedIndex = 0; segmentTasks.removeAll(); lock.unlock()

        let useRealtime = config.usesOpenAITranscriber
        if useRealtime {
            let rt = RealtimeTranscriber(apiKey: config.resolvedOpenAIKey ?? "",
                                         model: config.openaiTranscriptionModel ?? "gpt-4o-transcribe",
                                         language: config.micLanguage ?? config.language,
                                         prompt: config.effectivePrompt())
            realtime = rt
            Task { try? await rt.start() }   // connect while the user starts talking; buffer regardless
        } else {
            guard FileManager.default.fileExists(atPath: config.modelPath.path) else {
                throw ScribeError.missingModel(config.model)
            }
            let manager = serverManager
            let cfg = config
            warmTask = Task { try await manager.ensureRunning(config: cfg) }
        }

        var announcedListening = false
        try PersistentMic.shared.begin(echoCancellation: echoCancellation) { [weak self] samples in
            guard let self else { return }
            self.lock.lock(); self.buffer.append(contentsOf: samples); self.lock.unlock()
            self.realtime?.append(samples)
            if !announcedListening {
                announcedListening = true
                self.onListening?()
            }
        }
        if !useRealtime { startScanLoop() }
    }

    /// Stop capture and return the complete transcript. Awaits every in-flight segment — text is
    /// never dropped on release.
    public func finish() async throws -> String {
        scanTask?.cancel(); scanTask = nil   // the scanner only slices; transcription tasks live on
        PersistentMic.shared.end()

        if let realtime {
            defer { self.realtime = nil }
            if !realtime.hasFailed, let text = try? await realtime.finish(), !text.isEmpty {
                return config.postProcess(text)
            }
            realtime.close()
            // Stream failed (network, auth, …): salvage with a one-shot POST of the whole clip.
            FileHandle.standardError.write(Data("[dictation] realtime failed — falling back to one-shot POST\n".utf8))
            return try await oneShotFallback()
        }

        // Local engine: enqueue whatever remains as the final segment, then await all in order.
        lock.lock()
        let tail = emittedIndex < buffer.count ? Array(buffer[emittedIndex...]) : []
        let wholeClipRMS = Audio.rms(buffer)
        let hadSegments = !segmentTasks.isEmpty
        lock.unlock()

        // Whole clip silent and nothing committed: nothing to do (avoids vocabulary parroting).
        if !hadSegments && wholeClipRMS < silenceRMS { return "" }
        // The tail uses a softer gate: a quiet trailing phrase is worth transcribing; pure silence
        // is still skipped (whisper hallucinates outros on it).
        if tail.count >= Int(0.3 * Audio.targetRate), hadSegments ? Audio.rms(tail) >= silenceRMS * 0.5 : true {
            enqueueSegment(tail, isTail: true)
        }

        lock.lock(); let tasks = segmentTasks; lock.unlock()
        var parts: [String] = []
        for task in tasks {                    // ordered await — never cancelled
            let text = await task.value
            if !text.isEmpty { parts.append(text) }
        }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return config.postProcess(joined)
    }

    public func cancel() {
        scanTask?.cancel(); scanTask = nil
        PersistentMic.shared.end()
        warmTask?.cancel()
        realtime?.close(); realtime = nil
        lock.lock(); segmentTasks.removeAll(); buffer.removeAll(); lock.unlock()
    }

    // MARK: - Local engine internals

    /// Every 250 ms, look for a natural pause and commit the speech before it as a segment.
    private func startScanLoop() {
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self else { break }
                if let segment = self.takeSegmentAtSilence() {
                    self.enqueueSegment(segment)
                }
            }
        }
    }

    /// If the un-emitted audio is long enough AND currently ends in a pause, split there.
    private func takeSegmentAtSilence() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        let unemitted = buffer.count - emittedIndex
        guard unemitted >= minSegment else { return nil }
        let windowStart = buffer.count - silenceWindow
        guard windowStart > emittedIndex else { return nil }
        let trailing = Array(buffer[windowStart...])
        guard Audio.rms(trailing) < silenceRMS else { return nil }   // still talking
        let segment = Array(buffer[emittedIndex..<buffer.count])
        emittedIndex = buffer.count
        return segment
    }

    /// Chain a transcription task after the previous one so results stay ordered and each segment
    /// gets the previous text as context (better continuity across boundaries).
    private func enqueueSegment(_ samples: [Float], isTail: Bool = false) {
        guard Audio.rms(samples) >= (isTail ? silenceRMS * 0.5 : silenceRMS) else { return }
        lock.lock()
        let previous = segmentTasks.last
        let cfg = config
        let warm = warmTask
        let task = Task<String, Never> {
            var prevText = ""
            if let previous { prevText = await previous.value }
            try? await warm?.value
            let wav = Audio.wavData(samples)
            let client = WhisperClient(inferenceURL: cfg.inferenceURL)
            var prompt = cfg.effectivePrompt() ?? ""
            if !prevText.isEmpty { prompt = (prompt + " …" + prevText.suffix(200)).trimmingCharacters(in: .whitespaces) }
            let language = cfg.micLanguage ?? cfg.language
            let text = (try? await client.transcribe(wav: wav, language: language,
                                                     prompt: prompt.isEmpty ? nil : String(prompt.prefix(900)))) ?? ""
            return cfg.postProcess(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        segmentTasks.append(task)
        lock.unlock()
    }

    // MARK: - Cloud fallback

    private func oneShotFallback() async throws -> String {
        lock.lock(); let samples = buffer; lock.unlock()
        guard samples.count >= Int(0.3 * Audio.targetRate), Audio.rms(samples) >= silenceRMS else { return "" }
        guard let key = config.resolvedOpenAIKey else { throw ScribeError.serverFailed("no OpenAI key") }
        let engine = OpenAITranscriber(apiKey: key, model: config.openaiTranscriptionModel ?? "gpt-4o-transcribe")
        let text = try await engine.transcribe(wav: Audio.wavData(samples),
                                               language: config.micLanguage ?? config.language,
                                               prompt: config.effectivePrompt())
        return config.postProcess(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
