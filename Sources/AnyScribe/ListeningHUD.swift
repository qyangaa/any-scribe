import AppKit

/// A small floating pill near the bottom of the screen shown during push-to-talk.
@MainActor
final class ListeningHUD {
    private var panel: NSPanel?
    private var label: NSTextField?

    func show(_ text: String) {
        let p = panel ?? makePanel()
        panel = p
        label?.stringValue = text
        position(p)
        p.orderFrontRegardless()
    }

    func update(_ text: String) { label?.stringValue = text }

    func hide() { panel?.orderOut(nil) }

    private let width: CGFloat = 380

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 54),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let blur = NSVisualEffectView(frame: p.contentView!.bounds)
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        let lbl = NSTextField(labelWithString: "")
        lbl.font = .systemFont(ofSize: 15, weight: .medium)
        lbl.textColor = .white
        lbl.alignment = .center
        lbl.lineBreakMode = .byTruncatingHead   // show the latest words of a live preview
        lbl.frame = NSRect(x: 14, y: 16, width: width - 28, height: 22)
        lbl.autoresizingMask = [.width]
        blur.addSubview(lbl)

        p.contentView?.addSubview(blur)
        label = lbl
        return p
    }

    private func position(_ p: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let s = p.frame.size
        p.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: f.minY + 140))
    }
}
