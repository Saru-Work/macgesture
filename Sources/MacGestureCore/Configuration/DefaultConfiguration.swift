import Foundation

/// Factory defaults. Enabled mappings deliberately avoid gestures macOS uses
/// out of the box (two-finger anything, 3/4-finger swipes in any direction,
/// 4/5-finger pinches), because MacGesture observes touches and cannot stop macOS from
/// also acting on them. Overlapping examples ship disabled.
public enum DefaultConfiguration {
    public static func make() -> AppConfiguration {
        let profile = defaultProfile()
        let browsing = GestureProfile(name: "Browsing", mappings: [
            GestureMapping(name: "Next tab", trigger: .rotate(3, .clockwise), action: .keyboardShortcut(combo: KeyCombo(keyCode: 30, modifiers: [.command, .shift]))),
            GestureMapping(name: "Previous tab", trigger: .rotate(3, .counterclockwise), action: .keyboardShortcut(combo: KeyCombo(keyCode: 33, modifiers: [.command, .shift]))),
            GestureMapping(name: "Reopen closed tab", trigger: .circle(3, .counterclockwise), action: .keyboardShortcut(combo: KeyCombo(keyCode: 17, modifiers: [.command, .shift]))),
            GestureMapping(name: "New tab", trigger: .tap(4), action: .keyboardShortcut(combo: KeyCombo(keyCode: 17, modifiers: .command))),
        ] + anchorVolumeMappings())
        return AppConfiguration(profiles: [profile, browsing], activeProfileID: profile.id)
    }

    public static func defaultProfile() -> GestureProfile {
        GestureProfile(name: "Default", mappings: [
            GestureMapping(name: "Play/Pause", trigger: .tap(4), action: .media(command: .playPause)),
            GestureMapping(name: "Volume up", trigger: .rotate(3, .clockwise), action: .volume(command: .up(step: VolumeCommand.defaultStep))),
            GestureMapping(name: "Volume down", trigger: .rotate(3, .counterclockwise), action: .volume(command: .down(step: VolumeCommand.defaultStep))),
            GestureMapping(name: "Maximize window", trigger: .pinch(3, .pinchOut), action: .window(command: .maximize)),
            GestureMapping(name: "Minimize window", trigger: .pinch(3, .pinchIn), action: .window(command: .minimize)),
            GestureMapping(name: "Next track", trigger: .circle(3, .clockwise), action: .media(command: .nextTrack)),
            GestureMapping(name: "Previous track", trigger: .circle(3, .counterclockwise), action: .media(command: .previousTrack)),
            GestureMapping(name: "Mission Control", trigger: .hold(4), action: .system(feature: .missionControl)),
        ] + anchorVolumeMappings() + [
            // Overlap with macOS's default 3/4-finger swipes; enable after turning
            // those off in System Settings ▸ Trackpad ▸ More Gestures.
            GestureMapping(name: "Window to left half", isEnabled: false, trigger: .swipe(4, .left), action: .window(command: .leftHalf)),
            GestureMapping(name: "Window to right half", isEnabled: false, trigger: .swipe(4, .right), action: .window(command: .rightHalf)),
            GestureMapping(name: "Browser back", isEnabled: false, trigger: .swipe(3, .left), action: .keyboardShortcut(combo: KeyCombo(keyCode: 33, modifiers: .command))),
            GestureMapping(name: "Browser forward", isEnabled: false, trigger: .swipe(3, .right), action: .keyboardShortcut(combo: KeyCombo(keyCode: 30, modifiers: .command))),
        ])
    }

    /// Volume per anchor-swipe step. With the default 1.5 mm step, sliding
    /// the full height of a MacBook trackpad covers about 0–100%.
    public static let anchorVolumeStep = 0.02

    /// "Anchor finger + vertical swipe" adjusts the output volume.
    public static func anchorVolumeMappings() -> [GestureMapping] {
        [
            GestureMapping(name: "Volume slider up", trigger: .anchorSwipe(.up), action: .volume(command: .up(step: anchorVolumeStep))),
            GestureMapping(name: "Volume slider down", trigger: .anchorSwipe(.down), action: .volume(command: .down(step: anchorVolumeStep))),
        ]
    }
}
