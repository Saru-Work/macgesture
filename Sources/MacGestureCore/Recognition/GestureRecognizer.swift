import Foundation
import simd

/// Turns a stream of touch frames from one device into discrete gestures.
///
/// One recognition cycle runs from the first finger landing until every
/// finger lifts. Each cycle produces at most one gesture:
///
///     idle → began → tracking → recognized → completed
///                        ↘ cancelled (unmapped, ambiguous, timed out)
///
/// Continuous gestures (swipe, pinch, rotate, circle, hold) fire as soon as
/// they cross their threshold; taps fire on lift. All geometry is computed in
/// millimetres, independent of how the frames were produced.
public struct GestureRecognizer: Sendable {
    public var settings: RecognitionSettings
    public var armed: ArmedGestures

    public private(set) var phase: RecognitionPhase = .idle
    public private(set) var metrics = GestureMetrics()
    public private(set) var progress = RecognitionProgress()

    private var session: Session?
    /// Reused per frame to avoid allocating.
    private var contacts: [Contact] = []

    /// Below this initial spread, pinch and rotation are too noisy to measure.
    private static let minimumSpread = 3.0
    /// Centroid steps shorter than this are ignored when following the path,
    /// so sensor jitter doesn't accumulate as turning.
    private static let pathStep = 1.0

    public init(settings: RecognitionSettings = RecognitionSettings(), armed: ArmedGestures = .everything) {
        self.settings = settings
        self.armed = armed
        contacts.reserveCapacity(8)
    }

    /// Abandons the current cycle, e.g. when input stops or the device sleeps.
    public mutating func reset() {
        session = nil
        phase = .idle
        metrics = GestureMetrics()
        progress = RecognitionProgress()
    }

    /// Whether a gesture already fired in the current touch cycle.
    public var hasRecognizedInCycle: Bool {
        if case .recognized = session?.resolution { return true }
        return false
    }

    /// Gives up the current cycle because another recognizer claimed it.
    /// Nothing fires until every finger lifts.
    public mutating func cancelCycle(reason: String) {
        guard var current = session, current.resolution == nil else { return }
        cancel(&current, reason: reason)
        session = current
    }

    public mutating func process(_ frame: TouchFrame) -> GestureEvent? {
        let surface = frame.device.surfaceSize
        contacts.removeAll(keepingCapacity: true)
        for touch in frame.touches where settings.maximumContactSize <= 0 || touch.size <= settings.maximumContactSize {
            contacts.append(Contact(id: touch.id, position: touch.position * surface))
        }

        if let existing = session, frame.timestamp - existing.lastTime > settings.frameGapReset {
            // The lift was never reported; don't let a stale cycle leak into this one.
            session = nil
            phase = .cancelled(reason: "Input gap")
        }

        guard !contacts.isEmpty else {
            return finishCycle(frame)
        }

        var current = session ?? beginCycle(at: frame.timestamp)
        let event = advance(&current, frame: frame)
        session = current
        return event
    }

    // MARK: - Cycle lifecycle

    private mutating func beginCycle(at time: TimeInterval) -> Session {
        var new = Session(startTime: time, lastTime: time)
        new.fingers = contacts.map { Finger(id: $0.id, position: $0.position) }
        new.peakFingers = contacts.count
        rebaseline(&new, at: time, settle: settings.settleDuration)
        phase = .began(fingers: contacts.count)
        metrics = GestureMetrics()
        progress = RecognitionProgress()
        return new
    }

    private mutating func advance(_ s: inout Session, frame: TouchFrame) -> GestureEvent? {
        let time = frame.timestamp
        s.lastTime = time
        var committed: GestureEvent?

        if fingerSetChanged(s) {
            let lifting = contacts.count < s.fingers.count
            if s.resolution == nil, lifting, var pending = s.pendingSwipe {
                // A swipe that was waiting on a possible circle commits as soon as
                // the hand starts to lift.
                pending.timestamp = time
                s.resolution = .recognized(pending.trigger)
                phase = .recognized(pending.trigger)
                committed = pending
            }
            s.fingers = contacts.map { contact in
                let first = s.fingers.first(where: { $0.id == contact.id })?.first ?? contact.position
                return Finger(id: contact.id, position: contact.position, first: first)
            }
            s.peakFingers = max(s.peakFingers, contacts.count)
            if s.resolution == nil {
                rebaseline(&s, at: time, settle: lifting ? settings.liftSettleDuration : settings.settleDuration)
                phase = .began(fingers: contacts.count)
            }
        } else {
            for contact in contacts {
                if let index = s.fingers.firstIndex(where: { $0.id == contact.id }) {
                    s.fingers[index].position = contact.position
                }
            }
        }

        for finger in s.fingers {
            s.maxTapMovement = max(s.maxTapMovement, simd_length(finger.position - finger.first))
        }

        if let committed { return committed }
        guard s.resolution == nil else { return nil }

        let count = s.fingers.count
        if count > GestureKind.fingerRange.upperBound {
            cancel(&s, reason: "Too many contacts")
            return nil
        }
        if time - s.startTime > settings.maximumSessionDuration {
            cancel(&s, reason: "Timed out")
            return nil
        }

        measure(&s, at: time)
        guard time - s.baselineTime >= s.settleDuration else {
            phase = .began(fingers: count)
            return nil
        }
        guard GestureKind.fingerRange.contains(count), armed.hasAnyArmed(fingers: count) else {
            phase = .tracking(fingers: count)
            progress = RecognitionProgress()
            return nil
        }
        phase = .tracking(fingers: count)
        return evaluate(&s, frame: frame)
    }

    private mutating func finishCycle(_ frame: TouchFrame) -> GestureEvent? {
        guard let s = session else { return nil }
        session = nil

        switch s.resolution {
        case .recognized(let trigger):
            phase = .completed(trigger)
            return nil
        case .cancelled(let reason):
            phase = .cancelled(reason: reason)
            return nil
        case nil:
            break
        }

        if var pending = s.pendingSwipe {
            pending.timestamp = frame.timestamp
            phase = .completed(pending.trigger)
            return pending
        }

        let duration = frame.timestamp - s.startTime
        let isTap = GestureKind.fingerRange.contains(s.peakFingers)
            && duration <= settings.tapMaximumDuration
            && s.maxTapMovement <= settings.tapMaximumMovement
        guard isTap else {
            phase = .cancelled(reason: "No gesture")
            return nil
        }
        let trigger = GestureTrigger.tap(s.peakFingers)
        guard armed.isArmed(trigger) else {
            phase = .cancelled(reason: "\(trigger.displayName) is not mapped")
            return nil
        }
        phase = .completed(trigger)
        var tapMetrics = GestureMetrics()
        tapMetrics.fingers = s.peakFingers
        tapMetrics.duration = duration
        tapMetrics.maxFingerMovement = s.maxTapMovement
        metrics = tapMetrics
        return GestureEvent(trigger: trigger, timestamp: frame.timestamp, source: frame.source, deviceID: frame.device.id, score: 1, metrics: tapMetrics)
    }

    // MARK: - Measurement

    private func fingerSetChanged(_ s: Session) -> Bool {
        // Contact order is not guaranteed between frames; compare identities.
        guard contacts.count == s.fingers.count else { return true }
        return contacts.contains { contact in !s.fingers.contains { $0.id == contact.id } }
    }

    private func rebaseline(_ s: inout Session, at time: TimeInterval, settle: TimeInterval) {
        let center = Self.centroid(s.fingers)
        s.baselineTime = time
        s.settleDuration = settle
        s.baselineCentroid = center
        var spread = 0.0
        for index in s.fingers.indices {
            let offset = s.fingers[index].position - center
            s.fingers[index].baseline = s.fingers[index].position
            s.fingers[index].baselineAngle = atan2(offset.y, offset.x)
            spread += simd_length(offset)
        }
        s.baselineSpread = spread / Double(max(s.fingers.count, 1))
        s.pathAnchor = center
        s.lastHeading = nil
        s.turn = 0
        s.pathLength = 0
        s.pendingSwipe = nil
    }

    private mutating func measure(_ s: inout Session, at time: TimeInterval) {
        let center = Self.centroid(s.fingers)
        var spread = 0.0
        var rotation = 0.0
        var maxMovement = 0.0
        for finger in s.fingers {
            let offset = finger.position - center
            spread += simd_length(offset)
            rotation += Self.wrap(atan2(offset.y, offset.x) - finger.baselineAngle)
            maxMovement = max(maxMovement, simd_length(finger.position - finger.baseline))
        }
        let count = Double(max(s.fingers.count, 1))
        spread /= count

        let step = center - s.pathAnchor
        let stepLength = simd_length(step)
        if stepLength >= Self.pathStep {
            let heading = atan2(step.y, step.x)
            if let last = s.lastHeading {
                s.turn += Self.wrap(heading - last)
            }
            s.lastHeading = heading
            s.pathLength += stepLength
            s.pathAnchor = center
        }

        let translation = center - s.baselineCentroid
        let measurable = s.baselineSpread >= Self.minimumSpread && s.fingers.count >= 2
        metrics.fingers = s.fingers.count
        metrics.translation = translation
        metrics.scale = measurable ? spread / s.baselineSpread : 1
        metrics.rotation = measurable ? rotation / count * 180 / .pi : 0
        metrics.turn = s.turn * 180 / .pi
        metrics.pathLength = s.pathLength
        metrics.straightness = s.pathLength > 3 ? min(1, simd_length(translation) / s.pathLength) : 1
        metrics.maxFingerMovement = maxMovement
        metrics.duration = time - s.baselineTime
    }

    // MARK: - Classification

    private mutating func evaluate(_ s: inout Session, frame: TouchFrame) -> GestureEvent? {
        let fingers = s.fingers.count
        let scale = settings.thresholdScale
        progress = RecognitionProgress()

        if armed.hasArmed(.hold, fingers: fingers) {
            let trigger = GestureTrigger.hold(fingers)
            let still = metrics.maxFingerMovement <= settings.holdMaximumMovement * scale * armed.thresholdScale(for: trigger)
            progress.hold = still ? metrics.duration / settings.holdDuration : 0
            if still, metrics.duration >= settings.holdDuration, armed.isArmed(trigger) {
                return recognize(trigger, score: progress.hold, in: &s, frame: frame)
            }
        }

        let circlesArmed = armed.hasArmed(.circle, fingers: fingers)
        if circlesArmed {
            let trigger = GestureTrigger.circle(fingers, s.turn >= 0 ? .counterclockwise : .clockwise)
            let radius = settings.circleMinimumRadius * scale * armed.thresholdScale(for: trigger)
            let minimumPath = 2 * Double.pi * radius * settings.circleMinimumTurn / 360
            let score = min(abs(metrics.turn) / settings.circleMinimumTurn, metrics.pathLength / minimumPath)
            progress.circle = score
            if score >= 1 {
                return armed.isArmed(trigger) ? recognize(trigger, score: score, in: &s, frame: frame) : unmapped(trigger, in: &s)
            }
        }

        let distance = simd_length(metrics.translation)
        let swipeDirection = Self.swipeDirection(
            for: metrics.translation,
            allowDiagonals: armed.allowsDiagonalSwipes(fingers: fingers),
            diagonalTolerance: settings.diagonalTolerance
        )
        let swipe = GestureTrigger.swipe(fingers, swipeDirection)
        let swipeScore = metrics.straightness >= settings.swipeMinimumStraightness
            ? distance / (settings.swipeDistance * scale * armed.thresholdScale(for: swipe))
            : 0

        let pinch = GestureTrigger.pinch(fingers, metrics.scale < 1 ? .pinchIn : .pinchOut)
        let pinchLimit = log(1 + settings.pinchThreshold * scale * armed.thresholdScale(for: pinch))
        let pinchScore = abs(log(metrics.scale)) / pinchLimit

        let rotate = GestureTrigger.rotate(fingers, metrics.rotation < 0 ? .clockwise : .counterclockwise)
        let rotateScore = abs(metrics.rotation) / (settings.rotationThreshold * scale * armed.thresholdScale(for: rotate))

        progress.swipe = swipeScore
        progress.pinch = pinchScore
        progress.rotate = rotateScore

        var best = (trigger: swipe, score: swipeScore)
        var runnerUp = 0.0
        for candidate in [(pinch, pinchScore), (rotate, rotateScore)] {
            if candidate.1 > best.score {
                runnerUp = best.score
                best = (candidate.0, candidate.1)
            } else {
                runnerUp = max(runnerUp, candidate.1)
            }
        }

        let decisive = best.score >= 1 && best.score >= settings.dominanceRatio * runnerUp
        if best.trigger.kind == .swipe, circlesArmed {
            // A circle starts out looking like a swipe. Hold the swipe until
            // the hand lifts, dropping it if the path stops being straight.
            s.pendingSwipe = decisive && armed.isArmed(swipe)
                ? makeEvent(swipe, score: swipeScore, frame: frame)
                : nil
            return nil
        }
        s.pendingSwipe = nil
        guard decisive else { return nil }
        return armed.isArmed(best.trigger)
            ? recognize(best.trigger, score: best.score, in: &s, frame: frame)
            : unmapped(best.trigger, in: &s)
    }

    private mutating func recognize(_ trigger: GestureTrigger, score: Double, in s: inout Session, frame: TouchFrame) -> GestureEvent {
        s.resolution = .recognized(trigger)
        phase = .recognized(trigger)
        return makeEvent(trigger, score: score, frame: frame)
    }

    private mutating func unmapped(_ trigger: GestureTrigger, in s: inout Session) -> GestureEvent? {
        cancel(&s, reason: "\(trigger.displayName) is not mapped")
        return nil
    }

    private mutating func cancel(_ s: inout Session, reason: String) {
        s.resolution = .cancelled(reason)
        s.pendingSwipe = nil
        phase = .cancelled(reason: reason)
    }

    private func makeEvent(_ trigger: GestureTrigger, score: Double, frame: TouchFrame) -> GestureEvent {
        GestureEvent(trigger: trigger, timestamp: frame.timestamp, source: frame.source, deviceID: frame.device.id, score: score, metrics: metrics)
    }

    // MARK: - Geometry

    /// Classifies a displacement (y up) into a swipe direction. Diagonals are
    /// only reported within `diagonalTolerance` degrees of a 45° line.
    public static func swipeDirection(for vector: SIMD2<Double>, allowDiagonals: Bool, diagonalTolerance: Double) -> GestureDirection {
        let angle = atan2(vector.y, vector.x) * 180 / .pi
        if allowDiagonals {
            let diagonals: [(Double, GestureDirection)] = [(45, .upRight), (135, .upLeft), (-45, .downRight), (-135, .downLeft)]
            for (center, direction) in diagonals where abs(wrapDegrees(angle - center)) <= diagonalTolerance {
                return direction
            }
        }
        switch angle {
        case -45...45: return .right
        case 45...135: return .up
        case -135 ... -45: return .down
        default: return .left
        }
    }

    static func wrap(_ radians: Double) -> Double {
        var value = radians.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value <= -.pi { value += 2 * .pi }
        return value
    }

    static func wrapDegrees(_ degrees: Double) -> Double {
        wrap(degrees * .pi / 180) * 180 / .pi
    }

    private static func centroid(_ fingers: [Finger]) -> SIMD2<Double> {
        guard !fingers.isEmpty else { return .zero }
        var sum = SIMD2<Double>.zero
        for finger in fingers {
            sum += finger.position
        }
        return sum / Double(fingers.count)
    }
}

// MARK: - Private state

private struct Contact {
    var id: Int
    var position: SIMD2<Double>
}

private struct Finger {
    var id: Int
    var position: SIMD2<Double>
    /// Where the finger first landed this cycle (for tap movement).
    var first: SIMD2<Double>
    var baseline: SIMD2<Double>
    var baselineAngle: Double = 0

    init(id: Int, position: SIMD2<Double>, first: SIMD2<Double>? = nil) {
        self.id = id
        self.position = position
        self.first = first ?? position
        self.baseline = position
    }
}

private enum Resolution {
    case recognized(GestureTrigger)
    case cancelled(String)
}

private struct Session {
    var startTime: TimeInterval
    var lastTime: TimeInterval
    var fingers: [Finger] = []
    var peakFingers = 0
    var maxTapMovement = 0.0

    var baselineTime: TimeInterval = 0
    var settleDuration: TimeInterval = 0
    var baselineCentroid = SIMD2<Double>.zero
    var baselineSpread = 0.0

    var pathAnchor = SIMD2<Double>.zero
    var lastHeading: Double?
    var turn = 0.0
    var pathLength = 0.0

    var resolution: Resolution?
    var pendingSwipe: GestureEvent?
}
