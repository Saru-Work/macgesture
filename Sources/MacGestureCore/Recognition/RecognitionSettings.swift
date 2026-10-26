import Foundation

/// Thresholds for the recognizer. Distances are physical millimetres so they
/// behave the same on differently sized trackpads.
public struct RecognitionSettings: Codable, Sendable, Hashable {
    /// 0 = least sensitive (thresholds doubled), 1 = most sensitive (halved).
    public var sensitivity: Double = 0.5

    public var swipeDistance: Double = 14
    /// Rejects wandering paths as swipes; 1 means perfectly straight.
    public var swipeMinimumStraightness: Double = 0.75
    /// Degrees either side of a 45° line that count as diagonal (when diagonal
    /// swipes are mapped).
    public var diagonalTolerance: Double = 15

    /// Fractional change in finger spread for a pinch.
    public var pinchThreshold: Double = 0.22
    public var rotationThreshold: Double = 25

    public var circleMinimumTurn: Double = 300
    public var circleMinimumRadius: Double = 4

    public var tapMaximumDuration: TimeInterval = 0.25
    public var tapMaximumMovement: Double = 3

    public var holdDuration: TimeInterval = 0.6
    public var holdMaximumMovement: Double = 2.5

    /// Time a new finger set must be stable before motion counts.
    public var settleDuration: TimeInterval = 0.04
    /// Longer settle after a finger lifts, so staggered lifts don't register
    /// as a gesture with fewer fingers.
    public var liftSettleDuration: TimeInterval = 0.1
    /// The winning candidate must lead the runner-up by this ratio.
    public var dominanceRatio: Double = 1.3
    /// Contacts larger than this are treated as palms and ignored (0 disables).
    public var maximumContactSize: Double = 2.5
    /// Resting hands that never gesture are abandoned after this long.
    public var maximumSessionDuration: TimeInterval = 8
    /// A gap in frames longer than this starts a new cycle.
    public var frameGapReset: TimeInterval = 0.3

    // MARK: Anchor finger + vertical swipe

    /// The anchor must rest alone this long before a second finger arrives.
    /// Ordinary two-finger scrolls land both fingers almost together.
    public var anchorMinimumHold: TimeInterval = 0.2
    /// The anchor may drift this far before the gesture is cancelled.
    public var anchorMovementTolerance: Double = 4
    /// Vertical travel of the second finger before adjustments begin.
    public var anchorDeadZone: Double = 3
    /// Vertical travel per adjustment step. Smaller is more sensitive.
    public var anchorStepDistance: Double = 1.5
    /// Extra travel needed to reverse direction, absorbing tremor.
    public var anchorReversalHysteresis: Double = 0.6
    /// Minimum time between updates; steps in between are combined.
    public var anchorUpdateInterval: TimeInterval = 0.03
    /// Anchors in this bottom fraction of the trackpad are ignored, where a
    /// thumb typically rests (0 disables).
    public var anchorExcludedBottomFraction: Double = 0.12

    public init() {}

    /// Multiplier applied to movement thresholds for a given sensitivity.
    public static func thresholdScale(forSensitivity sensitivity: Double) -> Double {
        pow(2, (0.5 - min(max(sensitivity, 0), 1)) * 2)
    }

    public var thresholdScale: Double {
        Self.thresholdScale(forSensitivity: sensitivity)
    }
}

extension RecognitionSettings {
    // Tolerant decoding: missing keys fall back to defaults so configuration
    // files written by older builds keep loading after new settings are added.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RecognitionSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        sensitivity = try value(.sensitivity, defaults.sensitivity)
        swipeDistance = try value(.swipeDistance, defaults.swipeDistance)
        swipeMinimumStraightness = try value(.swipeMinimumStraightness, defaults.swipeMinimumStraightness)
        diagonalTolerance = try value(.diagonalTolerance, defaults.diagonalTolerance)
        pinchThreshold = try value(.pinchThreshold, defaults.pinchThreshold)
        rotationThreshold = try value(.rotationThreshold, defaults.rotationThreshold)
        circleMinimumTurn = try value(.circleMinimumTurn, defaults.circleMinimumTurn)
        circleMinimumRadius = try value(.circleMinimumRadius, defaults.circleMinimumRadius)
        tapMaximumDuration = try value(.tapMaximumDuration, defaults.tapMaximumDuration)
        tapMaximumMovement = try value(.tapMaximumMovement, defaults.tapMaximumMovement)
        holdDuration = try value(.holdDuration, defaults.holdDuration)
        holdMaximumMovement = try value(.holdMaximumMovement, defaults.holdMaximumMovement)
        settleDuration = try value(.settleDuration, defaults.settleDuration)
        liftSettleDuration = try value(.liftSettleDuration, defaults.liftSettleDuration)
        dominanceRatio = try value(.dominanceRatio, defaults.dominanceRatio)
        maximumContactSize = try value(.maximumContactSize, defaults.maximumContactSize)
        maximumSessionDuration = try value(.maximumSessionDuration, defaults.maximumSessionDuration)
        frameGapReset = try value(.frameGapReset, defaults.frameGapReset)
        anchorMinimumHold = try value(.anchorMinimumHold, defaults.anchorMinimumHold)
        anchorMovementTolerance = try value(.anchorMovementTolerance, defaults.anchorMovementTolerance)
        anchorDeadZone = try value(.anchorDeadZone, defaults.anchorDeadZone)
        anchorStepDistance = try value(.anchorStepDistance, defaults.anchorStepDistance)
        anchorReversalHysteresis = try value(.anchorReversalHysteresis, defaults.anchorReversalHysteresis)
        anchorUpdateInterval = try value(.anchorUpdateInterval, defaults.anchorUpdateInterval)
        anchorExcludedBottomFraction = try value(.anchorExcludedBottomFraction, defaults.anchorExcludedBottomFraction)
    }
}
