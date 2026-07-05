import Foundation

/// Append-only CSV log of push-to-talk voice-input results (one column: the transcribed text).
public enum VoiceLog {
    /// Append `text` as a CSV row to `config.voiceLogURL`, if logging is enabled. Creates the file
    /// (with a header) on first use. No-op for empty text or when disabled.
    public static func append(_ text: String, config: Config) {
        guard config.saveVoiceLogOn else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url = config.voiceLogURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let isNew = !FileManager.default.fileExists(atPath: url.path)
        var out = isNew ? "text\n" : ""
        out += csvEscape(trimmed) + "\n"
        guard let data = out.data(using: .utf8) else { return }

        if isNew {
            try? data.write(to: url)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Quote per RFC 4180 if the value contains a comma, quote, or newline.
    static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
