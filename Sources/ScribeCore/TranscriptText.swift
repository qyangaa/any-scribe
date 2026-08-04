import Foundation

/// Text-similarity helpers shared by the live UI and the final-transcript de-duplication.
public enum TranscriptText {
    /// Lowercase and strip whitespace + punctuation (ASCII and CJK) for comparison.
    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let kept = lowered.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar.properties.isAlphabetic
        }
        return String(String.UnicodeScalarView(kept))
    }

    /// Levenshtein-based similarity ratio in [0, 1].
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// True if `b` is essentially a duplicate or overlapping extension of `a` — i.e. one
    /// contains the other (sliding-window overlap) or they're highly similar (echo).
    public static func isRedundant(_ a: String, _ b: String, threshold: Double = 0.72) -> Bool {
        let na = normalize(a), nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na.contains(nb) || nb.contains(na) { return true }
        return similarity(na, nb) >= threshold
    }

    /// Remove verbatim injections of the vocabulary list. Whisper sometimes copies the bias
    /// prompt into the transcript over quiet spans ("… currently the audit is only Claude, agent,
    /// Codex, Arky, OpenClaw …"). Any run of ≥3 consecutive vocabulary entries, in list order and
    /// joined list-style, is treated as parroting and removed.
    public static func stripVocabularyParroting(_ text: String, vocabulary: [String]) -> String {
        let words = vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard words.count >= 3 else { return text }
        var result = text
        var length = words.count
        while length >= 3 {
            for start in 0...(words.count - length) {
                let run = words[start..<(start + length)]
                // Tolerate ", " / " " / "，" separators between the copied entries.
                let pattern = run.map { NSRegularExpression.escapedPattern(for: $0) }
                    .joined(separator: "[,，]?\\s+")
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let range = NSRange(result.startIndex..., in: result)
                    result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
                }
            }
            length -= 1
        }
        // Tidy leftover doubled separators/spaces from the removal.
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([,.，。!?])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[,，]\s*[,，]"#, with: ",", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper appends stock outro hallucinations to trailing silence ("See you in the next
    /// video."). Trim any of them (repeatedly) off the END of otherwise-real text.
    public static func trimTrailingHallucinations(_ text: String) -> String {
        let phrases = [
            "see you in the next video", "see you in next video", "see you next video",
            "see you next time", "see you in the next one", "thanks for watching",
            "thank you for watching", "please subscribe", "like and subscribe",
            "don't forget to subscribe", "bye bye", "goodbye",
            "下次再见", "我们下期再见", "下期再见", "谢谢观看", "感谢观看", "再见"
        ]
        var result = text
        var changed = true
        while changed {
            changed = false
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()
            for phrase in phrases {
                for suffix in [phrase, phrase + ".", phrase + "!", phrase + "。", phrase + "！"] {
                    if lowered.hasSuffix(suffix), lowered != suffix {
                        result = String(trimmed.dropLast(suffix.count))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        changed = true
                        break
                    }
                }
                if changed { break }
            }
        }
        return result
    }
}
