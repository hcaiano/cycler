# Cycler — handoff

Read this first. It captures what Cycler is, the decisions behind it, what's already built, and
what to do next. Written for the agents picking up development from the initial scaffold.

## The product, in one line

A macOS menu-bar utility: **bind a hotkey to an app — press it to jump there, press the same
key again to walk through that app's windows, one at a time, wrapping around.**

Example: `Hyper + 1` bound to Chrome. First press → Chrome comes to the front. Press again →
Chrome's next window. Again → the next, then wrap to the first. The goal is keyboard-only window
navigation per app, without the Dock or Mission Control.

### Why it exists / how we got here

- It started as an idea for **Lineup** (the column window-manager) but cycling an app's windows
  is orthogonal to Lineup's *layout/tiling* focus, so the decision was to ship it as a
  **separate utility** rather than bolt it onto Lineup.
- The name **Cycler** was chosen after a multi-round debate (with Codex): the brief landed on
  "one word, understandable as what it does, window-related, ownable for SEO, not taken on the
  Mac App Store." Cycler won as the clearest one-word read of the behaviour. It was verified
  open on the Mac App Store. (Rejected along the way, for reference, so we don't re-pitch them:
  Flit, Swoop, Pounce, Beeline, Hail, Nock, Jolt, Shuttle, Tram, Trolley, Sash, Riffle,
  Casement, Pane, plus the "Window___" compounds.)

## What's already built (the scaffold)

Everything compiles, tests pass, and the app assembles + launches Developer-ID-signed with
Sparkle embedded. Verified end to end.

- **`Sources/CyclerCore/`** (pure, tested):
  - `WindowCycle.swift` — the round-robin `next(count:current:direction:)` index math. First
    engagement focuses window 0 ("go to app"); repeat presses advance with wraparound. **This is
    the heart of the behaviour and it's fully unit-tested.**
  - `Bindings.swift` — `AppBinding` (keyCode + Carbon modifiers + bundle id) and `CyclerConfig`
    (the Codable on-disk model).
  - `SemVer.swift` — version comparison (copied standard).
- **`Sources/cycler/`** (AppKit agent):
  - `main.swift` — menu-bar `AppDelegate`: loads `~/.config/cycler/bindings.json`, registers a
    Carbon hotkey per binding, builds the menu (warnings, binding count, Reload, Launch at login,
    Check for Updates, About, Quit), watches the Accessibility grant live (App-Nap-safe poll only
    when launched untrusted), and starts Sparkle.
  - `AppActivator.swift` — **the working core mechanism**: given a bundle id, activate the app;
    if it's already frontmost, enumerate its AX windows and raise the next one. Holds per-app
    cycle state.
  - `Hotkeys.swift` — global Carbon `RegisterEventHotKey` manager (signature `'CYCL'`).
  - `Updater.swift`, `Theme.swift`, `AboutWindow.swift`.
- **`Scripts/`** — the full Lineup-grade build pipeline, adapted: `build-app.sh` (universal,
  probe-based identity resolution, hardened-runtime only for Developer ID, inside-out Sparkle
  re-sign, fail-closed guards), `setup-signing.sh`, `make-dmg.sh`, `notarize.sh`,
  `sparkle-keygen.sh`, `sparkle-appcast.sh` (fail-closed: only appcasts a notarized, stapled,
  Developer-ID DMG), `make-icon.swift` (real Cycler icon generator), `make-icns.sh`.
- **`web/`** — minimal static landing page + empty `appcast.xml` + `wrangler.toml` +
  `.assetsignore`, plus `.github/workflows/deploy-web.yml` (Cloudflare auto-deploy on push to
  `web/**`). Needs the `CLOUDFLARE_API_TOKEN` repo secret and the `cycler.caiano.com` domain set
  up to actually deploy.
- **`Resources/Info.plist`** — bundle id `com.caiano.cycler`, version `0.1.0`
  (build 1), runtime `.accessory` policy at rest, Sparkle keys wired (`SUFeedURL` = `https://cycler.caiano.com/appcast.xml`,
  `SUPublicEDKey` = the **shared Caiano** key, so the existing private key signs releases).

## What's built now

1. **Settings UI for bindings.** The menu has Settings…, with an AppKit settings window, empty
   state, inline searchable app picker (running apps + Dock apps + Browse…), key recorder, save,
   and live reload through the existing bindings path.
2. **Hardened `AppActivator`.** Cycling filters AX windows to standard, non-minimized windows.
   Minimized windows are skipped rather than un-minimized.
3. **Launch a not-running app.** First press resolves the bundle id to an app URL and launches it
   with `NSWorkspace.openApplication(at:configuration:)`.
4. **Reverse cycling.** Bindings that do not already include Shift get a generated Shift variant
   that cycles backward. Explicit user bindings win if they would collide with that generated
   variant.

## What's stubbed / next (roughly in priority order)

1. **Marketing website.** The website (`web/`) is still a placeholder — replace it with a proper
   launch site modeled on Lineup's `web/`.
2. **First release.** Once the website is ready: bump version, run the BUILDING.md
   release sequence (build → notarize app → dmg → notarize dmg → GitHub release → `sparkle-appcast.sh`
   → commit `web/appcast.xml`). That publishes the first auto-updatable build.

## Conventions

See [AGENTS.md](AGENTS.md). Short version: keep `CyclerCore` AppKit-free and tested; smallest
change that works; never commit secrets / `dist/` / `.build/`; run `swift run cycler-tests`
before calling anything done.

## Stack / standards

Identical toolchain to Lineup (`~/code/window-manager`) and Synclock (`~/code/hcaiano/midiclock`):
Swift + AppKit menu-bar agent, SwiftPM under Command Line Tools, Carbon hotkeys, Accessibility
API for window control, Sparkle for auto-updates with the shared Caiano EdDSA key, dependency-free
test runner, Cloudflare static-site auto-deploy. Those repos are the reference when a pattern here
needs to grow up (the key recorder, a richer Settings/About, the launch website).
