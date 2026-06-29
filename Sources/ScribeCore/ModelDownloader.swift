import Foundation

/// Downloads ggml whisper models from the official Hugging Face mirror.
public enum ModelDownloader {
    /// Common model names offered in the UI / docs.
    public static let knownModels = [
        "large-v3-turbo", "large-v3-turbo-q5_0", "large-v3", "medium",
        "small", "small.en", "base", "base.en"
    ]

    public static func download(model: String, to destination: URL) async throws {
        let urlString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(model).bin"
        guard let url = URL(string: urlString) else {
            throw ScribeError.serverFailed("bad model URL")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ScribeError.serverFailed("model download HTTP \(http.statusCode) — is '\(model)' a valid model name?")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
}
