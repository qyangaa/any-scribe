import Foundation

/// One per audio stream (mic / system). Accumulates 16 kHz mono samples, slices them into
/// overlapping windows, transcribes each via whisper-server, and forwards labeled lines to
/// the shared TranscriptWriter.
final class ChunkPipeline: @unchecked Sendable {
    private let label: String
    private let language: String
    private let prompt: String?
    private let client: WhisperClient
    private let writer: TranscriptWriter
    private let sessionStart: Date

    private let windowSamples: Int
    private let hopSamples: Int
    private let silenceThreshold: Float = 0.005

    private let lock = NSLock()
    private var buffer: [Float] = []     // samples from `baseIndex` onward
    private var baseIndex = 0            // absolute index of buffer[0]
    private var nextWindowStart = 0      // absolute index where the next window begins
    private var running = false
    private var loopTask: Task<Void, Never>?

    init(label: String, language: String, prompt: String?, config: Config, client: WhisperClient, writer: TranscriptWriter, sessionStart: Date) {
        self.label = label
        self.language = language
        self.prompt = prompt
        self.client = client
        self.writer = writer
        self.sessionStart = sessionStart
        self.windowSamples = Int(config.chunkSeconds * Audio.targetRate)
        let hop = max(0.5, config.chunkSeconds - config.overlapSeconds)
        self.hopSamples = Int(hop * Audio.targetRate)
    }

    /// Called from capture callbacks with already-converted 16 kHz mono samples.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        buffer.append(contentsOf: samples)
        lock.unlock()
    }

    func start() {
        running = true
        loopTask = Task.detached { [weak self] in
            await self?.run()
        }
    }

    /// Stop accepting new windows and flush whatever remains as a final window.
    func stop() async {
        running = false
        loopTask?.cancel()
        await flushRemainder()
    }

    private func run() async {
        while running && !Task.isCancelled {
            if let (window, startIndex) = nextWindow() {
                await transcribe(window, startIndex: startIndex)
            } else {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Pull the next ready window, advancing the read cursor and trimming consumed samples.
    private func nextWindow() -> (window: [Float], startIndex: Int)? {
        lock.lock()
        defer { lock.unlock() }
        let available = baseIndex + buffer.count
        guard available - nextWindowStart >= windowSamples else { return nil }

        let localStart = nextWindowStart - baseIndex
        let window = Array(buffer[localStart..<(localStart + windowSamples)])
        let startIndex = nextWindowStart

        nextWindowStart += hopSamples
        // Drop everything before the new window start to bound memory.
        let dropTo = nextWindowStart - baseIndex
        if dropTo > 0 && dropTo <= buffer.count {
            buffer.removeFirst(dropTo)
            baseIndex = nextWindowStart
        }
        return (window, startIndex)
    }

    /// At shutdown, transcribe any leftover audio shorter than a full window.
    private func flushRemainder() async {
        guard let (window, startIndex) = takeRemainder() else { return }
        // Only bother if there's at least ~1s of audio.
        if window.count >= Int(Audio.targetRate) {
            await transcribe(window, startIndex: startIndex)
        }
    }

    private func takeRemainder() -> (window: [Float], startIndex: Int)? {
        lock.lock()
        defer { lock.unlock() }
        let localStart = max(0, nextWindowStart - baseIndex)
        guard localStart < buffer.count else { return nil }
        let window = Array(buffer[localStart...])
        let startIndex = nextWindowStart
        buffer.removeAll()
        return (window, startIndex)
    }

    private func transcribe(_ window: [Float], startIndex: Int) async {
        let level = Audio.rms(window)
        guard level >= silenceThreshold else { return }
        let wav = Audio.wavData(window)
        do {
            let text = try await client.transcribe(wav: wav, language: language, prompt: prompt)
            guard !text.isEmpty else { return }
            let offset = Double(startIndex) / Audio.targetRate
            let time = sessionStart.addingTimeInterval(offset)
            await writer.add(time: time, label: label, text: text, energy: level)
        } catch {
            FileHandle.standardError.write(Data("[\(label)] transcription error: \(error)\n".utf8))
        }
    }
}
