import SwiftUI
import AppKit
import ScribeCore

/// Folder + language + model settings, persisted to the shared config.json (auto-saved on change).
struct SettingsView: View {
    @State private var config = Config.loadOrDefaults()
    @State private var modelPresent = false
    @State private var downloading = false
    @State private var downloadError: String?

    private let languages: [(String, String)] = [
        ("zh", "Chinese (zh)"), ("en", "English (en)"), ("auto", "Auto-detect")
    ]

    var body: some View {
        Form {
            Section("Output") {
                HStack {
                    TextField("Folder", text: $config.outputDir)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { pickFolder() }
                }
                Text("Transcripts are saved here as Markdown, with a tail-able .live.txt while recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Language", selection: $config.language) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Model", selection: $config.model) {
                    ForEach(ModelDownloader.knownModels, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    if modelPresent {
                        Label("Model downloaded", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout)
                    } else if downloading {
                        ProgressView().controlSize(.small)
                        Text("Downloading \(config.model)…").font(.callout)
                    } else {
                        Button("Download model") { downloadModel() }
                        Text("not downloaded").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let downloadError {
                    Text(downloadError).font(.caption).foregroundStyle(.red)
                }
                Text("Chinese / mixed zh+en: use a multilingual model (e.g. large-v3-turbo) with language Auto. Don't force a language the speaker isn't using — Whisper will translate instead of transcribe. The .en models are English-only.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Shortcut") {
                HStack {
                    Text("Start / stop recording:")
                    Spacer()
                    HotKeyRecorder().frame(width: 170, height: 24)
                }
                Text("Global hotkey — works from any app. Press it once to start, again to stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Echo & cross-talk (speakers)") {
                Toggle("Echo cancellation", isOn: Binding(
                    get: { config.echoCancellation ?? true },
                    set: { config.echoCancellation = $0 }))
                Toggle("De-duplicate cross-talk", isOn: Binding(
                    get: { config.dedupeCrossTalk ?? true },
                    set: { config.dedupeCrossTalk = $0 }))
                Text("Keep both on when recording over speakers (mic hears the system output). Headphones make them unnecessary. Changes apply to the next recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { refreshModelPresent() }
        .onChange(of: config) { _ in
            try? config.save()
            refreshModelPresent()
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            config.outputDir = url.path
        }
    }

    private func refreshModelPresent() {
        modelPresent = FileManager.default.fileExists(atPath: config.modelPath.path)
    }

    private func downloadModel() {
        downloading = true
        downloadError = nil
        let model = config.model
        let dest = config.modelPath
        Task {
            do {
                try await ModelDownloader.download(model: model, to: dest)
                await MainActor.run {
                    downloading = false
                    refreshModelPresent()
                }
            } catch {
                await MainActor.run {
                    downloading = false
                    downloadError = "\(error)"
                }
            }
        }
    }
}
