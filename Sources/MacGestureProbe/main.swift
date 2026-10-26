// Hardware probe: runs the real trackpad backend through the recognition
// engine in diagnostics mode (every gesture recognized, no actions run) and
// prints what it sees.
//
//   swift run macgesture-probe [seconds]
//   swift run macgesture-probe --check     read-only check of action backends
//   swift run macgesture-probe --haptic    play one trackpad click
import Darwin
import Foundation
import MacGestureCore
import os

setvbuf(stdout, nil, _IOLBF, 0)

if CommandLine.arguments.contains("--haptic") {
    let played = TrackpadHaptics.play(.weak)
    print(played ? "Trackpad actuator: click played" : "Trackpad actuator unavailable (fell back to NSHapticFeedbackManager)")
    exit(played ? 0 : 1)
}

if CommandLine.arguments.contains("--check") {
    let permissions = PermissionChecker.current()
    print("Accessibility (AX): \(permissions.accessibility ? "granted" : "not granted")")
    print("Post events: \(permissions.postEvents ? "granted" : "not granted")")
    do {
        print(String(format: "Core Audio default output volume: %.0f%%", try VolumeController().current().level * 100))
    } catch {
        print("Core Audio: \(error.localizedDescription)")
    }
    for feature in SystemFeature.allCases {
        switch SymbolicHotKeys.lookup(feature) {
        case .enabled(let combo): print("\(feature.displayName): shortcut \(combo.displayName)")
        case .disabled: print("\(feature.displayName): shortcut turned OFF in System Settings")
        case nil: print("\(feature.displayName): launches an app")
        }
    }
    let system = SystemGestureSettings.current()
    print("macOS gestures: 3F horiz \(system.threeFingerHorizontalSwipe), 3F vert \(system.threeFingerVerticalSwipe), 4F horiz \(system.fourFingerHorizontalSwipe), 4F vert \(system.fourFingerVerticalSwipe), 4F pinch \(system.fourFingerPinch), 5F pinch \(system.fiveFingerPinch), 3F tap \(system.threeFingerTap), 3F drag \(system.threeFingerDrag)")
    let issues = MappingConflictDetector.issues(in: DefaultConfiguration.defaultProfile(), system: system)
    print("Default profile issues on this Mac: \(issues.isEmpty ? "none" : "")")
    for issue in issues { print("  [\(issue.severity)] \(issue.message)") }
    exit(0)
}

let duration = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 60

let provider = MultitouchSupportProvider()
switch provider.availability() {
case .unavailable(let reason):
    print("UNAVAILABLE: \(reason)")
    exit(1)
case .noDevices:
    print("No multitouch devices attached.")
    exit(1)
case .available(let devices):
    for device in devices {
        print(String(format: "Device %llu: %@ (%.1f × %.1f mm, built-in: %@)", device.id, device.name, device.surfaceSize.x, device.surfaceSize.y, device.isBuiltIn ? "yes" : "no"))
    }
}

struct Stats {
    var frames = 0
    var touchFrames = 0
    var maxFingers = 0
    var lastTouch: TimeInterval?
    /// Sum of gaps between consecutive contact frames within one touch.
    var activeTime: TimeInterval = 0
    var identifiers = Set<Int>()
    var gestures = 0
}

let stats = OSAllocatedUnfairLock(initialState: Stats())
let origin = ProcessInfo.processInfo.systemUptime
let lastPhase = OSAllocatedUnfairLock<String?>(initialState: nil)
let lastAnchor = OSAllocatedUnfairLock<String?>(initialState: nil)

func stamp() -> String {
    String(format: "%7.2fs", ProcessInfo.processInfo.systemUptime - origin)
}

let engine = GestureEngine(configuration: DefaultConfiguration.make()) { output in
    switch output {
    case .recognized(let event, _):
        stats.withLock { $0.gestures += 1 }
        if event.trigger.kind.isContinuous {
            print("\(stamp())  ⇅ \(event.trigger.displayName) ×\(event.magnitude)  " + String(format: "travel %+.1f mm", event.metrics.translation.y))
            return
        }
        let m = event.metrics
        print("\(stamp())  ✅ \(event.trigger.displayName.uppercased())  score \(String(format: "%.2f", event.score))  "
            + String(format: "move (%.1f, %.1f)mm scale %.2f rot %.0f° turn %.0f° straight %.2f", m.translation.x, m.translation.y, m.scale, m.rotation, m.turn, m.straightness))
    case .anchorGestureStopped(let reason):
        print("\(stamp())  ⚓︎ stopped early: \(reason)")
    case .diagnostics(let snapshot):
        let anchorSummary: String? = switch snapshot.anchor {
        case .anchored(let id): "anchor held (finger \(id))"
        case .active(let anchor, let finger, _, let engaged): "second finger \(finger) on anchor \(anchor)\(engaged ? ", adjusting" : "")"
        case .cancelled(let reason) where reason != "Fingers landed together": "anchor gesture rejected: \(reason)"
        default: nil
        }
        if let anchorSummary {
            let changed = lastAnchor.withLock { last -> Bool in
                defer { last = anchorSummary }
                return last != anchorSummary
            }
            if changed { print("\(stamp())  ⚓︎ \(anchorSummary)") }
        }
        guard case .cancelled(let reason) = snapshot.phase, reason != "No gesture", reason != "Anchor gesture in progress" else { return }
        let changed = lastPhase.withLock { last -> Bool in
            defer { last = reason }
            return last != reason
        }
        if changed {
            print("\(stamp())  ·  cancelled: \(reason)")
        }
    }
}
engine.setMode(.diagnoseAll)
engine.setDiagnosticsRate(60)

do {
    try provider.start { frame in
        stats.withLock { stats in
            stats.frames += 1
            if !frame.touches.isEmpty {
                stats.touchFrames += 1
                stats.maxFingers = max(stats.maxFingers, frame.touches.count)
                if let last = stats.lastTouch, frame.timestamp - last < 0.1 {
                    stats.activeTime += frame.timestamp - last
                }
                stats.lastTouch = frame.timestamp
                for touch in frame.touches { stats.identifiers.insert(touch.id) }
            }
        }
        engine.ingest(frame)
    }
} catch {
    print("Failed to start: \(error.localizedDescription)")
    exit(1)
}

print("Listening for \(Int(duration))s. Perform gestures on the trackpad (no actions will run)…")
var usageStart = rusage()
getrusage(RUSAGE_SELF, &usageStart)
Thread.sleep(forTimeInterval: duration)
provider.stop()
Thread.sleep(forTimeInterval: 0.2)

var usageEnd = rusage()
getrusage(RUSAGE_SELF, &usageEnd)
func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
let cpu = seconds(usageEnd.ru_utime) - seconds(usageStart.ru_utime) + seconds(usageEnd.ru_stime) - seconds(usageStart.ru_stime)

let final = stats.withLock { $0 }
print("\n--- Summary ---")
print("Frames delivered: \(final.frames) (\(final.touchFrames) with contact)")
print("Max simultaneous fingers: \(final.maxFingers); distinct touch IDs seen: \(final.identifiers.count)")
print("Gestures recognized: \(final.gestures)")
print(String(format: "CPU time: %.3fs over %.0fs wall (%.2f%% average)", cpu, duration, cpu / duration * 100))
if final.activeTime > 0 {
    print(String(format: "Frame rate while touching: ~%.0f Hz (%.1fs of contact)", Double(final.touchFrames) / final.activeTime, final.activeTime))
}
