import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

/// Captures the generic system audio output mix (everything the Mac plays) via
/// ScreenCaptureKit — not tied to any specific app. Requires Screen Recording permission,
/// even though we capture a token 2x2 video frame and only use the audio.
@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onSamples: ([Float]) -> Void
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "anyscribe.systemaudio")

    init(onSamples: @escaping ([Float]) -> Void) {
        self.onSamples = onSamples
    }

    func start() async throws {
        // Pre-flight the Screen Recording permission so we surface one clear message instead of
        // racing the OS prompt with a failed capture. CGRequestScreenCaptureAccess() also
        // registers the app in System Settings → Screen Recording so the user can toggle it on.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw ScribeError.screenRecordingNeeded
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw ScribeError.screenRecordingNeeded
        }
        guard let display = content.displays.first else {
            throw ScribeError.captureFailed("no display available for ScreenCaptureKit")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // don't capture our own output -> no feedback
        config.width = 2                              // minimal video; we only want audio
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let mono = Self.monoSamples(from: sampleBuffer) else { return }
        if !mono.samples.isEmpty {
            let resampled = Audio.resampleTo16k(mono.samples, sourceRate: mono.sampleRate)
            onSamples(resampled)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("System audio stream stopped: \(error.localizedDescription)\n".utf8))
    }

    /// Extract downmixed mono Float32 samples (at the source rate) from a CoreMedia audio buffer.
    private static func monoSamples(from sampleBuffer: CMSampleBuffer) -> (samples: [Float], sampleRate: Double)? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let channels = Int(asbd.mChannelsPerFrame)
        let sampleRate = asbd.mSampleRate
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard isFloat, channels > 0 else { return nil }   // ScreenCaptureKit delivers Float32

        var blockBuffer: CMBlockBuffer?
        var sizeNeeded = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil) == noErr else { return nil }

        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablRaw.deallocate() }
        let ablPtr = ablRaw.assumingMemoryBound(to: AudioBufferList.self)

        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer) == noErr else { return nil }
        _ = blockBuffer   // keep alive until we finish reading below

        let list = UnsafeMutableAudioBufferListPointer(ablPtr)

        if list.count >= channels && channels > 1 {
            // Non-interleaved: one buffer per channel, average them.
            let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            var out = [Float](repeating: 0, count: frames)
            for ch in 0..<channels {
                guard let data = list[ch].mData else { continue }
                let p = data.assumingMemoryBound(to: Float.self)
                for i in 0..<frames { out[i] += p[i] }
            }
            let scale = 1.0 / Float(channels)
            for i in 0..<frames { out[i] *= scale }
            return (out, sampleRate)
        } else {
            // Single buffer: mono, or interleaved multi-channel.
            guard let data = list[0].mData else { return nil }
            let totalFloats = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            let p = data.assumingMemoryBound(to: Float.self)
            if channels <= 1 {
                return (Array(UnsafeBufferPointer(start: p, count: totalFloats)), sampleRate)
            }
            let frames = totalFloats / channels
            var out = [Float](repeating: 0, count: frames)
            let scale = 1.0 / Float(channels)
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += p[i * channels + ch] }
                out[i] = sum * scale
            }
            return (out, sampleRate)
        }
    }
}
