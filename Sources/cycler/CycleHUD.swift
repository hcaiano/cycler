import AppKit

final class CycleHUD {
    static let shared = CycleHUD()

    private let panel: NSPanel
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private var dismissWorkItem: DispatchWorkItem?
    private var displayGeneration = 0

    private init() {
        panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 82),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.setAccessibilityTitle("Cycler Window HUD")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = buildContentView()
    }

    func show(appIcon: NSImage?, title: String, index: Int, count: Int) {
        guard count > 0 else { return }

        displayGeneration += 1
        dismissWorkItem?.cancel()
        iconView.image = appIcon
        titleLabel.stringValue = title.isEmpty ? "Untitled Window" : title
        positionLabel.stringValue = "\(index + 1) / \(count)"
        positionLabel.isHidden = count <= 1

        panel.layoutIfNeeded()
        position(on: NSScreen.main ?? NSScreen.screens.first)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: workItem)
    }

    private func hide() {
        let generation = displayGeneration
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.displayGeneration == generation else { return }
            self.panel.orderOut(nil)
        }
    }

    private func buildContentView() -> NSView {
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 18
        material.layer?.masksToBounds = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1

        positionLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        positionLabel.textColor = .secondaryLabelColor
        positionLabel.alignment = .right
        positionLabel.setContentHuggingPriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, positionLabel])
        textStack.orientation = .horizontal
        textStack.alignment = .centerY
        textStack.spacing = 12
        textStack.translatesAutoresizingMaskIntoConstraints = false

        material.addSubview(iconView)
        material.addSubview(textStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 18),
            iconView.centerYAnchor.constraint(equalTo: material.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalToConstant: 42),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -18),
            textStack.centerYAnchor.constraint(equalTo: material.centerYAnchor),
        ])

        return material
    }

    private func position(on screen: NSScreen?) {
        guard let screen else { return }
        let frame = panel.frame
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2))
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
