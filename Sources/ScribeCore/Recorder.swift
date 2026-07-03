import Foundation

/// Orchestrates a recording session end-to-end: starts the local whisper-server, wires up the
/// mic + system-audio capture into per-stream pipelines, and finalizes the transcript on stop.
/// Shared by both the CLI and the menu-bar app.
public final class Recorder: @unchecked Sendable {
    public struct Line: Sendable {
        public let time: Date
        public let label: String
        public let text: String
    }

    private let config: Config
    private let serverManager: WhisperServerManager?

    private var server: WhisperServer?
    private var writer: TranscriptWriter?
    private var micPipe: ChunkPipeline?
    private var sysPipe: ChunkPipeline?
    private var mic: MicCapture?
    private var sys: SystemAudioCapture?

    /// Called for every transcribed line. May be invoked on a background thread; hop to the main
    /// actor in UI consumers.
    public var onLine: (@Sendable (Line) -> Void)?

    private var _liveFilePath: String?
    public var liveFilePath: String? { _liveFilePath }

    /// `serverManager` (app only) keeps the whisper-server warm across recordings. When nil
    /// (CLI), the recorder spawns and tears down its own server per session.
    public init(config: Config, serverManager: WhisperServerManager? = nil) {
        self.config = config
        self.serverManager = serverManager
    }

    /// Start the whisper-server and both capture streams. Throws if the model is missing,
    /// the server fails, or a capture source can't start (e.g. missing permission).
    public func start() async throws {
        guard FileManager.default.fileExists(atPath: config.modelPath.path) else {
            throw ScribeError.missingModel(config.model)
        }

        let sessionStart = Date()
        let lineSink = onLine
        let writer = try TranscriptWriter(config: config, sessionStart: sessionStart, dedupe: config.dedupeCrossTalkOn) { time, label, text in
            lineSink?(Line(time: time, label: label, text: text))
        }

        let client = WhisperClient(inferenceURL: config.inferenceURL)
        let micLang = config.micLanguage ?? config.language
        let sysLang = config.systemLanguage ?? config.language
        let prompt = config.effectivePrompt()   // custom prompt + vocabulary bias
        let micPipe = ChunkPipeline(label: config.micLabel, language: micLang, prompt: prompt,
                                    config: config, client: client, writer: writer, sessionStart: sessionStart)
        let sysPipe = ChunkPipeline(label: config.systemLabel, language: sysLang, prompt: prompt,
                                    config: config, client: client, writer: writer, sessionStart: sessionStart)

        let mic = MicCapture(preferredDeviceName: config.micDeviceName, echoCancellation: config.echoCancellationOn) { micPipe.append($0) }
        let sys = SystemAudioCapture { sysPipe.append($0) }

        // Start CAPTURE first so audio is buffered from t=0 — the whisper-server's model load can
        // take several seconds, and we must not drop the start of the meeting. (This also surfaces
        // Microphone / Screen Recording permission errors immediately.)
        do {
            try mic.start()
        } catch {
            throw error
        }
        do {
            try await sys.start()
        } catch {
            mic.stop()
            throw error
        }

        // Now bring up the server (buffers keep filling during any model warmup). A warm shared
        // server (app) returns instantly; otherwise we spawn one for this session (CLI).
        do {
            if let serverManager {
                try await serverManager.ensureRunning(config: config)
            } else {
                let server = WhisperServer(config: config)
                try await server.start()
                self.server = server
            }
        } catch {
            mic.stop()
            await sys.stop()
            throw error
        }

        // Begin transcribing the buffered + ongoing audio.
        micPipe.start()
        sysPipe.start()

        self.writer = writer
        self.micPipe = micPipe
        self.sysPipe = sysPipe
        self.mic = mic
        self.sys = sys
        self._liveFilePath = await writer.liveFilePath
    }

    /// Stop all capture, flush pending audio, terminate the server, and write the final
    /// markdown transcript. Returns its path.
    @discardableResult
    public func stop() async -> String? {
        mic?.stop()
        await sys?.stop()
        await micPipe?.stop()   // flushes pending audio (still POSTs to the live server)
        await sysPipe?.stop()
        if let serverManager {
            await serverManager.recordingStopped()  // keep warm, idle-shutdown later
        } else {
            server?.stop()
        }
        let path = await writer?.finalize(endTime: Date())

        mic = nil; sys = nil; micPipe = nil; sysPipe = nil; server = nil; writer = nil
        return path
    }
}
