import Foundation

/// Launches and supervises a local `whisper-server` child process, then waits for it to
/// become reachable. Terminated on stop.
public final class WhisperServer {
    private let config: Config
    private var process: Process?

    init(config: Config) {
        self.config = config
    }

    /// Locate the whisper-server binary: explicit override, then the engine bundled inside the
    /// app, then the native Metal build, then Homebrew, then PATH.
    public static func findBinary(override: String? = nil) -> String? {
        // Explicit override wins.
        if let override, FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        // Engine bundled inside AnyScribe.app (Contents/Resources/whisper/whisper-server).
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("whisper/whisper-server").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        // Prefer the native Metal build, then arm64 Homebrew, then the x86 fallback.
        let candidates = [
            Config.metalServerBin,
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to PATH lookup.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "whisper-server"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Report a binary's architecture ("arm64", "x86_64", …) via `lipo -archs`.
    public static func binaryArch(_ path: String) -> String {
        let lipo = Process()
        lipo.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        lipo.arguments = ["-archs", path]
        let pipe = Pipe()
        lipo.standardOutput = pipe
        lipo.standardError = FileHandle.nullDevice
        do { try lipo.run() } catch { return "unknown" }
        lipo.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false ? out! : "unknown")
    }

    /// Whether the child process is still alive.
    var isRunning: Bool { process?.isRunning ?? false }

    /// Start the server and block (async) until it answers, or throw.
    func start() async throws {
        guard let binary = Self.findBinary(override: config.whisperServerBin) else {
            throw ScribeError.missingWhisperServer
        }
        guard FileManager.default.fileExists(atPath: config.modelPath.path) else {
            throw ScribeError.missingModel(config.model)
        }

        // Clear any stale server (e.g. orphaned by a previous crash) holding our port.
        Self.killProcess(onPort: config.serverPort)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "-m", config.modelPath.path,
            "--host", config.serverHost,
            "--port", String(config.serverPort),
            "-l", config.language,
            "-nt",            // no timestamps in output text
            "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        ]
        // Keep the server quiet; we only care about the HTTP API.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        self.process = proc

        // Poll the port until it responds (model load can take a few seconds).
        let deadline = 60
        for attempt in 0..<deadline {
            if !proc.isRunning {
                throw ScribeError.serverFailed("process exited during startup")
            }
            if await isReachable() {
                return
            }
            if attempt == 0 {
                FileHandle.standardError.write(Data("Loading model \(config.model)...\n".utf8))
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw ScribeError.serverFailed("did not become reachable within \(deadline)s")
    }

    private func isReachable() async -> Bool {
        guard let url = URL(string: config.whisperServerUrl) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.httpMethod = "GET"
        do {
            _ = try await URLSession.shared.data(for: request)
            return true
        } catch {
            // Connection refused -> not up yet; any HTTP response -> up.
            let nsError = error as NSError
            return nsError.domain == NSURLErrorDomain && nsError.code != NSURLErrorCannotConnectToHost
                && nsError.code != NSURLErrorNetworkConnectionLost
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    /// Best-effort kill of whatever is listening on `port` (a stale/orphaned server).
    private static func killProcess(onPort port: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "lsof -ti tcp:\(port) | xargs kill -9 2>/dev/null || true"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
