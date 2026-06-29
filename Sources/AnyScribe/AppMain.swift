import AppKit

/// Menu-bar-only app entry. Runs as an accessory (no Dock icon, no main window).
@main
enum AppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu-bar only; reinforced by LSUIElement in Info.plist
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.appWillTerminate()
    }
}
