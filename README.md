# Cycler

A tiny macOS menu-bar utility: **bind a hotkey to an app, press it to jump there, press
again to walk through that app's windows.**

First press of `Hyper + 1` (say, bound to Chrome) brings Chrome to the front. Press it again
and Cycler steps to Chrome's next window, then the next, wrapping around. No Dock hunting, no
Mission Control. It lives in the menu bar and stays out of the way.

You can also bind one key to several apps. The same press then steps between those apps in the
order you set, instead of one app's windows. While you cycle, a small HUD shows where you are.
For Chrome and other Chromium browsers, it puts the profile first so you can tell Work from
Personal.

Cycler is signed, notarized, and updates itself with Sparkle.

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
    { "keyCode": 18, "modifiers": 6912, "bundleIdentifiers": ["com.google.Chrome"] },
    { "keyCode": 19, "modifiers": 6912, "bundleIdentifiers": ["com.apple.Safari", "com.apple.mail", "com.apple.Notes"] }
  ]
}
```

- `keyCode` — a Carbon virtual key (`kVK_*`). `18` = the `1` key, `19` = `2`, etc.
- `modifiers` — a Carbon modifier mask. `6912` is the Hyper key (⌃⌥⇧⌘).
- `bundleIdentifiers` — the target apps, in order (`osascript -e 'id of app "Safari"'` to look one up):
  - **One app** — press to jump to it, press again to cycle that app's windows. Apps with
    multiple windows show the compact HUD on first engagement and while cycling. For supported
    Chromium-family browsers, Cycler shows the profile/account context first in the HUD row when
    macOS exposes it in the window title.
  - **Two or more apps (an app group)** — press to cycle between the apps in this order; window
    cycling is given up in favour of app cycling. With nothing running, the first installed app in
    the list launches. With one group app running, repeat presses hide/show that app. With several
    running, each press activates the next running app (Shift for the previous). Launch/activate
    group presses show a compact HUD with the configured app order and selected app.
- In Settings, recording a shortcut that another row already uses joins those apps into one group
  instead of asking for a different shortcut.

> Older configs wrote a single `"bundleIdentifier": "…"` string. Cycler still reads that shape and
> rewrites it to the `"bundleIdentifiers": […]` array on the next save.

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
