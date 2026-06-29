import AppKit
import Carbon.HIToolbox
import CyclerCore
import SwiftUI
import UniformTypeIdentifiers

/// Hooks the Settings window needs from the app delegate.
struct SettingsContext {
    var config: () -> CyclerConfig
    var saveConfig: (CyclerConfig) throws -> Void
    var setRecording: (Bool) -> Void
    var hyperKeyStatus: () -> String?
}

// MARK: - Window controller (AppKit shell hosting a SwiftUI view)

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: SettingsModel

    init(context: SettingsContext) {
        model = SettingsModel(context: context)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Cycler"
        window.minSize = NSSize(width: 480, height: 420)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        super.init()
        window.delegate = self
        let host = NSHostingView(rootView: SettingsRootView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = host
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        if !window.isVisible { model.reload() }
        placeWindowIfNeeded()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKey()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
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

// MARK: - Model

final class SettingsModel: ObservableObject {
    struct AppEntry: Identifiable, Equatable {
        var bundleIdentifier: String
        var name: String
        var icon: NSImage?
        var installed: Bool
        var id: String { bundleIdentifier }
    }

    struct Row: Identifiable {
        let id = UUID()
        var apps: [AppEntry]
        var keyCode: Int?
        var modifiers: UInt32?

        var isGroup: Bool { apps.count > 1 }
        var missingCount: Int { apps.filter { !$0.installed }.count }
        var title: String {
            guard !apps.isEmpty else { return "Empty Shortcut" }
            if apps.count <= 2 { return apps.map(\.name).joined(separator: " + ") }
            return "\(apps[0].name) + \(apps[1].name) + \(apps.count - 2) more"
        }
        var detailText: String {
            if missingCount > 0 {
                return missingCount == 1 ? "1 app not installed" : "\(missingCount) apps not installed"
            }
            return isGroup ? "First app launches when none are running" : "Cycles windows"
        }
        var shortcutText: String {
            guard let keyCode, let modifiers else { return "" }
            return ShortcutKit.display(keyCode: keyCode, modifiers: modifiers)
        }
        var binding: AppBinding? {
            guard let keyCode, let modifiers, !apps.isEmpty else { return nil }
            return AppBinding(
                keyCode: keyCode,
                modifiers: modifiers,
                bundleIdentifiers: apps.map(\.bundleIdentifier))
        }
    }

    struct AlertItem: Identifiable { let id = UUID(); let title: String; let message: String }
    struct PickerRequest: Identifiable {
        let id = UUID()
        var targetRowID: UUID?
    }

    @Published var rows: [Row] = []
    @Published var recordingID: UUID?
    @Published var pickerRequest: PickerRequest?
    @Published var alert: AlertItem?
    @Published var hyperKey: HyperKeySettings = .disabled
    @Published var hyperKeyStatus: String?

    private let ctx: SettingsContext
    private var monitor: Any?

    init(context: SettingsContext) {
        ctx = context
        reload()
    }

    var boundIdentifiers: Set<String> {
        Set(rows.flatMap { row in row.apps.map(\.bundleIdentifier) })
    }

    func reload() {
        stopRecording()
        let config = ctx.config()
        rows = config.bindings.map { b in
            Row(apps: b.bundleIdentifiers.map(Self.appEntry),
                keyCode: b.keyCode, modifiers: b.modifiers)
        }
        hyperKey = config.hyperKey
        hyperKeyStatus = ctx.hyperKeyStatus()
    }

    func showAddShortcutPicker() {
        stopRecording()
        pickerRequest = PickerRequest(targetRowID: nil)
    }

    func showAddAppPicker(for row: Row) {
        stopRecording()
        pickerRequest = PickerRequest(targetRowID: row.id)
    }

    func finishPicking(_ choice: AppChoice?, request: PickerRequest) {
        guard let choice else { return }
        if let rowID = request.targetRowID {
            add(choice, to: rowID)
        } else {
            addShortcut(choice)
        }
    }

    func addShortcut(_ choice: AppChoice) {
        let row = Row(apps: [Self.appEntry(for: choice)])
        rows.append(row)
        // Drop straight into recording the new row's shortcut.
        DispatchQueue.main.async { [weak self] in self?.startRecording(row.id) }
    }

    func add(_ choice: AppChoice, to rowID: UUID) {
        guard let idx = rows.firstIndex(where: { $0.id == rowID }),
              !boundIdentifiers.contains(choice.bundleIdentifier) else { return }
        rows[idx].apps.append(Self.appEntry(for: choice))
        apply()
    }

    func remove(_ row: Row) {
        stopRecording()
        rows.removeAll { $0.id == row.id }
        apply()
    }

    func remove(_ app: AppEntry, from row: Row) {
        guard let rowIdx = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[rowIdx].apps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        if rows[rowIdx].apps.isEmpty {
            rows.remove(at: rowIdx)
        }
        apply()
    }

    func move(_ app: AppEntry, in row: Row, by offset: Int) {
        guard let rowIdx = rows.firstIndex(where: { $0.id == row.id }),
              let appIdx = rows[rowIdx].apps.firstIndex(of: app) else { return }
        let maxIdx = rows[rowIdx].apps.count - 1
        let newIdx = min(max(appIdx + offset, 0), maxIdx)
        guard newIdx != appIdx else { return }
        let moved = rows[rowIdx].apps.remove(at: appIdx)
        rows[rowIdx].apps.insert(moved, at: newIdx)
        apply()
    }

    func toggleRecording(_ id: UUID) {
        if recordingID == id { stopRecording() } else { startRecording(id) }
    }

    func setHyperKeyEnabled(_ enabled: Bool) {
        hyperKey.enabled = enabled
        apply()
    }

    func setHyperKeyTrigger(_ trigger: TriggerKey) {
        hyperKey.triggerKey = trigger
        apply()
    }

    func setHyperKeyIncludeShift(_ includeShift: Bool) {
        hyperKey.includeShift = includeShift
        apply()
    }

    func startRecording(_ id: UUID) {
        guard rows.contains(where: { $0.id == id }) else { return }
        if recordingID != nil { stopRecording() }
        recordingID = id
        ctx.setRecording(true)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                (self?.handle(event) ?? false) ? nil : event
            }
        }
    }

    func stopRecording() {
        let was = recordingID != nil
        recordingID = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if was { ctx.setRecording(false) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let id = recordingID, let idx = rows.firstIndex(where: { $0.id == id }) else { return false }
        let keyCode = Int(event.keyCode)
        let bare = !ShortcutKit.hasModifier(event.modifierFlags)
        if keyCode == kVK_Escape, bare { stopRecording(); return true }
        if keyCode == kVK_Delete, bare {
            rows[idx].keyCode = nil; rows[idx].modifiers = nil
            stopRecording(); apply(); return true
        }
        guard ShortcutKit.hasModifier(event.modifierFlags) else { NSSound.beep(); return true }

        let mods = ShortcutKit.carbonModifiers(from: event.modifierFlags)
        if let other = rows.firstIndex(where: { $0.id != id && $0.keyCode == keyCode && $0.modifiers == mods }) {
            let targetID = rows[other].id
            stopRecording()
            merge(rowID: id, into: targetID)
            return true
        }
        rows[idx].keyCode = keyCode
        rows[idx].modifiers = mods
        stopRecording(); apply()
        return true
    }

    /// Persist only complete rows (app + shortcut) and live-reload hotkeys; native apps apply
    /// immediately, and an incomplete row stays visible until its shortcut is recorded.
    private func apply() {
        let config = CyclerConfig(bindings: rows.compactMap(\.binding), hyperKey: hyperKey)
            .coalescingDuplicateShortcuts()
        do {
            try ctx.saveConfig(config)
            hyperKeyStatus = ctx.hyperKeyStatus()
        }
        catch { alert = AlertItem(title: "Couldn’t save your shortcuts.", message: error.localizedDescription) }
    }

    private func merge(rowID sourceID: UUID, into targetID: UUID) {
        guard sourceID != targetID,
              let sourceIdx = rows.firstIndex(where: { $0.id == sourceID }),
              let targetIdx = rows.firstIndex(where: { $0.id == targetID }) else { return }

        var seen = Set(rows[targetIdx].apps.map(\.bundleIdentifier))
        for app in rows[sourceIdx].apps where !seen.contains(app.bundleIdentifier) {
            rows[targetIdx].apps.append(app)
            seen.insert(app.bundleIdentifier)
        }
        rows.removeAll { $0.id == sourceID }
        apply()
    }

    private static func appEntry(_ bundleIdentifier: String) -> AppEntry {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        return AppEntry(bundleIdentifier: bundleIdentifier,
                        name: AppInfo.name(forBundleIdentifier: bundleIdentifier),
                        icon: AppInfo.icon(forBundleIdentifier: bundleIdentifier),
                        installed: installed)
    }

    private static func appEntry(for choice: AppChoice) -> AppEntry {
        AppEntry(bundleIdentifier: choice.bundleIdentifier, name: choice.name, icon: choice.icon, installed: true)
    }
}

// MARK: - Root view

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            ShortcutsTab(model: model)
                .tabItem { Label("Shortcuts", systemImage: "command") }
            HyperKeyTab(model: model)
                .tabItem { Label("Hyper Key", systemImage: "capslock") }
        }
        .frame(minWidth: 480, minHeight: 420)
        .sheet(item: $model.pickerRequest) { request in
            AppPickerView(excluding: model.boundIdentifiers) { choice in
                model.finishPicking(choice, request: request)
            }
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }
}

/// The primary page: the list of app shortcuts. Hyper Key lives on its own tab so this stays
/// focused on the one thing most users come here to do.
private struct ShortcutsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shortcuts").font(.system(size: 22, weight: .bold))
                Text("Use one app to cycle windows, or add multiple apps to cycle between them.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
            Divider()

            if model.rows.isEmpty {
                EmptyStateView { model.showAddShortcutPicker() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.rows) { row in
                        BindingRowView(row: row, model: model)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()
            HStack {
                Button { model.showAddShortcutPicker() } label: {
                    Label("Add Shortcut", systemImage: "plus")
                }
                .controlSize(.large)
                Spacer()
            }
            .padding(16)
        }
    }
}

/// Secondary, rarely-touched settings: the optional built-in Hyper Key. A grouped Form is the
/// native macOS-settings shape and keeps this off the primary Shortcuts page.
private struct HyperKeyTab: View {
    @ObservedObject var model: SettingsModel

    private var enabled: Binding<Bool> {
        Binding(get: { model.hyperKey.enabled }, set: { model.setHyperKeyEnabled($0) })
    }

    private var trigger: Binding<TriggerKey> {
        Binding(get: { model.hyperKey.triggerKey }, set: { model.setHyperKeyTrigger($0) })
    }

    private var includeShift: Binding<Bool> {
        Binding(get: { model.hyperKey.includeShift }, set: { model.setHyperKeyIncludeShift($0) })
    }

    private var shortcutHint: String {
        model.hyperKey.includeShift ? "Records shortcuts as ⌃⌥⇧⌘." : "Records shortcuts as ⌃⌥⌘."
    }

    private var blockedStatus: String? {
        guard let status = model.hyperKeyStatus, status.hasPrefix("Blocked") else { return nil }
        return status
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Hyper Key", isOn: enabled)
            } footer: {
                Text("Turns one key into a system-wide Hyper modifier, so you don't need Karabiner or Raycast. Off by default.")
            }

            if model.hyperKey.enabled {
                Section {
                    Picker("Trigger key", selection: trigger) {
                        ForEach(TriggerKey.allCases, id: \.self) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    Toggle("Include Shift (⇧)", isOn: includeShift)
                        .help("Adds ⇧ so Hyper is ⌃⌥⇧⌘.")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shortcutHint)
                        if model.hyperKey.triggerKey == .capsLock {
                            Text("Caps Lock is remapped while Cycler runs and restored when you switch keys or quit.")
                        }
                    }
                }

                if let blockedStatus {
                    Section {
                        Label(blockedStatus, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct BindingRowView: View {
    let row: SettingsModel.Row
    @ObservedObject var model: SettingsModel

    private var isRecording: Bool { model.recordingID == row.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                AppIconStack(apps: row.apps)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(row.detailText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                ShortcutField(text: row.shortcutText, isRecording: isRecording) {
                    model.toggleRecording(row.id)
                }
                Button {
                    model.showAddAppPicker(for: row)
                } label: {
                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Add app to this shortcut")
                .accessibilityLabel("Add app to \(row.title)")
                Button {
                    model.remove(row)
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
                .accessibilityLabel("Remove shortcut for \(row.title)")
            }

            if row.isGroup {
                GroupAppList(row: row, model: model)
                    .padding(.leading, 38)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct AppIconStack: View {
    let apps: [SettingsModel.AppEntry]

    var body: some View {
        let visibleApps = apps.count > 3 ? Array(apps.prefix(2)) : Array(apps.prefix(3))
        HStack(spacing: -6) {
            ForEach(visibleApps) { app in
                Image(nsImage: app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
                    .resizable()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
            if apps.count > 3 {
                Text("+\(apps.count - visibleApps.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .frame(width: 66, alignment: .leading)
    }
}

private struct GroupAppList: View {
    let row: SettingsModel.Row
    @ObservedObject var model: SettingsModel
    @State private var draggingID: String?

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(row.apps.enumerated()), id: \.element.id) { idx, app in
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Drag to reorder")
                    Text("\(idx + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .trailing)
                    Image(nsImage: app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
                        .resizable().frame(width: 18, height: 18)
                    Text(app.name).font(.caption).lineLimit(1)
                    if idx == 0 {
                        Label("Primary", systemImage: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Launches first when none of the group apps are running")
                    }
                    if !app.installed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("App not installed")
                    }
                    Spacer(minLength: 8)
                    Button {
                        model.move(app, in: row, by: -1)
                    } label: {
                        Image(systemName: "chevron.up").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(idx == 0)
                    .help("Move up")
                    .accessibilityLabel("Move \(app.name) up")
                    Button {
                        model.move(app, in: row, by: 1)
                    } label: {
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(idx == row.apps.count - 1)
                    .help("Move down")
                    .accessibilityLabel("Move \(app.name) down")
                    Button {
                        model.remove(app, from: row)
                    } label: {
                        Image(systemName: "minus.circle").font(.caption).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove app from group")
                    .accessibilityLabel("Remove \(app.name) from group")
                }
                .padding(.vertical, 2)
                .opacity(app.installed ? 1 : 0.55)
                .background(draggingID == app.bundleIdentifier ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        draggingID = app.bundleIdentifier
                    }
                    .onEnded { value in
                        let rowHeight: CGFloat = 26
                        let offset = Int((value.translation.height / rowHeight).rounded())
                        if offset != 0 {
                            model.move(app, in: row, by: offset)
                        }
                        draggingID = nil
                    })
                .accessibilityAction(named: "Move Up") {
                    model.move(app, in: row, by: -1)
                }
                .accessibilityAction(named: "Move Down") {
                    model.move(app, in: row, by: 1)
                }
                .onDisappear {
                    if draggingID == app.bundleIdentifier {
                        draggingID = nil
                    }
                }
                .help("Drag to reorder")
            }
        }
    }
}

/// A native-styled button that shows the recorded shortcut and toggles recording.
private struct ShortcutField: View {
    let text: String
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: text.isEmpty ? .regular : .semibold))
                .foregroundStyle(color)
                .frame(width: 150)
                .padding(.vertical, 5)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(isRecording ? Color(Brand.accent) : nil)
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return text.isEmpty ? "Record Shortcut" : text
    }
    private var color: Color {
        if isRecording { return Color(Brand.accent) }
        return text.isEmpty ? .secondary : .primary
    }
}

private struct EmptyStateView: View {
    let onAdd: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "command").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("No shortcuts yet").font(.system(size: 17, weight: .semibold))
            Text("Add one app to cycle its windows, or add multiple apps to cycle between them.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            Button(action: onAdd) { Label("Add Shortcut", systemImage: "plus") }
                .controlSize(.large).padding(.top, 4)
        }
        .padding(40)
    }
}

// MARK: - App picker sheet

struct AppPickerView: View {
    let excluding: Set<String>
    let onPick: (AppChoice?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let openNow: [AppChoice]
    private let dock: [AppChoice]

    init(excluding: Set<String>, onPick: @escaping (AppChoice?) -> Void) {
        self.excluding = excluding
        self.onPick = onPick
        let open = AppCatalog.openNow().filter { !excluding.contains($0.bundleIdentifier) }
        let openIDs = Set(open.map(\.bundleIdentifier))
        openNow = open
        dock = AppCatalog.inDock().filter { !excluding.contains($0.bundleIdentifier) && !openIDs.contains($0.bundleIdentifier) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose an App").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 16)

            List {
                section("Open Now", filtered(openNow))
                section("In Your Dock", filtered(dock))
                if filtered(openNow).isEmpty && filtered(dock).isEmpty {
                    Text(query.isEmpty ? "No apps available." : "No matches.")
                        .foregroundStyle(.secondary).font(.callout)
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Button("Cancel") { onPick(nil); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Browse…") { browse() }
            }
            .padding(12)
        }
        .frame(width: 380, height: 480)
    }

    private func filtered(_ apps: [AppChoice]) -> [AppChoice] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder private func section(_ title: String, _ apps: [AppChoice]) -> some View {
        if !apps.isEmpty {
            Section(title) {
                ForEach(apps) { app in
                    Button { onPick(app); dismiss() } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                            Text(app.name)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url, let choice = AppCatalog.choice(forURL: url) else { return }
        if excluding.contains(choice.bundleIdentifier) { onPick(nil) } else { onPick(choice) }
        dismiss()
    }
}

// MARK: - App lookup

struct AppChoice: Identifiable {
    var bundleIdentifier: String
    var name: String
    var icon: NSImage
    var id: String { bundleIdentifier }
}

enum AppInfo {
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

enum AppCatalog {
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
