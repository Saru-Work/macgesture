import AppKit
import CMultitouchBridge

public enum HapticStrength: Sendable, Equatable {
    case weak, medium, strong
}

/// Clicks on the trackpad's Taptic Engine.
///
/// - Important: Uses the PRIVATE MTActuator API from MultitouchSupport,
///   because the public `NSHapticFeedbackManager` only reliably plays for the
///   active app, and MacGesture runs in the background. If the actuator is
///   unavailable, the public API is tried as a best-effort fallback.
public enum TrackpadHaptics {
    /// Returns true if the trackpad actuator played the click.
    @MainActor
    @discardableResult
    public static func play(_ strength: HapticStrength) -> Bool {
        let id: Int32 = switch strength {
        case .weak: MG_HAPTIC_WEAK
        case .medium: MG_HAPTIC_MEDIUM
        case .strong: MG_HAPTIC_STRONG
        }
        if MGBridgeActuate(id) == MG_BRIDGE_OK {
            return true
        }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = strength == .weak ? .alignment : .levelChange
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        return false
    }
}

/// When gestures that change the volume click the trackpad.
public enum VolumeHapticMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    /// A firm click on reaching 0% or 100%.
    case limits
    /// A light click when the gesture takes hold, plus the limit clicks.
    case startAndLimits
    /// A light click each time the level crosses a 10% mark, plus the limit
    /// clicks. (Stored as "everyStep" for compatibility.)
    case everyStep

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .limits: "At 0% and 100%"
        case .startAndLimits: "When it starts, and at 0% and 100%"
        case .everyStep: "Every 10%"
        }
    }
}

/// Decides when a volume change deserves a click. By default the level clicks
/// like a dial with a detent every 10%, with a firmer click at 0% and 100%;
/// continuing to push past a limit stays quiet. Detent clicks are rate-limited.
public struct VolumeHapticFeedback: Sendable {
    public var mode: VolumeHapticMode
    /// Detents across the range: 10 means one every 10%.
    public var divisions = 10
    public var minimumInterval: TimeInterval = 0.035

    private var lastDetent: Int?
    private var awaitingStart = true
    private var lastClick = -Double.infinity

    public init(mode: VolumeHapticMode = .everyStep) {
        self.mode = mode
    }

    /// Call at the start of each gesture.
    public mutating func reset() {
        lastDetent = nil
        awaitingStart = true
    }

    public mutating func feedback(forLevel level: Double, at time: TimeInterval) -> HapticStrength? {
        guard mode != .off else { return nil }
        let clamped = min(max(level, 0), 1)
        let atLimit = clamped <= 0.0001 || clamped >= 0.9999
        // The epsilon keeps 0.6 (stored as 0.5999…) on the 60% detent.
        let detent = atLimit ? (clamped < 0.5 ? -1 : divisions + 1) : Int(clamped * Double(divisions) + 1e-6)
        let previous = lastDetent
        let isStart = awaitingStart
        lastDetent = detent
        awaitingStart = false

        if atLimit, detent != previous {
            return click(.medium, at: time, rateLimited: false)
        }
        switch mode {
        case .off, .limits:
            return nil
        case .startAndLimits:
            return isStart ? click(.weak, at: time, rateLimited: false) : nil
        case .everyStep:
            // Only crossings count; the first update of a gesture just sets the baseline.
            guard let previous, detent != previous else { return nil }
            return click(.weak, at: time, rateLimited: true)
        }
    }

    private mutating func click(_ strength: HapticStrength, at time: TimeInterval, rateLimited: Bool) -> HapticStrength? {
        if rateLimited, time - lastClick < minimumInterval { return nil }
        lastClick = time
        return strength
    }
}
