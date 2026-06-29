import AppKit
import SwiftUI
import Combine
import ScribeCore
import KeyboardShortcuts

/// Owns the NSStatusItem. Left-click toggles recording (one click). Right-click / control-click
/// opens a menu for Settings, the live transcript, the transcripts folder, and Quit.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let viewModel = RecorderViewModel()
    private var cancellables = Set<AnyCancellable>()

    private var settingsWindow: NSWindow?
    private var transcriptWindow: NSWindow?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateButton()

        viewModel.$state.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }.store(in: &cancellables)
        viewModel.$elapsed.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }.store(in: &cancellables)
        viewModel.$lastError.receive(on: RunLoop.main)
            .sink { [weak self] err in if let err { self?.presentError(err) } }.store(in: &cancellables)
        viewModel.$savedPath.receive(on: RunLoop.main)
            .sink { [weak self] path in if let path { self?.notifySaved(path) } }.store(in: &cancellables)

        // Global start/stop hotkey (same shortcut toggles).
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.viewModel.toggle()
        }
    }

    // MARK: - Status button

    private func updateButton() {
        guard let button = statusItem.button else { return }
        switch viewModel.state {
        case .idle:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = symbol("waveform", description: "Any Scribe (idle)")
            button.image?.isTemplate = true
            button.toolTip = "Click to start recording"
        case .starting:
            button.image = nil
            button.attributedTitle = NSAttributedString(string: "● …",
                attributes: [.foregroundColor: NSColor.systemOrange])
            button.toolTip = "Starting…"
        case .recording:
            button.image = nil
            let dot = NSAttributedString(string: "● ", attributes: [.foregroundColor: NSColor.systemRed])
            let time = NSAttributedString(string: timeString(viewModel.elapsed),
                attributes: [.foregroundColor: NSColor.labelColor,
                             .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
            let combined = NSMutableAttributedString()
            combined.append(dot); combined.append(time)
            button.attributedTitle = combined
            button.toolTip = "Click to stop recording"
        }
    }

    private func symbol(_ name: String, description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Clicks

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            showMenu()
        } else {
            viewModel.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let toggleTitle = viewModel.state == .idle ? "Start Recording" : "Stop Recording"
        add(menu, toggleTitle, #selector(toggleFromMenu))
        menu.addItem(.separator())
        add(menu, "Show Live Transcript", #selector(showTranscript))
        add(menu, "Settings…", #selector(showSettings))
        add(menu, "Open Transcripts Folder", #selector(openTranscriptsFolder))
        menu.addItem(.separator())
        add(menu, "Quit Any Scribe", #selector(quit))

        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func toggleFromMenu() { viewModel.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Called on app termination — stop the warm whisper-server so it doesn't linger.
    func appWillTerminate() { viewModel.shutdownServer() }

    @objc private func openTranscriptsFolder() {
        let config = Config.loadOrDefaults()
        let url = URL(fileURLWithPath: config.outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Windows

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = makeWindow(title: "Any Scribe Settings",
                                    content: SettingsView(),
                                    size: NSSize(width: 460, height: 600))
            settingsWindow = window
        }
        present(settingsWindow)
    }

    @objc private func showTranscript() {
        if transcriptWindow == nil {
            let window = makeWindow(title: "Live Transcript",
                                    content: LiveTranscriptView(viewModel: viewModel),
                                    size: NSSize(width: 480, height: 420))
            transcriptWindow = window
        }
        present(transcriptWindow)
    }

    private func makeWindow<Content: View>(title: String, content: Content, size: NSSize) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Feedback

    private func presentError(_ message: String) {
        let isScreen = message.localizedCaseInsensitiveContains("Screen Recording")
        let alert = NSAlert()
        alert.alertStyle = .warning
        if isScreen {
            alert.messageText = "Screen Recording permission needed"
            alert.informativeText = message
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
        } else {
            alert.messageText = "Couldn't start recording"
            alert.informativeText = message + "\n\nIf this mentions Microphone, grant Any Scribe access in System Settings → Privacy & Security, then try again."
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if isScreen, response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        viewModel.lastError = nil
    }

    private func notifySaved(_ path: String) {
        statusItem.button?.toolTip = "Saved: \(path)"
    }
}
