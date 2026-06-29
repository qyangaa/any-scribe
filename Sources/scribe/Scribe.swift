import Foundation
import ArgumentParser
import AVFoundation
import CoreGraphics
import ScribeCore

@main
struct Scribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scribe",
        abstract: "Record and live-transcribe meetings: your mic + the Mac's system audio output.",
        subcommands: [Init.self, Check.self, Start.self],
        defaultSubcommand: Start.self
    )
}

// MARK: - init

extension Scribe {
    struct Init: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write a default config file.")

        @Flag(name: .shortAndLong, help: "Overwrite an existing config.")
        var force = false

        @Option(name: .long, help: "Output directory for transcripts.")
        var out: String?

        func run() async throws {
            if FileManager.default.fileExists(atPath: Config.configFile.path) && !force {
                print("Config already exists at \(Config.configFile.path). Use --force to overwrite.")
                return
            }
            let outputDir = out ?? Config.defaultOutputDir()
            let config = Config.defaults(outputDir: outputDir)
            try config.save()
            print("Wrote config to \(Config.configFile.path)")
            print("  outputDir: \(config.outputDir)")
            print("  model:     \(config.model)")
            print("\nNext: `scribe check --download` to fetch the model and verify permissions.")
        }
    }
}

// MARK: - check

extension Scribe {
    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Verify model, whisper-server, and permissions.")

        @Flag(name: .long, help: "Download the configured model if missing.")
        var download = false

        func run() async throws {
            let config = try Config.load()
            print("Config: \(Config.configFile.path)\n")

            // whisper-server
            if let bin = WhisperServer.findBinary(override: config.whisperServerBin) {
                let arch = WhisperServer.binaryArch(bin)
                let note = arch == "arm64" ? " (native arm64 — Metal GPU)" : " (\(arch) — no Metal; slow under Rosetta)"
                print("✓ whisper-server: \(bin)\(note)")
            } else {
                print("✗ whisper-server not found. Install with: brew install whisper-cpp")
            }

            // Model
            if FileManager.default.fileExists(atPath: config.modelPath.path) {
                print("✓ model \(config.model): \(config.modelPath.path)")
            } else if download {
                print("… downloading model \(config.model)…")
                try await ModelDownloader.download(model: config.model, to: config.modelPath)
                print("✓ model downloaded to \(config.modelPath.path)")
            } else {
                print("✗ model \(config.model) missing. Run `scribe check --download` to fetch it.")
            }

            // Microphone permission
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                print("✓ Microphone permission granted")
            case .notDetermined:
                print("… requesting Microphone permission…")
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                print(granted ? "✓ Microphone permission granted" : "✗ Microphone permission denied")
            default:
                print("✗ Microphone permission denied. Enable it for your terminal in System Settings → Privacy & Security → Microphone.")
            }

            // Screen Recording permission (required by ScreenCaptureKit for system audio)
            if CGPreflightScreenCaptureAccess() {
                print("✓ Screen Recording permission granted (needed for system audio)")
            } else {
                print("✗ Screen Recording permission missing. Triggering the prompt…")
                CGRequestScreenCaptureAccess()
                print("  Enable your terminal in System Settings → Privacy & Security → Screen Recording, then restart the terminal.")
            }

            print("\nReminder: permissions attach to the terminal app you launch from, not to scribe itself.")
        }
    }
}

// MARK: - start

extension Scribe {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start recording and live transcription. Ctrl-C to stop.")

        @Option(name: .long, help: "Override the model for this session.")
        var model: String?

        @Option(name: .long, help: "Override the output directory for this session.")
        var out: String?

        @Option(name: .long, help: "Override the language for this session (e.g. zh, en, auto).")
        var language: String?

        func run() async throws {
            var config = try Config.load()
            if let model { config.model = model }
            if let out { config.outputDir = out }
            if let language {
                config.language = language
                config.micLanguage = nil
                config.systemLanguage = nil
            }

            guard FileManager.default.fileExists(atPath: config.modelPath.path) else {
                throw ScribeError.missingModel(config.model)
            }

            let recorder = Recorder(config: config)
            recorder.onLine = { line in
                let f = DateFormatter()
                f.dateFormat = "HH:mm:ss"
                f.locale = Locale(identifier: "en_US_POSIX")
                let text = "[\(f.string(from: line.time))] **\(line.label):** \(line.text)\n"
                FileHandle.standardOutput.write(Data(text.utf8))
            }

            try await recorder.start()
            print("● Recording. Live transcript: \(recorder.liveFilePath ?? "(pending)")")
            print("  \(config.micLabel) = microphone, \(config.systemLabel) = system audio. Press Ctrl-C to stop.\n")

            await Self.waitForInterrupt()

            print("\n■ Stopping…")
            let path = await recorder.stop()
            print("Saved transcript: \(path ?? "(none)")")
        }

        /// Block until SIGINT (Ctrl-C).
        static func waitForInterrupt() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
                signal(SIGINT, SIG_IGN)
                source.setEventHandler {
                    source.cancel()
                    continuation.resume()
                }
                source.resume()
                // Retain the source for the lifetime of the wait.
                Self.signalSource = source
            }
        }

        nonisolated(unsafe) static var signalSource: DispatchSourceSignal?
    }
}
