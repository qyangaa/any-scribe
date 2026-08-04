import Foundation
import AVFoundation

/// A microphone engine that is configured once and reused across push-to-talk sessions.
/// Creating an AVAudioEngine and enabling Voice-Processing takes hundreds of milliseconds —
/// doing that per hold swallowed the first words. Here the expensive setup happens once
/// (ideally pre-warmed at app launch); each hold only starts/stops the prepared engine, so
/// capture begins almost immediately. The mic indicator is only on while a hold is active.
public final class PersistentMic: @unchecked Sendable {
    public static let shared = PersistentMic()

    private var engine: AVAudioEngine?
    private var engineAEC: Bool?
    private var onSamples: (([Float]) -> Void)?
    private var tapped = false
    private let queue = DispatchQueue(label: "anyscribe.persistentmic")

    private init() {}

    /// Build and prepare the engine ahead of first use (no capture starts; no mic indicator).
    public func prewarm(echoCancellation: Bool) {
        queue.async { [weak self] in
            _ = try? self?.preparedEngine(echoCancellation: echoCancellation)
        }
    }

    /// Start delivering 16 kHz mono samples. Fast after the first configuration.
    public func begin(echoCancellation: Bool, onSamples: @escaping ([Float]) -> Void) throws {
        try queue.sync {
            let engine = try preparedEngine(echoCancellation: echoCancellation)
            self.onSamples = onSamples
            if !tapped {
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0 else {
                    throw ScribeError.captureFailed("microphone unavailable (check Microphone permission)")
                }
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                    let samples = Audio.toMono16k(buffer)
                    if !samples.isEmpty { self?.onSamples?(samples) }
                }
                tapped = true
            }
            engine.prepare()
            try engine.start()
        }
    }

    /// Stop capture (mic indicator turns off); the configured engine is kept for the next hold.
    public func end() {
        queue.sync {
            onSamples = nil
            engine?.stop()
        }
    }

    // MARK: - Private

    private func preparedEngine(echoCancellation: Bool) throws -> AVAudioEngine {
        if let engine, engineAEC == echoCancellation { return engine }
        // Settings changed (or first use): tear down and rebuild.
        if let old = engine {
            if tapped { old.inputNode.removeTap(onBus: 0); tapped = false }
            old.stop()
        }
        let fresh = AVAudioEngine()
        let input = fresh.inputNode
        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                if #available(macOS 14.0, *) {
                    input.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                            enableAdvancedDucking: false, duckingLevel: .min)
                }
            } catch {
                FileHandle.standardError.write(Data("Warning: echo cancellation unavailable (\(error)); continuing without it.\n".utf8))
            }
        }
        fresh.prepare()
        engine = fresh
        engineAEC = echoCancellation
        return fresh
    }
}
