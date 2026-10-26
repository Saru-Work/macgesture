import AppKit
import Foundation

/// Reads the user's configured system shortcuts (System Settings ▸ Keyboard ▸
/// Keyboard Shortcuts) so MacGesture posts the shortcut that is actually
/// bound, and can tell when one is turned off.
public enum SymbolicHotKeys {
    public enum Lookup: Equatable, Sendable {
        case enabled(KeyCombo)
        case disabled
    }

    /// IDs in com.apple.symbolichotkeys and the macOS default bindings.
    public static func defaults(for feature: SystemFeature) -> (id: Int, combo: KeyCombo)? {
        switch feature {
        case .missionControl: (32, KeyCombo(keyCode: 126, modifiers: .control))
        case .applicationWindows: (33, KeyCombo(keyCode: 125, modifiers: .control))
        case .showDesktop: (36, KeyCombo(keyCode: 103, modifiers: []))
        case .moveSpaceLeft: (79, KeyCombo(keyCode: 123, modifiers: .control))
        case .moveSpaceRight: (81, KeyCombo(keyCode: 124, modifiers: .control))
        case .spotlight: (64, KeyCombo(keyCode: 49, modifiers: .command))
        case .appsLauncher: nil
        }
    }

    public static func lookup(_ feature: SystemFeature) -> Lookup? {
        guard let (id, fallback) = defaults(for: feature) else { return nil }
        let table = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        guard let entry = table?[String(id)] as? [String: Any] else {
            return .enabled(fallback)
        }
        if let enabled = entry["enabled"] as? Bool, !enabled {
            return .disabled
        }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int], parameters.count == 3,
              parameters[1] >= 0, parameters[1] < 0xFFFF else {
            return .enabled(fallback)
        }
        return .enabled(KeyCombo(keyCode: UInt16(parameters[1]), modifiers: modifiers(fromHotKeyFlags: parameters[2])))
    }

    /// The plist stores NSEvent.ModifierFlags raw values.
    static func modifiers(fromHotKeyFlags flags: Int) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags & 0x20000 != 0 { result.insert(.shift) }
        if flags & 0x40000 != 0 { result.insert(.control) }
        if flags & 0x80000 != 0 { result.insert(.option) }
        if flags & 0x100000 != 0 { result.insert(.command) }
        return result
    }
}

public enum SystemFeatureController {
    @MainActor
    public static func trigger(_ feature: SystemFeature) async throws(ActionError) -> String {
        switch feature {
        case .missionControl:
            try await openSystemApp(["/System/Applications/Mission Control.app"])
            return "Opened Mission Control"
        case .appsLauncher:
            try await openSystemApp(["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"])
            return "Opened Apps"
        default:
            switch SymbolicHotKeys.lookup(feature) {
            case .enabled(let combo):
                try KeyboardEventSynthesizer.press(combo)
                return "\(feature.displayName) (\(combo.displayName))"
            case .disabled:
                throw .unsupported("The “\(feature.displayName)” shortcut is turned off in System Settings ▸ Keyboard ▸ Keyboard Shortcuts.")
            case nil:
                throw .unsupported("\(feature.displayName) has no shortcut to post.")
            }
        }
    }

    @MainActor
    private static func openSystemApp(_ candidates: [String]) async throws(ActionError) {
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw .unsupported("This feature isn't available on this version of macOS.")
        }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw .executionFailed(error.localizedDescription)
        }
    }
}
