# MacGesture

A native macOS menu-bar app that adds custom system-wide trackpad gestures —
multi-finger taps, swipes (including diagonals), pinches, rotations, circles,
and long holds — and maps them to keyboard shortcuts, window layouts, media
and volume controls, system features, apps, URLs, scripts, and Shortcuts.

Swift 6 · SwiftUI + AppKit · no third-party dependencies · macOS 15+ on Apple Silicon.

> **Private API notice.** macOS has no public API for system-wide raw trackpad
> touches. MacGesture reads them through Apple's private
> `MultitouchSupport.framework`, loaded at runtime. That means it is not App
> Store compatible, cannot be sandboxed, and a macOS update could break it.
> If that happens, MacGesture reports the backend as unavailable instead of
> crashing. See [docs/InputBackend.md](docs/InputBackend.md).

## Status

Developed and checked on a MacBook Air (M4, Mac16,12), macOS 27.0, Xcode 26.2.

| Area | State | Evidence |
|---|---|---|
| Real trackpad input (built-in) | **Working on hardware** | Probe: framework loads, real frames with stable finger IDs and up to 4 contacts, no permission prompt, 0.09% average CPU over 150 s. |
| 2- and 4-finger swipes | **Recognized from real input** | Correct directions and finger counts during normal use (scrolling, Spaces swipes). No false positives in ~1,500 contact frames of pointing/scrolling. |
| Taps, pinch, rotate, circle, hold, diagonals, 3/5-finger | Automated tests only | 38 recognizer/engine tests on synthetic sequences, including jitter, staggered landing/lift, palms, timeouts. **Not yet confirmed on hardware.** Run the probe to check. |
| Keyboard, media, window actions | Implemented; denial path verified | Without Accessibility they fail with a clear "permission required" (tested on this Mac). The success path needs the grant and wasn't exercised here. |
| Volume (Core Audio) | Read verified on hardware | Reads the real output volume. Not changed during development. |
| System shortcuts | Verified | Reads your actual bindings from System Settings (e.g. a remapped Mission Control key). |
| Scripts / shell / Shortcuts | Tested | Exit status, timeout, confirmation decline, forced confirmation for destructive commands, path validation. |
| Persistence | Tested and verified | Round-trip, migration, corrupt/newer-file tests, plus edits surviving a real relaunch of the app. |
| App, menu bar, windows | Builds and launches | Onboarding opens on first launch and not after. UI interactions were not driven by an automated test. |
| Anchor finger + vertical swipe | Automated tests only | 30 tests with a mock volume service, covering the 12 required scenarios plus reversal, pauses, tremor, rate limiting, engine exclusivity, and migration. **Not yet confirmed on hardware**, including scroll suppression. |
| Sleep/wake, trackpad hot-plug | Implemented, untested | Restarts input on wake, session change, and IOKit device add/remove. |

## Build and install

Requirements: Xcode 16+ command-line tools (developed with Xcode 26.2 / Swift 6.2).

```sh
swift test                      # run the automated test suite
scripts/build-app.sh            # build/MacGesture.app (release, ad-hoc signed)
open build/MacGesture.app
```

Copy `build/MacGesture.app` to `/Applications` to keep it. On first launch a
short onboarding window checks the trackpad, explains permissions, and lists
overlaps with macOS gestures. Afterwards MacGesture lives in the menu bar
(hand icon; a slashed hand means paused).

### Signing and the Accessibility permission

macOS ties the Accessibility grant to the app's code signature. An ad-hoc
signature changes on every build, so after rebuilding you must remove
MacGesture from System Settings ▸ Privacy & Security ▸ Accessibility and add it
again. To avoid that, create a code-signing certificate once (Keychain Access ▸
Certificate Assistant ▸ Create a Certificate…, type **Code Signing**, e.g.
"MacGesture Local") and build with:

```sh
MACGESTURE_SIGN_IDENTITY="MacGesture Local" scripts/build-app.sh
```

### Hardware probe

`swift run -c release macgesture-probe 60` reads the real trackpad through the
same engine with every gesture type enabled and **no actions**, printing each
recognized gesture with its measurements, why cycles were cancelled, the frame
rate, and CPU use. Use it to check that input works after a macOS update.

## Using it

* **Menu bar:** status, enable/pause (⌘E), profile switcher, open settings, Live Test, quit.
* **Dashboard:** engine, trackpad backend and devices, permission status,
  overlap warnings, and recent gestures with each action's result.
* **Gestures:** add, edit (double-click), duplicate, enable/disable, reorder, and
  delete mappings. Duplicate triggers, invalid actions, and overlaps with
  enabled macOS gestures are flagged. The editor can **try the gesture on the
  trackpad** (without running anything) and **run the action now**, before
  saving.
* **Live Test:** finger positions, recognizer state, each candidate's progress
  toward its threshold, and measurements in millimetres. A simulator generates
  every gesture type, and you can drag on the diagram. Simulated input is
  labelled **SIMULATED** everywhere and doesn't run actions unless you turn that on.
* **Permissions:** status, requests, and troubleshooting.
* **Settings:** enable, open at login, cooldown, sensitivity and advanced
  thresholds, profiles, log level, reset to defaults.

## Gestures

| Gesture | Fingers | Directions | Fires |
|---|---|---|---|
| Tap | 2–5 | — | on lift, if short (≤ 0.25 s) and still (≤ 3 mm) |
| Swipe | 2–5 | 4 cardinal + 4 diagonal | when the centroid travels 14 mm in a straight line |
| Pinch | 2–5 | in / out | at a 22% change in finger spread |
| Rotate | 2–5 | clockwise / counterclockwise | at 25° of rotation |
| Circle | 2–5 | clockwise / counterclockwise | after 300° of turning along a circular path |
| Long hold | 2–5 | — | after 0.6 s with every finger still |
| Anchor finger + vertical swipe | 1 + 1 | up / down (continuous) | repeatedly while the second finger slides, after a 3 mm dead zone |

Defaults are shown at 50% sensitivity. Distances are physical millimetres
(converted using the trackpad's reported size), so they feel the same on any
trackpad.

How recognition avoids false positives:

* **State machine per cycle** (fingers down → all lifted): *began → tracking →
  recognized → completed*, or *cancelled*. At most one gesture fires per cycle.
* **Only mapped gestures fire.** Every motion is still classified, and the
  dominant candidate must lead the runner-up by 1.3×. If the winner isn't
  mapped, the cycle is cancelled rather than letting a weaker match fire. A
  pinch never turns into a swipe just because only swipes are mapped.
* **Settling.** A new finger set must be stable for 40 ms (100 ms after a lift)
  before motion counts, so staggered landings and lifts don't register with the
  wrong finger count.
* **Disambiguation.** When circles are mapped for a finger count, swipes with
  that count fire on lift instead of mid-motion (a circle starts out looking
  like a swipe). Diagonals are only split out when a diagonal is mapped.
  Holds only fire when a hold is mapped.
* **Noise.** Palm-sized contacts are ignored, path turning ignores sub-millimetre
  jitter, resting hands time out after 8 s, and a frame gap starts a new cycle.
* **Cooldowns.** A global cooldown (0.35 s) after any action, plus optional
  per-gesture cooldowns.

### Anchor finger + vertical swipe (volume slider)

Hold one finger still, add a second finger, and slide it up or down. By
default this adjusts the output volume like a slider (about 13% per cm,
adjustable). Set it up under *Settings ▸ Anchor Finger + Vertical Swipe*; it
can be remapped in the Gestures editor (“anchor finger + swipe up/down”).

* **Separate recognizer** (`AnchorSwipeRecognizer`), run by the same engine.
  Fingers are tracked by the backend's stable touch IDs, never by array
  position.
* **Starting.** The anchor must rest *alone* for 0.2 s before the second finger
  lands. Two fingers landing together are a normal scroll and are ignored.
  Anchors in the bottom 12% of the trackpad (where a thumb rests) are ignored.
* **Cancelling.** The gesture is rejected until every finger lifts if:
  * the anchor moves more than 4 mm,
  * a third finger lands,
  * or a finger's identity changes.
  Lifting the moving finger stops adjustments immediately; the anchor can stay
  down for another stroke. Lifting the anchor ends the gesture.
* **Smoothness.**
  * Only vertical movement counts.
  * A light filter absorbs tremor, and reversing needs 0.6 mm of extra travel.
  * Updates are limited to one per 30 ms, with steps in between combined.
  * Pauses don't cause jumps, and volume is clamped to 0–100%.
* **Exclusivity.** While the anchor gesture owns the touch, the regular
  recognizer's cycle is cancelled, so no other mapping fires from the same
  motion.
* **Scrolling and the pointer.** macOS sees the moving finger as a
  two-finger scroll, or sometimes (treating the still anchor as a resting
  finger) as pointer movement. With Accessibility granted, an event tap on its
  own thread holds both still (you can turn this off):
  * scroll events and pointer-movement events are dropped, and the cursor is
    put back where it was when the second finger landed;
  * this starts when the second finger lands and lasts until every finger
    lifts, even if the gesture stopped early because the anchor drifted;
  * it covers 0.2 s of trailing events after lift, plus the momentum scroll.

  Pointing with one finger before the second lands is untouched. Early stops
  and their reasons are written to the log.
* **Haptics.** By default the trackpad clicks lightly each time the volume
  crosses a 10% mark, and firmly on reaching 0% or 100%. Pushing past a limit
  stays quiet, and clicks are rate-limited on very fast swipes. Other modes:
  Off, limits only, or a start click plus limits. This uses the private
  MTActuator API (same framework), because the public haptics API only plays
  for the frontmost app.
* **Volume** goes through Core Audio on the default output device only. If that
  device has no software volume (some HDMI/DisplayPort outputs), it falls back
  to the system volume keys. Nothing runs a shell command.

## Actions

| Action | How | Needs Accessibility |
|---|---|---|
| Keyboard shortcut (with presets: app switcher, tabs, back/forward…) | Quartz `CGEvent`s, including real modifier key events | yes |
| Window: minimize, maximize (toggle back), full screen, center, halves, thirds, two-thirds, quarters, next display | Accessibility API on the frontmost app's focused window | yes |
| Media: play/pause, next, previous | System-defined media-key events, to the Now Playing app | yes |
| Volume: up, down, mute, set level | Core Audio on the default output device | no |
| Mission Control, Apps/Launchpad | Opens the system app | no |
| Application Windows, Show Desktop, move left/right a Space, Spotlight | Posts *your* shortcut from System Settings ▸ Keyboard Shortcuts; fails clearly if it's turned off | yes |
| Open application, open URL | `NSWorkspace` | no |
| Run script | Runs an executable directly with fixed arguments (no shell) | no |
| Shell command | `/bin/zsh -c`; asks first by default | no |
| Run Shortcut | `/usr/bin/shortcuts run <name>` | no |

Safety rules for scripts and commands:

* They only ever come from your configuration, never from touch data.
* Script paths must be absolute, exist, be regular executable files, and must
  not be writable by other users.
* Shell commands ask before running by default. Commands that look destructive
  (`rm`, `sudo`, `mv`, `kill`, `>` overwrite, `git reset --hard`, …) **always** ask,
  and the dialog's default button is Cancel.
* Output is discarded, and logs never contain command text, arguments, output,
  or URLs. Processes are stopped after a timeout (30 s by default).
* Gestures are ignored while a confirmation dialog is open.

Every action returns success, failure, or cancelled. Failures (missing
permission, no focused window, fixed-volume device, disabled system shortcut,
missing app…) show in Recent Activity and the log. They are never dropped silently.

## Configuration, logs, and data

* Configuration: `~/Library/Application Support/MacGesture/configuration.json`,
  versioned (`schemaVersion`), saved atomically.
  * Missing settings fall back to defaults, so older files keep loading.
  * Older schemas migrate step by step, keeping a backup.
  * Unreadable files are moved aside (`configuration.corrupt-<date>.json`) and
    defaults are loaded.
  * Files from a *newer* MacGesture are never overwritten. Changes aren't saved
    until you reset.
  * "Reset to Defaults" keeps the previous file as a backup.
* Log: `~/Library/Logs/MacGesture/MacGesture.log` (rotated at 1 MB) and the
  unified log (subsystem `local.macgesture.MacGesture`). Levels: Off, Standard, Verbose.
* No credentials or personal data are stored. Touch data is never written to disk.

## Architecture

```text
Sources/
├── CMultitouchBridge/          C: dlopen bridge to the private framework (isolated)
├── MacGestureCore/             Testable core (no UI)
│   ├── Input/                  TouchFrame model, TrackpadInputProvider protocol,
│   │                           MultitouchSupportProvider, SimulatedInputProvider,
│   │                           SyntheticGestureGenerator, device hot-plug monitor
│   ├── Recognition/            GestureRecognizer state machine, settings, armed set
│   ├── Routing/                GestureEngine pipeline, GestureRouter (cooldowns),
│   │                           conflict detection, macOS gesture overlap detection
│   ├── Actions/                ActionExecutor + keyboard, window, media, volume,
│   │                           system feature, command runner, validation
│   ├── Permissions/            Accessibility / event-posting checks and requests
│   ├── Configuration/          Codable models, defaults, store + migration
│   └── Diagnostics/            Logging
├── MacGesture/                 The app
│   ├── App/                    @main, AppDelegate, AppModel (state, lifecycle)
│   └── UI/                     Menu bar, dashboard, gesture editor, live test,
│                               permissions, settings, onboarding
└── MacGestureProbe/            CLI hardware probe
Tests/MacGestureCoreTests/      Recognizer, routing/engine, configuration, actions
```

Data flow: the provider's callback (on MultitouchSupport's thread) →
`GestureEngine.ingest` → a serial recognition queue (one `GestureRecognizer`
per device, then `GestureRouter`) → main queue → `AppModel` → `ActionExecutor`.
Window operations run on a `WindowManager` actor because Accessibility calls
are blocking IPC (with a 1 s timeout per app). The core compiles under Swift 6
strict concurrency with no warnings.

## Limitations

* **Private, unsupported input API** (see above). Not App Store or sandbox
  compatible. Distribute outside the App Store and sign with Developer ID plus
  notarization for other Macs.
* **MacGesture can't suppress macOS gestures.** If you map a gesture macOS also
  uses, both happen. Turn the macOS one off in System Settings ▸ Trackpad. The
  app reads your trackpad settings and warns about each overlap.
* **No virtual-desktop API.** Space switching posts your Mission Control
  shortcuts. It can't jump to arbitrary Spaces or move windows between them.
* **Window control depends on the app.** Some windows can't be resized, have
  minimum sizes, or don't expose Accessibility attributes. MacGesture reports
  that rather than claiming success.
* **Synthetic keystrokes** are ignored by secure text fields (passwords) and
  some games or remote-desktop apps.
* **Volume changes don't show the system HUD** (Core Audio is set directly).
  Devices with fixed volume (many HDMI/DisplayPort outputs) report an error.
* **Thumbs and resting fingers** count as contacts. Palm-sized contacts are
  filtered, but a resting thumb can change a gesture's finger count.
* **Hold vs. slow start.** Resting fingers still for the hold duration fires a
  mapped hold, so a swipe that starts after a long pause becomes a hold.
* **Anchor gesture and scrolling.** Without Accessibility (or with
  suppression off), the window under the pointer may scroll while you adjust
  the volume. Suppression drops *all* scroll events while the gesture is
  active, including from a mouse.
* **Window actions on MacGesture's own windows** run on the main thread.
  Earlier builds crashed here; this is fixed.
* Only Apple Silicon (arm64) builds are produced. Older/newer macOS versions
  than tested may behave differently; check with the probe.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Dashboard says "Unavailable on this macOS" | The private framework changed. Run the probe; nothing in MacGesture can work around it. |
| "No trackpad found" | Connect a trackpad. MacGesture restarts input when one appears. Or use *Settings ▸ Restart Trackpad Input*. |
| Gestures are recognized but actions fail with "Accessibility permission is required" | Grant Accessibility. After a rebuild, remove and re-add the app (see Signing). |
| Gesture fires twice, or macOS also reacts | Turn off the overlapping macOS gesture. Raise the cooldown if needed. |
| Gesture doesn't fire | Open Live Test, watch the threshold meters, and adjust sensitivity or the per-gesture sensitivity. |
| Stops working after sleep | It should restart automatically on wake. Otherwise use *Restart Trackpad Input*, and send the log. |
| Space switching does nothing | Turn on "Move left/right a space" in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control. |
