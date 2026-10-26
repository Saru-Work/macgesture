import CoreGraphics
import Foundation

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)

    public var eventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// Modifier glyphs in Apple's canonical order.
    public var symbols: String {
        var result = ""
        if contains(.function) { result += "fn " }
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }

    /// Virtual key codes of the left-hand modifier keys, in press order.
    var keyCodes: [(KeyModifiers, CGKeyCode)] {
        var codes: [(KeyModifiers, CGKeyCode)] = []
        if contains(.control) { codes.append((.control, 59)) }
        if contains(.option) { codes.append((.option, 58)) }
        if contains(.shift) { codes.append((.shift, 56)) }
        if contains(.command) { codes.append((.command, 55)) }
        return codes
    }
}

/// A keyboard shortcut as a virtual key code plus modifiers. Key codes are
/// layout-independent physical keys (ANSI positions).
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, modifiers: KeyModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var displayName: String {
        modifiers.symbols + KeyCodeNames.name(for: keyCode)
    }

    /// Arrow, navigation, and function keys carry the fn flag (and arrows the
    /// keypad flag) when typed on real hardware; some consumers, including the
    /// Dock's Spaces shortcuts, ignore synthetic events without them.
    var impliedFlags: CGEventFlags {
        switch keyCode {
        case 123...126: [.maskSecondaryFn, .maskNumericPad]
        case 115, 116, 119, 121, 117: .maskSecondaryFn
        case _ where KeyCodeNames.functionKeys.values.contains(keyCode): .maskSecondaryFn
        default: []
        }
    }
}

public enum KeyCodeNames {
    static let functionKeys: [String: UInt16] = [
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100,
        "F9": 101, "F10": 109, "F11": 103, "F12": 111, "F13": 105, "F14": 107, "F15": 113,
        "F16": 106, "F17": 64, "F18": 79, "F19": 80, "F20": 90,
    ]

    private static let names: [UInt16: String] = {
        var table: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
            29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
            47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 117: "⌦",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /",
            76: "Keypad ↩", 78: "Keypad -", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1",
            84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
            89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
        ]
        for (name, code) in functionKeys {
            table[code] = name
        }
        return table
    }()

    public static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    /// Codes of keys that are modifiers on their own and can't be a shortcut's main key.
    public static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
}

/// Common shortcuts offered as one-click presets in the editor.
public struct KeyboardPreset: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let combo: KeyCombo

    public static let all: [KeyboardPreset] = [
        KeyboardPreset(name: "Switch to Previous App", combo: KeyCombo(keyCode: 48, modifiers: .command)),
        KeyboardPreset(name: "Next Window of App", combo: KeyCombo(keyCode: 50, modifiers: .command)),
        KeyboardPreset(name: "Next Tab", combo: KeyCombo(keyCode: 30, modifiers: [.command, .shift])),
        KeyboardPreset(name: "Previous Tab", combo: KeyCombo(keyCode: 33, modifiers: [.command, .shift])),
        KeyboardPreset(name: "Back", combo: KeyCombo(keyCode: 33, modifiers: .command)),
        KeyboardPreset(name: "Forward", combo: KeyCombo(keyCode: 30, modifiers: .command)),
        KeyboardPreset(name: "New Tab", combo: KeyCombo(keyCode: 17, modifiers: .command)),
        KeyboardPreset(name: "Close Tab or Window", combo: KeyCombo(keyCode: 13, modifiers: .command)),
        KeyboardPreset(name: "Reopen Closed Tab", combo: KeyCombo(keyCode: 17, modifiers: [.command, .shift])),
        KeyboardPreset(name: "Reload", combo: KeyCombo(keyCode: 15, modifiers: .command)),
        KeyboardPreset(name: "Hide App", combo: KeyCombo(keyCode: 4, modifiers: .command)),
        KeyboardPreset(name: "Copy", combo: KeyCombo(keyCode: 8, modifiers: .command)),
        KeyboardPreset(name: "Paste", combo: KeyCombo(keyCode: 9, modifiers: .command)),
        KeyboardPreset(name: "Undo", combo: KeyCombo(keyCode: 6, modifiers: .command)),
        KeyboardPreset(name: "Screenshot Selection", combo: KeyCombo(keyCode: 21, modifiers: [.command, .shift])),
        KeyboardPreset(name: "Screenshot Toolbar", combo: KeyCombo(keyCode: 23, modifiers: [.command, .shift])),
        KeyboardPreset(name: "Lock Screen", combo: KeyCombo(keyCode: 12, modifiers: [.command, .control])),
    ]
}
