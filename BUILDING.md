# Building Cycler

For contributors and anyone who wants to build from source. End users should grab the DMG from
the [Releases page](https://github.com/hcaiano/cycler/releases/latest); see the [README](README.md).

## Requirements

- macOS 13 or later
- Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode is not required.

## Build and run

```sh
git clone https://github.com/hcaiano/cycler.git && cd cycler
swift run cycler-tests              # dependency-free test suite (no Xcode/XCTest needed)
./Scripts/setup-signing.sh          # one-time: stable signature so the macOS permission sticks
./Scripts/build-app.sh ~/Applications
open ~/Applications/Cycler.app
```

`build-app.sh` produces a **universal** (arm64 + x86_64) app by default, so it runs on every
supported Mac. For faster local iteration, `UNIVERSAL=0 ./Scripts/build-app.sh …` builds the
host arch only. (One-shot `--arch` needs full Xcode; under Command Line Tools each slice is
built with `--triple` and combined with `lipo`.)

A locally built app is ad-hoc signed, whose signature changes every build, so macOS keeps asking
you to re-grant Accessibility. `setup-signing.sh` creates a reused self-signed identity once, so
every build shares one stable signature and you grant Accessibility a single time. The same applies
to releases: build the release DMG on a machine where this has been run, so users authorize once
and updates keep working. Pass `REQUIRE_STABLE_SIGNATURE=1 ./Scripts/build-app.sh dist` to make a
release build fail loudly rather than ship an ad-hoc signature by accident.

## Package the installer

```sh
REQUIRE_STABLE_SIGNATURE=1 ./Scripts/build-app.sh dist   # refuses to build an ad-hoc release
./Scripts/make-dmg.sh dist          # -> dist/Cycler-<version>.dmg; also rejects an ad-hoc app
```

Both steps refuse an ad-hoc signature so a release can't accidentally ship one (which would
make every update drop the user's Accessibility grant). Run `setup-signing.sh` first. For a
throwaway local DMG you can bypass with `ALLOW_ADHOC_DMG=1 ./Scripts/make-dmg.sh dist`.

## Project layout

```
Sources/CyclerCore/         Pure, tested core (no AppKit)
  WindowCycle.swift         Round-robin "press again to advance" index math
  Bindings.swift            AppBinding + CyclerConfig (Codable on-disk model)
  SemVer.swift              Version comparison for update checks
Sources/cycler/             AppKit agent
  main.swift                Menu-bar app, config lifecycle, hotkey registration, AX watch
  AppActivator.swift        Activate an app / cycle its windows via the Accessibility API
  Hotkeys.swift             Global Carbon hotkeys (RegisterEventHotKey)
  AboutWindow.swift         Minimal About panel
  Theme.swift               Brand colour + placeholder menu-bar logo
  Updater.swift             Sparkle updater controller (Check for Updates + background checks)
Sources/cycler-tests/       Dependency-free test runner
Scripts/                    build-app, setup-signing, make-dmg, make-icon, make-icns,
                            notarize, sparkle-keygen, sparkle-appcast
```

Bindings live at `~/.config/cycler/bindings.json` (per-app hotkeys). See `bindings.example.json`.

## Notarized release (Developer ID)

With an Apple Developer account, a **Developer ID Application** certificate in the keychain
makes `build-app.sh` sign with it automatically (hardened runtime + secure timestamp), which
`notarize.sh` can then submit to Apple. Notarization removes the "unidentified developer"
prompt on first open. One-time credential setup (keeps secrets out of scripts):

```sh
xcrun notarytool store-credentials "cycler-notary" \
  --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
```

Release flow (the `REQUIRE_DEVELOPER_ID_SIGNATURE=1` gate fails fast if no Developer ID
identity is found, so a notarized release can't silently fall back to the self-signed cert):

```sh
REQUIRE_DEVELOPER_ID_SIGNATURE=1 ./Scripts/build-app.sh dist   # sign the app w/ Developer ID
./Scripts/notarize.sh dist/Cycler.app                          # notarize + staple the app
./Scripts/make-dmg.sh dist                                     # package it; signs the DMG too
./Scripts/notarize.sh dist/Cycler-<version>.dmg                # notarize + staple the DMG
```

Stapling the app makes the dragged-out copy pass Gatekeeper offline; notarizing the DMG makes
the download itself open cleanly. `notarytool` and `stapler` ship with the Command Line Tools,
so no full Xcode is needed.

## Auto-updates (Sparkle)

Cycler updates in place with [Sparkle](https://sparkle-project.org). `build-app.sh` embeds
`Sparkle.framework` and re-signs it inside-out with the same identity as the app; updates are
authenticated with an **EdDSA** signature so a tampered or man-in-the-middled download is
rejected. The feed is `web/appcast.xml`, served at `https://cycler.caiano.com/appcast.xml`
(auto-deployed from `web/`), and pointed to by `SUFeedURL` in `Resources/Info.plist`.

**EdDSA key:** Cycler ships the **shared Caiano `SUPublicEDKey`** (the same one used by Lineup
and Synclock). The matching private key already lives in the release machine's login Keychain,
so there's nothing to generate — `sparkle-appcast.sh` signs releases with it. (If you ever need
a fresh, app-specific key instead, run `./Scripts/sparkle-keygen.sh` and paste the new public
key into `Resources/Info.plist`; but then existing installs that trusted the old key won't
accept the new updates.)

**Per release**, after notarizing the DMG and uploading it to its GitHub release, regenerate
the signed feed and commit it (committing `web/appcast.xml` auto-deploys the feed):

```sh
./Scripts/sparkle-appcast.sh dist/Cycler-<version>.dmg   # EdDSA-signs the DMG, writes web/appcast.xml
git add web/appcast.xml && git commit -m "Appcast: <version>"   # deploys; installs see the update
```

The full release sequence is therefore: `build-app.sh` → `notarize.sh` (app) → `make-dmg.sh`
→ `notarize.sh` (DMG) → publish the GitHub release with the DMG → `sparkle-appcast.sh` →
commit `web/appcast.xml`.

## Website auto-deploy

`web/` is a static site served by a Cloudflare Worker. Pushing a change under `web/` to `main`
triggers `.github/workflows/deploy-web.yml`, which deploys via `cloudflare/wrangler-action`. The
only repo secret required is `CLOUDFLARE_API_TOKEN` (a token with **Workers Scripts: Edit** on
the Caiano account). The account id is in `web/wrangler.toml`.
