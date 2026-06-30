import Foundation

/// A single hotkey: a Carbon key code + modifier mask that, when pressed, drives one or more apps.
///
/// `bundleIdentifiers` is an ordered, non-empty list of target apps:
/// - One app: press to bring it forward, press again to cycle its windows (the original behaviour).
/// - Two or more apps (an "app group"): press to cycle between the apps in this order, giving up
///   per-window cycling. See `AppGroupCycle` for the pure decision logic.
///
/// `keyCode` is a Carbon virtual key (kVK_*). `modifiers` is a Carbon modifier mask (the value
/// `HotkeyManager.hyper` produces for ⌃⌥⇧⌘). Storing raw Carbon values keeps the config in the
/// same vocabulary the hotkey registration uses, so there's no NSEvent<->Carbon translation here.
public struct AppBinding: Codable, Equatable, Sendable {
    public var keyCode: Int
    public var modifiers: UInt32
    public var bundleIdentifiers: [String]

    /// Convenience for a single-app binding (the common case, and what existing call sites use).
    public init(keyCode: Int, modifiers: UInt32, bundleIdentifier: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.bundleIdentifiers = [bundleIdentifier]
    }

    /// Multi-app (or single-app) binding. `bundleIdentifiers` must be non-empty.
    public init(keyCode: Int, modifiers: UInt32, bundleIdentifiers: [String]) {
        precondition(!bundleIdentifiers.isEmpty, "bundleIdentifiers must not be empty")
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.bundleIdentifiers = bundleIdentifiers
    }

    /// The first target — the app a single-app binding drives, or a group's first member.
    public var bundleIdentifier: String { bundleIdentifiers[0] }

    /// Two or more apps means "cycle between apps" instead of "cycle one app's windows".
    public var isGroup: Bool { bundleIdentifiers.count > 1 }

    // MARK: - Codable

    // Canonical on-disk shape is `bundleIdentifiers: [String]`. Legacy files wrote a single
    // `bundleIdentifier: String`; we still decode those, but always re-encode the array shape.
    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, bundleIdentifiers, bundleIdentifier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(Int.self, forKey: .keyCode)
        modifiers = try c.decode(UInt32.self, forKey: .modifiers)
        if let ids = try c.decodeIfPresent([String].self, forKey: .bundleIdentifiers) {
            guard !ids.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .bundleIdentifiers, in: c,
                    debugDescription: "bundleIdentifiers must not be empty")
            }
            bundleIdentifiers = ids
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier) {
            bundleIdentifiers = [legacy]
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .bundleIdentifiers, in: c,
                debugDescription: "a binding needs bundleIdentifiers (or legacy bundleIdentifier)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(modifiers, forKey: .modifiers)
        try c.encode(bundleIdentifiers, forKey: .bundleIdentifiers)
    }
}

/// Which physical key, when held, Cycler turns into Hyper.
///
/// Caps Lock needs an OS-level remap (Cycler maps it to F18 via `hidutil`) because macOS otherwise
/// swallows it as a lock toggle. The function keys are already ordinary keys, so Cycler can grab
/// them straight from its event tap with no remap. Raw values are stable on-disk tokens — `capsLock`
/// matches what older configs already wrote, so they keep decoding unchanged.
public enum TriggerKey: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case capsLock
    case f18
    case f19
    case f20

    /// Human label for the trigger picker. Pure text (no AppKit), so it stays in CyclerCore.
    public var displayName: String {
        switch self {
        case .capsLock: return "Caps Lock"
        case .f18: return "F18"
        case .f19: return "F19"
        case .f20: return "F20"
        }
    }

    /// Whether engaging this trigger requires Cycler's `hidutil` remap. Only Caps Lock does; the
    /// function keys are caught directly by the event tap.
    public var needsCapsLockRemap: Bool { self == .capsLock }
}

/// Optional, off-by-default built-in HyperKey. When `enabled`, Cycler itself makes the `triggerKey`
/// behave as Hyper system-wide, so users don't need Raycast/Karabiner. This is pure persisted
/// settings only; the actual key remapping lives in the AppKit target (Sources/cycler), never here.
public struct HyperKeySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var triggerKey: TriggerKey
    /// `true` means Cycler's default Hyper (control+option+shift+command); `false` excludes Shift.
    public var includeShift: Bool

    public init(enabled: Bool = false, triggerKey: TriggerKey = .capsLock, includeShift: Bool = true) {
        self.enabled = enabled
        self.triggerKey = triggerKey
        self.includeShift = includeShift
    }

    /// The default for a config that has never enabled HyperKey: off, Caps Lock, full Hyper.
    public static let disabled = HyperKeySettings()
}

/// The on-disk config: the user's per-app bindings. Loaded from
/// `~/.config/cycler/bindings.json`. A missing or empty file is valid (no shortcuts bound yet).
public struct CyclerConfig: Codable, Equatable, Sendable {
    public var bindings: [AppBinding]
    public var hyperKey: HyperKeySettings

    public init(bindings: [AppBinding] = [], hyperKey: HyperKeySettings = .disabled) {
        self.bindings = bindings
        self.hyperKey = hyperKey
    }

    // `hyperKey` is a later addition; files written before it simply omit the key. Decode it with
    // `decodeIfPresent` so existing configs load as `.disabled` instead of failing.
    private enum CodingKeys: String, CodingKey {
        case bindings, hyperKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bindings = try c.decode([AppBinding].self, forKey: .bindings)
        hyperKey = try c.decodeIfPresent(HyperKeySettings.self, forKey: .hyperKey) ?? .disabled
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bindings, forKey: .bindings)
        try c.encode(hyperKey, forKey: .hyperKey)
    }

    /// Decode from raw JSON bytes. Throws on malformed JSON (the caller surfaces it and keeps an
    /// empty config rather than clobbering the file — see Sources/cycler/main.swift).
    public static func decode(_ data: Data) throws -> CyclerConfig {
        try JSONDecoder().decode(CyclerConfig.self, from: data)
    }

    /// Encode to pretty, stable JSON for writing back to disk.
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    /// Coalesce repeated shortcut combos into app groups. The first binding for a shortcut keeps
    /// its position and app order; later duplicates append any new apps to that group.
    public func coalescingDuplicateShortcuts() -> CyclerConfig {
        var indexByShortcut: [BindingShortcut: Int] = [:]
        var merged: [AppBinding] = []

        for binding in bindings {
            let shortcut = BindingShortcut(keyCode: binding.keyCode, modifiers: binding.modifiers)
            guard let existingIndex = indexByShortcut[shortcut] else {
                indexByShortcut[shortcut] = merged.count
                merged.append(binding)
                continue
            }

            var existing = merged[existingIndex]
            var seen = Set(existing.bundleIdentifiers)
            for bundleIdentifier in binding.bundleIdentifiers where !seen.contains(bundleIdentifier) {
                existing.bundleIdentifiers.append(bundleIdentifier)
                seen.insert(bundleIdentifier)
            }
            merged[existingIndex] = existing
        }

        return CyclerConfig(bindings: merged, hyperKey: hyperKey)
    }
}

private struct BindingShortcut: Hashable {
    var keyCode: Int
    var modifiers: UInt32
}
