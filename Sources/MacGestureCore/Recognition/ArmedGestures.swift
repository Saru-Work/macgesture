import Foundation

/// The set of gestures the recognizer should produce, derived from the
/// enabled mappings. Knowing what is armed lets the recognizer disambiguate:
/// circles delay swipes until lift, diagonals are only split out when mapped,
/// and holds only fire when something is listening for them.
public struct ArmedGestures: Sendable, Equatable {
    /// Arms every gesture with default thresholds, for live diagnostics.
    public static let everything = ArmedGestures(armsEverything: true)
    public static let nothing = ArmedGestures(armsEverything: false)

    public let armsEverything: Bool
    /// Trigger -> threshold multiplier relative to the global sensitivity.
    private var scales: [GestureTrigger: Double] = [:]
    private var kindsByFingers: [Int: Set<GestureKind>] = [:]
    private var diagonalFingers: Set<Int> = []
    private var anchorSwipe = false

    private init(armsEverything: Bool) {
        self.armsEverything = armsEverything
    }

    public init(triggers: [GestureTrigger: Double]) {
        armsEverything = false
        for (trigger, scale) in triggers where trigger.isValid {
            scales[trigger] = scale
            // The anchor gesture has its own recognizer; the regular one
            // shouldn't start evaluating two-finger motion because of it.
            if trigger.kind == .anchorSwipe {
                anchorSwipe = true
                continue
            }
            kindsByFingers[trigger.fingers, default: []].insert(trigger.kind)
            if trigger.kind == .swipe, trigger.direction.isDiagonal {
                diagonalFingers.insert(trigger.fingers)
            }
        }
    }

    public var isEmpty: Bool {
        !armsEverything && scales.isEmpty
    }

    public func isArmed(_ trigger: GestureTrigger) -> Bool {
        armsEverything || scales[trigger] != nil
    }

    public func hasArmed(_ kind: GestureKind, fingers: Int) -> Bool {
        armsEverything || kindsByFingers[fingers]?.contains(kind) == true
    }

    public func hasAnyArmed(fingers: Int) -> Bool {
        armsEverything || kindsByFingers[fingers]?.isEmpty == false
    }

    public var armsAnchorSwipe: Bool {
        armsEverything || anchorSwipe
    }

    public func allowsDiagonalSwipes(fingers: Int) -> Bool {
        armsEverything || diagonalFingers.contains(fingers)
    }

    /// Threshold multiplier for a specific trigger (1 when not overridden).
    public func thresholdScale(for trigger: GestureTrigger) -> Double {
        scales[trigger] ?? 1
    }
}
