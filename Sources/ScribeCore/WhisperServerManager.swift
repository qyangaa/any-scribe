import Foundation

/// Keeps a single `whisper-server` warm across recordings to avoid the per-recording model-load
/// warmup, then shuts it down after an idle period to free memory.
///
/// Used by the menu-bar app. The CLI doesn't use this (it spawns a server per `scribe start`).
@MainActor
public final class WhisperServerManager {
    private var server: WhisperServer?
    private var currentKey: String?            // model + binary the warm server was started with
    private var idleTask: Task<Void, Never>?

    /// How long to keep the server warm after a recording ends, in seconds.
    public var idleSeconds: Double = 300

    public init() {}

    private func key(_ config: Config) -> String {
        "\(config.model)|\(config.whisperServerBin ?? "")"
    }

    /// Ensure a server is running for this config. Reuses a warm server when the model/binary
    /// match (instant); otherwise (re)starts one (pays the model-load warmup).
    public func ensureRunning(config: Config) async throws {
        idleTask?.cancel()
        idleTask = nil

        if let server, server.isRunning, currentKey == key(config) {
            return // warm hit
        }
        server?.stop()
        server = nil

        let fresh = WhisperServer(config: config)
        try await fresh.start()
        server = fresh
        currentKey = key(config)
    }

    /// Call when a recording ends: keep the server warm, then shut it down after `idleSeconds`.
    public func recordingStopped() {
        idleTask?.cancel()
        let seconds = idleSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.shutdown()
        }
    }

    /// Stop the server immediately (idle expiry or app quit).
    public func shutdown() {
        idleTask?.cancel()
        idleTask = nil
        server?.stop()
        server = nil
        currentKey = nil
    }
}
