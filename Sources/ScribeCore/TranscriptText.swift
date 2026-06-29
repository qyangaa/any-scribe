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
}
