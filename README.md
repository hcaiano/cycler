# Cycler

A tiny macOS menu-bar utility: **bind a hotkey to an app — press it to jump there, press
again to walk through that app's windows.**

First press of `Hyper + 1` (say, bound to Chrome) brings Chrome to the front. Press it again
and Cycler steps to Chrome's next window, then the next, wrapping around. No Dock hunting, no
Mission Control. It lives in the menu bar and stays out of the way.

> **Status: v0.1 feature surface.** The full pipeline (build, sign, notarize, auto-update,
> website, CI) is wired, and the Settings UI plus app window cycling are implemented. See
> [HANDOFF.md](HANDOFF.md) for what's done and what's next.

## Requirements

- macOS 13+
- **Accessibility permission** (Cycler reads and raises other apps' windows via the
  Accessibility API). The menu surfaces a "Grant Accessibility…" item until it's granted.
- A Hyper key is optional but recommended (Caps Lock → ⌃⌥⇧⌘ via Karabiner/hidutil). Any
  modifier combo works.

## Configure shortcuts

Use **Settings…** from the Cycler menu-bar item to add, edit, remove, and save app shortcuts.
The app picker suggests running apps and Dock apps, with **Browse…** as a fallback.

Bindings are stored in `~/.config/cycler/bindings.json`:

```json
{
  "bindings": [
    { "keyCode": 18, "modifiers": 6912, "bundleIdentifier": "com.google.Chrome" },
    { "keyCode": 19, "modifiers": 6912, "bundleIdentifier": "com.apple.Safari" }
  ]
}
```

- `keyCode` — a Carbon virtual key (`kVK_*`). `18` = the `1` key, `19` = `2`, etc.
- `modifiers` — a Carbon modifier mask. `6912` is the Hyper key (⌃⌥⇧⌘).
- `bundleIdentifier` — the target app (`osascript -e 'id of app "Safari"'` to look one up).

See [`bindings.example.json`](bindings.example.json). If you edit the file by hand, use
**Reload bindings** in the menu (or relaunch).

Cycler registers a generated Shift variant for each shortcut that does not already include
Shift: press the shortcut to cycle forward, press Shift plus that shortcut to cycle backward.

## Build & run

```sh
swift run cycler-tests          # dependency-free test suite (no Xcode needed)
./Scripts/build-app.sh ~/Applications   # assemble + sign Cycler.app
open ~/Applications/Cycler.app
```

Full build / signing / notarization / auto-update details are in [BUILDING.md](BUILDING.md).

## Stack

Native Swift + AppKit menu-bar agent (runtime `.accessory` policy at rest), built with SwiftPM
under the Command Line Tools (no full Xcode required). Global hotkeys via Carbon
`RegisterEventHotKey`; window control via the Accessibility API; auto-updates via
[Sparkle](https://sparkle-project.org).
Same toolchain and conventions as [Lineup](https://github.com/hcaiano/lineup) and Synclock.

## License

MIT — see [LICENSE](LICENSE).
