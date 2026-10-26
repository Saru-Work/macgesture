import XCTest
@testable import MacGestureCore

final class GestureRecognizerTests: XCTestCase {
    private let generator = SyntheticGestureGenerator()

    private func recognize(
        _ frames: [TouchFrame],
        armed: ArmedGestures = .everything,
        settings: RecognitionSettings = RecognitionSettings()
    ) -> [GestureEvent] {
        var recognizer = GestureRecognizer(settings: settings, armed: armed)
        return frames.compactMap { recognizer.process($0) }
    }

    /// Index of the frame that produced the first event.
    private func firingIndex(_ frames: [TouchFrame], armed: ArmedGestures) -> Int? {
        var recognizer = GestureRecognizer(armed: armed)
        return frames.firstIndex { recognizer.process($0) != nil }
    }

    private func armed(_ triggers: GestureTrigger...) -> ArmedGestures {
        ArmedGestures(triggers: Dictionary(uniqueKeysWithValues: triggers.map { ($0, 1.0) }))
    }

    // MARK: - Swipes

    func testThreeAndFourFingerCardinalSwipes() {
        for fingers in [3, 4] {
            for direction in [GestureDirection.up, .down, .left, .right] {
                let events = recognize(generator.swipe(fingers: fingers, direction: direction))
                XCTAssertEqual(events.map(\.trigger), [.swipe(fingers, direction)], "\(fingers) fingers \(direction)")
            }
        }
    }

    func testDiagonalSwipesWhenMapped() {
        for direction in [GestureDirection.upLeft, .upRight, .downLeft, .downRight] {
            let events = recognize(generator.swipe(fingers: 3, direction: direction), armed: armed(.swipe(3, direction)))
            XCTAssertEqual(events.map(\.trigger), [.swipe(3, direction)])
        }
    }

    func testOffAxisSwipeFallsBackToCardinalWhenNoDiagonalsMapped() {
        // 25° above horizontal: neither diagonal (when unmapped) nor ambiguous.
        let angle = 25.0 * .pi / 180
        let frames = generator.motion(fingers: 3, duration: 0.25) { progress in
            .init(translation: SIMD2(cos(angle), sin(angle)) * 30 * progress)
        }
        XCTAssertEqual(recognize(frames, armed: armed(.swipe(3, .right))).map(\.trigger), [.swipe(3, .right)])
    }

    func testSwipeFiresMidMotionWhenNoCirclesArmed() throws {
        let frames = generator.swipe(fingers: 3, direction: .left)
        let index = try XCTUnwrap(firingIndex(frames, armed: armed(.swipe(3, .left))))
        XCTAssertLessThan(index, frames.count - 1, "Should fire before the lift frame")
    }

    func testSwipeWaitsForLiftWhenCirclesShareFingerCount() throws {
        let frames = generator.swipe(fingers: 3, direction: .left)
        let index = try XCTUnwrap(firingIndex(frames, armed: armed(.swipe(3, .left), .circle(3, .clockwise))))
        XCTAssertEqual(index, frames.count - 1, "Swipe should be deferred to the lift frame")
    }

    func testLongSwipeFiresOnlyOnce() {
        let events = recognize(generator.swipe(fingers: 4, direction: .right, distance: 90, duration: 0.6), armed: armed(.swipe(4, .right)))
        XCTAssertEqual(events.count, 1)
    }

    func testShortMovementDoesNotSwipe() {
        let events = recognize(generator.swipe(fingers: 3, direction: .left, distance: 8), armed: armed(.swipe(3, .left)))
        XCTAssertTrue(events.isEmpty)
    }

    func testSensitivityScalesSwipeDistance() {
        let frames = generator.swipe(fingers: 3, direction: .left, distance: 10)
        var settings = RecognitionSettings()
        settings.sensitivity = 1
        XCTAssertEqual(recognize(frames, armed: armed(.swipe(3, .left)), settings: settings).count, 1)
        settings.sensitivity = 0
        XCTAssertEqual(recognize(frames, armed: armed(.swipe(3, .left)), settings: settings).count, 0)
    }

    func testPerMappingThresholdScale() {
        let frames = generator.swipe(fingers: 3, direction: .left, distance: 10)
        let sensitive = ArmedGestures(triggers: [.swipe(3, .left): 0.5])
        XCTAssertEqual(recognize(frames, armed: sensitive).map(\.trigger), [.swipe(3, .left)])
    }

    // MARK: - Taps and holds

    func testMultiFingerTaps() {
        for fingers in 2...5 {
            XCTAssertEqual(recognize(generator.tap(fingers: fingers)).map(\.trigger), [.tap(fingers)])
        }
    }

    func testSlowPressIsNotATap() {
        let events = recognize(generator.tap(fingers: 3, duration: 0.45), armed: armed(.tap(3)))
        XCTAssertTrue(events.isEmpty)
    }

    func testSingleFingerTapIgnored() {
        XCTAssertTrue(recognize(generator.tap(fingers: 1)).isEmpty)
    }

    func testHoldFiresWhileFingersRemainDown() throws {
        let frames = generator.hold(fingers: 3, duration: 1.0)
        XCTAssertEqual(recognize(frames).map(\.trigger), [.hold(3)])
        let index = try XCTUnwrap(firingIndex(frames, armed: armed(.hold(3))))
        XCTAssertLessThan(index, frames.count - 1)
    }

    func testHoldNotReportedWhenUnmapped() {
        XCTAssertTrue(recognize(generator.hold(fingers: 3, duration: 1.0), armed: armed(.tap(3))).isEmpty)
    }

    // MARK: - Pinch, rotation, circles

    func testPinchInAndOut() {
        for fingers in [2, 3, 4] {
            XCTAssertEqual(recognize(generator.pinch(fingers: fingers, scale: 0.5)).map(\.trigger), [.pinch(fingers, .pinchIn)])
            XCTAssertEqual(recognize(generator.pinch(fingers: fingers, scale: 1.8)).map(\.trigger), [.pinch(fingers, .pinchOut)])
        }
    }

    func testRotationDirections() {
        XCTAssertEqual(recognize(generator.rotate(fingers: 3, degrees: 60)).map(\.trigger), [.rotate(3, .counterclockwise)])
        XCTAssertEqual(recognize(generator.rotate(fingers: 3, degrees: -60)).map(\.trigger), [.rotate(3, .clockwise)])
        XCTAssertEqual(recognize(generator.rotate(fingers: 2, degrees: -60)).map(\.trigger), [.rotate(2, .clockwise)])
    }

    func testCircles() {
        XCTAssertEqual(recognize(generator.circle(fingers: 3, clockwise: true)).map(\.trigger), [.circle(3, .clockwise)])
        XCTAssertEqual(recognize(generator.circle(fingers: 3, clockwise: false)).map(\.trigger), [.circle(3, .counterclockwise)])
    }

    func testPartialCircleProducesNothing() {
        let frames = generator.circle(fingers: 3, clockwise: true, turns: 0.6, duration: 0.5)
        XCTAssertTrue(recognize(frames, armed: armed(.circle(3, .clockwise), .swipe(3, .left), .swipe(3, .down))).isEmpty)
    }

    // MARK: - Noise and false positives

    func testJitterDoesNotBreakTapsOrHolds() {
        var noisy = generator
        noisy.jitter = 0.4
        XCTAssertEqual(recognize(noisy.tap(fingers: 3)).map(\.trigger), [.tap(3)])
        XCTAssertEqual(recognize(noisy.hold(fingers: 4, duration: 1)).map(\.trigger), [.hold(4)])
    }

    func testJitteryRestingHandTriggersNothing() {
        var noisy = generator
        noisy.jitter = 0.5
        let frames = noisy.stationary(fingers: 3, duration: 3)
        XCTAssertTrue(recognize(frames, armed: armed(.swipe(3, .left), .pinch(3, .pinchIn), .rotate(3, .clockwise), .circle(3, .clockwise))).isEmpty)
    }

    func testTwoFingerScrollIgnoredWhenOnlyThreeFingerGesturesMapped() {
        let frames = generator.swipe(fingers: 2, direction: .down, distance: 60)
        XCTAssertTrue(recognize(frames, armed: armed(.swipe(3, .down))).isEmpty)
    }

    func testUnmappedGestureCancelsCycleInsteadOfMisfiring() {
        // Pinching while only a swipe is mapped must not turn into the swipe.
        var recognizer = GestureRecognizer(armed: armed(.swipe(3, .left)))
        let pinchEvents = generator.pinch(fingers: 3, scale: 0.45).compactMap { recognizer.process($0) }
        XCTAssertTrue(pinchEvents.isEmpty)
        XCTAssertEqual(recognizer.phase, .cancelled(reason: "3-finger pinch in is not mapped"))

        let swipeEvents = generator.swipe(fingers: 3, direction: .left).compactMap { recognizer.process($0) }
        XCTAssertEqual(swipeEvents.map(\.trigger), [.swipe(3, .left)])
    }

    func testStaggeredLandingUsesFinalFingerCount() {
        var frames = generator.swipe(fingers: 3, direction: .up)
        // First finger alone, then two, then all three over ~35ms.
        frames[0].touches = Array(frames[0].touches.prefix(1))
        frames[1].touches = Array(frames[1].touches.prefix(2))
        frames[2].touches = Array(frames[2].touches.prefix(2))
        XCTAssertEqual(recognize(frames, armed: armed(.swipe(2, .up), .swipe(3, .up))).map(\.trigger), [.swipe(3, .up)])
    }

    func testStaggeredLiftAfterTapStillCountsPeakFingers() {
        var frames = generator.tap(fingers: 3)
        let last = frames.count - 1
        frames.insert(TouchFrame(timestamp: frames[last].timestamp - 0.004, device: frames[last].device, touches: Array(frames[last - 1].touches.prefix(2))), at: last)
        XCTAssertEqual(recognize(frames).map(\.trigger), [.tap(3)])
    }

    func testPalmContactIsIgnored() {
        let frames = generator.swipe(fingers: 3, direction: .left).map { frame -> TouchFrame in
            var frame = frame
            if !frame.touches.isEmpty {
                frame.touches.append(TouchPoint(id: 99, position: SIMD2(0.9, 0.1), size: 4))
            }
            return frame
        }
        XCTAssertEqual(recognize(frames).map(\.trigger), [.swipe(3, .left)])
    }

    func testRestingHandTimesOut() {
        var settings = RecognitionSettings()
        settings.maximumSessionDuration = 2
        var recognizer = GestureRecognizer(settings: settings, armed: armed(.swipe(3, .left)))
        var frames = generator.stationary(fingers: 3, duration: 2.5)
        frames.removeLast()
        XCTAssertTrue(frames.compactMap { recognizer.process($0) }.isEmpty)
        XCTAssertEqual(recognizer.phase, .cancelled(reason: "Timed out"))
    }

    func testTooManyContactsCancels() {
        var recognizer = GestureRecognizer()
        var frames = generator.swipe(fingers: 6, direction: .left)
        frames.removeLast()
        XCTAssertTrue(frames.compactMap { recognizer.process($0) }.isEmpty)
        XCTAssertEqual(recognizer.phase, .cancelled(reason: "Too many contacts"))
    }

    func testFrameGapStartsNewCycle() {
        var recognizer = GestureRecognizer(armed: armed(.tap(3)))
        var first = generator.tap(fingers: 3)
        first.removeLast() // lift never reported
        _ = first.compactMap { recognizer.process($0) }

        var later = generator
        later.startTime = 200
        XCTAssertEqual(later.tap(fingers: 3).compactMap { recognizer.process($0) }.map(\.trigger), [.tap(3)])
    }

    func testContactOrderChangesDoNotResetTracking() {
        let frames = generator.swipe(fingers: 3, direction: .left).enumerated().map { index, frame -> TouchFrame in
            var frame = frame
            if index.isMultiple(of: 2) { frame.touches.reverse() }
            return frame
        }
        XCTAssertEqual(recognize(frames, armed: armed(.swipe(3, .left))).map(\.trigger), [.swipe(3, .left)])
    }

    // MARK: - State machine

    func testPhaseProgression() {
        var recognizer = GestureRecognizer(armed: armed(.swipe(3, .right)))
        var phases: [String] = []
        for frame in generator.swipe(fingers: 3, direction: .right) {
            _ = recognizer.process(frame)
            let name = switch recognizer.phase {
            case .idle: "idle"
            case .began: "began"
            case .tracking: "tracking"
            case .recognized: "recognized"
            case .cancelled: "cancelled"
            case .completed: "completed"
            }
            if phases.last != name { phases.append(name) }
        }
        XCTAssertEqual(phases, ["began", "tracking", "recognized", "completed"])
    }

    func testResetAbandonsCycle() {
        var recognizer = GestureRecognizer()
        let frames = generator.tap(fingers: 3)
        _ = recognizer.process(frames[0])
        recognizer.reset()
        XCTAssertEqual(recognizer.phase, .idle)
        XCTAssertNil(recognizer.process(frames.last!))
    }

    func testSwipeDirectionClassification() {
        func direction(_ degrees: Double, diagonals: Bool = true) -> GestureDirection {
            let radians = degrees * .pi / 180
            return GestureRecognizer.swipeDirection(for: SIMD2(cos(radians), sin(radians)), allowDiagonals: diagonals, diagonalTolerance: 15)
        }
        XCTAssertEqual(direction(0), .right)
        XCTAssertEqual(direction(90), .up)
        XCTAssertEqual(direction(180), .left)
        XCTAssertEqual(direction(-90), .down)
        XCTAssertEqual(direction(45), .upRight)
        XCTAssertEqual(direction(130), .upLeft)
        XCTAssertEqual(direction(-140), .downLeft)
        XCTAssertEqual(direction(-50), .downRight)
        XCTAssertEqual(direction(70), .up, "Outside the diagonal band")
        XCTAssertEqual(direction(40, diagonals: false), .right)
    }

    func testMetricsUsePhysicalUnits() {
        var recognizer = GestureRecognizer(armed: armed(.swipe(3, .up), .circle(3, .clockwise)))
        var frames = generator.swipe(fingers: 3, direction: .up, distance: 30)
        frames.removeLast()
        for frame in frames { _ = recognizer.process(frame) }
        XCTAssertEqual(recognizer.metrics.translation.y, 30, accuracy: 0.5)
        XCTAssertEqual(recognizer.metrics.straightness, 1, accuracy: 0.05)
    }
}
