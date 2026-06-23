import AppKit

/// Minimal About panel: name, version, one-line description. Intentionally small for the
/// scaffold — a richer About (brand wordmark, links) is a later design pass (see HANDOFF.md).
final class AboutWindowController {
    private static var shared: AboutWindowController?

    private let window: NSWindow

    static func show() {
        if shared == nil { shared = AboutWindowController() }
        shared?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init() {
        let size = NSSize(width: 360, height: 200)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About Cycler"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: NSRect(origin: .zero, size: size))

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

        let title = NSTextField(labelWithString: "Cycler")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = Brand.accent
        title.frame = NSRect(x: 0, y: size.height - 86, width: size.width, height: 36)
        title.alignment = .center

        let subtitle = NSTextField(labelWithString: "Jump to an app, press again to walk its windows.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 20, y: size.height - 112, width: size.width - 40, height: 18)
        subtitle.alignment = .center

        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.frame = NSRect(x: 0, y: 28, width: size.width, height: 16)
        versionLabel.alignment = .center

        content.addSubview(title)
        content.addSubview(subtitle)
        content.addSubview(versionLabel)
        window.contentView = content
    }
}
