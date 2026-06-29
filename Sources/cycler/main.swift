import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import CyclerCore
import Sparkle

private struct HotkeyCombo: Hashable {
    var keyCode: Int
    var modifiers: UInt32
}

private struct FailedHotkey {
    var label: String
    var keyCode: Int
    var modifiers: UInt32
    var status: OSStatus
    var generatedReverse: Bool
}

/// Minimal menu-bar agent: loads the per-app bindings, registers their global hotkeys, and on
/// each press jumps to the bound app / cycles its windows (see AppActivator).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var config = CyclerConfig()
    private var configLoadError = false
    private var failedHotkeys: [FailedHotkey] = []
    private var failedHotkeyRetryTimer: Timer?
    private var hotkeysSuspended = false
    private var lastTrusted = AXIsProcessTrusted()
    private var trustTimer: Timer?
    private var trustPollTicks = 0
    private var settingsWindowController: SettingsWindowController?
    private let hyperKeyController = HyperKeyController()
    private var hyperKeySignalSources: [DispatchSourceSignal] = []

    /// `~/.config/cycler/bindings.json` — the user's per-app hotkey bindings.
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cycler/bindings.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // agent at rest: no Dock icon until Settings opens.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
        _ = AppUpdater.shared  // start Sparkle's scheduled background update checks
        reloadConfig()
        registerHotkeys()
        applyHyperKeySettings()
        buildStatusItem()
        startAccessibilityWatch()
        installHyperKeySignalCleanup()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil)
    }

    // MARK: - Config

    private func reloadConfig() {
        configLoadError = false
        let url = AppDelegate.configURL
        guard let data = try? Data(contentsOf: url) else {
            config = CyclerConfig() // no file yet = no bindings; that's fine
            return
        }
        do {
            config = try CyclerConfig.decode(data).coalescingDuplicateShortcuts()
        } catch {
            // Malformed file: surface it, keep an empty config, do NOT overwrite the file.
            FileHandle.standardError.write(Data("bindings file could not be loaded (left untouched): \(error)\n".utf8))
            config = CyclerConfig()
            configLoadError = true
        }
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        guard !hotkeysSuspended else { return }

        var failed: [FailedHotkey] = []
        let explicitCombos = Set(config.bindings.map { HotkeyCombo(keyCode: $0.keyCode, modifiers: $0.modifiers) })
        for b in config.bindings {
            let binding = b
            let status = HotkeyManager.shared.register(keyCode: b.keyCode, modifiers: b.modifiers) {
                self.engage(binding, direction: .forward)
            }
            if status != noErr {
                failed.append(FailedHotkey(
                    label: bindingTitle(for: b.bundleIdentifiers),
                    keyCode: b.keyCode,
                    modifiers: b.modifiers,
                    status: status,
                    generatedReverse: false))
            }
        }
        for b in config.bindings {
            guard b.modifiers & UInt32(shiftKey) == 0 else { continue }
            let backwardModifiers = b.modifiers | UInt32(shiftKey)
            let combo = HotkeyCombo(keyCode: b.keyCode, modifiers: backwardModifiers)
            guard !explicitCombos.contains(combo) else { continue }

            let binding = b
            let status = HotkeyManager.shared.register(keyCode: b.keyCode, modifiers: backwardModifiers) {
                self.engage(binding, direction: .backward)
            }
            if status != noErr {
                failed.append(FailedHotkey(
                    label: bindingTitle(for: b.bundleIdentifiers),
                    keyCode: b.keyCode,
                    modifiers: backwardModifiers,
                    status: status,
                    generatedReverse: true))
            }
        }
        failedHotkeys = failed
        for failure in failedHotkeys {
            logHotkeyFailure(failure)
        }
        updateFailedHotkeyRetryTimer()
    }

    private func engage(_ binding: AppBinding, direction: WindowCycle.Direction) {
        if binding.isGroup {
            AppActivator.shared.engageGroup(bundleIdentifiers: binding.bundleIdentifiers, direction: direction)
        } else {
            AppActivator.shared.engage(bundleIdentifier: binding.bundleIdentifier, direction: direction)
        }
    }

    @objc private func retryHotkeys() {
        HotkeyManager.shared.unregisterAll()
        registerHotkeys()
        buildStatusItem()
    }

    @objc private func reloadBindings() {
        hotkeysSuspended = false
        HotkeyManager.shared.unregisterAll()
        reloadConfig()
        registerHotkeys()
        applyHyperKeySettings()
        buildStatusItem()
    }

    private func saveConfigAndReload(_ newConfig: CyclerConfig) throws {
        let url = AppDelegate.configURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // If the current file couldn't be parsed, Settings shows an empty draft list; preserve the
        // unreadable original to a .bak before overwriting so a hand-edit mistake isn't lost. The
        // backup is the only safety net here, so a failed backup must abort the save (throw) rather
        // than overwrite the unrecoverable original.
        if configLoadError, FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.copyItem(at: url, to: backup)
        }
        try newConfig.coalescingDuplicateShortcuts().encoded().write(to: url, options: .atomic)
        hotkeysSuspended = false
        reloadBindings()
    }

    private func setRecordingShortcut(_ recording: Bool) {
        hotkeysSuspended = recording
        if recording {
            failedHotkeyRetryTimer?.invalidate()
            failedHotkeyRetryTimer = nil
            HotkeyManager.shared.unregisterAll()
        } else {
            registerHotkeys()
        }
        buildStatusItem()
    }

    private func applyHyperKeySettings() {
        hyperKeyController.apply(config.hyperKey)
        if case .blocked(let message) = hyperKeyController.state {
            FileHandle.standardError.write(Data("Cycler HyperKey blocked: \(message)\n".utf8))
        }
    }

    private func installHyperKeySignalCleanup() {
        guard hyperKeySignalSources.isEmpty else { return }
        for signal in [SIGINT, SIGTERM, SIGHUP] {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
            source.setEventHandler { [weak self] in
                self?.hyperKeyController.stop()
                fflush(stderr)
                exit(128 + signal)
            }
            source.resume()
            hyperKeySignalSources.append(source)
        }
    }

    @objc private func systemDidWake() {
        applyHyperKeySettings()
        buildStatusItem()
    }

    private func updateFailedHotkeyRetryTimer() {
        guard !failedHotkeys.isEmpty, !hotkeysSuspended else {
            failedHotkeyRetryTimer?.invalidate()
            failedHotkeyRetryTimer = nil
            return
        }
        guard failedHotkeyRetryTimer == nil else { return }
        failedHotkeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.retryFailedHotkeys()
        }
    }

    private func retryFailedHotkeys() {
        guard !failedHotkeys.isEmpty, !hotkeysSuspended else {
            updateFailedHotkeyRetryTimer()
            return
        }
        HotkeyManager.shared.unregisterAll()
        registerHotkeys()
        buildStatusItem()
    }

    @objc private func applicationBecameActive() {
        retryFailedHotkeys()
    }

    private func logHotkeyFailure(_ failure: FailedHotkey) {
        let combo = ShortcutKit.display(keyCode: failure.keyCode, modifiers: failure.modifiers)
        let direction = failure.generatedReverse ? " reverse" : ""
        FileHandle.standardError.write(Data(
            "RegisterEventHotKey failed (\(failure.status)) for\(direction) \(failure.label) \(combo) key \(failure.keyCode)\n".utf8))
    }

    // MARK: - Accessibility watch

    /// macOS grants Accessibility while the app keeps running; refresh the menu live when the
    /// permission flips so the user never has to quit and reopen. Only poll when we launched
    /// UNTRUSTED (a returning, already-trusted user has nothing to wait for, and an unconditional
    /// poll would defeat App Nap). Revocation still arrives via the distributed notification.
    private func startAccessibilityWatch() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(accessibilityMaybeChanged),
            name: NSNotification.Name("com.apple.accessibility.api"), object: nil)
        guard !lastTrusted else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.accessibilityMaybeChanged()
            self.trustPollTicks += 1
            if self.trustTimer != nil, self.trustPollTicks >= 80 { // ~120s, then rely on the notification
                self.trustTimer?.invalidate(); self.trustTimer = nil
            }
        }
    }

    @objc private func accessibilityMaybeChanged() {
        let trusted = AXIsProcessTrusted()
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        buildStatusItem()
        if trusted { trustTimer?.invalidate(); trustTimer = nil }
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.image = Brand.menuBarLogo()
            statusItem.button?.toolTip = "Cycler — jump to an app, cycle its windows"
        }
        let menu = NSMenu()

        var hasWarning = false
        if !AXIsProcessTrusted() {
            addInfo(menu, "⚠︎ Accessibility not granted")
            menu.addItem(menuItem("Grant Accessibility…", #selector(openAccessibilitySettings), symbol: "lock.shield"))
            hasWarning = true
        }
        if !failedHotkeys.isEmpty {
            addInfo(menu, "⚠︎ \(failedHotkeys.count) shortcut\(failedHotkeys.count == 1 ? "" : "s") blocked")
            for failure in failedHotkeys.prefix(4) {
                addInfo(menu, "  \(blockedHotkeyTitle(failure))")
            }
            if failedHotkeys.count > 4 {
                addInfo(menu, "  …and \(failedHotkeys.count - 4) more")
            }
            menu.addItem(menuItem("Retry shortcuts", #selector(retryHotkeys), symbol: "arrow.clockwise"))
            hasWarning = true
        }
        if configLoadError {
            addInfo(menu, "⚠︎ bindings.json couldn't be loaded")
            hasWarning = true
        }
        if let status = hyperKeyController.menuStatus {
            addInfo(menu, status)
            hasWarning = true
        }
        if hasWarning { menu.addItem(.separator()) }

        if config.bindings.isEmpty {
            addInfo(menu, "No shortcuts yet")
        }
        menu.addItem(menuItem("Settings…", #selector(showSettings), symbol: "gearshape"))
        menu.addItem(menuItem("Reload bindings", #selector(reloadBindings), symbol: "arrow.clockwise"))

        menu.addItem(.separator())
        let loginItem = menuItem("Launch at login", #selector(toggleLaunchAtLogin), symbol: "power")
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        // Sparkle owns this item: it runs the check AND enables/disables the item via
        // canCheckForUpdates, so it targets the updater controller, not the app delegate.
        let updatesItem = menuItem("Check for Updates…",
                                   #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                   symbol: "arrow.down.circle")
        updatesItem.target = AppUpdater.shared
        menu.addItem(updatesItem)
        menu.addItem(menuItem("About Cycler", #selector(showAbout), symbol: "info.circle"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Cycler", #selector(quit), key: "q", symbol: "xmark.circle"))
        statusItem.menu = menu
    }

    /// A menu row with a consistent SF Symbol icon, so every action lines up the same way.
    private func menuItem(_ title: String, _ action: Selector, key: String = "", symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            item.image = img.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        return item
    }

    private func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func blockedHotkeyTitle(_ failure: FailedHotkey) -> String {
        let prefix = failure.generatedReverse ? "Reverse " : ""
        let combo = ShortcutKit.display(keyCode: failure.keyCode, modifiers: failure.modifiers)
        return "\(prefix)\(failure.label) \(combo) — \(hotkeyStatusDescription(failure.status))"
    }

    private func hotkeyStatusDescription(_ status: OSStatus) -> String {
        if status == -9878 { return "already in use" } // eventHotKeyExistsErr
        return "status \(status)"
    }

    private func appName(for bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
    }

    private func bindingTitle(for bundleIdentifiers: [String]) -> String {
        let names = bundleIdentifiers.map(appName)
        switch names.count {
        case 0:
            return "Empty group"
        case 1:
            return names[0]
        case 2, 3:
            return names.joined(separator: " + ")
        default:
            return "\(names[0]) + \(names[1]) + \(names.count - 2) more"
        }
    }

    @objc private func showAbout() { AboutWindowController.show() }

    @objc private func showSettings() {
        NSApp.setActivationPolicy(.regular)
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(context: SettingsContext(
                config: { [weak self] in self?.config ?? CyclerConfig() },
                saveConfig: { [weak self] newConfig in try self?.saveConfigAndReload(newConfig) },
                setRecording: { [weak self] recording in self?.setRecordingShortcut(recording) },
                hyperKeyStatus: { [weak self] in self?.hyperKeyController.settingsStatus }
            ))
        }
        DispatchQueue.main.async { [weak self] in
            self?.settingsWindowController?.show()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            FileHandle.standardError.write(Data("launch-at-login toggle failed: \(error)\n".utf8))
        }
        buildStatusItem()
    }

    /// Fire the system Accessibility prompt AND open the pane directly, so a user who declined
    /// once isn't stuck clicking a button that does nothing (the prompt no longer auto-appears
    /// after a decision is recorded).
    @objc private func openAccessibilitySettings() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hyperKeyController.stop()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
