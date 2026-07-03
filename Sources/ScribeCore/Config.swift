import Foundation

/// User-editable settings, loaded from ~/.config/anyscribe/config.json.
/// Every tunable (output location, model, labels, chunking) lives here — nothing is hard-coded.
public struct Config: Codable, Equatable {
    /// Directory where finished transcripts (markdown) and the live file are written.
    public var outputDir: String
    /// Whisper model name, e.g. "small.en", "large-v3-turbo". Resolved to a ggml file.
    public var model: String
    /// Base URL of the local whisper-server. Host/port are parsed from this.
    public var whisperServerUrl: String
    /// Spoken language code (e.g. "zh", "en"), or "auto". Default for both streams.
    public var language: String
    /// Per-stream language override for the mic, or null to use `language`.
    public var micLanguage: String?
    /// Per-stream language override for system audio, or null to use `language`.
    public var systemLanguage: String?
    /// Optional initial prompt to bias decoding — helpful for code-switching and
    /// domain vocabulary, e.g. "以下是普通话和英文混合的技术会议。".
    public var prompt: String?
    /// User-provided words/names/phrases (jargon, proper nouns) to bias recognition toward the
    /// correct spelling. Fed to Whisper as part of the initial prompt.
    public var vocabulary: [String]?
    /// Length of each audio window sent to whisper, in seconds.
    public var chunkSeconds: Double
    /// Overlap between consecutive windows, in seconds (prevents word cutoff at boundaries).
    public var overlapSeconds: Double
    /// Label applied to microphone transcript lines.
    public var micLabel: String
    /// Label applied to system-audio transcript lines.
    public var systemLabel: String
    /// Preferred input device name substring, or null for the system default.
    public var micDeviceName: String?
    /// Explicit path to a whisper-server binary, or null to auto-detect (prefers the native
    /// Metal build, then Homebrew). Set this to override the binary used.
    public var whisperServerBin: String?
    /// Apple Voice-Processing echo cancellation on the mic (subtracts system audio so it
    /// doesn't bleed in when using speakers). Null = on. `echoCancellationOn` resolves it.
    public var echoCancellation: Bool?
    /// Drop near-duplicate lines that appear on both streams within a short window (echo).
    /// Null = on. `dedupeCrossTalkOn` resolves it.
    public var dedupeCrossTalk: Bool?
    /// Minutes to keep the whisper-server warm after a recording before shutting it down to free
    /// memory (app only). Null = 5. `serverIdleSeconds` resolves it.
    public var serverIdleMinutes: Int?

    /// Resolved defaults for the optional toggles (absent in older config files → enabled).
    public var echoCancellationOn: Bool { echoCancellation ?? true }
    public var dedupeCrossTalkOn: Bool { dedupeCrossTalk ?? true }
    public var serverIdleSeconds: Double { Double((serverIdleMinutes ?? 5) * 60) }

    public static func defaults(outputDir: String) -> Config {
        Config(
            outputDir: outputDir,
            model: "small.en",
            whisperServerUrl: "http://127.0.0.1:8178",
            language: "en",
            micLanguage: nil,
            systemLanguage: nil,
            prompt: nil,
            vocabulary: nil,
            chunkSeconds: 5,
            overlapSeconds: 1,
            micLabel: "Me",
            systemLabel: "Them",
            micDeviceName: nil,
            whisperServerBin: nil,
            echoCancellation: true,
            dedupeCrossTalk: true,
            serverIdleMinutes: 5
        )
    }

    /// Conventional location of the native Metal whisper-server build (see README).
    public static var metalServerBin: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/anyscribe/whisper.cpp/build/bin/whisper-server")
            .path
    }

    // MARK: - Locations

    /// ~/.config/anyscribe
    public static var configDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/anyscribe", isDirectory: true)
    }

    public static var configFile: URL {
        configDir.appendingPathComponent("config.json")
    }

    /// Where downloaded ggml models are cached.
    public static var modelsDir: URL {
        configDir.appendingPathComponent("models", isDirectory: true)
    }

    /// Default transcript output folder for first-run users.
    public static func defaultOutputDir() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Any Scribe").path
    }

    // MARK: - Load / Save

    public static func load() throws -> Config {
        let url = configFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ScribeError.missingConfig(url.path)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// Load the config if present, otherwise return defaults (used by the app on first run).
    public static func loadOrDefaults() -> Config {
        (try? load()) ?? defaults(outputDir: defaultOutputDir())
    }

    /// Whisper initial prompt combining any custom `prompt` with the vocabulary list. Whisper biases
    /// decoding toward words in its initial prompt, improving recognition of names/jargon. Bounded to
    /// stay well under whisper's ~224-token prompt limit.
    public func effectivePrompt() -> String? {
        var parts: [String] = []
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            parts.append(prompt)
        }
        let words = (vocabulary ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !words.isEmpty {
            var hint = "Vocabulary: " + words.joined(separator: ", ")
            if hint.count > 800 { hint = String(hint.prefix(800)) }   // ~200 tokens
            parts.append(hint)
        }
        let combined = parts.joined(separator: " ")
        return combined.isEmpty ? nil : combined
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try data.write(to: Config.configFile, options: .atomic)
    }

    // MARK: - Derived values

    /// Path to the ggml model file for `model`.
    public var modelPath: URL {
        Config.modelsDir.appendingPathComponent("ggml-\(model).bin")
    }

    var serverHost: String {
        URLComponents(string: whisperServerUrl)?.host ?? "127.0.0.1"
    }

    var serverPort: Int {
        URLComponents(string: whisperServerUrl)?.port ?? 8178
    }

    /// Endpoint used for transcription POSTs.
    var inferenceURL: URL {
        URL(string: whisperServerUrl)!.appendingPathComponent("inference")
    }
}

public enum ScribeError: Error, CustomStringConvertible {
    case missingConfig(String)
    case missingModel(String)
    case missingWhisperServer
    case serverFailed(String)
    case captureFailed(String)
    case screenRecordingNeeded

    public var description: String {
        switch self {
        case .missingConfig(let path):
            return "No config found at \(path). Run `scribe init` first."
        case .missingModel(let name):
            return "Whisper model not found: \(name). Run `scribe check --download` to fetch it."
        case .missingWhisperServer:
            return "whisper-server not found in PATH. Install it with `brew install whisper-cpp`."
        case .serverFailed(let msg):
            return "whisper-server failed: \(msg)"
        case .captureFailed(let msg):
            return "Audio capture failed: \(msg)"
        case .screenRecordingNeeded:
            return "Screen Recording permission is needed to capture system audio. Enable it for this app in System Settings → Privacy & Security → Screen Recording, then quit and reopen the app."
        }
    }
}
