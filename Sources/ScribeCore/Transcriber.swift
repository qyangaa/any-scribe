import Foundation

/// A speech-to-text engine: local whisper-server or the OpenAI transcription API.
public protocol Transcribing: Sendable {
    func transcribe(wav: Data, language: String, prompt: String?) async throws -> String
    /// Whether this engine needs the local whisper-server running.
    var needsLocalServer: Bool { get }
}

extension WhisperClient: Transcribing {
    public var needsLocalServer: Bool { true }
}

/// OpenAI `/v1/audio/transcriptions` (gpt-4o-transcribe / whisper-1). Sends audio to OpenAI —
/// only used when the user explicitly opts in with an API key.
public struct OpenAITranscriber: Transcribing {
    let apiKey: String
    let model: String
    public var needsLocalServer: Bool { false }

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    public func transcribe(wav: Data, language: String, prompt: String?) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "----anyscribe-\(UInt32.random(in: .min ... .max))"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        field("model", model)
        if language != "auto", !language.isEmpty { field("language", language) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? "?"
            throw ScribeError.serverFailed("OpenAI transcription failed: \(detail)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            throw ScribeError.serverFailed("OpenAI transcription: unexpected response")
        }
        return WhisperClient.clean(text)
    }
}

public extension Config {
    /// Build the configured transcription engine.
    func makeTranscriber() -> any Transcribing {
        if usesOpenAITranscriber, let key = resolvedOpenAIKey {
            return OpenAITranscriber(apiKey: key, model: openaiTranscriptionModel ?? "gpt-4o-transcribe")
        }
        return WhisperClient(inferenceURL: inferenceURL)
    }
}
