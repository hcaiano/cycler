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

/// Minimal menu-bar agent: loads the per-app bindings, registers their global hotkeys, and on
/// each press jumps to the bound app / cycles its windows (see AppActivator).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var config = CyclerConfig()
    private var configLoadError = false
    private var failedHotkeys = 0
    private var lastTrusted = AXIsProcessTrusted()
    private var trustTimer: Timer?
    private var trustPollTicks = 0
    private var settingsWindowController: SettingsWindowController?

    /// `~/.config/cycler/bindings.json` — the user's per-app hotkey bindings.
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cycler/bindings.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // agent at rest: no Dock icon until Settings opens.
        _ = AppUpdater.shared  // start Sparkle's scheduled background update checks
        reloadConfig()
        registerHotkeys()
        buildStatusItem()
        startAccessibilityWatch()
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
            config = try CyclerConfig.decode(data)
        } catch {
            // Malformed file: surface it, keep an empty config, do NOT overwrite the file.
            FileHandle.standardError.write(Data("bindings file could not be loaded (left untouched): \(error)\n".utf8))
            config = CyclerConfig()
            configLoadError = true
        }
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        var failed = 0
        let explicitCombos = Set(config.bindings.map { HotkeyCombo(keyCode: $0.keyCode, modifiers: $0.modifiers) })
        for b in config.bindings {
            let bundleID = b.bundleIdentifier
            let ok = HotkeyManager.shared.register(keyCode: b.keyCode, modifiers: b.modifiers) {
                AppActivator.shared.engage(bundleIdentifier: bundleID)
            }
            if !ok { failed += 1 }
        }
        for b in config.bindings {
            guard b.modifiers & UInt32(shiftKey) == 0 else { continue }
            let backwardModifiers = b.modifiers | UInt32(shiftKey)
            let combo = HotkeyCombo(keyCode: b.keyCode, modifiers: backwardModifiers)
            guard !explicitCombos.contains(combo) else { continue }

            let bundleID = b.bundleIdentifier
            let ok = HotkeyManager.shared.register(keyCode: b.keyCode, modifiers: backwardModifiers) {
                AppActivator.shared.engage(bundleIdentifier: bundleID, direction: .backward)
            }
            if !ok { failed += 1 }
        }
        failedHotkeys = failed
    }

    @objc private func retryHotkeys() {
        HotkeyManager.shared.unregisterAll()
        registerHotkeys()
        buildStatusItem()
    }

    @objc private func reloadBindings() {
        HotkeyManager.shared.unregisterAll()
        reloadConfig()
        registerHotkeys()
        buildStatusItem()
    }

    private func saveConfigAndReload(_ newConfig: CyclerConfig) throws {
        let url = AppDelegate.configURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // If the current file couldn't be parsed, Settings shows an empty draft list; preserve the
        // unreadable original to a .bak before overwriting so a hand-edit mistake isn't lost.
        if configLoadError, FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        try newConfig.encoded().write(to: url, options: .atomic)
        reloadBindings()
    }

    private func setRecordingShortcut(_ recording: Bool) {
        if recording {
            HotkeyManager.shared.unregisterAll()
        } else {
            registerHotkeys()
        }
        buildStatusItem()
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
        if failedHotkeys > 0 {
            addInfo(menu, "⚠︎ \(failedHotkeys) shortcut\(failedHotkeys == 1 ? "" : "s") blocked by another app")
            menu.addItem(menuItem("Retry shortcuts", #selector(retryHotkeys), symbol: "arrow.clockwise"))
            hasWarning = true
        }
        if configLoadError {
            addInfo(menu, "⚠︎ bindings.json couldn't be loaded")
            hasWarning = true
        }
        if hasWarning { menu.addItem(.separator()) }

        if config.bindings.isEmpty {
            addInfo(menu, "No app shortcuts configured")
            addInfo(menu, "Use Settings or edit ~/.config/cycler/bindings.json")
        } else {
            addInfo(menu, "\(config.bindings.count) app shortcut\(config.bindings.count == 1 ? "" : "s") active")
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

    @objc private func showAbout() { AboutWindowController.show() }

    @objc private func showSettings() {
        NSApp.setActivationPolicy(.regular)
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(context: SettingsContext(
                config: { [weak self] in self?.config ?? CyclerConfig() },
                saveConfig: { [weak self] newConfig in try self?.saveConfigAndReload(newConfig) },
                setRecording: { [weak self] recording in self?.setRecordingShortcut(recording) }
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

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
