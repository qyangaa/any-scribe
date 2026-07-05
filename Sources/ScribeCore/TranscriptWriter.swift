import Foundation

/// Collects labeled, timestamped transcript lines from both streams. Appends to a tail-able
/// `live.txt` as text arrives, and writes a timestamp-ordered markdown file when finalized.
///
/// When recording over speakers, the same speech can leak across both streams (the mic hears the
/// speaker output). We suppress those echoes by detecting near-duplicate lines that appear on the
/// *other* stream within a short window, keeping the louder (true-source) one.
actor TranscriptWriter {
    struct Line {
        let time: Date
        let label: String
        let text: String
        let energy: Float
    }

    private let config: Config
    private let sessionStart: Date
    private var lines: [Line] = []
    private let liveURL: URL
    private let finalURL: URL
    private let onLine: (@Sendable (Date, String, String) -> Void)?

    // Cross-stream de-duplication.
    private let dedupe: Bool
    private let dedupeWindow: TimeInterval = 4.0
    private var liveRecent: [(text: String, label: String, time: Date)] = []

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(config: Config, sessionStart: Date, dedupe: Bool = true,
         onLine: (@Sendable (Date, String, String) -> Void)? = nil) throws {
        self.config = config
        self.sessionStart = sessionStart
        self.dedupe = dedupe
        self.onLine = onLine
        let dir = URL(fileURLWithPath: config.resolvedOutputDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let base = "\(stamp.string(from: sessionStart)) Meeting"
        self.finalURL = dir.appendingPathComponent("\(base).md")
        self.liveURL = dir.appendingPathComponent("\(base).live.txt")

        // Start the live file.
        let header = "# \(base)\n\n"
        try? header.data(using: .utf8)?.write(to: liveURL)
    }

    var liveFilePath: String { liveURL.path }
    var finalFilePath: String { finalURL.path }

    func add(time: Date, label: String, text: String, energy: Float) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let line = Line(time: time, label: label, text: clean, energy: energy)
        lines.append(line)

        // Live echo suppression: if the OTHER stream already showed a near-identical line within
        // the window, don't echo this one to the live view (the final file dedups by energy).
        // Same-stream overlap (sliding-window repeats) is merged downstream in the UI / finalize.
        let suppressed = dedupe && liveRecent.contains(where: { $0.label != label
            && abs($0.time.timeIntervalSince(time)) <= dedupeWindow
            && TranscriptText.isRedundant($0.text, clean) })
        if !suppressed {
            liveRecent.append((text: clean, label: label, time: time))
            if liveRecent.count > 16 { liveRecent.removeFirst(liveRecent.count - 16) }
            appendLive(line)
            onLine?(line.time, line.label, line.text)
        }

        // Keep the .md file current from the very first line (survives crashes / a forgotten stop).
        writeMarkdown(endTime: Date())
    }

    private func appendLive(_ line: Line) {
        let rendered = format(line) + "\n"
        guard let data = rendered.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: liveURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private func format(_ line: Line) -> String {
        "[\(Self.clock.string(from: line.time))] **\(line.label):** \(line.text)"
    }

    /// Write the timestamp-ordered, de-duplicated markdown file. Called incrementally on each line
    /// (so the .md is always current) and once more on stop with the final duration.
    private func writeMarkdown(endTime: Date) {
        let ordered = lines.sorted { $0.time < $1.time }
        let cleaned = dedupe ? dedupeLines(ordered) : ordered
        let duration = endTime.timeIntervalSince(sessionStart)

        let iso = ISO8601DateFormatter()
        var out = "---\n"
        out += "date: \(iso.string(from: sessionStart))\n"
        out += "duration: \(formatDuration(duration))\n"
        out += "model: \(config.model)\n"
        out += "---\n\n"
        for line in cleaned {
            out += format(line) + "\n"
        }
        try? out.data(using: .utf8)?.write(to: finalURL, options: .atomic)
    }

    /// Finalize with the accurate end time. Returns the file path.
    @discardableResult
    func finalize(endTime: Date) -> String {
        writeMarkdown(endTime: endTime)
        return finalURL.path
    }

    /// Collapse redundant lines:
    /// - same stream, overlapping text (sliding-window repeats) → keep the longer/more complete one
    /// - different streams, near-identical (speaker echo) → keep the louder (true source)
    private func dedupeLines(_ input: [Line]) -> [Line] {
        var kept: [Line] = []
        for line in input {
            if let idx = kept.lastIndex(where: {
                abs($0.time.timeIntervalSince(line.time)) <= dedupeWindow
                && TranscriptText.isRedundant($0.text, line.text) }) {
                let other = kept[idx]
                if other.label == line.label {
                    // sliding-window overlap on the same stream — keep the longer text
                    if line.text.count > other.text.count { kept[idx] = line }
                } else {
                    // cross-stream echo — keep the louder source
                    if line.energy > other.energy { kept[idx] = line }
                }
            } else {
                kept.append(line)
            }
        }
        return kept.sorted { $0.time < $1.time }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
