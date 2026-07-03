import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Inserts text at the current cursor in the focused app by pasting: stash clipboard → set text →
/// synthesize ⌘V → restore clipboard. Synthesizing the keystroke requires Accessibility permission.
enum TextInserter {
    /// Whether the app is trusted for Accessibility (needed to post the ⌘V keystroke).
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Show the system Accessibility prompt (and register the app in the list).
    @discardableResult
    static func requestTrust() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Settings → Privacy & Security → Accessibility.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Paste `text` at the cursor, restoring the previous clipboard afterward.
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        sendCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
