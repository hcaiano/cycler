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
    struct Row: Identifiable {
        let id = UUID()
        var bundleIdentifier: String
        var name: String
        var icon: NSImage?
        var keyCode: Int?
        var modifiers: UInt32?

        var shortcutText: String {
            guard let keyCode, let modifiers else { return "" }
            return ShortcutKit.display(keyCode: keyCode, modifiers: modifiers)
        }
        var binding: AppBinding? {
            guard let keyCode, let modifiers else { return nil }
            return AppBinding(keyCode: keyCode, modifiers: modifiers, bundleIdentifier: bundleIdentifier)
        }
    }

    struct AlertItem: Identifiable { let id = UUID(); let title: String; let message: String }

    @Published var rows: [Row] = []
    @Published var recordingID: UUID?
    @Published var showPicker = false
    @Published var alert: AlertItem?

    private let ctx: SettingsContext
    private var monitor: Any?

    init(context: SettingsContext) {
        ctx = context
        reload()
    }

    var boundIdentifiers: Set<String> { Set(rows.map(\.bundleIdentifier)) }

    func reload() {
        stopRecording()
        rows = ctx.config().bindings.map { b in
            Row(bundleIdentifier: b.bundleIdentifier,
                name: AppInfo.name(forBundleIdentifier: b.bundleIdentifier),
                icon: AppInfo.icon(forBundleIdentifier: b.bundleIdentifier),
                keyCode: b.keyCode, modifiers: b.modifiers)
        }
    }

    func add(_ choice: AppChoice) {
        let row = Row(bundleIdentifier: choice.bundleIdentifier, name: choice.name, icon: choice.icon)
        rows.append(row)
        // Drop straight into recording the new row's shortcut.
        DispatchQueue.main.async { [weak self] in self?.startRecording(row.id) }
    }

    func remove(_ row: Row) {
        stopRecording()
        rows.removeAll { $0.id == row.id }
        apply()
    }

    func toggleRecording(_ id: UUID) {
        if recordingID == id { stopRecording() } else { startRecording(id) }
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
            stopRecording(); NSSound.beep()
            alert = AlertItem(title: "That shortcut is taken.",
                message: "\(ShortcutKit.display(keyCode: keyCode, modifiers: mods)) is already used by \(rows[other].name). Pick a different one.")
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
        let config = CyclerConfig(bindings: rows.compactMap(\.binding))
        do { try ctx.saveConfig(config) }
        catch { alert = AlertItem(title: "Couldn’t save your shortcuts.", message: error.localizedDescription) }
    }
}

// MARK: - Root view

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shortcuts").font(.system(size: 22, weight: .bold))
                Text("Press a shortcut to jump to its app. Press it again to step through that app’s windows.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)

            if model.rows.isEmpty {
                EmptyStateView { model.showPicker = true }
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
                Button { model.showPicker = true } label: {
                    Label("Add Shortcut", systemImage: "plus")
                }
                .controlSize(.large)
                Spacer()
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 420)
        .sheet(isPresented: $model.showPicker) {
            AppPickerView(excluding: model.boundIdentifiers) { choice in
                if let choice { model.add(choice) }
            }
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }
}

private struct BindingRowView: View {
    let row: SettingsModel.Row
    @ObservedObject var model: SettingsModel

    private var isRecording: Bool { model.recordingID == row.id }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: row.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
                .resizable().frame(width: 26, height: 26)
            Text(row.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
            Spacer(minLength: 12)
            ShortcutField(text: row.shortcutText, isRecording: isRecording) {
                model.toggleRecording(row.id)
            }
            Button {
                model.remove(row)
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .accessibilityLabel("Remove shortcut for \(row.name)")
        }
        .padding(.vertical, 6)
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
            Text("Add a shortcut for an app to jump to it, then press it again to cycle that app’s windows.")
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
