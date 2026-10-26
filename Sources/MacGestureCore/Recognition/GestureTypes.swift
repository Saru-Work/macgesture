import Foundation

public enum GestureKind: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case swipe
    case tap
    case pinch
    case rotate
    case circle
    case hold
    /// One finger held still as an anchor while a second finger slides
    /// vertically. Continuous: fires repeatedly while the second finger moves.
    case anchorSwipe

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .swipe: "Swipe"
        case .tap: "Tap"
        case .pinch: "Pinch"
        case .rotate: "Rotate"
        case .circle: "Circle"
        case .hold: "Long Hold"
        case .anchorSwipe: "Anchor Finger + Vertical Swipe"
        }
    }

    /// Short form used inside trigger names.
    var shortName: String {
        self == .anchorSwipe ? "anchor swipe" : displayName.lowercased()
    }

    public var validDirections: [GestureDirection] {
        switch self {
        case .swipe: [.up, .down, .left, .right, .upLeft, .upRight, .downLeft, .downRight]
        case .pinch: [.pinchIn, .pinchOut]
        case .rotate, .circle: [.clockwise, .counterclockwise]
        case .tap, .hold: [.none]
        case .anchorSwipe: [.up, .down]
        }
    }

    /// Finger counts a trigger of this kind can use.
    public var allowedFingers: ClosedRange<Int> {
        self == .anchorSwipe ? 2...2 : Self.fingerRange
    }

    /// Continuous gestures report repeated updates during one touch cycle
    /// rather than firing once.
    public var isContinuous: Bool {
        self == .anchorSwipe
    }

    /// Two-finger pinch/rotate/swipe collide with scrolling and zooming, so
    /// rotation and pinch start at two, everything else at three by default
    /// in the editor; the recognizer itself accepts 2...5.
    public static let fingerRange = 2...5
}

public enum GestureDirection: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case none
    case up, down, left, right
    case upLeft, upRight, downLeft, downRight
    case pinchIn, pinchOut
    case clockwise, counterclockwise

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "—"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .upLeft: "Up-Left"
        case .upRight: "Up-Right"
        case .downLeft: "Down-Left"
        case .downRight: "Down-Right"
        case .pinchIn: "In"
        case .pinchOut: "Out"
        case .clockwise: "Clockwise"
        case .counterclockwise: "Counterclockwise"
        }
    }

    public var symbolName: String {
        switch self {
        case .none: "circle"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .upLeft: "arrow.up.left"
        case .upRight: "arrow.up.right"
        case .downLeft: "arrow.down.left"
        case .downRight: "arrow.down.right"
        case .pinchIn: "arrow.down.right.and.arrow.up.left"
        case .pinchOut: "arrow.up.left.and.arrow.down.right"
        case .clockwise: "arrow.clockwise"
        case .counterclockwise: "arrow.counterclockwise"
        }
    }

    public var isDiagonal: Bool {
        switch self {
        case .upLeft, .upRight, .downLeft, .downRight: true
        default: false
        }
    }

    /// Unit vector for swipe directions (y up), nil otherwise.
    public var unitVector: SIMD2<Double>? {
        let diagonal = 1 / 2.0.squareRoot()
        switch self {
        case .up: return SIMD2(0, 1)
        case .down: return SIMD2(0, -1)
        case .left: return SIMD2(-1, 0)
        case .right: return SIMD2(1, 0)
        case .upLeft: return SIMD2(-diagonal, diagonal)
        case .upRight: return SIMD2(diagonal, diagonal)
        case .downLeft: return SIMD2(-diagonal, -diagonal)
        case .downRight: return SIMD2(diagonal, -diagonal)
        default: return nil
        }
    }
}

/// What a mapping listens for: a gesture kind, finger count, and direction.
public struct GestureTrigger: Codable, Sendable, Hashable {
    public var kind: GestureKind
    public var fingers: Int
    public var direction: GestureDirection

    public init(kind: GestureKind, fingers: Int, direction: GestureDirection = .none) {
        self.kind = kind
        self.fingers = kind == .anchorSwipe ? 2 : fingers
        self.direction = kind.validDirections.contains(direction) ? direction : kind.validDirections[0]
    }

    public static func swipe(_ fingers: Int, _ direction: GestureDirection) -> Self { .init(kind: .swipe, fingers: fingers, direction: direction) }
    public static func tap(_ fingers: Int) -> Self { .init(kind: .tap, fingers: fingers) }
    public static func hold(_ fingers: Int) -> Self { .init(kind: .hold, fingers: fingers) }
    public static func pinch(_ fingers: Int, _ direction: GestureDirection) -> Self { .init(kind: .pinch, fingers: fingers, direction: direction) }
    public static func rotate(_ fingers: Int, _ direction: GestureDirection) -> Self { .init(kind: .rotate, fingers: fingers, direction: direction) }
    public static func circle(_ fingers: Int, _ direction: GestureDirection) -> Self { .init(kind: .circle, fingers: fingers, direction: direction) }
    public static func anchorSwipe(_ direction: GestureDirection) -> Self { .init(kind: .anchorSwipe, fingers: 2, direction: direction) }

    public var isValid: Bool {
        kind.allowedFingers.contains(fingers) && kind.validDirections.contains(direction)
    }

    public var displayName: String {
        let base = "\(fingers)-finger \(kind.shortName)"
        switch kind {
        case .tap, .hold: return base
        case .anchorSwipe: return "anchor finger + swipe \(direction.displayName.lowercased())"
        default: return "\(base) \(direction.displayName.lowercased())"
        }
    }
}

/// Measurements taken while recognizing a gesture, in physical units.
public struct GestureMetrics: Sendable, Hashable {
    public var fingers: Int = 0
    /// Centroid displacement in millimetres (y up).
    public var translation: SIMD2<Double> = .zero
    /// Ratio of current to initial finger spread.
    public var scale: Double = 1
    /// Mean finger rotation about the centroid in degrees, positive counterclockwise.
    public var rotation: Double = 0
    /// Accumulated heading change of the centroid path in degrees.
    public var turn: Double = 0
    /// Centroid path length in millimetres.
    public var pathLength: Double = 0
    /// Displacement divided by path length; 1 for a perfectly straight path.
    public var straightness: Double = 1
    /// Largest movement of any single finger since tracking began, in millimetres.
    public var maxFingerMovement: Double = 0
    /// Seconds since the current finger set settled.
    public var duration: TimeInterval = 0

    public init() {}
}

public struct GestureEvent: Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var trigger: GestureTrigger
    public var timestamp: TimeInterval
    public var source: InputSourceKind
    public var deviceID: UInt64
    /// How far past its threshold the gesture was when recognized (>= 1).
    public var score: Double
    public var metrics: GestureMetrics
    /// For continuous gestures: how many steps this update represents (≥ 1).
    public var magnitude = 1
    /// For continuous gestures: true for every update after the first in the
    /// same touch cycle.
    public var isContinuation = false

    public init(trigger: GestureTrigger, timestamp: TimeInterval, source: InputSourceKind, deviceID: UInt64, score: Double, metrics: GestureMetrics) {
        self.trigger = trigger
        self.timestamp = timestamp
        self.source = source
        self.deviceID = deviceID
        self.score = score
        self.metrics = metrics
    }
}

/// Recognizer state machine phases.
public enum RecognitionPhase: Sendable, Hashable {
    /// No fingers on the surface.
    case idle
    /// Fingers landed; waiting for the finger set to settle.
    case began(fingers: Int)
    /// Measuring motion against thresholds.
    case tracking(fingers: Int)
    /// A gesture fired; further motion is ignored until every finger lifts.
    case recognized(GestureTrigger)
    /// The cycle ended without a gesture, or was abandoned.
    case cancelled(reason: String)
    /// Fingers lifted after a recognized gesture.
    case completed(GestureTrigger)

    public var displayName: String {
        switch self {
        case .idle: "Idle"
        case .began(let fingers): "Began (\(fingers) fingers)"
        case .tracking(let fingers): "Tracking (\(fingers) fingers)"
        case .recognized(let trigger): "Recognized: \(trigger.displayName)"
        case .cancelled(let reason): "Cancelled: \(reason)"
        case .completed(let trigger): "Completed: \(trigger.displayName)"
        }
    }
}

/// Progress of each candidate toward its threshold (1.0 == fires).
public struct RecognitionProgress: Sendable, Hashable {
    public var swipe: Double = 0
    public var pinch: Double = 0
    public var rotate: Double = 0
    public var circle: Double = 0
    public var hold: Double = 0

    public init() {}
}
