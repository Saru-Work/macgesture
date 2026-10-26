import Foundation

/// Builds deterministic touch sequences for the simulator and automated tests.
/// Geometry is specified in millimetres and converted to normalized positions
/// using the device's surface size.
public struct SyntheticGestureGenerator: Sendable {
    public var device: TrackpadDevice
    public var frameRate: Double = 90
    public var startTime: TimeInterval = 100
    /// Normalized centre of the hand.
    public var center = SIMD2<Double>(0.5, 0.45)
    /// Radius of the circle the fingertips sit on, in millimetres.
    public var handRadius: Double = 14
    /// Stationary time before motion begins, as when fingers land and then move.
    public var leadIn: TimeInterval = 0.08
    /// Peak positional noise in millimetres, applied deterministically.
    public var jitter: Double = 0
    public var seed: UInt64 = 0x5EED

    public init(device: TrackpadDevice = .simulated) {
        self.device = device
    }

    /// A finger-relative transform at a given progress through the motion.
    public struct Pose: Sendable {
        public var translation: SIMD2<Double>
        public var scale: Double
        public var rotation: Double

        public init(translation: SIMD2<Double> = .zero, scale: Double = 1, rotation: Double = 0) {
            self.translation = translation
            self.scale = scale
            self.rotation = rotation
        }
    }

    public func swipe(fingers: Int, direction: GestureDirection, distance: Double = 30, duration: TimeInterval = 0.25) -> [TouchFrame] {
        let unit = direction.unitVector ?? .zero
        return motion(fingers: fingers, duration: duration) { progress in
            Pose(translation: unit * (distance * progress))
        }
    }

    public func tap(fingers: Int, duration: TimeInterval = 0.12) -> [TouchFrame] {
        stationary(fingers: fingers, duration: duration)
    }

    public func hold(fingers: Int, duration: TimeInterval = 1.0) -> [TouchFrame] {
        stationary(fingers: fingers, duration: duration)
    }

    /// `scale` < 1 pinches in, > 1 spreads out.
    public func pinch(fingers: Int, scale: Double, duration: TimeInterval = 0.35) -> [TouchFrame] {
        motion(fingers: fingers, duration: duration) { progress in
            Pose(scale: 1 + (scale - 1) * progress)
        }
    }

    /// Positive degrees rotate counterclockwise.
    public func rotate(fingers: Int, degrees: Double, duration: TimeInterval = 0.4) -> [TouchFrame] {
        motion(fingers: fingers, duration: duration) { progress in
            Pose(rotation: degrees * .pi / 180 * progress)
        }
    }

    /// Moves the whole hand around a circle starting and ending at its origin.
    public func circle(fingers: Int, radius: Double = 12, clockwise: Bool, turns: Double = 1, duration: TimeInterval = 0.8) -> [TouchFrame] {
        let sign: Double = clockwise ? -1 : 1
        return motion(fingers: fingers, duration: duration) { progress in
            let angle = sign * 2 * .pi * turns * progress
            // Start at angle 0 on a circle centred one radius to the left.
            return Pose(translation: SIMD2(radius * cos(angle) - radius, radius * sin(angle)))
        }
    }

    public enum AnchorEnding: Sendable {
        /// The moving finger lifts, then the anchor.
        case liftMovingFinger
        /// The anchor lifts first while the other finger stays down.
        case liftAnchor
        /// Both lift in the same frame.
        case liftBoth
    }

    /// One finger rests as an anchor, then a second finger lands and follows
    /// `path` (offset in mm from where it landed, y up) from progress 0 to 1.
    /// The anchor can drift along `anchorPath`. Finger IDs are fixed: the
    /// anchor is `anchorID`, the moving finger `fingerID`.
    public func anchorSequence(
        anchorHold: TimeInterval = 0.3,
        strokeDuration: TimeInterval = 0.5,
        anchorID: Int = 1,
        fingerID: Int = 2,
        ending: AnchorEnding = .liftMovingFinger,
        anchorPath: (Double) -> SIMD2<Double> = { _ in .zero },
        path: (Double) -> SIMD2<Double>
    ) -> [TouchFrame] {
        let size = device.surfaceSize
        let anchorMM = center * size + SIMD2(-18, 0)
        let fingerMM = center * size + SIMD2(18, 0)
        let interval = 1 / frameRate
        var noise = SplitMix(seed: seed)
        var time = startTime
        var frames: [TouchFrame] = []

        func point(_ id: Int, _ mm: SIMD2<Double>) -> TouchPoint {
            var position = mm
            if jitter > 0 {
                position += SIMD2(noise.nextSigned(), noise.nextSigned()) * jitter
            }
            return TouchPoint(id: id, position: position / size)
        }

        for _ in 0..<max(1, Int((anchorHold * frameRate).rounded())) {
            frames.append(TouchFrame(timestamp: time, device: device, touches: [point(anchorID, anchorMM)]))
            time += interval
        }
        let steps = max(1, Int((strokeDuration * frameRate).rounded()))
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            frames.append(TouchFrame(timestamp: time, device: device, touches: [
                point(anchorID, anchorMM + anchorPath(progress)),
                point(fingerID, fingerMM + path(progress)),
            ]))
            time += interval
        }
        let finalAnchor = anchorMM + anchorPath(1)
        let finalFinger = fingerMM + path(1)
        switch ending {
        case .liftMovingFinger:
            frames.append(TouchFrame(timestamp: time, device: device, touches: [point(anchorID, finalAnchor)]))
            time += interval
        case .liftAnchor:
            frames.append(TouchFrame(timestamp: time, device: device, touches: [point(fingerID, finalFinger)]))
            time += interval
        case .liftBoth:
            break
        }
        frames.append(TouchFrame(timestamp: time, device: device, touches: []))
        return frames
    }

    /// Anchor plus a straight vertical stroke of `distance` mm (positive is up),
    /// optionally with horizontal travel.
    public func anchorSwipe(distance: Double, horizontal: Double = 0, anchorHold: TimeInterval = 0.3, duration: TimeInterval = 0.5) -> [TouchFrame] {
        anchorSequence(anchorHold: anchorHold, strokeDuration: duration) { progress in
            SIMD2(horizontal * progress, distance * progress)
        }
    }

    /// General motion: lead-in, then `pose(progress)` from 0 to 1, then lift.
    public func motion(fingers: Int, duration: TimeInterval, pose: (Double) -> Pose) -> [TouchFrame] {
        var frames: [TouchFrame] = []
        let interval = 1 / frameRate
        var time = startTime
        var noise = SplitMix(seed: seed)

        let leadInFrames = max(1, Int((leadIn * frameRate).rounded()))
        for _ in 0..<leadInFrames {
            frames.append(frame(at: time, fingers: fingers, pose: Pose(), noise: &noise))
            time += interval
        }
        let steps = max(1, Int((duration * frameRate).rounded()))
        for step in 1...steps {
            frames.append(frame(at: time, fingers: fingers, pose: pose(Double(step) / Double(steps)), noise: &noise))
            time += interval
        }
        frames.append(TouchFrame(timestamp: time, device: device, touches: []))
        return frames
    }

    public func stationary(fingers: Int, duration: TimeInterval) -> [TouchFrame] {
        var frames: [TouchFrame] = []
        var noise = SplitMix(seed: seed)
        let interval = 1 / frameRate
        let count = max(1, Int((duration * frameRate).rounded()))
        for index in 0..<count {
            frames.append(frame(at: startTime + Double(index) * interval, fingers: fingers, pose: Pose(), noise: &noise))
        }
        frames.append(TouchFrame(timestamp: startTime + Double(count) * interval, device: device, touches: []))
        return frames
    }

    /// Fingertip offsets from the hand centre, in millimetres.
    public func restingOffsets(fingers: Int) -> [SIMD2<Double>] {
        (0..<fingers).map { index in
            let angle = Double.pi / 2 + 2 * Double.pi * Double(index) / Double(max(fingers, 1))
            return SIMD2(cos(angle), sin(angle)) * handRadius
        }
    }

    private func frame(at time: TimeInterval, fingers: Int, pose: Pose, noise: inout SplitMix) -> TouchFrame {
        let size = device.surfaceSize
        let centerMM = center * size
        let cosR = cos(pose.rotation)
        let sinR = sin(pose.rotation)
        let touches = restingOffsets(fingers: fingers).enumerated().map { index, offset -> TouchPoint in
            let scaled = offset * pose.scale
            let rotated = SIMD2(scaled.x * cosR - scaled.y * sinR, scaled.x * sinR + scaled.y * cosR)
            var positionMM = centerMM + rotated + pose.translation
            if jitter > 0 {
                positionMM += SIMD2(noise.nextSigned(), noise.nextSigned()) * jitter
            }
            return TouchPoint(id: index + 1, position: positionMM / size)
        }
        return TouchFrame(timestamp: time, device: device, touches: touches)
    }
}

/// Small deterministic PRNG so jittered test sequences are reproducible.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// Uniform in -1...1.
    mutating func nextSigned() -> Double {
        Double(next() >> 11) / Double(1 << 53) * 2 - 1
    }
}
