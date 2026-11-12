# Developing BitPolish

Building, releasing, how it works, and the test hooks. For what BitPolish is and how to use it, see the [README](../README.md).

## Requirements

- Apple's Command Line Tools with Swift 6 or later (`xcode-select --install`). Xcode isn't required.

## Build and check

```bash
./build.sh
swift run BitPolishChecks
```

`./build.sh` puts the app in `build/BitPolish.app` (ad-hoc signed, for the machine that built it). `BitPolishChecks` runs the checks for the core logic (decoder-line and track-title parsing, rate choice, bit-depth choice, the Manually Prime DAC layout, open-file matching, rate formatting) and exits non-zero on a failure.

## Releasing a download anyone can open

Needs an Apple Developer Program membership. One-time setup:

1. In your Apple Developer account, create a **Developer ID Application** certificate and install it in your keychain.
2. Make an app-specific password at account.apple.com, then store notarization credentials:

   ```bash
   xcrun notarytool store-credentials BitPolish-notary
   ```

Then each release is one command:

```bash
./build.sh --release
```

It builds for Apple Silicon, signs with your Developer ID and the hardened runtime, notarizes and staples the app, wraps it in `build/BitPolish-<version>.dmg` (drag BitPolish onto Applications), then signs, notarizes and staples the disk image and runs a Gatekeeper check. `./build.sh --release --dry-run` runs the same pipeline with an ad-hoc signature and no notarization, to test packaging without credentials. The version comes from `Support/Info.plist`.

### Software updates (Sparkle)

BitPolish checks for updates once a day while it's running, and on **Check for Updates…** (About window, or right-click the menu-bar readout), using [Sparkle](https://sparkle-project.org) 2.10.0. The update feed (`appcast.xml`) is published at blockstarsoftware.com, and each release's disk image on GitHub. Updates stay off until both `SUFeedURL` and `SUPublicEDKey` in `Support/Info.plist` are filled in.

One-time setup:

1. Create the signing key that proves updates come from you. It's stored in your login Keychain:

   ```bash
   ./build.sh --keys
   ```

   Copy the public key it prints into `Support/Info.plist` as `SUPublicEDKey`. Back up the private key (`build/sparkle-tools/bin/generate_keys -x <file>`) and keep that file safe: without it, existing copies can't verify future updates.
2. `SUFeedURL` is `https://blockstarsoftware.com/bitpolish/appcast.xml`. If you publish your own builds, set it to an address you control.

Each release, write its notes in `ReleaseNotes/<version>.md` (Markdown, for example `ReleaseNotes/1.1.md`); Sparkle shows them in the update window. A release without a notes file shows none. Then, after `./build.sh --release` (which also copies the disk image into `build/updates/`):

```bash
./build.sh --appcast
```

The download links point at `blockstarsoftware/BitPolish`'s GitHub Releases; if you publish your own builds, prefix the command with `BITPOLISH_GITHUB_REPO=<owner>/<repo>`.

This signs the update, embeds the notes, and writes `build/updates/appcast.xml`. Create a GitHub Release tagged `v<version>` with the disk image attached (the same notes work as its description), then publish the new `appcast.xml` at the `SUFeedURL` address. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist` for every release; Sparkle compares `CFBundleVersion`.

## How it works

- **Track format:** Music's decoders log an "Input format" line for each track (sample rate, bit depth, codec). Music pre-decodes the next track for gapless playback, so after a track change the first line is that track's and later lines are held for the next one.
- **Device control:** CoreAudio's hardware API sets the device's physical format (rate and bit depth together) on its first output stream. Every device call runs on one background queue and waits until the device confirms the change. While On, if the device drifts (another app changes it, or it resets on wake), BitPolish puts the lock back.
- **Restore points:** switching On first saves the device's format and rate to `~/Library/Application Support/BitPolish/Restore Points/` (one file per device). Off, quit, the next launch after a crash, or reconnecting an unplugged DAC restores it, and the file is deleted only after the restore is confirmed. Restore points cover only the format and rate; BitPolish never changes volume. Output moves it made are undone at Off when the original was a DAC, or offered back with **Return to …** otherwise.
- **One copy at a time:** a lock file in Application Support stops a second copy from starting.

## Verification

The bit-perfect claim was tested, not assumed: Music's output was captured on its way to the DAC and compared sample by sample with the file, with the capture method itself checked first, and the DAC's input-rate display confirmed the rate. [`VERIFICATION.md`](VERIFICATION.md) gives the method, the results, what the tests don't cover, and how to repeat them on your own Mac.

## Source map

| Path | What's there |
|---|---|
| `Sources/BitPolishCore/` | Pure logic: decoder-line parsing, rate choice, bit depth choice, priming layout (family rows), open-file matching, formatting |
| `Sources/BitPolishChecks/` | The checks for BitPolishCore |
| `Sources/BitPolish/main.swift` | App startup, single-copy lock, quit and signal handling |
| `Sources/BitPolish/SessionController.swift` | The On/Off state machine, restore points, following Music |
| `Sources/BitPolish/AudioDevice.swift` | CoreAudio device access |
| `Sources/BitPolish/Snapshot.swift` | Restore points: capture, verified restore, storage |
| `Sources/BitPolish/MusicWatcher.swift` | Music's log stream and track-change notifications |
| `Sources/BitPolish/FileInspector.swift` | The playing file, from the open-file table |
| `Sources/BitPolish/StatusItemController.swift` | Menu-bar readout and the popover |
| `Sources/BitPolish/PanelView.swift` | The panel: CardView (composition and staging), the popover content, shared controls (ⓘ, pop-ups, Prime buttons) |
| `Sources/BitPolish/PanelSections.swift` | The panel's sections, one view each: header, bit depth, Manually Prime DAC, Playing File, Output, Accepts and Details, footer |
| `Sources/BitPolish/Tool.swift` | Running command-line tools; finding Music |
| `Sources/BitPolish/Updates.swift` | Software updates (Sparkle): daily check, Check for Updates…, the panel's update line |
| `Sources/BitPolish/AboutWindow.swift` | The About window |
| `Sources/BitPolish/WelcomeWindow.swift` | The first-launch welcome window |
| `Support/BitPolish.icns` | The app icon (Finder, Dock, About, Welcome); the full icon package, with sources and previews, is kept outside the app folder |
| `Sources/BitPolish/Dock.swift` | Show in Dock: the activation policy, and the app menu a Dock app shows in the menu bar |
| `Sources/BitPolish/Windows.swift` | Shared window setup for About and Welcome, immediate activation, the donation link |
| `Sources/BitPolish/TestHooks.swift` | Developer test hooks (testing builds only) |
| `docs/VERIFICATION.md` | How the bit-perfect claim was tested, and the results |
| `Tools/verification/` | The test signal, capture and comparison tools |

## Developer test hooks

`./build.sh --testing` builds with these compiled in; normal and release builds contain none of them. Set them when launching `build/BitPolish.app/Contents/MacOS/BitPolish` from Terminal:

| Variable | Effect |
|---|---|
| `BITPOLISH_START_ON=1` | Launch with Bit-Perfect Listening On |
| `BITPOLISH_OPEN_PANEL=1` | Open the panel at launch |
| `BITPOLISH_DETAILS=1` | With `BITPOLISH_OPEN_PANEL`, open it as if Option-clicked |
| `BITPOLISH_OUTPUT_TEST=<DAC>\|<DAC>` | Switch On, then choose each named DAC 3 s apart (skipped while Music plays) |
| `BITPOLISH_ITEM_AT=<path>` / `BITPOLISH_OUTPUT_BUTTON_AT=<path>` | Write the menu-bar item's / Output button's screen center to a file, for scripted click tests |
| `BITPOLISH_INFO_AT=<path>` | Write the screen center of the panel's first ⓘ to a file, for scripted hover tests |
| `BITPOLISH_FAKE_RATES=all` or `<Hz>,<Hz>…` | Draw Manually Prime DAC as if the DAC offered these rates (display only; priming a rate the DAC lacks does nothing) |
| `BITPOLISH_RENDER_WELCOME=<dir>` | Render the welcome window to PNG files (light and dark) in that folder |
| `BITPOLISH_WELCOME=1` | Show the welcome window at launch, whether or not it has been shown |
| `BITPOLISH_ABOUT=1` | Open the About window at launch |
| `BITPOLISH_BITS_TEST=<bits>` | Switch On, lock at that bit depth at +3 s, back to 24-bit at +6 s |
| `BITPOLISH_SESSION_TEST=1` | On at +2 s, Off at +5 s, trace the return offer; `BITPOLISH_RETURN=1` takes it at +7 s; `BITPOLISH_SESSION_QUIT=1` quits at +5 s instead |
| `BITPOLISH_FAKE_TRACK=<Hz>` | Act as if Music started a track at that rate, at +2.5 s |
| `BITPOLISH_RECONNECT_TEST=1` | With Keep On set: switch Off at +4 s, simulate the DAC being replugged at +5 s |
| `BITPOLISH_PICK_TEST=<DAC name>` | While Off, pick that DAC at +1.5 s (the Mac's output must not change), switch On at +3 s and Off at +7 s, tracing the Mac's output, the target and the Return offer |
| `BITPOLISH_STUCK_TEST=1` | Open, On, Off, close, reopen, On (a reported stuck "Setting …" panel), tracing whether the panel filled in; add `BITPOLISH_STUCK_FAST=1` to land the second On during the slow restore, and `BITPOLISH_RENDER_PANEL_LIVE=<dir>` to save the live popover after each On |
| `BITPOLISH_READOUT=hide\|show\|report` | Take the menu-bar readout out of the menu bar, put it back, or just report; traces the readout and the Dock icon at +1 s and +2.5 s, quits at +3 s. The choice persists, so end with `show` |
| `BITPOLISH_NOTICE_TEST=1` | Post test notices of each kind and reopen the panel on a clock moved forward (4 and 6 minutes, 25 hours), tracing whether each notice is still shown; quits itself |
| `BITPOLISH_RENDER_PANEL=<dir>` | Open the panel and save it as PNGs (light and dark) at +4 s; add `BITPOLISH_DETAILS=1` for the Option view, `BITPOLISH_RENDER_AT=<s>` to render later (e.g. after `BITPOLISH_SESSION_TEST`'s Off, for the Return offer), and `BITPOLISH_RENDER_PICK=<DAC>` to pick that DAC while Off first, for the move note (this saves it as the remembered DAC) |
| `BITPOLISH_RENDER_ABOUT=<dir>` | Save the About window's content as PNGs (light and dark) |
| `BITPOLISH_MAX_HEIGHT=<pt>` | Pretend the screen allows only this tall a panel, to check that the content scrolls above the pinned Quit row (with `BITPOLISH_RENDER_PANEL`, renders at that height) |
| `BITPOLISH_OPEN_DELAY=<s>` | With `BITPOLISH_OPEN_PANEL`, open the panel after this many seconds instead of 1 |
| `BITPOLISH_DOCK_TEST=1` | Open the panel with Details, check Show in Dock at +2 s and uncheck it at +5 s, tracing the activation policy and whether the panel stayed open |
| `BITPOLISH_LOGIN_TEST=1` | Add BitPolish as a login item at +2 s and remove it at +4 s |
| `BITPOLISH_REOPEN_TEST=1` | Open with Details, close, reopen without; traces both popover frames |
| `BITPOLISH_FLIP_TEST=1` | Switch On at +2 s, Off at +5 s |
| `BITPOLISH_OFF_THEN_QUIT=1` | Switch On, then Off and quit in the same instant |
| `BITPOLISH_RAPID_TEST=1` | On/Off three times, 150 ms apart |
| `BITPOLISH_PRIME_TEST=<Hz>` | Switch On, then prime for that rate at +3 s (Music paused) |
| `BITPOLISH_TRACE=1` | Timestamped event trace on stderr |
| `BITPOLISH_DUMP_LABEL=<path>` | Save the menu-bar readout image as PNG |
| `BITPOLISH_SIMULATE_NO_LOG=1` | Behave as a standard (non-admin) account that can't read the log |

