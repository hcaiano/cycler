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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Cycler Settings"
        window.minSize = NSSize(width: 680, height: 460)
        window.collectionBehavior = [.moveToActiveSpace]
        window.isReleasedWhenClosed = false
        bindingsView = BindingsSettingsView(context: context)
        super.init()
        window.delegate = self
        window.contentView = bindingsView
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        bindingsView.reloadFromConfig()
        placeWindowIfNeeded()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKey()
    }

    func windowWillClose(_ notification: Notification) {
        bindingsView.stopRecording()
        bindingsView.closeTransientUI()
        NSApp.setActivationPolicy(.accessory)
    }

    private func placeWindowIfNeeded() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            if !window.isVisible { window.center() }
            return
        }
        let visible = screen.visibleFrame
        let frame = window.frame
        let isUsableFrame = frame.width >= window.minSize.width &&
            frame.height >= window.minSize.height &&
            visible.intersects(frame)
        guard !window.isVisible || !isUsableFrame else { return }

        let width = max(frame.width, window.minSize.width)
        let height = max(frame.height, window.minSize.height)
        let origin = NSPoint(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2)
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
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

    static func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
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
    private var pickerIndex: Int?

    private let titleLabel = NSTextField(labelWithString: "App Shortcuts")
    private let helpLabel = NSTextField(labelWithString:
        "Choose an app, record a shortcut, then save. Esc cancels recording; bare Delete clears a shortcut.")
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let rowStack = NSStackView()
    private let emptyView = EmptyBindingsView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "Add Binding", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(context: SettingsContext) {
        self.ctx = context
        drafts = context.config().bindings.map(BindingDraft.init(binding:))
        super.init(frame: .zero)
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
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.lineBreakMode = .byWordWrapping
        helpLabel.maximumNumberOfLines = 2

        addButton.target = self
        addButton.action = #selector(addBinding)
        addButton.bezelStyle = .rounded

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 10
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
        ])

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.onAdd = { [weak self] in self?.addBinding() }

        let headerStack = NSStackView(views: [titleLabel, helpLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let footerStack = NSStackView(views: [statusLabel, addButton, saveButton])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 12
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(headerStack)
        addSubview(scroll)
        addSubview(emptyView)
        addSubview(footerStack)

        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 24),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 18),
            scroll.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -16),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            emptyView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: scroll.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),

            footerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            footerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            footerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
    }

    private func rebuildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        rowStack.arrangedSubviews.forEach { view in
            rowStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        emptyView.isHidden = !drafts.isEmpty
        scroll.isHidden = drafts.isEmpty
        addButton.isHidden = drafts.isEmpty
        saveButton.isEnabled = true // allow saving an empty list so removing the last binding persists

        if drafts.isEmpty {
            statusLabel.stringValue = "No bindings configured."
            return
        }

        statusLabel.stringValue = "\(drafts.count) binding\(drafts.count == 1 ? "" : "s")"
        for (index, draft) in drafts.enumerated() {
            let row = BindingRowView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.configure(draft: draft)
            row.isRecording = index == recordingIndex
            row.onChooseApp = { [weak self, weak row] source in
                guard let row else { return }
                self?.chooseApp(for: index, relativeTo: source, in: row)
            }
            row.onRecord = { [weak self] in self?.toggleRecording(index) }
            row.onRemove = { [weak self] in self?.removeBinding(index) }
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
            rowViews.append(row)

            if pickerIndex == index {
                let openNow = AppChoices.openNow()
                let picker = AppPickerView(
                    openNow: openNow,
                    dockApps: AppChoices.inDock(excluding: Set(openNow.map(\.bundleIdentifier))),
                    onSelect: { [weak self] choice in
                        guard let self, self.drafts.indices.contains(index) else { return }
                        self.drafts[index].bundleIdentifier = choice.bundleIdentifier
                        self.drafts[index].appName = choice.name
                        self.pickerIndex = nil
                        self.rebuildRows()
                    },
                    onBrowse: { [weak self] in
                        guard let self else { return }
                        self.pickerIndex = nil
                        self.browseApp(for: index)
                    })
                picker.translatesAutoresizingMaskIntoConstraints = false
                rowStack.addArrangedSubview(picker)
                picker.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
            }
        }
        document.layoutSubtreeIfNeeded()
    }

    @objc private func addBinding() {
        stopRecording()
        drafts.append(BindingDraft())
        pickerIndex = drafts.count - 1
        rebuildRows()
        statusLabel.stringValue = "Choose an app and record a shortcut."
    }

    private func removeBinding(_ index: Int) {
        guard drafts.indices.contains(index) else { return }
        stopRecording()
        drafts.remove(at: index)
        pickerIndex = nil
        rebuildRows()
    }

    private func chooseApp(for index: Int, relativeTo source: NSView, in row: BindingRowView) {
        guard drafts.indices.contains(index) else { return }
        stopRecording()
        pickerIndex = (pickerIndex == index) ? nil : index
        rebuildRows()
        row.markPickerOpen()
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
        guard window?.isKeyWindow == true else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
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

    func closeTransientUI() {
        pickerIndex = nil
        rebuildRows()
    }

    /// Resync drafts from the current on-disk config. Called on every Settings open so a reused
    /// controller never shows stale drafts or overwrites edits made via Reload bindings / the JSON.
    func reloadFromConfig() {
        stopRecording()
        pickerIndex = nil
        drafts = ctx.config().bindings.map(BindingDraft.init(binding:))
        rebuildRows()
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
        if keyCode == kVK_Escape, bare {
            stopRecording()
            return true
        }
        if keyCode == kVK_Delete, bare {
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
            statusLabel.stringValue = "Saved to ~/.config/cycler/bindings.json"
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

private final class EmptyBindingsView: NSView {
    var onAdd: () -> Void = {}
    private let title = NSTextField(labelWithString: "No bindings yet")
    private let message = NSTextField(labelWithString: "Add an app shortcut to jump to an app, then press it again to cycle that app's windows.")
    private let addButton = NSButton(title: "Add Binding", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center
        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byWordWrapping
        addButton.target = self
        addButton.action = #selector(add)
        addButton.bezelStyle = .rounded

        let stack = NSStackView(views: [title, message, addButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    @objc private func add() { onAdd() }
}

private final class BindingRowView: NSView {
    var onChooseApp: (NSView) -> Void = { _ in }
    var onRecord: () -> Void = {}
    var onRemove: () -> Void = {}

    private let iconView = NSImageView()
    private let appButton = NSButton(title: "", target: nil, action: nil)
    private let bundleLabel = NSTextField(labelWithString: "")
    private let recorder = RecorderField()
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)

    var isRecording = false {
        didSet { recorder.isRecording = isRecording }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(draft: BindingDraft) {
        appButton.title = draft.appName.isEmpty ? "Choose App..." : draft.appName
        appButton.setAccessibilityTitle(appButton.title)
        appButton.setAccessibilityLabel(appButton.title)
        bundleLabel.stringValue = draft.bundleIdentifier ?? "No app selected"
        recorder.text = draft.shortcutText
        recorder.actionLabel = draft.appName.isEmpty ? "Binding" : draft.appName
        if let bundleIdentifier = draft.bundleIdentifier,
           let icon = AppDisplay.icon(forBundleIdentifier: bundleIdentifier) {
            iconView.image = icon
        } else {
            iconView.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        }
    }

    func markPickerOpen() {
        appButton.highlight(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.appButton.highlight(false) }
    }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        appButton.target = self
        appButton.action = #selector(chooseApp)
        appButton.bezelStyle = .rounded
        appButton.alignment = .left

        bundleLabel.font = .systemFont(ofSize: 11)
        bundleLabel.textColor = .secondaryLabelColor
        bundleLabel.lineBreakMode = .byTruncatingMiddle

        recorder.onClick = { [weak self] in self?.onRecord() }

        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.bezelStyle = .rounded
        removeButton.setAccessibilityTitle("Remove")
        removeButton.setAccessibilityLabel("Remove")

        let appTextStack = NSStackView(views: [appButton, bundleLabel])
        appTextStack.orientation = .vertical
        appTextStack.alignment = .leading
        appTextStack.spacing = 3

        let appStack = NSStackView(views: [iconView, appTextStack])
        appStack.orientation = .horizontal
        appStack.alignment = .centerY
        appStack.spacing = 10

        let stack = NSStackView(views: [appStack, recorder, removeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        appStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        recorder.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        removeButton.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            appTextStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            recorder.widthAnchor.constraint(equalToConstant: 190),
            recorder.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @objc private func chooseApp() { onChooseApp(appButton) }
    @objc private func remove() { onRemove() }
}

private final class AppPickerView: NSView, NSSearchFieldDelegate {
    private let openNow: [AppChoice]
    private let dockApps: [AppChoice]
    private let onSelect: (AppChoice) -> Void
    private let onBrowse: () -> Void

    private let searchField = NSSearchField()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()

    init(openNow: [AppChoice], dockApps: [AppChoice],
         onSelect: @escaping (AppChoice) -> Void, onBrowse: @escaping () -> Void) {
        self.openNow = openNow
        self.dockApps = dockApps
        self.onSelect = onSelect
        self.onBrowse = onBrowse
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        searchField.placeholderString = "Search suggested apps"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = document

        let browse = NSButton(title: "Browse...", target: self, action: #selector(browse))
        browse.bezelStyle = .rounded
        browse.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(scroll)
        addSubview(browse)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 260),

            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: browse.topAnchor, constant: -10),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),

            browse.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            browse.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        rebuild()
    }

    func controlTextDidChange(_ obj: Notification) {
        rebuild()
    }

    @objc private func searchChanged() {
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredOpenNow = filter(openNow, query: query)
        let filteredDockApps = filter(dockApps, query: query)

        addSection("Open now", choices: filteredOpenNow)
        addSection("In your Dock", choices: filteredDockApps)
        if filteredOpenNow.isEmpty && filteredDockApps.isEmpty {
            let empty = NSTextField(labelWithString: query.isEmpty ? "No suggested apps found." : "No matching apps.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
        }
        document.layoutSubtreeIfNeeded()
    }

    private func filter(_ choices: [AppChoice], query: String) -> [AppChoice] {
        guard !query.isEmpty else { return choices }
        return choices.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
                $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    private func addSection(_ title: String, choices: [AppChoice]) {
        guard !choices.isEmpty else { return }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)

        for choice in choices {
            let button = AppChoiceButton(choice: choice, target: self, action: #selector(select(_:)))
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = choice.name
        image = choice.icon
        imagePosition = .imageLeft
        imageScaling = .scaleProportionallyUpOrDown
        alignment = .left
        bezelStyle = .regularSquare
        isBordered = false
        setButtonType(.momentaryChange)
        toolTip = choice.bundleIdentifier
        setAccessibilityTitle(choice.name)
        setAccessibilityLabel(choice.name)
        setAccessibilityHelp(choice.bundleIdentifier)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
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
