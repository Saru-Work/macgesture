import Foundation

/// Which built-in trackpad gestures macOS currently has enabled, read from the
/// user's trackpad preferences. MacGesture can only observe touches; it can't
/// stop macOS from also responding, so overlaps are surfaced as warnings.
public struct SystemGestureSettings: Sendable, Hashable {
    public var threeFingerHorizontalSwipe = false
    public var threeFingerVerticalSwipe = false
    public var fourFingerHorizontalSwipe = false
    public var fourFingerVerticalSwipe = false
    public var fourFingerPinch = false
    public var fiveFingerPinch = false
    public var threeFingerTap = false
    public var threeFingerDrag = false

    public init() {}

    /// Assumes the macOS defaults when preferences can't be read.
    public static let assumedDefaults: SystemGestureSettings = {
        var settings = SystemGestureSettings()
        settings.threeFingerVerticalSwipe = true
        settings.fourFingerHorizontalSwipe = true
        settings.fourFingerVerticalSwipe = true
        settings.fourFingerPinch = true
        settings.fiveFingerPinch = true
        return settings
    }()

    /// Reads both the built-in and Bluetooth trackpad preference domains; a
    /// gesture counts as enabled if either domain enables it.
    public static func current() -> SystemGestureSettings {
        let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        func enabled(_ key: String) -> Bool? {
            var found: Bool?
            for domain in domains {
                guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber else { continue }
                found = (found ?? false) || value.intValue != 0
            }
            return found
        }
        let fallback = assumedDefaults
        var settings = SystemGestureSettings()
        settings.threeFingerHorizontalSwipe = enabled("TrackpadThreeFingerHorizSwipeGesture") ?? fallback.threeFingerHorizontalSwipe
        settings.threeFingerVerticalSwipe = enabled("TrackpadThreeFingerVertSwipeGesture") ?? fallback.threeFingerVerticalSwipe
        settings.fourFingerHorizontalSwipe = enabled("TrackpadFourFingerHorizSwipeGesture") ?? fallback.fourFingerHorizontalSwipe
        settings.fourFingerVerticalSwipe = enabled("TrackpadFourFingerVertSwipeGesture") ?? fallback.fourFingerVerticalSwipe
        settings.fourFingerPinch = enabled("TrackpadFourFingerPinchGesture") ?? fallback.fourFingerPinch
        settings.fiveFingerPinch = enabled("TrackpadFiveFingerPinchGesture") ?? fallback.fiveFingerPinch
        settings.threeFingerTap = enabled("TrackpadThreeFingerTapGesture") ?? fallback.threeFingerTap
        settings.threeFingerDrag = enabled("TrackpadThreeFingerDrag") ?? fallback.threeFingerDrag
        return settings
    }

    /// A description of the macOS gesture this trigger collides with, if any.
    public func overlap(with trigger: GestureTrigger) -> String? {
        let horizontal: Set<GestureDirection> = [.left, .right]
        let vertical: Set<GestureDirection> = [.up, .down]

        switch (trigger.fingers, trigger.kind) {
        case (_, .anchorSwipe):
            // Handled by scroll suppression while the gesture is active.
            return nil
        case (2, _):
            return "Two-finger gestures overlap scrolling, zooming, and rotating."
        case (3, .swipe), (3, .circle):
            if threeFingerDrag {
                return "Three-finger drag is on, so three-finger movement also drags windows and selects text."
            }
            guard trigger.kind == .swipe else { return nil }
            if threeFingerHorizontalSwipe, horizontal.contains(trigger.direction) {
                return "macOS also uses three-finger horizontal swipes (switching Spaces or pages)."
            }
            if threeFingerVerticalSwipe, vertical.contains(trigger.direction) {
                return "macOS also uses three-finger vertical swipes (Mission Control / App Exposé)."
            }
            if trigger.direction.isDiagonal, threeFingerHorizontalSwipe || threeFingerVerticalSwipe {
                return "Diagonal three-finger swipes can also trigger macOS's three-finger swipes."
            }
        case (4, .swipe):
            if fourFingerHorizontalSwipe, horizontal.contains(trigger.direction) {
                return "macOS also uses four-finger horizontal swipes (switching Spaces)."
            }
            if fourFingerVerticalSwipe, vertical.contains(trigger.direction) {
                return "macOS also uses four-finger vertical swipes (Mission Control / App Exposé)."
            }
            if trigger.direction.isDiagonal, fourFingerHorizontalSwipe || fourFingerVerticalSwipe {
                return "Diagonal four-finger swipes can also trigger macOS's four-finger swipes."
            }
        case (4, .pinch) where fourFingerPinch:
            return "macOS also uses four-finger pinches (Launchpad / Show Desktop)."
        case (5, .pinch) where fiveFingerPinch:
            return "macOS also uses five-finger pinches (Launchpad / Show Desktop)."
        case (3, .tap) where threeFingerTap:
            return "macOS uses three-finger tap for Look Up."
        default:
            break
        }
        return nil
    }
}
