import AppKit
import ApplicationServices
import CyclerCore

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// The heart of Cycler: press a per-app hotkey to bring an app to the front; press it again to
/// walk that app's windows one at a time. Multi-app groups use the same app activation helpers,
/// but intentionally stay window-agnostic.
///
/// First press (app not already frontmost) = "go to this app": activate it and remember its main
/// standard window. Repeat press (app already frontmost) = advance through a stable CGWindowID
/// order via the pure `WindowCycle` order, wrapping around. Window focus comes from the
/// Accessibility API, so the app must be Accessibility-trusted (the menu surfaces this when it
/// isn't). A bound app that is not running yet is launched and activated on first press.
final class AppActivator {
    static let shared = AppActivator()

    /// Index of the window we focused last time, per bundle id, so a repeat press advances from
    /// where we left off if the system's main-window readback is momentarily stale.
    private var lastIndex: [String: Int] = [:]

    /// Bring `bundleIdentifier` forward, or cycle its windows if it's already frontmost.
    func engage(bundleIdentifier: String, direction: WindowCycle.Direction = .forward) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            Self.launch(bundleIdentifier: bundleIdentifier)
            lastIndex.removeValue(forKey: bundleIdentifier)
            return
        }

        guard AXIsProcessTrusted() else {
            FileHandle.standardError.write(Data("Cycler: Accessibility not granted; cannot cycle windows.\n".utf8))
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let windows = Self.windows(of: axApp)
        let alreadyFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier

        if !alreadyFront {
            // First press: go to the app. Show the current window position without advancing, so
            // the HUD appears consistently on the first engagement for multi-window apps.
            Self.activate(app)
            let focusedWindows = Self.windows(of: axApp)
            let visibleWindows = focusedWindows.isEmpty ? windows : focusedWindows
            let current = Self.indexOfMain(in: visibleWindows)
                ?? (visibleWindows.isEmpty ? nil : 0)
            if let current {
                Self.raise(visibleWindows[current].element)
                lastIndex[bundleIdentifier] = current
                Self.showWindowHUD(app, windows: visibleWindows, selectedIndex: current)
            }
            return
        }

        guard windows.count >= 2 else {
            // With nothing to cycle, repeat presses become a show/hide toggle.
            app.hide()
            lastIndex.removeValue(forKey: bundleIdentifier)
            return
        }

        // Repeat press: advance from whatever window is focused now (falling back to our last
        // remembered index), then raise the next one.
        let current = Self.indexOfMain(in: windows) ?? lastIndex[bundleIdentifier]
        guard let nextIdx = WindowCycle.next(count: windows.count, current: current, direction: direction) else { return }
        let targetWindow = windows[nextIdx].element
        Self.activate(app)
        Self.raise(targetWindow)
        lastIndex[bundleIdentifier] = nextIdx
        Self.showWindowHUD(app, windows: windows, selectedIndex: nextIdx)
    }

    /// Cycle between the running members of an app group. Groups deliberately do not inspect or
    /// cycle windows: a multi-app shortcut means "switch apps", while a single-app shortcut keeps
    /// the per-window behaviour above.
    func engageGroup(bundleIdentifiers: [String], direction: WindowCycle.Direction = .forward) {
        guard bundleIdentifiers.count > 1 else {
            if let bundleIdentifier = bundleIdentifiers.first {
                engage(bundleIdentifier: bundleIdentifier, direction: direction)
            }
            return
        }

        let running = Set(bundleIdentifiers.filter { id in
            !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        })
        let installed: Set<String> = running.isEmpty
            ? Set(bundleIdentifiers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
            : []
        let action = AppGroupCycle.next(
            group: bundleIdentifiers,
            installed: installed,
            running: running,
            frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            direction: direction)
        let display = AppGroupCycle.display(group: bundleIdentifiers, running: running, action: action)

        switch action {
        case .launch(let bundleIdentifier):
            Self.launch(bundleIdentifier: bundleIdentifier)
            Self.showGroupHUD(display)
        case .activate(let bundleIdentifier):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return }
            Self.activate(app)
            Self.showGroupHUD(display)
        case .hide(let bundleIdentifier):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return }
            app.hide()
        case .none:
            let label = bundleIdentifiers.joined(separator: ", ")
            FileHandle.standardError.write(Data(
                "Cycler: no installed apps found for group \(label).\n".utf8))
        }
    }

    private static func showGroupHUD(_ display: AppGroupCycle.Display) {
        guard let selectedIndex = display.selectedIndex else { return }
        CycleHUD.shared.showAppGroup(
            apps: display.rows.map { row in
                CycleHUD.AppGroupItem(
                    name: appName(for: row.bundleIdentifier),
                    icon: appIcon(for: row.bundleIdentifier),
                    isRunning: row.isRunning,
                    isSelected: row.isSelected)
            },
            selectedIndex: selectedIndex)
    }

    private static func showWindowHUD(_ app: NSRunningApplication, windows: [WindowRecord], selectedIndex: Int) {
        let items = windows.map { Self.windowItem(for: $0, app: app) }
        CycleHUD.shared.show(
            appIcon: app.icon,
            appName: app.localizedName ?? "",
            windows: items,
            selectedIndex: selectedIndex)
    }

    // MARK: - AX helpers

    private struct WindowRecord {
        var element: AXUIElement
        var windowID: CGWindowID
    }

    private static func windows(of axApp: AXUIElement) -> [WindowRecord] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
            .filter { isStandardWindow($0) && !isMinimized($0) }
            .compactMap { window in
                guard let windowID = windowID(of: window) else { return nil }
                return WindowRecord(element: window, windowID: windowID)
            }
            .sorted { lhs, rhs in lhs.windowID < rhs.windowID }
    }

    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String else { return false }
        return subrole == kAXStandardWindowSubrole as String
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
              let minimized = value as? Bool else { return false }
        return minimized
    }

    private static func windowID(of window: AXUIElement) -> CGWindowID? {
        var windowID = CGWindowID(0)
        guard _AXUIElementGetWindow(window, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    /// Index of the app's main window within the stable CGWindowID order, if any.
    private static func indexOfMain(in windows: [WindowRecord]) -> Int? {
        guard let mainWindowID = mainWindowID(in: windows) else { return nil }
        return windows.firstIndex { $0.windowID == mainWindowID }
    }

    private static func mainWindowID(in windows: [WindowRecord]) -> CGWindowID? {
        for win in windows {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(win.element, kAXMainAttribute as CFString, &value) == .success,
               let isMain = value as? Bool, isMain {
                return win.windowID
            }
        }
        return nil
    }

    private static func title(of window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String else { return "" }
        return title
    }

    private static func windowItem(for window: WindowRecord, app: NSRunningApplication) -> CycleHUD.WindowItem {
        let rawTitle = Self.title(of: window.element)
        guard WindowContext.supportsTrailingContext(bundleIdentifier: app.bundleIdentifier),
              let appName = app.localizedName else {
            return CycleHUD.WindowItem(title: rawTitle, context: nil)
        }
        let parsed = WindowContext.trailingContext(title: rawTitle, appName: appName)
        return CycleHUD.WindowItem(title: parsed.title, context: parsed.context)
    }

    /// Raise a window and make it the app's main/focused window.
    private static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func activate(_ app: NSRunningApplication) {
        // A hidden app must be un-hidden first — activate() alone leaves it hidden, which is why a
        // single-window app toggled off with hide() never came back.
        if app.isHidden { app.unhide() }
        app.activate(options: [.activateAllWindows])
    }

    private static func launch(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            FileHandle.standardError.write(Data("Cycler: no installed app found for \(bundleIdentifier).\n".utf8))
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                FileHandle.standardError.write(Data("Cycler: could not launch \(bundleIdentifier): \(error)\n".utf8))
            }
        }
    }

    private static func appName(for bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        if let bundle = Bundle(url: url) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = bundle.object(forInfoDictionaryKey: key) as? String, !name.isEmpty {
                    return name
                }
            }
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
    }

    private static func appIcon(for bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
