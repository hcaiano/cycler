import AppKit
import ApplicationServices
import CyclerCore

/// The heart of Cycler: press a per-app hotkey to bring an app to the front; press it again to
/// walk that app's windows one at a time.
///
/// window. Repeat press (app already frontmost) = advance to the next standard, non-minimized
/// window via the pure `WindowCycle` order, wrapping around. Window order/focus come from the
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

        guard !windows.isEmpty else {
            // App with no AX windows (e.g. only a menu-bar presence): just activate it.
            Self.activate(app)
            return
        }

        if !alreadyFront {
            // First press: go to the app. Focus its current main window (don't advance).
            Self.activate(app)
            if let mainIdx = Self.indexOfMain(in: windows) { lastIndex[bundleIdentifier] = mainIdx }
            return
        }

        // Repeat press: advance from whatever window is focused now (falling back to our last
        // remembered index), then raise the next one.
        let current = Self.indexOfMain(in: windows) ?? lastIndex[bundleIdentifier]
        guard let nextIdx = WindowCycle.next(count: windows.count, current: current, direction: direction) else { return }
        Self.raise(windows[nextIdx])
        Self.activate(app)
        lastIndex[bundleIdentifier] = nextIdx
    }

    // MARK: - AX helpers

    private static func windows(of axApp: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.filter { isStandardWindow($0) && !isMinimized($0) }
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

    /// Index of the app's main window (the one AX marks `kAXMainAttribute`), if any.
    private static func indexOfMain(in windows: [AXUIElement]) -> Int? {
        for (i, win) in windows.enumerated() {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXMainAttribute as CFString, &value) == .success,
               let isMain = value as? Bool, isMain {
                return i
            }
        }
        return nil
    }

    /// Raise a window and make it the app's main/focused window.
    private static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func activate(_ app: NSRunningApplication) {
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
}
