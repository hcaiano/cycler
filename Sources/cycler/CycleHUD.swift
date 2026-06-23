import AppKit

/// A small, non-activating window switcher shown while cycling an app's windows: the app, plus the
/// list of its windows with the current one highlighted, so you can see where the next press lands.
/// It never becomes key/main, so it cannot steal focus from the app being cycled.
final class CycleHUD {
    static let shared = CycleHUD()

    private let panel: HUDPanel
    private let iconView = NSImageView()
    private let appLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let rowStack = NSStackView()
    private var rowViews: [WindowRow] = []
    private var measureView: NSView!     // the padded content; drives the panel's fitting size
    private var dismissWorkItem: DispatchWorkItem?
    private var generation = 0
    private var shownCount = 0

    private let corner: CGFloat = 14
    private let width: CGFloat = 320      // fixed: titles truncate, panel never resizes while cycling
    private let maxVisibleRows = 7

    private init() {
        panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = buildContainer()
    }

    /// Show the app's windows with `selectedIndex` highlighted. No-op for fewer than two windows.
    func show(appIcon: NSImage?, appName: String, windowTitles: [String], selectedIndex: Int) {
        guard windowTitles.count > 1 else { return }

        generation += 1
        dismissWorkItem?.cancel()

        iconView.image = appIcon
        appLabel.stringValue = appName
        countLabel.stringValue = "\(selectedIndex + 1) of \(windowTitles.count)"

        // Rebuild rows only when the window set changes; otherwise just move the highlight so the
        // panel never resizes or flickers mid-cycle.
        let window = visibleWindow(count: windowTitles.count, selected: selectedIndex)
        let slice = Array(windowTitles[window])
        if slice.count != shownCount { rebuildRows(slice.count) }
        shownCount = slice.count
        for (offset, row) in rowViews.enumerated() {
            let absolute = window.lowerBound + offset
            row.update(title: slice[offset], selected: absolute == selectedIndex)
        }

        if let content = measureView {
            content.layoutSubtreeIfNeeded()
            let size = NSSize(width: width, height: content.fittingSize.height)
            let screen = NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? .zero
            let origin = NSPoint(x: round(visible.midX - size.width / 2),
                                 y: round(visible.midY - size.height / 2))
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.07
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func hide() {
        let gen = generation
        dismissWorkItem = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.generation == gen else { return }
            self.panel.orderOut(nil)
        }
    }

    private func rebuildRows(_ count: Int) {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = (0..<count).map { _ in WindowRow() }
        rowViews.forEach { rowStack.addArrangedSubview($0) }
        rowViews.forEach { $0.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true }
    }

    private func visibleWindow(count: Int, selected: Int) -> Range<Int> {
        guard count > maxVisibleRows else { return 0..<count }
        var start = max(0, selected - maxVisibleRows / 2)
        start = min(start, count - maxVisibleRows)
        return start..<(start + maxVisibleRows)
    }

    private func buildContainer() -> NSView {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        appLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        appLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        appLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = NSStackView(views: [iconView, appLabel, NSView(), countLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        header.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 1
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [header, separator, rowStack])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 9
        column.setCustomSpacing(8, after: separator)
        column.translatesAutoresizingMaskIntoConstraints = false

        // `content` is the padded surface we measure for the panel's fitting size; it lives inside
        // whichever glass/blur container we choose below.
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: width),
            iconView.widthAnchor.constraint(equalToConstant: 17),
            iconView.heightAnchor.constraint(equalToConstant: 17),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.widthAnchor.constraint(equalTo: column.widthAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            rowStack.widthAnchor.constraint(equalTo: column.widthAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        measureView = content

        // macOS 26+: real Liquid Glass, which adapts to whatever's behind it. A subtle dark tint
        // keeps the white text legible even over bright/white backgrounds.
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = corner
            glass.tintColor = NSColor(white: 0.0, alpha: 0.42)
            glass.contentView = content
            glass.translatesAutoresizingMaskIntoConstraints = false
            return glass
        }

        // Fallback (< macOS 26): vibrancy forced to a dark appearance so it stays a readable dark
        // HUD on any background, rounded via a mask image.
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.maskImage = Self.roundedMask(radius: corner)
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            content.topAnchor.constraint(equalTo: blur.topAnchor),
            content.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        return blur
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// One window in the switcher. Reused across presses; only its title and selection change, so the
/// panel layout stays stable (no resize, no text jump).
private final class WindowRow: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7

        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(title: String, selected: Bool) {
        label.stringValue = title.isEmpty ? "Untitled" : title
        label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        label.textColor = selected ? .white : NSColor.white.withAlphaComponent(0.7)
        // A soft white wash for the selection — subtle, not a loud brand pill.
        layer?.backgroundColor = selected
            ? NSColor.white.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
