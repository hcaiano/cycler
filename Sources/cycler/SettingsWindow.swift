import AppKit
import Carbon.HIToolbox
import CyclerCore
import UniformTypeIdentifiers

/// Hooks the Settings window needs from the app delegate.
struct SettingsContext {
    var config: () -> CyclerConfig
    var saveConfig: (CyclerConfig) throws -> Void
    var setRecording: (Bool) -> Void
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let bindingsView: BindingsSettingsView

    init(context: SettingsContext) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Cycler"
        window.minSize = NSSize(width: 560, height: 420)
        window.collectionBehavior = [.moveToActiveSpace]
        window.isReleasedWhenClosed = false
        bindingsView = BindingsSettingsView(context: context)
        super.init()
        bindingsView.hostWindow = window
        window.delegate = self
        window.contentView = bindingsView
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        if !window.isVisible { bindingsView.reloadFromConfig() }
        placeWindowIfNeeded()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKey()
    }

    func windowWillClose(_ notification: Notification) {
        bindingsView.stopRecording()
        NSApp.setActivationPolicy(.accessory)
    }

    private func placeWindowIfNeeded() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            if !window.isVisible { window.center() }
            return
        }
        let visible = screen.visibleFrame
        let frame = window.frame
        let usable = frame.width >= window.minSize.width && frame.height >= window.minSize.height
            && visible.intersects(frame)
        guard !window.isVisible || !usable else { return }
        let size = NSSize(width: max(frame.width, window.minSize.width),
                          height: max(frame.height, window.minSize.height))
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

// MARK: - Draft model

private struct BindingDraft {
    var bundleIdentifier: String
    var appName: String
    var keyCode: Int?
    var modifiers: UInt32?

    init(binding: AppBinding) {
        bundleIdentifier = binding.bundleIdentifier
        appName = AppInfo.name(forBundleIdentifier: binding.bundleIdentifier)
        keyCode = binding.keyCode
        modifiers = binding.modifiers
    }

    init(bundleIdentifier: String, appName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
    }

    var shortcutText: String {
        guard let keyCode, let modifiers else { return "" }
        return ShortcutKit.display(keyCode: keyCode, modifiers: modifiers)
    }

    var binding: AppBinding? {
        guard let keyCode, let modifiers else { return nil }
        return AppBinding(keyCode: keyCode, modifiers: modifiers, bundleIdentifier: bundleIdentifier)
    }
}

// MARK: - App lookup

private enum AppInfo {
    static func name(forBundleIdentifier id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return name(forAppURL: url) ?? id
    }

    static func name(forAppURL url: URL) -> String? {
        if let bundle = Bundle(url: url) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let v = bundle.object(forInfoDictionaryKey: key) as? String, !v.isEmpty { return v }
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func icon(forBundleIdentifier id: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct AppChoice {
    var bundleIdentifier: String
    var name: String
    var icon: NSImage
}

private enum AppCatalog {
    static func openNow() -> [AppChoice] {
        sortByName(dedup(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
                return AppChoice(bundleIdentifier: id,
                                 name: AppInfo.name(forAppURL: url) ?? app.localizedName ?? id,
                                 icon: NSWorkspace.shared.icon(forFile: url.path))
            }))
    }

    static func inDock() -> [AppChoice] {
        sortByName(dedup(dockURLs().compactMap(choice(forURL:))))
    }

    static func choice(forURL url: URL) -> AppChoice? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        return AppChoice(bundleIdentifier: id,
                         name: AppInfo.name(forAppURL: url) ?? id,
                         icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    private static func dockURLs() -> [URL] {
        guard let apps = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") else { return [] }
        return apps.compactMap { item in
            guard let d = item as? [String: Any], let t = d["tile-data"] as? [String: Any],
                  let f = t["file-data"] as? [String: Any], let raw = f["_CFURLString"] as? String,
                  let url = URL(string: raw), url.isFileURL else { return nil }
            return url
        }
    }

    private static func dedup(_ c: [AppChoice]) -> [AppChoice] {
        var seen = Set<String>(); var out: [AppChoice] = []
        for x in c where !seen.contains(x.bundleIdentifier) { seen.insert(x.bundleIdentifier); out.append(x) }
        return out
    }
    private static func sortByName(_ c: [AppChoice]) -> [AppChoice] {
        c.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Main view

private final class BindingsSettingsView: NSView {
    weak var hostWindow: NSWindow?

    private let ctx: SettingsContext
    private var drafts: [BindingDraft]
    private var recordingIndex: Int?
    private var monitor: Any?

    private let titleLabel = NSTextField(labelWithString: "Shortcuts")
    private let subtitleLabel = NSTextField(labelWithString:
        "Press a shortcut to jump to its app. Press it again to step through that app’s windows.")
    private let listStack = NSStackView()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let emptyView = EmptyView()
    private let addButton = NSButton()

    init(context: SettingsContext) {
        ctx = context
        drafts = context.config().bindings.map(BindingDraft.init(binding:))
        super.init(frame: .zero)
        build()
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let w = window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowLeft),
                                               name: NSWindow.didResignKeyNotification, object: w)
    }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2

        let header = NSStackView(views: [titleLabel, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5
        header.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false

        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
        ])

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.onAdd = { [weak self] in self?.beginAddBinding() }

        addButton.title = "Add Shortcut"
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .rounded
        addButton.controlSize = .large
        addButton.target = self
        addButton.action = #selector(beginAddBinding)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [addButton, NSView()])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header); addSubview(scroll); addSubview(emptyView); addSubview(footer)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 26),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            emptyView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: scroll.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])
    }

    // MARK: List

    private func rebuild() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        emptyView.isHidden = !drafts.isEmpty
        scroll.isHidden = drafts.isEmpty
        addButton.isHidden = drafts.isEmpty

        for (index, draft) in drafts.enumerated() {
            let row = BindingRowView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.configure(draft: draft, isRecording: index == recordingIndex)
            row.onRecord = { [weak self] in self?.toggleRecording(index) }
            row.onRemove = { [weak self] in self?.removeBinding(index) }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
        document.layoutSubtreeIfNeeded()
    }

    /// Write only complete bindings (app + shortcut) and live-reload hotkeys. Native apps apply
    /// immediately; an incomplete row stays visible until its shortcut is recorded.
    private func apply() {
        let config = CyclerConfig(bindings: drafts.compactMap(\.binding))
        do { try ctx.saveConfig(config) }
        catch { presentError("Couldn’t save your shortcuts.", error.localizedDescription) }
    }

    // MARK: Add / remove / pick

    @objc private func beginAddBinding() {
        stopRecording()
        guard let host = hostWindow else { return }
        let bound = Set(drafts.map(\.bundleIdentifier))
        let picker = AppPickerSheet(excluding: bound) { [weak self] choice in
            guard let self, let choice else { return }
            self.drafts.append(BindingDraft(bundleIdentifier: choice.bundleIdentifier, appName: choice.name))
            self.rebuild()
            // Jump straight into recording the new row's shortcut.
            self.toggleRecording(self.drafts.count - 1)
        }
        picker.present(in: host)
    }

    private func removeBinding(_ index: Int) {
        guard drafts.indices.contains(index) else { return }
        stopRecording()
        drafts.remove(at: index)
        rebuild()
        apply()
    }

    // MARK: Recording

    private func toggleRecording(_ index: Int) {
        guard drafts.indices.contains(index) else { return }
        if recordingIndex == index { stopRecording() } else { startRecording(index) }
    }

    private func startRecording(_ index: Int) {
        guard window?.isKeyWindow == true else { window?.makeKeyAndOrderFront(nil); return }
        if recordingIndex != nil { stopRecording() }
        recordingIndex = index
        ctx.setRecording(true)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }
        rebuild()
    }

    func stopRecording() {
        let was = recordingIndex != nil
        recordingIndex = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if was { ctx.setRecording(false) }
        rebuild()
    }

    @objc private func windowLeft() { stopRecording() }

    func reloadFromConfig() {
        stopRecording()
        drafts = ctx.config().bindings.map(BindingDraft.init(binding:))
        rebuild()
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let index = recordingIndex, drafts.indices.contains(index) else { return false }
        let keyCode = Int(event.keyCode)
        let bare = !ShortcutKit.hasModifier(event.modifierFlags)
        if keyCode == kVK_Escape, bare { stopRecording(); return true }
        if keyCode == kVK_Delete, bare {
            drafts[index].keyCode = nil; drafts[index].modifiers = nil
            stopRecording(); apply(); return true
        }
        guard ShortcutKit.hasModifier(event.modifierFlags) else { NSSound.beep(); return true }

        let modifiers = ShortcutKit.carbonModifiers(from: event.modifierFlags)
        // Reject a duplicate shortcut: no two apps may share a combo.
        if let other = drafts.indices.first(where: { i in
            i != index && drafts[i].keyCode == keyCode && drafts[i].modifiers == modifiers
        }) {
            stopRecording()
            NSSound.beep()
            presentError("That shortcut is taken.",
                         "\(ShortcutKit.display(keyCode: keyCode, modifiers: modifiers)) is already used by \(drafts[other].appName). Pick a different one.")
            return true
        }
        drafts[index].keyCode = keyCode
        drafts[index].modifiers = modifiers
        stopRecording()
        apply()
        return true
    }

    private func presentError(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        if let host = hostWindow { alert.beginSheetModal(for: host) } else { alert.runModal() }
    }
}

// MARK: - Row

private final class BindingRowView: NSView {
    var onRecord: () -> Void = {}
    var onRemove: () -> Void = {}

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let recorder = RecorderField()
    private let removeButton = NSButton()

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    func configure(draft: BindingDraft, isRecording: Bool) {
        nameLabel.stringValue = draft.appName
        recorder.text = draft.shortcutText
        recorder.isRecording = isRecording
        recorder.appName = draft.appName
        iconView.image = AppInfo.icon(forBundleIdentifier: draft.bundleIdentifier)
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
    }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.4).cgColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        recorder.onClick = { [weak self] in self?.onRecord() }

        removeButton.image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove")
        removeButton.imageScaling = .scaleProportionallyDown
        removeButton.isBordered = false
        removeButton.bezelStyle = .regularSquare
        removeButton.contentTintColor = .tertiaryLabelColor
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.toolTip = "Remove"
        removeButton.setAccessibilityLabel("Remove shortcut for \(nameLabel.stringValue)")
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, nameLabel, recorder, removeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 60),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            recorder.widthAnchor.constraint(equalToConstant: 168),
            recorder.heightAnchor.constraint(equalToConstant: 30),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
            removeButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @objc private func remove() { onRemove() }
}

// MARK: - Recorder

private final class RecorderField: NSView {
    var onClick: () -> Void = {}
    var isRecording = false { didSet { needsDisplay = true } }
    var text = "" { didSet { needsDisplay = true } }
    var appName = ""

    override var isFlipped: Bool { true }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        if isRecording { return "Recording shortcut for \(appName). Press a key combination." }
        return "Shortcut for \(appName), \(text.isEmpty ? "not set" : text)"
    }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        (isRecording ? Brand.accent.withAlphaComponent(0.14) : NSColor.textBackgroundColor.withAlphaComponent(0.6)).setFill()
        path.fill()
        (isRecording ? Brand.accent : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let str: String, color: NSColor, weight: NSFont.Weight
        if isRecording { str = "Press keys…"; color = Brand.accent; weight = .regular }
        else if text.isEmpty { str = "Record shortcut"; color = .secondaryLabelColor; weight = .regular }
        else { str = text; color = .labelColor; weight = .semibold }

        let s = NSAttributedString(string: str, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: weight), .foregroundColor: color,
        ])
        let sz = s.size()
        s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }

    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Empty state

private final class EmptyView: NSView {
    var onAdd: () -> Void = {}
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); build() }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: "No shortcuts yet")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center

        let message = NSTextField(labelWithString:
            "Add a shortcut for an app to jump to it, then press it again to cycle that app’s windows.")
        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byWordWrapping

        let add = NSButton(title: "Add Shortcut", target: self, action: #selector(addTapped))
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        add.bezelStyle = .rounded
        add.controlSize = .large
        add.keyEquivalent = "\r"

        let stack = NSStackView(views: [icon, title, message, add])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: message)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }
    @objc private func addTapped() { onAdd() }
}

// MARK: - App picker sheet

private final class AppPickerSheet: NSObject, NSSearchFieldDelegate {
    private let excluded: Set<String>
    private let completion: (AppChoice?) -> Void
    private var sheet: NSWindow?

    private let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    private let openNow: [AppChoice]
    private let dock: [AppChoice]

    init(excluding: Set<String>, completion: @escaping (AppChoice?) -> Void) {
        self.excluded = excluding
        self.completion = completion
        openNow = AppCatalog.openNow().filter { !excluding.contains($0.bundleIdentifier) }
        let openIDs = Set(openNow.map(\.bundleIdentifier))
        dock = AppCatalog.inDock().filter { !excluding.contains($0.bundleIdentifier) && !openIDs.contains($0.bundleIdentifier) }
        super.init()
    }

    func present(in host: NSWindow) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 460))

        let heading = NSTextField(labelWithString: "Choose an App")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search apps"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = document

        let browse = NSButton(title: "Browse…", target: self, action: #selector(browse))
        browse.bezelStyle = .rounded
        browse.translatesAutoresizingMaskIntoConstraints = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false

        [heading, searchField, scroll, browse, cancel].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            searchField.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: browse.topAnchor, constant: -14),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -6),

            cancel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            cancel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            browse.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            browse.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        let sheetWindow = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        sheetWindow.contentView = root
        sheet = sheetWindow
        rebuild()
        host.beginSheet(sheetWindow, completionHandler: nil)
        sheetWindow.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let on = openNow.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        let dk = dock.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        addSection("Open Now", on)
        addSection("In Your Dock", dk)
        if on.isEmpty && dk.isEmpty {
            let empty = NSTextField(labelWithString: q.isEmpty ? "No apps available." : "No matches.")
            empty.font = .systemFont(ofSize: 12); empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
        }
        document.layoutSubtreeIfNeeded()
    }

    private func addSection(_ title: String, _ choices: [AppChoice]) {
        guard !choices.isEmpty else { return }
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -3),
        ])
        stack.addArrangedSubview(wrap)
        wrap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for choice in choices {
            let btn = AppRow(choice: choice, target: self, action: #selector(pick(_:)))
            stack.addArrangedSubview(btn)
            btn.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc private func pick(_ sender: AppRow) { finish(sender.choice) }
    @objc private func cancel() { finish(nil) }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        guard let host = sheet else { return }
        panel.beginSheetModal(for: host) { [weak self] resp in
            guard let self else { return }
            guard resp == .OK, let url = panel.url, let choice = AppCatalog.choice(forURL: url) else { return }
            if self.excluded.contains(choice.bundleIdentifier) { self.finish(nil); return }
            self.finish(choice)
        }
    }

    private func finish(_ choice: AppChoice?) {
        if let sheet, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        sheet = nil
        completion(choice)
    }
}

private final class AppRow: NSButton {
    let choice: AppChoice
    init(choice: AppChoice, target: AnyObject?, action: Selector) {
        self.choice = choice
        super.init(frame: .zero)
        self.target = target; self.action = action
        title = "  " + choice.name
        image = choice.icon
        image?.size = NSSize(width: 22, height: 22)
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        alignment = .left
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        contentTintColor = .labelColor
        font = .systemFont(ofSize: 13)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 34).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
