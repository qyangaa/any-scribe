import Foundation

/// Talks to a running whisper-server over HTTP. Posts a WAV window to /inference and
/// returns the cleaned transcript text (empty string if nothing usable).
struct WhisperClient {
    let inferenceURL: URL

    func transcribe(wav: Data, language: String, prompt: String?) async throws -> String {
        let boundary = "----anyscribe-\(UInt32(wav.count))-\(wav.count)"
        var request = URLRequest(url: inferenceURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        // The WAV payload.
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        field("response_format", "json")
        field("temperature", "0.0")
        field("language", language)
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ScribeError.serverFailed("HTTP \(http.statusCode)")
        }

        let text = Self.parseText(from: data)
        return Self.clean(text)
    }

    /// whisper-server returns `{"text": "..."}` for response_format=json.
    private static func parseText(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = obj["text"] as? String {
            return text
        }
        // Fall back to raw body if it wasn't JSON.
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Hallucination filtering

    /// whisper hallucinates boilerplate on silence ("[BLANK_AUDIO]", "(music)",
    /// "Thanks for watching!", etc.). Strip those and trim noise.
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // A line that is entirely bracketed/parenthetical is noise: [music], (applause), 【音乐】.
        if let regex = try? NSRegularExpression(pattern: "^[\\[(（【].*[\\])）】]$") {
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, range: range) != nil {
                return ""
            }
        }

        let lowered = text.lowercased()
        for phrase in hallucinationPhrases {
            if lowered == phrase || lowered == phrase + "." {
                return ""
            }
        }

        // Collapse internal whitespace/newlines into single spaces.
        text = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return text
    }

    private static let hallucinationPhrases: Set<String> = [
        // English
        "thanks for watching", "thanks for watching!", "thank you for watching",
        "please subscribe", "like and subscribe", "you", "bye", "bye.",
        "[blank_audio]", "(blank audio)", "[music]", "(music)", "[applause]",
        "(applause)", "[silence]", "(silence)", "subtitles by the amara.org community",
        // Chinese — notorious large-v3 silence/music hallucinations
        "请不吝点赞订阅转发打赏支持明镜与点点栏目",
        "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目",
        "字幕由amara.org社区提供", "字幕志愿者", "明镜需要您的支持",
        "请点赞订阅", "请订阅", "下集再见", "谢谢观看", "感谢观看",
        "字幕组", "本字幕由"
    ]
}
