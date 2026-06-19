# Agent guide — Cycler

Conventions for anyone (human or agent) working in this repo. Mirrors the Lineup / Synclock
standards.

## What this is

A macOS menu-bar utility. Bind a hotkey to an app: first press jumps to it, repeat presses
cycle that app's windows. Native Swift + AppKit agent, SwiftPM, builds under Command Line Tools
(no full Xcode). See [HANDOFF.md](HANDOFF.md) for the full state and roadmap.

## Quality gate (run before declaring work done)

```sh
swift build               # must compile clean
swift run cycler-tests    # dependency-free suite; must print "ok — N checks passed"
```

For anything touching the bundle / signing / Sparkle, also assemble and launch the app:

```sh
UNIVERSAL=0 ./Scripts/build-app.sh dist && open dist/Cycler.app
```

## House rules

- **Keep `CyclerCore` AppKit-free.** Pure logic (cycle order, config model, version math) lives
  there so it stays unit-testable under the dependency-free runner. AppKit/AX code lives in
  `Sources/cycler`.
- **Smallest change that solves the task.** No new abstractions, helpers, or files unless the
  task clearly needs them. Match the existing style.
- **Add a test for new core logic** in `Sources/cycler-tests/main.swift`.
- **Never commit secrets.** The EdDSA private key and notary credential live only in the
  Keychain. Never commit `dist/`, the generated icon, or `.build/`.
- **Don't commit directly to `main`** for feature work; open a PR. (The initial scaffold commit
  is the exception.)

## Security notes

- Signing, notarization, and the Sparkle inside-out re-sign are all handled by `Scripts/`. The
  fail-closed guards there (placeholder-key check, Developer-ID-only notarization, ad-hoc DMG
  refusal) are deliberate — don't loosen them without reason.
- `SUPublicEDKey` in `Resources/Info.plist` is the **shared Caiano key** (same as Lineup /
  Synclock). The private half is in the release machine's Keychain. See BUILDING.md.
