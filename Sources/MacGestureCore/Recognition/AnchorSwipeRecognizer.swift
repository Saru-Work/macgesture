import Foundation
import simd

/// What the anchor recognizer currently sees, for diagnostics and live testing.
public enum AnchorSwipeState: Sendable, Hashable {
    case idle
    /// One finger is down but hasn't rested long enough to be an anchor.
    case anchorCandidate(anchorID: Int)
    /// The anchor is established; waiting for a second finger.
    case anchored(anchorID: Int)
    /// A second finger is down. `travel` is its vertical movement in mm
    /// (y up); `engaged` once it has left the dead zone.
    case active(anchorID: Int, fingerID: Int, travel: Double, engaged: Bool)
    /// The sequence was rejected; nothing happens until every finger lifts.
    case cancelled(reason: String)

    public var anchorID: Int? {
        switch self {
        case .anchorCandidate(let id), .anchored(let id), .active(let id, _, _, _): id
        default: nil
        }
    }

    public var movingFingerID: Int? {
        if case .active(_, let id, _, _) = self { return id }
        return nil
    }

    public var displayName: String {
        switch self {
        case .idle: "Idle"
        case .anchorCandidate: "Finger down; hold still to anchor"
        case .anchored: "Anchor held; add a second finger"
        case .active(_, _, let travel, let engaged):
            engaged ? String(format: "Adjusting (%+.1f mm)", travel) : String(format: "Second finger down (%+.1f mm, in dead zone)", travel)
        case .cancelled(let reason): "Cancelled: \(reason)"
        }
    }
}

/// Recognizes "hold one finger still, slide a second finger vertically".
///
/// The anchor is identified by the backend's stable touch identifier, never
/// by array position. Any change of identity, a third finger, two fingers
/// landing together (a normal two-finger scroll), or anchor movement beyond
/// the tolerance rejects the sequence until all fingers lift.
///
/// While the second finger moves, the recognizer emits `anchorSwipe(up/down)`
/// events. Each event's `magnitude` is the number of `anchorStepDistance`
/// steps travelled since the previous event; events are at most one per
/// `anchorUpdateInterval`, with intermediate steps combined.
public struct AnchorSwipeRecognizer: Sendable {
    public var settings: RecognitionSettings
    public var armed: ArmedGestures
    public private(set) var state = AnchorSwipeState.idle

    private var anchorID = 0
    private var anchorOrigin = SIMD2<Double>.zero
    private var anchorSince: TimeInterval = 0
    private var anchorEstablished = false
    private var lastTime: TimeInterval?
    private var stroke: Stroke?
    /// Set when a second finger lands on an anchor; kept until every finger
    /// lifts, even if the gesture is cancelled, so scrolling stays blocked
    /// and no other gesture fires from the rest of the motion.
    private var ownsCycle = false

    private struct Stroke {
        var fingerID: Int
        var startTime: TimeInterval
        var originY: Double
        var filteredY: Double
        var referenceY: Double
        var engaged = false
        var lastDirection: GestureDirection?
        var lastEmit = -Double.infinity
        var emitted = false
    }

    public init(settings: RecognitionSettings = RecognitionSettings(), armed: ArmedGestures = .everything) {
        self.settings = settings
        self.armed = armed
    }

    /// True from the moment a second finger lands on an anchor until every
    /// finger lifts: this touch cycle belongs to the anchor gesture.
    public var claimsCycle: Bool {
        ownsCycle
    }

    public mutating func reset() {
        state = .idle
        stroke = nil
        lastTime = nil
        anchorEstablished = false
        ownsCycle = false
    }

    /// - Parameter mayActivate: false when another gesture already fired in
    ///   this touch cycle, so the anchor gesture must not start.
    public mutating func process(_ frame: TouchFrame, mayActivate: Bool = true) -> GestureEvent? {
        let time = frame.timestamp
        if let lastTime, time - lastTime > settings.frameGapReset {
            reset()
        }
        lastTime = time

        let surface = frame.device.surfaceSize
        var contacts: [(id: Int, position: SIMD2<Double>, normalizedY: Double)] = []
        contacts.reserveCapacity(frame.touches.count)
        for touch in frame.touches where settings.maximumContactSize <= 0 || touch.size <= settings.maximumContactSize {
            contacts.append((touch.id, touch.position * surface, touch.position.y))
        }

        guard !contacts.isEmpty else {
            // Every finger lifted: the cycle is over.
            reset()
            lastTime = time
            return nil
        }

        switch state {
        case .cancelled:
            return nil

        case .idle:
            guard contacts.count == 1 else {
                state = .cancelled(reason: "Fingers landed together")
                return nil
            }
            if contacts[0].normalizedY < settings.anchorExcludedBottomFraction {
                state = .cancelled(reason: "Anchor in the resting-thumb zone")
                return nil
            }
            anchorID = contacts[0].id
            anchorOrigin = contacts[0].position
            anchorSince = time
            anchorEstablished = false
            state = .anchorCandidate(anchorID: anchorID)
            return nil

        case .anchorCandidate, .anchored, .active:
            guard let anchor = contacts.first(where: { $0.id == anchorID }) else {
                return cancel(stroke == nil ? "Anchor lifted before a second finger" : "Anchor lifted")
            }
            if simd_length(anchor.position - anchorOrigin) > settings.anchorMovementTolerance {
                return cancel("Anchor moved")
            }
            if contacts.count > 2 {
                return cancel("Too many fingers")
            }
            if !anchorEstablished, time - anchorSince >= settings.anchorMinimumHold {
                anchorEstablished = true
            }
            let other = contacts.first { $0.id != anchorID }
            return advance(time: time, other: other.map { ($0.id, $0.position.y) }, frame: frame, mayActivate: mayActivate)
        }
    }

    private mutating func advance(time: TimeInterval, other: (id: Int, y: Double)?, frame: TouchFrame, mayActivate: Bool) -> GestureEvent? {
        guard let other else {
            // Only the anchor is down. If a stroke was running, its finger
            // lifted: stop immediately and wait for another stroke.
            stroke = nil
            state = anchorEstablished ? .anchored(anchorID: anchorID) : .anchorCandidate(anchorID: anchorID)
            return nil
        }

        guard var current = stroke else {
            guard anchorEstablished else {
                return cancel("Second finger arrived too soon")
            }
            guard mayActivate else {
                return cancel("Another gesture already fired")
            }
            stroke = Stroke(fingerID: other.id, startTime: time, originY: other.y, filteredY: other.y, referenceY: other.y)
            ownsCycle = true
            state = .active(anchorID: anchorID, fingerID: other.id, travel: 0, engaged: false)
            return nil
        }

        guard current.fingerID == other.id else {
            return cancel("Finger identity changed")
        }

        // Light smoothing absorbs sensor jitter without noticeable lag at ~90 Hz.
        current.filteredY += (other.y - current.filteredY) * 0.5
        let travel = current.filteredY - current.originY
        defer {
            stroke = current
            state = .active(anchorID: anchorID, fingerID: current.fingerID, travel: travel, engaged: current.engaged)
        }

        if !current.engaged {
            guard abs(travel) >= settings.anchorDeadZone else { return nil }
            // Start measuring from here so leaving the dead zone doesn't jump.
            current.engaged = true
            current.referenceY = current.filteredY
            return nil
        }

        var delta = current.filteredY - current.referenceY
        let direction: GestureDirection = delta >= 0 ? .up : .down
        let trigger = GestureTrigger.anchorSwipe(direction)
        let step = settings.anchorStepDistance * armed.thresholdScale(for: trigger)
        guard step > 0 else { return nil }

        if let last = current.lastDirection, last != direction {
            // Reversing needs a little extra travel so tremor can't flip-flop.
            guard abs(delta) >= step + settings.anchorReversalHysteresis else { return nil }
            current.referenceY += direction == .up ? settings.anchorReversalHysteresis : -settings.anchorReversalHysteresis
            delta = current.filteredY - current.referenceY
        }

        let steps = Int(abs(delta) / step)
        guard steps > 0, time - current.lastEmit >= settings.anchorUpdateInterval else { return nil }

        current.referenceY += (direction == .up ? 1 : -1) * Double(steps) * step
        current.lastDirection = direction
        current.lastEmit = time

        guard armed.isArmed(trigger) else { return nil }
        var metrics = GestureMetrics()
        metrics.fingers = 2
        metrics.translation = SIMD2(0, travel)
        metrics.duration = time - current.startTime
        var event = GestureEvent(trigger: trigger, timestamp: time, source: frame.source, deviceID: frame.device.id, score: Double(steps), metrics: metrics)
        event.magnitude = steps
        event.isContinuation = current.emitted
        current.emitted = true
        return event
    }

    private mutating func cancel(_ reason: String) -> GestureEvent? {
        state = .cancelled(reason: reason)
        stroke = nil
        return nil
    }
}
