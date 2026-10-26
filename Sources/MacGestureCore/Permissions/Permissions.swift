import ApplicationServices
import CoreGraphics
import Foundation

public enum PermissionKind: String, Sendable, CaseIterable, Identifiable {
    /// Inspecting and moving other apps' windows.
    case accessibility
    /// Posting synthetic keyboard and media-key events. macOS lists this under
    /// Accessibility in System Settings.
    case postEvents

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .postEvents: "Accessibility (keyboard events)"
        }
    }

    public var explanation: String {
        switch self {
        case .accessibility:
            "Lets MacGesture find the focused window and move, resize, or minimize it."
        case .postEvents:
            "Lets MacGesture press keyboard shortcuts and media keys on your behalf when a gesture fires."
        }
    }

    public var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
}

public struct PermissionStatus: Sendable, Equatable {
    public var accessibility: Bool
    public var postEvents: Bool

    public init(accessibility: Bool, postEvents: Bool) {
        self.accessibility = accessibility
        self.postEvents = postEvents
    }

    public func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: accessibility
        case .postEvents: postEvents
        }
    }

    public var allGranted: Bool { accessibility && postEvents }
}

/// Reads and requests the privacy permissions MacGesture uses. Reading raw
/// trackpad frames needs no permission; acting on them does.
public enum PermissionChecker {
    public static func current() -> PermissionStatus {
        PermissionStatus(accessibility: AXIsProcessTrusted(), postEvents: CGPreflightPostEventAccess())
    }

    /// Shows the system prompt (once per app identity) and returns the current state.
    @discardableResult
    public static func request(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility:
            // The string value of kAXTrustedCheckOptionPrompt; the global is not
            // concurrency-safe to read in Swift 6.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .postEvents:
            return CGRequestPostEventAccess()
        }
    }
}
