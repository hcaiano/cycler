import Foundation

/// A single per-app hotkey: a Carbon key code + modifier mask that, when pressed, brings the
/// app with `bundleIdentifier` to the front; pressing it again cycles that app's windows.
///
/// `keyCode` is a Carbon virtual key (kVK_*). `modifiers` is a Carbon modifier mask (the value
/// `HotkeyManager.hyper` produces for ⌃⌥⇧⌘). Storing raw Carbon values keeps the config in the
/// same vocabulary the hotkey registration uses, so there's no NSEvent<->Carbon translation here.
public struct AppBinding: Codable, Equatable, Sendable {
    public var keyCode: Int
    public var modifiers: UInt32
    public var bundleIdentifier: String

    public init(keyCode: Int, modifiers: UInt32, bundleIdentifier: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.bundleIdentifier = bundleIdentifier
    }
}

/// The on-disk config: the user's per-app bindings. Loaded from
/// `~/.config/cycler/bindings.json`. A missing or empty file is valid (no shortcuts bound yet).
public struct CyclerConfig: Codable, Equatable, Sendable {
    public var bindings: [AppBinding]

    public init(bindings: [AppBinding] = []) {
        self.bindings = bindings
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
}
