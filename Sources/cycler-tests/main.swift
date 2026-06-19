import Foundation
import CyclerCore

// Minimal, dependency-free assertion harness so the suite runs under Command Line Tools
// (XCTest needs full Xcode). Exits non-zero if any check fails. Run: `swift run cycler-tests`.

var failures = 0
var checks = 0

func check(_ cond: Bool, _ name: String) {
    checks += 1
    if !cond {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
    }
}

// Carbon hyper mask (⌃⌥⇧⌘), duplicated here so the test target needs no Carbon import.
let hyperMask: UInt32 = 0x100 | 0x800 | 0x200 | 0x1000 // shift | cmd | option | control

// ---- SemVer ----
check(SemVer.isNewer("1.7.0", than: "1.6.4"), "1.7.0 > 1.6.4")
check(SemVer.isNewer("v2.0.0", than: "1.9.9"), "v2.0.0 > 1.9.9 (leading v)")
check(!SemVer.isNewer("1.0.0", than: "1.0.0"), "equal is not newer")
check(!SemVer.isNewer("1.0", than: "1.0.0"), "1.0 == 1.0.0")
check(!SemVer.isNewer("garbage", than: "1.0.0"), "unparseable is not newer")

// ---- WindowCycle: the press-again-to-advance order ----
check(WindowCycle.next(count: 0, current: nil) == nil, "no windows -> nil")
check(WindowCycle.next(count: 3, current: nil) == 0, "first engagement focuses window 0")
check(WindowCycle.next(count: 1, current: nil) == 0, "single window -> 0")
check(WindowCycle.next(count: 1, current: 0) == 0, "single window repeat stays at 0")
check(WindowCycle.next(count: 3, current: 0) == 1, "advance 0 -> 1")
check(WindowCycle.next(count: 3, current: 1) == 2, "advance 1 -> 2")
check(WindowCycle.next(count: 3, current: 2) == 0, "advance wraps 2 -> 0")
check(WindowCycle.next(count: 3, current: 0, direction: .backward) == 2, "backward wraps 0 -> 2")
check(WindowCycle.next(count: 3, current: 2, direction: .backward) == 1, "backward 2 -> 1")
check(WindowCycle.next(count: 3, current: 9) == 1, "stale out-of-range index is normalised (9%3=0 -> 1)")

// ---- CyclerConfig: round-trips and tolerates a missing/empty file ----
do {
    let cfg = CyclerConfig(bindings: [
        AppBinding(keyCode: 18, modifiers: hyperMask, bundleIdentifier: "com.google.Chrome"),
        AppBinding(keyCode: 19, modifiers: hyperMask, bundleIdentifier: "com.apple.Safari"),
    ])
    let data = try cfg.encoded()
    let back = try CyclerConfig.decode(data)
    check(back == cfg, "CyclerConfig encode/decode round-trips")
    check(back.bindings.count == 2, "two bindings survive the round-trip")
}
do {
    let empty = try CyclerConfig.decode(Data("{\"bindings\":[]}".utf8))
    check(empty.bindings.isEmpty, "empty bindings array decodes to no bindings")
}

if failures == 0 {
    print("ok — \(checks) checks passed")
    exit(0)
} else {
    FileHandle.standardError.write(Data("\(failures)/\(checks) checks FAILED\n".utf8))
    exit(1)
}
