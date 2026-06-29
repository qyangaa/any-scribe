import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Single global shortcut that toggles recording on/off.
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.command, .option]))
}
