import Foundation

/// Streaming transcription over the OpenAI Realtime API (the approach Codex uses natively):
/// audio is appended continuously over a WebSocket; the server's VAD segments speech and emits
/// transcript deltas + completed segments; on release we commit and collect the finalized text.
/// If anything fails mid-session, the caller falls back to a one-shot POST of the buffered audio.
public final class RealtimeTranscriber: @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let language: String
    private let prompt: String?

    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var completedSegments: [String] = []
    private var lastDelta: String = ""          // salvage buffer if a final never arrives
    private var receiveLoop: Task<Void, Never>?
    private var failed = false

    /// Live partial text (concatenated finals + current delta), for optional UI.
    public var onPartial: (@Sendable (String) -> Void)?

    public init(apiKey: String, model: String, language: String, prompt: String?) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.prompt = prompt
    }

    /// Open the socket and configure a transcription session with server-side VAD.
    public func start() async throws {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        self.task = task

        var transcription: [String: Any] = ["model": model]
        if language != "auto", !language.isEmpty { transcription["language"] = language }
        if let prompt, !prompt.isEmpty { transcription["prompt"] = prompt }
        let update: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": transcription,
                        "turn_detection": ["type": "server_vad", "silence_duration_ms": 600]
                    ]
                ]
            ]
        ]
        try await send(update)
        startReceiveLoop()
    }

    /// Append 16 kHz mono samples (resampled to 24 kHz pcm16 on the way out).
    public func append(_ samples16k: [Float]) {
        guard let task, !failed else { return }
        let pcm = Audio.pcm16Data(Audio.resample(samples16k, to: 24_000))
        let event: [String: Any] = ["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()]
        Task {
            do { try await self.sendOn(task, event) }
            catch { self.markFailed("append: \(error)") }
        }
    }

    /// Commit any un-finalized audio, wait briefly for the last segment, and return the full text.
    public func finish() async throws -> String {
        guard let task, !failed else { throw ScribeError.serverFailed("realtime session not running") }
        try? await sendOn(task, ["type": "input_audio_buffer.commit"])

        // Wait up to ~4s for the final segment to land (VAD may already have finalized everything).
        let deadline = Date().addingTimeInterval(4)
        var lastCount = segmentCount()
        var stableSince = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let count = segmentCount()
            if count != lastCount { lastCount = count; stableSince = Date() }
            // Finals arrived and nothing new for 0.8s -> assume done.
            if count > 0 && Date().timeIntervalSince(stableSince) > 0.8 { break }
        }
        close()

        lock.lock()
        var parts = completedSegments
        // Salvage: if a delta was streaming but its final never arrived, keep it (Claude Code
        // does the same — "partial salvaged").
        if !lastDelta.isEmpty && !(parts.last?.contains(lastDelta) ?? false) {
            parts.append(lastDelta)
        }
        lock.unlock()
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasFailed: Bool { failed }

    public func close() {
        receiveLoop?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    // MARK: - Private

    private func segmentCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return completedSegments.count
    }

    private func startReceiveLoop() {
        receiveLoop = Task { [weak self] in
            while let self, let task = self.task, !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard case .string(let text) = message,
                          let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                          let type = obj["type"] as? String else { continue }
                    switch type {
                    case "conversation.item.input_audio_transcription.delta":
                        if let delta = obj["delta"] as? String {
                            self.lock.lock(); self.lastDelta += delta
                            let preview = (self.completedSegments + [self.lastDelta]).joined(separator: " ")
                            self.lock.unlock()
                            self.onPartial?(preview)
                        }
                    case "conversation.item.input_audio_transcription.completed":
                        if let final = obj["transcript"] as? String, !final.isEmpty {
                            self.lock.lock()
                            self.completedSegments.append(final.trimmingCharacters(in: .whitespacesAndNewlines))
                            self.lastDelta = ""
                            self.lock.unlock()
                        }
                    case "error":
                        let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "unknown"
                        self.markFailed("server error: \(msg)")
                    default:
                        break
                    }
                } catch {
                    if !Task.isCancelled { self.markFailed("receive: \(error)") }
                    break
                }
            }
        }
    }

    private func markFailed(_ reason: String) {
        if !failed {
            failed = true
            FileHandle.standardError.write(Data("[realtime] failed: \(reason)\n".utf8))
        }
    }

    private func send(_ obj: [String: Any]) async throws {
        guard let task else { throw ScribeError.serverFailed("realtime socket not open") }
        try await sendOn(task, obj)
    }

    private func sendOn(_ task: URLSessionWebSocketTask, _ obj: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        try await task.send(.string(String(data: data, encoding: .utf8)!))
    }
}
