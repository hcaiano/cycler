import AppKit
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
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Cycler Settings"
        window.isReleasedWhenClosed = false
        bindingsView = BindingsSettingsView(context: context)
        super.init()
        window.delegate = self
        window.contentView = bindingsView
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        bindingsView.stopRecording()
    }
}

private struct BindingDraft {
    var bundleIdentifier: String?
    var appName: String
    var keyCode: Int?
    var modifiers: UInt32?

    init(binding: AppBinding) {
        bundleIdentifier = binding.bundleIdentifier
        appName = AppDisplay.name(forBundleIdentifier: binding.bundleIdentifier)
        keyCode = binding.keyCode
        modifiers = binding.modifiers
    }

    init() {
        bundleIdentifier = nil
        appName = ""
        keyCode = nil
        modifiers = nil
    }

    var shortcutText: String {
        guard let keyCode, let modifiers else { return "" }
        return ShortcutKit.display(keyCode: keyCode, modifiers: modifiers)
    }

    var isComplete: Bool {
        bundleIdentifier != nil && keyCode != nil && modifiers != nil
    }

    func binding() -> AppBinding? {
        guard let bundleIdentifier, let keyCode, let modifiers else { return nil }
        return AppBinding(keyCode: keyCode, modifiers: modifiers, bundleIdentifier: bundleIdentifier)
    }
}

private enum AppDisplay {
    static func name(forBundleIdentifier bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        return name(forAppURL: url) ?? bundleIdentifier
    }

    static func name(forAppURL url: URL) -> String? {
        if let bundle = Bundle(url: url) {
            if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !display.isEmpty {
                return display
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.isEmpty {
                return name
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

private struct AppChoice {
    var bundleIdentifier: String
    var name: String
    var url: URL
    var icon: NSImage
}

private enum AppChoices {
    static func openNow() -> [AppChoice] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(choice(for:))
        return dedup(apps).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func inDock(excluding excludedBundleIDs: Set<String>) -> [AppChoice] {
        let apps = dockAppURLs()
            .compactMap(choice(forAppURL:))
            .filter { !excludedBundleIDs.contains($0.bundleIdentifier) }
        return dedup(apps).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func choice(for app: NSRunningApplication) -> AppChoice? {
        guard let bundleIdentifier = app.bundleIdentifier,
              let url = app.bundleURL else { return nil }
        return AppChoice(
            bundleIdentifier: bundleIdentifier,
            name: AppDisplay.name(forAppURL: url) ?? app.localizedName ?? bundleIdentifier,
            url: url,
            icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    private static func choice(forAppURL url: URL) -> AppChoice? {
        guard let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else { return nil }
        return AppChoice(
            bundleIdentifier: bundleIdentifier,
            name: AppDisplay.name(forAppURL: url) ?? bundleIdentifier,
            url: url,
            icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    private static func dedup(_ choices: [AppChoice]) -> [AppChoice] {
        var seen = Set<String>()
        var result: [AppChoice] = []
        for choice in choices where !seen.contains(choice.bundleIdentifier) {
            seen.insert(choice.bundleIdentifier)
            result.append(choice)
        }
        return result
    }

    private static func dockAppURLs() -> [URL] {
        guard let apps = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") else {
            return []
        }
        return apps.compactMap { item in
            guard let dict = item as? [String: Any],
                  let tileData = dict["tile-data"] as? [String: Any],
                  let fileData = tileData["file-data"] as? [String: Any],
                  let raw = fileData["_CFURLString"] as? String,
                  let url = URL(string: raw),
                  url.isFileURL else { return nil }
            return url
        }
    }
}

private final class BindingsSettingsView: NSView {
    private let ctx: SettingsContext
    private var drafts: [BindingDraft]
    private var rowViews: [BindingRowView] = []
    private var recordingIndex: Int?
    private var monitor: Any?
    private var appPickerPopover: NSPopover?

    private let help = NSTextField(labelWithString:
        "Choose an app, record a shortcut, then save. Esc cancels recording; bare Delete clears a shortcut.")
    private let status = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let addButton = NSButton(title: "Add Binding", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(context: SettingsContext) {
        self.ctx = context
        drafts = context.config().bindings.map(BindingDraft.init(binding:))
        super.init(frame: NSRect(x: 0, y: 0, width: 680, height: 500))
        autoresizingMask = [.width, .height]
        build()
        rebuildRows()
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
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowLeft), name: name, object: w)
        }
    }

    private func build() {
        help.frame = NSRect(x: 20, y: 462, width: 640, height: 20)
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.lineBreakMode = .byTruncatingTail
        help.autoresizingMask = [.width, .minYMargin]
        addSubview(help)

        scroll.frame = NSRect(x: 14, y: 58, width: 652, height: 392)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        addSubview(scroll)

        status.frame = NSRect(x: 20, y: 20, width: 360, height: 20)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.autoresizingMask = [.width, .maxYMargin]
        addSubview(status)

        addButton.target = self
        addButton.action = #selector(addBinding)
        addButton.bezelStyle = .rounded
        addButton.frame = NSRect(x: 446, y: 16, width: 104, height: 30)
        addButton.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(addButton)

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 562, y: 16, width: 88, height: 30)
        saveButton.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(saveButton)
    }

    private func rebuildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()

        let rowHeight: CGFloat = 48
        let width = max(scroll.contentSize.width, 640)
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(rowHeight, CGFloat(drafts.count) * rowHeight))

        if drafts.isEmpty {
            status.stringValue = "No bindings yet."
        } else {
            status.stringValue = "\(drafts.count) binding\(drafts.count == 1 ? "" : "s")"
        }

        for (index, draft) in drafts.enumerated() {
            let row = BindingRowView(frame: NSRect(x: 0, y: CGFloat(index) * rowHeight, width: width, height: rowHeight))
            row.autoresizingMask = [.width]
            row.appTitle = draft.appName.isEmpty ? "Choose App..." : draft.appName
            row.bundleIdentifier = draft.bundleIdentifier ?? "No app selected"
            row.shortcutText = draft.shortcutText
            row.isRecording = index == recordingIndex
            row.removeButton.isEnabled = true
            row.onChooseApp = { [weak self] source in self?.chooseApp(for: index, relativeTo: source) }
            row.onRecord = { [weak self] in self?.toggleRecording(index) }
            row.onRemove = { [weak self] in self?.removeBinding(index) }
            document.addSubview(row)
            rowViews.append(row)
        }
        document.needsDisplay = true
    }

    @objc private func addBinding() {
        stopRecording()
        drafts.append(BindingDraft())
        rebuildRows()
        status.stringValue = "Choose an app and record a shortcut."
    }

    private func removeBinding(_ index: Int) {
        guard drafts.indices.contains(index) else { return }
        stopRecording()
        drafts.remove(at: index)
        rebuildRows()
    }

    private func chooseApp(for index: Int, relativeTo source: NSView) {
        guard drafts.indices.contains(index) else { return }
        stopRecording()
        appPickerPopover?.performClose(nil)

        let openNow = AppChoices.openNow()
        let dockApps = AppChoices.inDock(excluding: Set(openNow.map(\.bundleIdentifier)))
        let picker = AppPickerViewController(
            openNow: openNow,
            dockApps: dockApps,
            onSelect: { [weak self] choice in
                guard let self, self.drafts.indices.contains(index) else { return }
                self.appPickerPopover?.performClose(nil)
                self.drafts[index].bundleIdentifier = choice.bundleIdentifier
                self.drafts[index].appName = choice.name
                self.rebuildRows()
            },
            onBrowse: { [weak self] in
                guard let self else { return }
                self.appPickerPopover?.performClose(nil)
                self.browseApp(for: index)
            })
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.contentViewController = picker
        appPickerPopover = popover
        popover.show(relativeTo: source.bounds, of: source, preferredEdge: .maxY)
    }

    private func browseApp(for index: Int) {
        guard drafts.indices.contains(index) else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose App"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else {
            showAlert(message: "That app has no bundle identifier",
                      info: "Choose a normal macOS application bundle.")
            return
        }
        drafts[index].bundleIdentifier = bundleIdentifier
        drafts[index].appName = AppDisplay.name(forAppURL: url) ?? bundleIdentifier
        rebuildRows()
    }

    private func toggleRecording(_ index: Int) {
        guard drafts.indices.contains(index) else { return }
        if recordingIndex == index {
            stopRecording()
        } else {
            startRecording(index)
        }
    }

    private func startRecording(_ index: Int) {
        if recordingIndex != nil { stopRecording() }
        recordingIndex = index
        ctx.setRecording(true)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }
        rebuildRows()
        window?.makeFirstResponder(self)
    }

    @objc private func windowLeft() {
        stopRecording()
    }

    func stopRecording() {
        let wasRecording = recordingIndex != nil
        recordingIndex = nil
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        if wasRecording { ctx.setRecording(false) }
        rebuildRows()
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let index = recordingIndex, drafts.indices.contains(index) else { return false }
        let keyCode = Int(event.keyCode)
        let bare = !ShortcutKit.hasModifier(event.modifierFlags)
        if keyCode == 53, bare {
            stopRecording()
            return true
        }
        if keyCode == 51, bare {
            drafts[index].keyCode = nil
            drafts[index].modifiers = nil
            stopRecording()
            return true
        }
        guard ShortcutKit.hasModifier(event.modifierFlags) else {
            NSSound.beep()
            return true
        }

        let modifiers = ShortcutKit.carbonModifiers(from: event.modifierFlags)
        stopRecording()

        let conflicts = drafts.indices.filter { other in
            other != index &&
                drafts[other].keyCode == keyCode &&
                drafts[other].modifiers == modifiers
        }
        if !conflicts.isEmpty, !confirmConflict(conflicts) {
            return true
        }
        for conflict in conflicts {
            drafts[conflict].keyCode = nil
            drafts[conflict].modifiers = nil
        }
        drafts[index].keyCode = keyCode
        drafts[index].modifiers = modifiers
        rebuildRows()
        return true
    }

    private func confirmConflict(_ conflicts: [Int]) -> Bool {
        let names = conflicts.map { drafts[$0].appName.isEmpty ? "another row" : drafts[$0].appName }
        let alert = NSAlert()
        alert.messageText = "Shortcut already in use"
        alert.informativeText = "This combo is assigned to \(names.joined(separator: ", ")). Reassign it here?"
        alert.addButton(withTitle: "Reassign")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func save() {
        stopRecording()
        guard drafts.allSatisfy(\.isComplete) else {
            showAlert(message: "Finish each binding before saving",
                      info: "Every row needs both an app and a shortcut. Remove unused rows or complete them.")
            return
        }
        let config = CyclerConfig(bindings: drafts.compactMap { $0.binding() })
        do {
            try ctx.saveConfig(config)
            status.stringValue = "Saved to ~/.config/cycler/bindings.json"
        } catch {
            showAlert(message: "Bindings could not be saved", info: error.localizedDescription)
        }
    }

    private func showAlert(message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private final class BindingRowView: NSView {
    var onChooseApp: (NSView) -> Void = { _ in }
    var onRecord: () -> Void = {}
    var onRemove: () -> Void = {}

    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let appButton = NSButton(title: "", target: nil, action: nil)
    private let bundleLabel = NSTextField(labelWithString: "")
    private let recorder = RecorderField(frame: NSRect(x: 324, y: 9, width: 190, height: 30))

    var appTitle = "" {
        didSet { appButton.title = appTitle }
    }
    var bundleIdentifier = "" {
        didSet { bundleLabel.stringValue = bundleIdentifier }
    }
    var shortcutText = "" {
        didSet { recorder.text = shortcutText }
    }
    var isRecording = false {
        didSet { recorder.isRecording = isRecording }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        appButton.target = self
        appButton.action = #selector(chooseApp)
        appButton.bezelStyle = .rounded
        appButton.frame = NSRect(x: 12, y: 9, width: 190, height: 30)
        appButton.autoresizingMask = [.maxXMargin]
        addSubview(appButton)

        bundleLabel.frame = NSRect(x: 214, y: 15, width: 96, height: 18)
        bundleLabel.font = .systemFont(ofSize: 11)
        bundleLabel.textColor = .secondaryLabelColor
        bundleLabel.lineBreakMode = .byTruncatingMiddle
        bundleLabel.autoresizingMask = [.width]
        addSubview(bundleLabel)

        recorder.onClick = { [weak self] in self?.onRecord() }
        recorder.actionLabel = "Binding"
        recorder.autoresizingMask = [.minXMargin]
        addSubview(recorder)

        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.bezelStyle = .rounded
        removeButton.frame = NSRect(x: 530, y: 9, width: 82, height: 30)
        removeButton.autoresizingMask = [.minXMargin]
        addSubview(removeButton)
    }

    override func layout() {
        super.layout()
        let right = bounds.width - 12
        removeButton.frame.origin.x = right - removeButton.frame.width
        recorder.frame.origin.x = removeButton.frame.minX - 16 - recorder.frame.width
        bundleLabel.frame.size.width = max(80, recorder.frame.minX - bundleLabel.frame.minX - 14)
    }

    @objc private func chooseApp() { onChooseApp(appButton) }
    @objc private func remove() { onRemove() }
}

private final class AppPickerViewController: NSViewController {
    private let openNow: [AppChoice]
    private let dockApps: [AppChoice]
    private let onSelect: (AppChoice) -> Void
    private let onBrowse: () -> Void

    init(openNow: [AppChoice], dockApps: [AppChoice],
         onSelect: @escaping (AppChoice) -> Void, onBrowse: @escaping () -> Void) {
        self.openNow = openNow
        self.dockApps = dockApps
        self.onSelect = onSelect
        self.onBrowse = onBrowse
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 420))

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 48, width: 320, height: 372))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        addSection("Open now", choices: openNow, to: stack)
        addSection("In your Dock", choices: dockApps, to: stack)
        if openNow.isEmpty && dockApps.isEmpty {
            let empty = NSTextField(labelWithString: "No suggested apps found.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
        }

        let documentHeight = max(372, stack.fittingSize.height)
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 320, height: documentHeight))
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: documentHeight)
        stack.autoresizingMask = [.width, .height]
        document.addSubview(stack)
        scroll.documentView = document
        root.addSubview(scroll)

        let browse = NSButton(title: "Browse...", target: self, action: #selector(browse))
        browse.bezelStyle = .rounded
        browse.frame = NSRect(x: 208, y: 12, width: 96, height: 28)
        browse.autoresizingMask = [.minXMargin, .maxYMargin]
        root.addSubview(browse)

        view = root
    }

    private func addSection(_ title: String, choices: [AppChoice], to stack: NSStackView) {
        guard !choices.isEmpty else { return }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)

        for choice in choices {
            let button = AppChoiceButton(choice: choice, target: self, action: #selector(select(_:)))
            stack.addArrangedSubview(button)
        }
    }

    @objc private func select(_ sender: AppChoiceButton) {
        onSelect(sender.choice)
    }

    @objc private func browse() {
        onBrowse()
    }
}

private final class AppChoiceButton: NSButton {
    let choice: AppChoice

    init(choice: AppChoice, target: AnyObject?, action: Selector) {
        self.choice = choice
        super.init(frame: NSRect(x: 0, y: 0, width: 296, height: 34))
        self.target = target
        self.action = action
        title = choice.name
        image = choice.icon
        image?.size = NSSize(width: 24, height: 24)
        imagePosition = .imageLeft
        alignment = .left
        bezelStyle = .regularSquare
        isBordered = false
        setButtonType(.momentaryChange)
        toolTip = choice.bundleIdentifier
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class RecorderField: NSView {
    var onClick: () -> Void = {}
    var isRecording = false { didSet { needsDisplay = true } }
    var text = "" { didSet { needsDisplay = true } }
    var enabled = true { didSet { needsDisplay = true } }
    var actionLabel = ""

    override var isFlipped: Bool { true }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityEnabled() -> Bool { enabled }
    override func accessibilityLabel() -> String? {
        if isRecording { return "\(actionLabel) shortcut, recording, press a key combination" }
        return "\(actionLabel) shortcut, \(text.isEmpty ? "not set" : text)"
    }
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        onClick()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        (isRecording ? Brand.blue.withAlphaComponent(0.12) : NSColor.textBackgroundColor).setFill()
        path.fill()
        (isRecording ? Brand.blue : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let str: String
        let color: NSColor
        let weight: NSFont.Weight
        if isRecording {
            str = "Press keys..."
            color = Brand.blue
            weight = .regular
        } else if text.isEmpty {
            str = "Click to record"
            color = .secondaryLabelColor
            weight = .regular
        } else {
            str = text
            color = enabled ? .labelColor : .disabledControlTextColor
            weight = .medium
        }
        let s = NSAttributedString(string: str, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: weight),
            .foregroundColor: color,
        ])
        let sz = s.size()
        s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        if enabled { onClick() }
    }

    override func resetCursorRects() {
        if enabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
