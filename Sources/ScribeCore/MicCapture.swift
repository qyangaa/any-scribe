import Foundation
import AVFoundation
import CoreAudio

/// Captures the microphone with AVAudioEngine. We do NOT enable Voice Processing IO: it
/// triggers the documented 9-channel format bug and ducks system audio, both of which break
/// this dual-stream setup. Echo cancellation is traded away in favor of using headphones.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let onSamples: ([Float]) -> Void
    private let preferredDeviceName: String?
    private let echoCancellation: Bool
    private var tapped = false

    init(preferredDeviceName: String?, echoCancellation: Bool, onSamples: @escaping ([Float]) -> Void) {
        self.preferredDeviceName = preferredDeviceName
        self.echoCancellation = echoCancellation
        self.onSamples = onSamples
    }

    func start() throws {
        if let name = preferredDeviceName, let deviceID = Self.findInputDevice(named: name) {
            try Self.setInputDevice(deviceID, on: engine)
        }

        let input = engine.inputNode
        // Voice-Processing IO performs acoustic echo cancellation, referencing the system output
        // to subtract speaker bleed from the mic. Our manual downmix tolerates the resulting
        // channel layout, so the documented AVAudioConverter 9-channel crash doesn't apply.
        // It can fail to initialize on some output-device configs (err -10875), so we fall back.
        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                // By default Voice-Processing aggressively ducks (lowers) other audio while active,
                // which makes the meeting hard to hear over speakers. Minimize that — echo
                // cancellation still works via the reference signal.
                if #available(macOS 14.0, *) {
                    input.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                            enableAdvancedDucking: false, duckingLevel: .min)
                }
                try startEngine(input: input)
                return
            } catch {
                FileHandle.standardError.write(Data("Warning: echo cancellation unavailable (\(error)); retrying without it.\n".utf8))
                if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
                engine.stop()
                try? input.setVoiceProcessingEnabled(false)
            }
        }
        try startEngine(input: input)
    }

    /// Install the tap and start the engine. Throws if the mic is unavailable or the engine
    /// can't initialize (the caller may retry with echo cancellation disabled).
    private func startEngine(input: AVAudioInputNode) throws {
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw ScribeError.captureFailed("microphone unavailable (check Microphone permission)")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            let samples = Audio.toMono16k(buffer)
            if !samples.isEmpty { self?.onSamples(samples) }
        }
        tapped = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        if engine.isRunning { engine.stop() }
    }

    // MARK: - CoreAudio device selection

    private static func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            FileHandle.standardError.write(Data("Warning: could not select mic device (status \(status)); using default.\n".utf8))
        }
    }

    /// Find an input device whose name contains `name` (case-insensitive).
    static func findInputDevice(named name: String) -> AudioDeviceID? {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return nil
        }

        for device in devices {
            guard hasInputChannels(device), let deviceName = deviceName(device) else { continue }
            if deviceName.localizedCaseInsensitiveContains(name) {
                return device
            }
        }
        return nil
    }

    private static func hasInputChannels(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in buffers where buffer.mNumberChannels > 0 { return true }
        return false
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value = name else { return nil }
        return value.takeRetainedValue() as String
    }
}
