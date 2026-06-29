import Foundation
import AVFoundation

/// Audio format helpers. We deliberately avoid `AVAudioConverter`: with some capture
/// configurations it mis-reports channel counts (the documented 9-channel Voice-Processing
/// bug) and crashes on the realtime thread. Instead we downmix and resample by hand.
enum Audio {
    static let targetRate: Double = 16_000

    /// Convert an arbitrary-format PCM buffer to 16 kHz mono Float32 samples.
    /// Channels are averaged; resampling is linear interpolation. Good enough for speech.
    static func toMono16k(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let mono = downmixToMono(buffer) else { return [] }
        let sourceRate = buffer.format.sampleRate
        if abs(sourceRate - targetRate) < 1 {
            return mono
        }
        return resampleLinear(mono, from: sourceRate, to: targetRate)
    }

    /// Average all channels into a single Float array, handling both float and int formats.
    private static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        let channels = Int(buffer.format.channelCount)

        if let floatData = buffer.floatChannelData {
            var out = [Float](repeating: 0, count: frames)
            for ch in 0..<channels {
                let p = floatData[ch]
                for i in 0..<frames { out[i] += p[i] }
            }
            if channels > 1 {
                let scale = 1.0 / Float(channels)
                for i in 0..<frames { out[i] *= scale }
            }
            return out
        }

        if let int16Data = buffer.int16ChannelData {
            var out = [Float](repeating: 0, count: frames)
            let norm: Float = 1.0 / 32768.0
            for ch in 0..<channels {
                let p = int16Data[ch]
                for i in 0..<frames { out[i] += Float(p[i]) * norm }
            }
            if channels > 1 {
                let scale = 1.0 / Float(channels)
                for i in 0..<frames { out[i] *= scale }
            }
            return out
        }

        return nil
    }

    /// Resample already-downmixed mono samples to 16 kHz. Used by the system-audio path,
    /// which extracts mono floats directly from CoreMedia buffers.
    static func resampleTo16k(_ mono: [Float], sourceRate: Double) -> [Float] {
        if abs(sourceRate - targetRate) < 1 { return mono }
        return resampleLinear(mono, from: sourceRate, to: targetRate)
    }

    private static func resampleLinear(_ input: [Float], from sourceRate: Double, to destRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        let ratio = destRate / sourceRate
        let outCount = Int(Double(input.count) * ratio)
        guard outCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: outCount)
        let step = sourceRate / destRate
        var pos = 0.0
        for i in 0..<outCount {
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let a = input[idx]
            let b = idx + 1 < input.count ? input[idx + 1] : a
            out[i] = a + (b - a) * frac
            pos += step
        }
        return out
    }

    /// Encode 16 kHz mono Float32 samples as a 16-bit PCM WAV file in memory.
    static func wavData(_ samples: [Float], sampleRate: Int = Int(targetRate)) -> Data {
        let bitsPerSample = 16
        let channels = 1
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * bitsPerSample / 8

        var data = Data()
        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func append32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        append32(16)                    // PCM fmt chunk size
        append16(1)                     // PCM format
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(byteRate))
        append16(UInt16(blockAlign))
        append16(UInt16(bitsPerSample))
        append("data")
        append32(UInt32(dataSize))

        data.reserveCapacity(data.count + dataSize)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let intSample = Int16(clamped * 32767.0)
            append16(UInt16(bitPattern: intSample))
        }
        return data
    }

    /// RMS level of a sample window, used to skip near-silent chunks.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
