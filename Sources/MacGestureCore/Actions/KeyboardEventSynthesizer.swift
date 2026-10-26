import AppKit
import CoreGraphics

/// Posts synthetic keyboard input through Quartz event services.
public enum KeyboardEventSynthesizer {
    /// Presses and releases a shortcut, including real modifier key events so
    /// that modifier-sensitive UI (like the ⌘⇥ app switcher) responds.
    public static func press(_ combo: KeyCombo) throws(ActionError) {
        guard CGPreflightPostEventAccess() else {
            throw .permissionRequired(.postEvents)
        }
        guard !KeyCodeNames.modifierKeyCodes.contains(combo.keyCode) else {
            throw .invalidConfiguration("A shortcut needs a non-modifier key.")
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw .executionFailed("Could not create a keyboard event source.")
        }

        var events: [CGEvent] = []
        var flags: CGEventFlags = []
        let modifierKeys = combo.modifiers.keyCodes
        for (modifier, keyCode) in modifierKeys {
            flags.formUnion(modifier.eventFlags)
            events.append(try makeEvent(source, keyCode, down: true, flags: flags))
        }

        let keyFlags = flags.union(combo.modifiers.eventFlags).union(combo.impliedFlags)
        events.append(try makeEvent(source, CGKeyCode(combo.keyCode), down: true, flags: keyFlags))
        events.append(try makeEvent(source, CGKeyCode(combo.keyCode), down: false, flags: keyFlags))

        for (modifier, keyCode) in modifierKeys.reversed() {
            flags.subtract(modifier.eventFlags)
            events.append(try makeEvent(source, keyCode, down: false, flags: flags))
        }

        for event in events {
            event.post(tap: .cghidEventTap)
        }
    }

    private static func makeEvent(_ source: CGEventSource, _ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) throws(ActionError) -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else {
            throw .executionFailed("Could not create a keyboard event.")
        }
        event.flags = flags
        return event
    }
}

/// Media keys are "system defined" events (NX_SYSDEFINED, subtype 8) carrying
/// an NX_KEYTYPE code; macOS routes them to the current Now Playing app.
public enum MediaKeyController {
    // From IOKit/hidsystem/ev_keymap.h.
    private static func keyType(for command: MediaCommand) -> Int {
        switch command {
        case .playPause: 16      // NX_KEYTYPE_PLAY
        case .nextTrack: 17      // NX_KEYTYPE_NEXT
        case .previousTrack: 18  // NX_KEYTYPE_PREVIOUS
        }
    }

    /// The keyboard's volume keys. macOS applies them to whatever output it
    /// can control, so they work as a fallback when Core Audio can't.
    public enum VolumeKey: Int, Sendable {
        case up = 0      // NX_KEYTYPE_SOUND_UP
        case down = 1    // NX_KEYTYPE_SOUND_DOWN
        case mute = 7    // NX_KEYTYPE_MUTE
    }

    @MainActor
    public static func send(_ command: MediaCommand) throws(ActionError) {
        try post(keyType(for: command))
    }

    @MainActor
    public static func send(_ key: VolumeKey) throws(ActionError) {
        try post(key.rawValue)
    }

    @MainActor
    private static func post(_ key: Int) throws(ActionError) {
        guard CGPreflightPostEventAccess() else {
            throw .permissionRequired(.postEvents)
        }
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (key << 16) | (state << 8),
                data2: -1
            ), let cgEvent = event.cgEvent else {
                throw .executionFailed("Could not create a media key event.")
            }
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}
