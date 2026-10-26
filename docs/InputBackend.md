# Trackpad Input Backend: Evaluation and Decision

macOS has no public API for reading raw, system-wide multitouch data from the
trackpad. `NSEvent` touch APIs only deliver touches to the focused view of the
app that owns it, and `NSEvent.addGlobalMonitorForEvents` only reports the
gestures macOS already recognized (swipe/magnify/rotate), not finger contacts.
Every tool in this space therefore uses Apple's **private**
`MultitouchSupport.framework`.

## Environment checked

| | |
|---|---|
| Machine | MacBook Air, Mac16,12, Apple M4 |
| macOS | 27.0 (26A428) |
| Toolchain | Xcode 26.2, Swift 6.2.3, macOS SDK 26.2 |
| Trackpad | "Apple Internal Keyboard / Trackpad", Family ID 110, 121.94 × 74.08 mm |

## Projects reviewed

| Project | License | Approach | Verdict |
|---|---|---|---|
| [gugahoi/touchy](https://github.com/gugahoi/touchy) | **No license file** (all rights reserved) | Links `MultitouchSupport` at build time via `-F /System/Library/PrivateFrameworks` (unsafe linker flags); C header with the community struct layout | Useful confirmation of the API, but no code could be reused. Build-time linking also means the app won't launch if the framework disappears. |
| [Kyome22/OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport) | MIT | Swift package wrapping a **prebuilt binary XCFramework** downloaded at build time, plus a swift-async-algorithms dependency; macOS 15+ | Works, but adds an opaque binary and a dependency for roughly 150 lines of C. |
| [Vatsal057/Glide](https://github.com/Vatsal057/Glide) | MIT | Small C bridge that `dlopen`s the framework and resolves symbols with `dlsym`, copying contacts into its own struct | Closest to what we need. MacGesture uses the same runtime-loading strategy, in its own code. |

## Decision

MacGesture ships its own `CMultitouchBridge` (≈250 lines of C):

* **Runtime loading.** `dlopen` + `dlsym`. Nothing links against the private
  framework, so if a future macOS removes or renames it, MacGesture still
  launches and reports *"MultitouchSupport.framework could not be loaded"* or
  *"…required functions are missing"* instead of crashing.
* **Owned data layout.** The private 96-byte contact record is declared once,
  guarded by `_Static_assert(sizeof == 96)`, and copied into an `MGContact`
  struct that MacGesture defines. Swift never sees the private layout.
* **Lifecycle safety.** Frame delivery holds a lock that `MGBridgeStop()` also
  takes, so no callback can be in flight after stop returns. MultitouchSupport
  is stopped *before* that lock is taken, to avoid deadlocking against an
  in-flight callback.
* **Multiple devices.** Every device from `MTDeviceCreateList` is registered.
  Frames carry the device ID, and the engine runs one recognizer per device so
  fingers on two trackpads never add up to one gesture.
* **Replaceable.** Everything above the bridge depends only on the
  `TrackpadInputProvider` protocol. `SimulatedInputProvider` implements the
  same protocol for the live simulator and tests, and its frames are always
  labelled `.simulated`.

### Verified on hardware (this machine)

* The framework loads; all required and optional symbols resolve except
  `MTUnregisterContactFrameCallbackWithRefcon` (not used).
* `MTDeviceCreateList` returns one built-in device; `MTDeviceGetSensorSurfaceDimensions`
  reports 12194 × 7408 (hundredths of a mm).
* Live frames decode correctly: stable identifiers per finger, state 4 while
  touching, normalized positions within 0…1, 4 simultaneous contacts observed.
* Reading frames needs **no** privacy permission, from Terminal or from the
  signed app bundle.

### Limitations that follow from this choice

* **Unsupported API.** Apple can change or remove it in any update. It is not
  App Store compatible and cannot run inside the App Sandbox.
* **Observe-only.** MultitouchSupport delivers copies of touch data. It cannot
  consume touches, so macOS still performs its own gestures (Mission Control,
  Spaces, scrolling, zooming…). MacGesture reads the user's trackpad
  preferences, warns about overlaps, and its defaults avoid them.
* **Contact states.** Only states 3 (make touch) and 4 (touching) count as
  contacts; hovering/lingering contacts are dropped. This mapping is
  community-documented, not specified by Apple.
* **Sleep and hot-plug.** Devices stop delivering after sleep. MacGesture stops
  input on sleep and session switch, restarts on wake, and restarts when IOKit
  reports an `AppleMultitouchDevice` appearing or disappearing.
