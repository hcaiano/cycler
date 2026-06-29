import CoreGraphics
import CyclerCore
import Foundation

final class HyperKeyController {
    enum State: Equatable {
        case disabled
        case active
        case blocked(String)
    }

    private static let capsLockHID: UInt64 = 0x700000039
    private static let f18HID: UInt64 = 0x70000006D
    private static let capsLockKeyCode = 57
    private static let ownsCapsLockMappingKey = "CyclerOwnsCapsLockToF18Mapping"
    private static let inputMonitoringBlockedMessage = "Input Monitoring permission required"
    private static var clearOnExit = false
    private static var installedAtexit = false

    /// The keycode the event tap watches for each trigger. Caps Lock is remapped to F18 via
    /// `hidutil`, so it shares F18's keycode; the function keys report their own.
    private static func watchKeyCode(for trigger: TriggerKey) -> Int64 {
        switch trigger {
        case .capsLock, .f18: return 79 // kVK_F18 (Caps Lock arrives here after the hidutil remap)
        case .f19: return 80 // kVK_F19
        case .f20: return 90 // kVK_F20
        }
    }

    private(set) var state: State = .disabled
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var triggerDown = false
    private var didApplyMapping = false
    private var includeShift = true
    private var activeTrigger: TriggerKey?
    private var triggerKeyCode: Int64 = 79

    var menuStatus: String? {
        switch state {
        case .disabled:
            return nil
        case .active:
            return "Hyper Key active"
        case .blocked(let message):
            return "⚠︎ Hyper Key blocked: \(message)"
        }
    }

    var settingsStatus: String? {
        switch state {
        case .disabled:
            return nil
        case .active:
            return "Active"
        case .blocked(let message):
            return "Blocked: \(message)"
        }
    }

    var needsInputMonitoring: Bool {
        state == .blocked(Self.inputMonitoringBlockedMessage)
    }

    func apply(_ settings: HyperKeySettings) {
        guard settings.enabled else {
            stop()
            _ = Self.clearKnownOwnedMapping()
            state = .disabled
            return
        }

        // Raycast only matters when Cycler also wants Caps Lock — F18/F19/F20 never collide with it.
        if settings.triggerKey.needsCapsLockRemap, Self.raycastCapsHyperEnabled() {
            stop()
            _ = Self.clearKnownOwnedMapping()
            state = .blocked("Raycast is using Caps Lock")
            return
        }

        // A function-key trigger never uses hidutil; clear only a Caps Lock remap that Cycler knows
        // it created in this or a previous crashed run. A user-owned CapsLock->F18 mapping has the
        // same shape, so shape alone must not be treated as ownership.
        if !settings.triggerKey.needsCapsLockRemap {
            _ = Self.clearKnownOwnedMapping()
        }

        switch start(trigger: settings.triggerKey, includeShift: settings.includeShift) {
        case .started:
            state = .active
        case .blocked(let message):
            state = .blocked(message)
        }
    }

    private enum StartResult {
        case started
        case blocked(String)
    }

    private func start(trigger: TriggerKey, includeShift: Bool) -> StartResult {
        // A live tap bound to a different trigger must be torn down so we re-apply the right mapping
        // and watch the right keycode; same-trigger reconfig only needs the live includeShift update.
        if tap != nil, activeTrigger != trigger {
            stop()
        }
        if tap != nil {
            self.includeShift = includeShift
            return .started
        }
        self.includeShift = includeShift

        guard Self.ensureListenEventAccess() else {
            return .blocked(Self.inputMonitoringBlockedMessage)
        }

        if trigger.needsCapsLockRemap {
            let mapping = Self.currentMapping()
            let mappingIsOurs = Self.isMappingOurs(mapping)
            guard Self.isMappingEmpty(mapping) || mappingIsOurs else {
                return .blocked("existing hidutil UserKeyMapping is not Cycler's CapsLock->F18 mapping")
            }
            var createdMapping = false
            if !mappingIsOurs {
                guard Self.applyCapsLockToF18() else {
                    return .blocked("hidutil failed to apply CapsLock->F18")
                }
                createdMapping = true
            }
            if createdMapping || Self.ownsCapsLockMapping {
                didApplyMapping = true
                if createdMapping {
                    Self.setOwnsCapsLockMapping(true)
                }
                Self.clearOnExit = true
                Self.installAtexit()
            }
        }

        triggerKeyCode = Self.watchKeyCode(for: trigger)

        let mask: CGEventMask = (
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)
        )
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hyperKeyControllerTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            stop()
            return .blocked("CGEvent.tapCreate failed")
        }

        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        if let source {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: created, enable: true)
        activeTrigger = trigger
        return .started
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        source = nil
        triggerDown = false
        activeTrigger = nil

        if didApplyMapping {
            _ = Self.clearKnownOwnedMapping()
            didApplyMapping = false
            Self.clearOnExit = false
        }
        if state != .disabled {
            state = .disabled
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown, keyCode == triggerKeyCode {
            triggerDown = true
            return nil
        }
        if type == .keyUp, keyCode == triggerKeyCode {
            triggerDown = false
            return nil
        }

        if triggerDown && (type == .keyDown || type == .keyUp || type == .flagsChanged) {
            event.flags = CGEventFlags(rawValue: event.flags.rawValue | hyperFlags.rawValue)
            return Unmanaged.passUnretained(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private var hyperFlags: CGEventFlags {
        var raw = CGEventFlags.maskCommand.rawValue |
            CGEventFlags.maskControl.rawValue |
            CGEventFlags.maskAlternate.rawValue
        if includeShift {
            raw |= CGEventFlags.maskShift.rawValue
        }
        return CGEventFlags(rawValue: raw)
    }

    private static func ensureListenEventAccess() -> Bool {
        if CGPreflightListenEventAccess() { return true }
        return CGRequestListenEventAccess()
    }

    private static func currentMapping() -> String {
        runHidutil(arguments: ["property", "--get", "UserKeyMapping"]).output
    }

    private static func isMappingEmpty(_ output: String) -> Bool {
        let compact = output.filter { !$0.isWhitespace }.lowercased()
        return compact == "()" || compact == "(null)" || compact == "null"
    }

    private static func isMappingOurs(_ output: String) -> Bool {
        // `hidutil property --get` prints a CoreFoundation description whose key quoting/spacing
        // isn't guaranteed (e.g. `"HIDKeyboardModifierMappingSrc" = N` vs `Src = N`). Match on the
        // structure (exactly one Src/Dst pair) plus our two specific HID usage values, so we recognise
        // and can therefore always clear our own CapsLock->F18 mapping regardless of formatting.
        // Failing to recognise it would leave Caps Lock remapped with no cleanup path.
        output.components(separatedBy: "HIDKeyboardModifierMappingSrc").count == 2
            && output.components(separatedBy: "HIDKeyboardModifierMappingDst").count == 2
            && output.contains("\(capsLockHID)")
            && output.contains("\(f18HID)")
    }

    private static func applyCapsLockToF18() -> Bool {
        let json = """
        {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\(capsLockHID),"HIDKeyboardModifierMappingDst":\(f18HID)}]}
        """
        let result = runHidutil(arguments: ["property", "--set", json])
        if result.status != 0 {
            FileHandle.standardError.write(Data("Cycler HyperKey: hidutil apply failed \(result.status): \(result.error)\n".utf8))
            return false
        }
        return true
    }

    private static func clearIfMappingIsOurs() -> Bool {
        guard isMappingOurs(currentMapping()) else { return false }
        let result = runHidutil(arguments: ["property", "--set", #"{"UserKeyMapping":[]}"#])
        if result.status != 0 {
            FileHandle.standardError.write(Data("Cycler HyperKey: hidutil clear failed \(result.status): \(result.error)\n".utf8))
            return false
        }
        return true
    }

    private static func clearKnownOwnedMapping() -> Bool {
        guard ownsCapsLockMapping else { return false }
        guard isMappingOurs(currentMapping()) else {
            setOwnsCapsLockMapping(false)
            clearOnExit = false
            return false
        }
        let cleared = clearIfMappingIsOurs()
        if cleared {
            setOwnsCapsLockMapping(false)
            clearOnExit = false
        }
        return cleared
    }

    private static var ownsCapsLockMapping: Bool {
        UserDefaults.standard.bool(forKey: ownsCapsLockMappingKey)
    }

    private static func setOwnsCapsLockMapping(_ owns: Bool) {
        if owns {
            UserDefaults.standard.set(true, forKey: ownsCapsLockMappingKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ownsCapsLockMappingKey)
        }
    }

    private static func raycastCapsHyperEnabled() -> Bool {
        guard let value = CFPreferencesCopyAppValue(
            "raycast_hyperKey_state" as CFString,
            "com.raycast.macos" as CFString
        ) as? [String: Any] else {
            return false
        }

        let enabled: Bool
        if let bool = value["enabled"] as? Bool {
            enabled = bool
        } else if let number = value["enabled"] as? NSNumber {
            enabled = number.boolValue
        } else {
            enabled = false
        }

        let keyCode: Int?
        if let int = value["keyCode"] as? Int {
            keyCode = int
        } else if let number = value["keyCode"] as? NSNumber {
            keyCode = number.intValue
        } else {
            keyCode = nil
        }

        return enabled && keyCode == capsLockKeyCode
    }

    private static func installAtexit() {
        guard !installedAtexit else { return }
        installedAtexit = true
        atexit {
            if HyperKeyController.clearOnExit {
                _ = HyperKeyController.clearKnownOwnedMapping()
            }
        }
    }

    private static func runHidutil(arguments: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (process.terminationStatus, output, error)
        } catch {
            return (127, "", String(describing: error))
        }
    }
}

private func hyperKeyControllerTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<HyperKeyController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handle(type: type, event: event)
}
