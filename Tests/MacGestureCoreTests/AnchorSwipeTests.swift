import os
import XCTest
@testable import MacGestureCore

/// In-memory volume so tests never change the Mac's real output volume.
final class MockVolume: VolumeBackend {
    struct State {
        var level: Double
        var muted = false
        var setCalls = 0
        var unsupported = false
    }

    let state: OSAllocatedUnfairLock<State>

    init(level: Double = 0.5) {
        state = OSAllocatedUnfairLock(initialState: State(level: level))
    }

    var level: Double { state.withLock { $0.level } }
    var setCalls: Int { state.withLock { $0.setCalls } }

    func volume() throws(ActionError) -> Double {
        let current = state.withLock { $0 }
        if current.unsupported { throw .unsupported("Mock device has fixed volume.") }
        return current.level
    }

    func setVolume(_ level: Double) throws(ActionError) -> Double {
        let result: Double? = state.withLock { state in
            guard !state.unsupported else { return nil }
            state.setCalls += 1
            state.level = min(max(level, 0), 1)
            return state.level
        }
        guard let result else { throw .unsupported("Mock device has fixed volume.") }
        return result
    }

    func isMuted() throws(ActionError) -> Bool {
        state.withLock { $0.muted }
    }

    func setMuted(_ muted: Bool) throws(ActionError) {
        state.withLock { $0.muted = muted }
    }
}

final class AnchorSwipeTests: XCTestCase {
    private let generator = SyntheticGestureGenerator()
    private let armed = ArmedGestures(triggers: [.anchorSwipe(.up): 1, .anchorSwipe(.down): 1])

    private struct Run {
        var events: [(index: Int, event: GestureEvent)] = []
        var states: [AnchorSwipeState] = []

        var triggers: [GestureTrigger] { events.map(\.event.trigger) }
        var totalSteps: Int { events.reduce(0) { $0 + $1.event.magnitude } }
    }

    private func run(_ frames: [TouchFrame], recognizer: inout AnchorSwipeRecognizer) -> Run {
        var result = Run()
        for (index, frame) in frames.enumerated() {
            if let event = recognizer.process(frame) {
                result.events.append((index, event))
            }
            result.states.append(recognizer.state)
        }
        return result
    }

    private func run(_ frames: [TouchFrame], settings: RecognitionSettings = RecognitionSettings()) -> Run {
        var recognizer = AnchorSwipeRecognizer(settings: settings, armed: armed)
        return run(frames, recognizer: &recognizer)
    }

    @MainActor
    private func applyToMockVolume(_ events: [GestureEvent], start: Double = 0.5) async -> MockVolume {
        let volume = MockVolume(level: start)
        let executor = ActionExecutor(volume: VolumeController(backend: volume)) { _ in true }
        let mappings = Dictionary(uniqueKeysWithValues: DefaultConfiguration.anchorVolumeMappings().map { ($0.trigger, $0) })
        for event in events {
            guard let mapping = mappings[event.trigger] else { continue }
            _ = await executor.perform(mapping.action, mappingName: mapping.displayName, magnitude: event.magnitude)
        }
        return volume
    }

    // MARK: 1–2. Anchor and second finger detection

    func testAnchorTouchDownIsTrackedByIdentity() {
        var frames = generator.anchorSwipe(distance: 0)
        frames = Array(frames.prefix(25)) // anchor alone (the hold phase is 27 frames)
        let result = run(frames)
        XCTAssertEqual(result.states.first, .anchorCandidate(anchorID: 1))
        XCTAssertEqual(result.states.last, .anchored(anchorID: 1))
        XCTAssertTrue(result.events.isEmpty)
    }

    func testSecondFingerWhileAnchorHeldActivatesAndClaimsCycle() {
        var recognizer = AnchorSwipeRecognizer(armed: armed)
        let frames = generator.anchorSwipe(distance: 0)
        let landing = frames.firstIndex { $0.touches.count == 2 }!
        _ = run(Array(frames.prefix(landing + 1)), recognizer: &recognizer)
        XCTAssertEqual(recognizer.state, .active(anchorID: 1, fingerID: 2, travel: 0, engaged: false))
        XCTAssertTrue(recognizer.claimsCycle)
    }

    func testAnchorIsFoundByIdentityNotArrayPosition() {
        // Reverse contact order on every frame: the anchor must stay finger 1.
        let frames = generator.anchorSwipe(distance: 30).map { frame -> TouchFrame in
            var frame = frame
            frame.touches.reverse()
            return frame
        }
        let result = run(frames)
        XCTAssertFalse(result.events.isEmpty)
        XCTAssertTrue(result.triggers.allSatisfy { $0 == .anchorSwipe(.up) })
    }

    // MARK: 3–4. Direction and proportional volume

    @MainActor
    func testSwipeUpIncreasesVolumeProportionally() async {
        let result = run(generator.anchorSwipe(distance: 30))
        XCTAssertTrue(result.triggers.allSatisfy { $0 == .anchorSwipe(.up) })
        // (30 mm − 3 mm dead zone) / 1.5 mm, less a little smoothing lag.
        XCTAssertGreaterThanOrEqual(result.totalSteps, 15)
        XCTAssertLessThanOrEqual(result.totalSteps, 18)
        XCTAssertFalse(result.events[0].event.isContinuation)
        XCTAssertTrue(result.events.dropFirst().allSatisfy(\.event.isContinuation))

        let volume = await applyToMockVolume(result.events.map(\.event))
        XCTAssertEqual(volume.level, 0.5 + Double(result.totalSteps) * DefaultConfiguration.anchorVolumeStep, accuracy: 0.0001)
    }

    @MainActor
    func testSwipeDownDecreasesVolume() async {
        let result = run(generator.anchorSwipe(distance: -30))
        XCTAssertFalse(result.events.isEmpty)
        XCTAssertTrue(result.triggers.allSatisfy { $0 == .anchorSwipe(.down) })
        let volume = await applyToMockVolume(result.events.map(\.event))
        XCTAssertLessThan(volume.level, 0.5)
    }

    func testLargerMovementGivesMoreSteps() {
        XCTAssertGreaterThan(run(generator.anchorSwipe(distance: 40)).totalSteps, run(generator.anchorSwipe(distance: 15)).totalSteps * 2)
    }

    @MainActor
    func testVolumeIsClamped() async {
        let result = run(generator.anchorSwipe(distance: 60))
        let volume = await applyToMockVolume(result.events.map(\.event), start: 0.95)
        XCTAssertEqual(volume.level, 1)
    }

    // MARK: 5–6. Horizontal movement and dead zone

    func testHorizontalMovementDoesNotAdjust() {
        XCTAssertTrue(run(generator.anchorSwipe(distance: 0, horizontal: 40)).events.isEmpty)
        // Mostly horizontal with slight vertical drift inside the dead zone.
        XCTAssertTrue(run(generator.anchorSwipe(distance: 2, horizontal: 40)).events.isEmpty)
    }

    func testMovementInsideDeadZoneDoesNotAdjust() {
        let result = run(generator.anchorSwipe(distance: 2.5))
        XCTAssertTrue(result.events.isEmpty)
        if case .active(_, _, _, let engaged) = result.states[result.states.count - 3] {
            XCTAssertFalse(engaged)
        } else {
            XCTFail("Expected an active, unengaged stroke")
        }
    }

    func testTremorWhileStillDoesNotAdjust() {
        var noisy = generator
        noisy.jitter = 0.4
        // Engage, then hold still with tremor for most of the stroke.
        let frames = noisy.anchorSequence(strokeDuration: 1.0) { progress in
            SIMD2(0, min(progress, 0.2) / 0.2 * 9)
        }
        var recognizer = AnchorSwipeRecognizer(armed: armed)
        let result = run(frames, recognizer: &recognizer)
        // 27 anchor-only frames, then the ramp occupies 20% of 90 stroke frames.
        let stillFrom = 27 + 18
        XCTAssertFalse(result.events.isEmpty, "The 9 mm ramp itself adjusts")
        XCTAssertTrue(result.events.allSatisfy { $0.index <= stillFrom + 2 }, "No adjustments while the finger only trembles")
    }

    // MARK: 7–9. Cancellation and release

    func testAnchorMovementCancels() throws {
        let frames = generator.anchorSequence(anchorPath: { SIMD2(12 * $0, 0) }) { SIMD2(0, 40 * $0) }
        let result = run(frames)
        let cancelIndex = try XCTUnwrap(result.states.firstIndex(of: .cancelled(reason: "Anchor moved")))
        XCTAssertTrue(result.events.allSatisfy { $0.index < cancelIndex })
    }

    func testAnchorReleaseStopsAdjustmentsImmediately() {
        var frames = generator.anchorSwipe(distance: 20)
        frames.removeLast(2)
        let last = frames.last!
        let finger = last.touches.first { $0.id == 2 }!
        // Anchor lifts; the other finger keeps sliding up another 25 mm.
        for step in 1...30 {
            var moved = finger
            moved.position.y += Double(step) * (25.0 / 30) / last.device.surfaceSize.y
            frames.append(TouchFrame(timestamp: last.timestamp + Double(step) / 90, device: last.device, touches: [moved]))
        }
        let liftIndex = frames.firstIndex { $0.touches.count == 1 && $0.touches[0].id == 2 }!
        let result = run(frames)
        XCTAssertFalse(result.events.isEmpty)
        XCTAssertTrue(result.events.allSatisfy { $0.index < liftIndex })
        XCTAssertEqual(result.states[liftIndex], .cancelled(reason: "Anchor lifted"))
    }

    func testSecondFingerReleaseStopsAndAllowsAnotherStroke() {
        var frames = generator.anchorSwipe(distance: 20)
        frames.removeLast() // keep the anchor down
        let afterLift = frames.count - 1
        var second = generator
        second.startTime = frames.last!.timestamp + 1 / 90
        // A new finger (ID 3) strokes down while the same anchor stays put.
        let more = second.anchorSequence(anchorHold: 0.05, fingerID: 3) { SIMD2(0, -20 * $0) }
        frames.append(contentsOf: more)

        let result = run(frames)
        XCTAssertEqual(result.states[afterLift], .anchored(anchorID: 1))
        let firstStroke = result.events.filter { $0.index < afterLift }
        let secondStroke = result.events.filter { $0.index > afterLift }
        XCTAssertTrue(firstStroke.allSatisfy { $0.event.trigger == .anchorSwipe(.up) })
        XCTAssertFalse(secondStroke.isEmpty)
        XCTAssertTrue(secondStroke.allSatisfy { $0.event.trigger == .anchorSwipe(.down) })
        XCTAssertFalse(secondStroke[0].event.isContinuation, "A new stroke starts a new sequence")
    }

    // MARK: 10. Identity changes and ambiguous frames

    func testFingerIdentityChangeCancels() throws {
        let frames = generator.anchorSwipe(distance: 40).enumerated().map { index, frame -> TouchFrame in
            var frame = frame
            if index > 45 {
                frame.touches = frame.touches.map { $0.id == 2 ? TouchPoint(id: 7, position: $0.position) : $0 }
            }
            return frame
        }
        let result = run(frames)
        let cancelIndex = try XCTUnwrap(result.states.firstIndex(of: .cancelled(reason: "Finger identity changed")))
        XCTAssertTrue(result.events.allSatisfy { $0.index < cancelIndex })
    }

    func testTwoFingersLandingTogetherIsAScrollNotAnAnchor() {
        let frames = generator.swipe(fingers: 2, direction: .up, distance: 40)
        let result = run(frames)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.states.first, .cancelled(reason: "Fingers landed together"))
    }

    func testSecondFingerTooSoonIsRejected() {
        let result = run(generator.anchorSwipe(distance: 30, anchorHold: 0.08))
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.states.contains(.cancelled(reason: "Second finger arrived too soon")))
    }

    func testThirdFingerCancels() {
        let frames = generator.anchorSwipe(distance: 40).enumerated().map { index, frame -> TouchFrame in
            var frame = frame
            if index > 40, frame.touches.count == 2 {
                frame.touches.append(TouchPoint(id: 9, position: SIMD2(0.8, 0.8)))
            }
            return frame
        }
        let result = run(frames)
        XCTAssertTrue(result.states.contains(.cancelled(reason: "Too many fingers")))
        let cancelIndex = result.states.firstIndex(of: .cancelled(reason: "Too many fingers"))!
        XCTAssertTrue(result.events.allSatisfy { $0.index < cancelIndex })
    }

    func testRestingThumbZoneIsNotAnAnchor() {
        var low = generator
        low.center = SIMD2(0.5, 0.06)
        let result = run(low.anchorSwipe(distance: 30))
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.states.first, .cancelled(reason: "Anchor in the resting-thumb zone"))
    }

    // MARK: 11. Rate limiting

    @MainActor
    func testRapidMovementIsRateLimited() async {
        let frames = generator.anchorSwipe(distance: 60, duration: 0.1)
        let result = run(frames)
        let strokeDuration = 0.1 + 2 / 90.0
        let maximumUpdates = Int(strokeDuration / RecognitionSettings().anchorUpdateInterval) + 1
        XCTAssertLessThanOrEqual(result.events.count, maximumUpdates)
        XCTAssertGreaterThan(result.totalSteps, result.events.count, "Steps are combined, not dropped")
        for pair in zip(result.events, result.events.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.event.timestamp - pair.0.event.timestamp, RecognitionSettings().anchorUpdateInterval - 1e-9)
        }
        let volume = await applyToMockVolume(result.events.map(\.event))
        XCTAssertEqual(volume.setCalls, result.events.count, "One Core Audio write per update, not per step")
    }

    // MARK: 12. Repeated gestures

    func testRepeatedGesturesAfterCompleteReset() {
        var recognizer = AnchorSwipeRecognizer(armed: armed)
        let first = run(generator.anchorSwipe(distance: 25), recognizer: &recognizer)
        XCTAssertEqual(recognizer.state, .idle)
        var later = generator
        later.startTime += 5
        let second = run(later.anchorSwipe(distance: -25), recognizer: &recognizer)
        recognizer.reset()
        later.startTime += 5
        let third = run(later.anchorSwipe(distance: 25), recognizer: &recognizer)
        XCTAssertFalse(first.events.isEmpty)
        XCTAssertTrue(second.triggers.allSatisfy { $0 == .anchorSwipe(.down) } && !second.events.isEmpty)
        XCTAssertEqual(first.totalSteps, third.totalSteps)
    }

    // MARK: Smoothness

    func testReversingDirectionReversesAdjustment() {
        let frames = generator.anchorSequence(strokeDuration: 1.0) { progress in
            SIMD2(0, progress < 0.5 ? 40 * progress : 20 - 40 * (progress - 0.5))
        }
        let result = run(frames)
        let directions = result.triggers.map(\.direction)
        let firstDown = directions.firstIndex(of: .down)
        XCTAssertNotNil(firstDown)
        XCTAssertTrue(directions.prefix(firstDown ?? 0).allSatisfy { $0 == .up })
        XCTAssertTrue(directions.suffix(from: firstDown ?? 0).allSatisfy { $0 == .down })
    }

    func testPauseDoesNotJump() {
        // Up 15 mm, pause, then up 15 mm more: same total as one 30 mm stroke
        // within a step, and nothing fires during the pause.
        let frames = generator.anchorSequence(strokeDuration: 1.2) { progress in
            let y = progress < 0.33 ? 45 * progress : (progress < 0.66 ? 15 : 15 + 45 * (progress - 0.66))
            return SIMD2(0, y)
        }
        let result = run(frames)
        let straight = run(generator.anchorSwipe(distance: 30.3))
        XCTAssertEqual(Double(result.totalSteps), Double(straight.totalSteps), accuracy: 1)
        let pauseStart = 27 + Int(0.40 * 108), pauseEnd = 27 + Int(0.64 * 108)
        XCTAssertTrue(result.events.allSatisfy { $0.index < pauseStart || $0.index > pauseEnd })
    }

    func testUnmappedDirectionProducesNothing() {
        var recognizer = AnchorSwipeRecognizer(armed: ArmedGestures(triggers: [.anchorSwipe(.up): 1]))
        XCTAssertTrue(run(generator.anchorSwipe(distance: -30), recognizer: &recognizer).events.isEmpty)
    }

    // MARK: Engine and routing integration

    private func profile(_ extra: [GestureMapping] = []) -> GestureProfile {
        GestureProfile(name: "Test", mappings: DefaultConfiguration.anchorVolumeMappings() + extra)
    }

    func testEngineGivesTheCycleToTheAnchorGesture() {
        // A 2-finger swipe up is also mapped; the anchor sequence must not trigger it.
        let swipe = GestureMapping(trigger: .swipe(2, .up), action: .media(command: .playPause))
        var configuration = AppConfiguration(profiles: [profile([swipe])])
        configuration.general.cooldown = 5
        let engine = GestureEngine(configuration: configuration, clock: { 0 }, output: { _ in })
        let recognized = engine.processSynchronously(generator.anchorSwipe(distance: 40)).compactMap { output -> (GestureTrigger, RouteDecision)? in
            if case .recognized(let event, let decision) = output { return (event.trigger, decision) }
            return nil
        }
        XCTAssertFalse(recognized.isEmpty)
        XCTAssertTrue(recognized.allSatisfy { $0.0 == .anchorSwipe(.up) })
        XCTAssertTrue(recognized.allSatisfy {
            if case .execute = $0.1 { return true }
            return false
        }, "Continuous updates bypass the cooldown")
    }

    func testEngineStillRecognizesOrdinaryTwoFingerSwipes() {
        let swipe = GestureMapping(trigger: .swipe(2, .up), action: .media(command: .playPause))
        let engine = GestureEngine(configuration: AppConfiguration(profiles: [profile([swipe])]), clock: { 0 }, output: { _ in })
        let triggers = engine.processSynchronously(generator.swipe(fingers: 2, direction: .up)).compactMap { output -> GestureTrigger? in
            if case .recognized(let event, _) = output { return event.trigger }
            return nil
        }
        XCTAssertEqual(triggers, [.swipe(2, .up)])
    }

    func testEngineReportsContinuousActivity() {
        let changes = OSAllocatedUnfairLock(initialState: [Bool]())
        let engine = GestureEngine(
            configuration: AppConfiguration(profiles: [profile()]),
            clock: { 0 },
            continuousGestureObserver: { active in changes.withLock { $0.append(active) } },
            output: { _ in }
        )
        _ = engine.processSynchronously(generator.anchorSwipe(distance: 20))
        XCTAssertEqual(changes.withLock { $0 }, [true, false])
    }

    // MARK: Volume service

    @MainActor
    func testFixedVolumeDeviceReportsErrorWithFallback() async throws {
        try XCTSkipIf(CGPreflightPostEventAccess(), "Fallback would post a real volume key")
        let volume = MockVolume()
        volume.state.withLock { $0.unsupported = true }
        let executor = ActionExecutor(volume: VolumeController(backend: volume)) { _ in true }
        let result = await executor.perform(.volume(command: .up(step: 0.02)), mappingName: "Test")
        guard case .failure(.unsupported(let message)) = result else {
            return XCTFail("Expected an unsupported error, got \(result)")
        }
        XCTAssertTrue(message.contains("fallback"))
    }

    func testVolumeUpUnmutes() throws {
        let volume = MockVolume(level: 0.3)
        volume.state.withLock { $0.muted = true }
        let change = try VolumeController(backend: volume).perform(.up(step: 0.1), magnitude: 2)
        XCTAssertEqual(change.level, 0.5, accuracy: 0.0001)
        XCTAssertFalse(change.isMuted)
    }

    // MARK: Configuration

    func testMigrationAddsAnchorMappingsAndPreservesExistingOnes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let custom = GestureMapping(name: "Mine", trigger: .tap(3), action: .media(command: .nextTrack))
        let alreadyAnchored = GestureMapping(name: "My slider", trigger: .anchorSwipe(.up), action: .media(command: .nextTrack))
        var v1 = AppConfiguration(profiles: [
            GestureProfile(name: "One", mappings: [custom]),
            GestureProfile(name: "Two", mappings: [alreadyAnchored]),
        ])
        v1.general.cooldown = 1.5
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(v1)) as! [String: Any]
        json["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("configuration.json"))

        let result = ConfigurationStore(directory: directory).load()
        guard case .migrated(from: 1, _) = result.issue else {
            return XCTFail("Expected migration, got \(String(describing: result.issue))")
        }
        let profiles = result.configuration.profiles
        XCTAssertEqual(profiles[0].mappings.first, custom, "Existing mappings are untouched")
        XCTAssertEqual(profiles[0].mappings.map(\.trigger), [.tap(3), .anchorSwipe(.up), .anchorSwipe(.down)])
        XCTAssertEqual(profiles[1].mappings, [alreadyAnchored], "Profiles already using the gesture aren't changed")
        XCTAssertEqual(result.configuration.general.cooldown, 1.5)
        XCTAssertEqual(result.configuration.schemaVersion, 2)
    }

    func testAnchorTriggerValidation() {
        XCTAssertEqual(GestureTrigger(kind: .anchorSwipe, fingers: 4, direction: .up).fingers, 2)
        XCTAssertEqual(GestureTrigger(kind: .anchorSwipe, fingers: 2, direction: .left).direction, .up)
        XCTAssertTrue(GestureTrigger.anchorSwipe(.down).isValid)
        XCTAssertNil(SystemGestureSettings.assumedDefaults.overlap(with: .anchorSwipe(.up)))
    }

    // MARK: Scrolling stays blocked for the whole cycle

    func testCancelledGestureKeepsOwningTheCycleUntilLift() {
        let frames = generator.anchorSequence(anchorPath: { SIMD2(12 * $0, 0) }) { SIMD2(0, 40 * $0) }
        var recognizer = AnchorSwipeRecognizer(armed: armed)
        var sawCancelWhileOwning = false
        for frame in frames.dropLast() {
            _ = recognizer.process(frame)
            if case .cancelled = recognizer.state, recognizer.claimsCycle { sawCancelWhileOwning = true }
        }
        XCTAssertTrue(sawCancelWhileOwning, "Ownership must outlive the cancellation")
        _ = recognizer.process(frames.last!)
        XCTAssertFalse(recognizer.claimsCycle, "Released once every finger lifts")
    }

    func testEngineKeepsScrollBlockedAfterAnchorDriftAndReportsWhy() {
        let changes = OSAllocatedUnfairLock(initialState: [Bool]())
        let swipe = GestureMapping(trigger: .swipe(2, .up), action: .media(command: .playPause))
        let engine = GestureEngine(
            configuration: AppConfiguration(profiles: [profile([swipe])]),
            clock: { 0 },
            continuousGestureObserver: { active in changes.withLock { $0.append(active) } },
            output: { _ in }
        )
        let frames = generator.anchorSequence(anchorPath: { SIMD2(12 * $0, 0) }) { SIMD2(0, 40 * $0) }
        let outputs = engine.processSynchronously(frames)
        XCTAssertEqual(changes.withLock { $0 }, [true, false], "Blocked from landing until all fingers lift, not just until the cancel")
        let stops = outputs.compactMap { output -> String? in
            if case .anchorGestureStopped(let reason) = output { return reason }
            return nil
        }
        XCTAssertEqual(stops, ["Anchor moved"])
        let regular = outputs.contains { output in
            if case .recognized(let event, _) = output { return event.trigger.kind != .anchorSwipe }
            return false
        }
        XCTAssertFalse(regular, "The rest of the motion must not become a two-finger swipe")
    }

    func testSuppressionWindows() {
        let suppressor = InputSuppressor()
        let now = { ProcessInfo.processInfo.systemUptime }
        XCTAssertFalse(suppressor.shouldDrop(.scroll(momentum: false), now: now()))
        XCTAssertFalse(suppressor.shouldDrop(.pointer, now: now()), "Normal pointing is untouched")
        suppressor.setActive(true)
        XCTAssertTrue(suppressor.shouldDrop(.scroll(momentum: false), now: now()))
        XCTAssertTrue(suppressor.shouldDrop(.pointer, now: now()), "Pointer held still during the gesture")
        suppressor.setActive(false)
        let released = now()
        XCTAssertTrue(suppressor.shouldDrop(.scroll(momentum: false), now: released + 0.05), "Trailing events right after lift")
        XCTAssertTrue(suppressor.shouldDrop(.pointer, now: released + 0.05))
        XCTAssertFalse(suppressor.shouldDrop(.scroll(momentum: false), now: released + 0.5), "Normal scrolling resumes")
        XCTAssertFalse(suppressor.shouldDrop(.pointer, now: released + 0.5), "Normal pointing resumes")
        XCTAssertTrue(suppressor.shouldDrop(.scroll(momentum: true), now: released + 0.5), "Momentum from the gesture")
        XCTAssertFalse(suppressor.shouldDrop(.scroll(momentum: true), now: released + 2), "Later momentum is the user's")
    }

    // MARK: Haptic feedback

    /// Clicks produced by a gesture that sweeps through `levels` 50 ms apart.
    private func clicks(_ mode: VolumeHapticMode, _ levels: [Double], interval: TimeInterval = 0.05) -> [HapticStrength] {
        var feedback = VolumeHapticFeedback(mode: mode)
        return levels.enumerated().compactMap { index, level in
            feedback.feedback(forLevel: level, at: Double(index) * interval)
        }
    }

    private let sweepUp = (50...75).map { Double($0) / 100 }

    func testDefaultClicksAtEveryTenPercent() {
        XCTAssertEqual(VolumeHapticFeedback().mode, .everyStep)
        // 50% → 75% crosses the 60% and 70% marks.
        XCTAssertEqual(clicks(.everyStep, sweepUp), [.weak, .weak])
        // 45% → 100% in 1% steps: 50, 60, 70, 80, 90 light, then 100% firm.
        let toTop = (45...100).map { Double($0) / 100 }
        XCTAssertEqual(clicks(.everyStep, toTop), Array(repeating: .weak, count: 5) + [.medium])
        // Downward works the same way.
        let down = (25...55).reversed().map { Double($0) / 100 }
        XCTAssertEqual(clicks(.everyStep, down).count, 3, "50, 40, 30")
    }

    func testTinyMovesAroundAMarkDontStutter() {
        // Small steps that stay within one 10% band never click.
        XCTAssertEqual(clicks(.everyStep, [0.52, 0.54, 0.56, 0.58, 0.56, 0.53]), [])
    }

    func testLimitsAreMarkedOnceInEveryMode() {
        let toTop = [0.94, 0.97, 1.0, 1.0, 1.0]
        XCTAssertEqual(clicks(.limits, toTop), [.medium])
        XCTAssertEqual(clicks(.everyStep, toTop), [.medium])
        XCTAssertEqual(clicks(.startAndLimits, toTop), [.weak, .medium])
        XCTAssertEqual(clicks(.everyStep, [1.0, 1.0, 1.0]), [.medium], "Already at the top: one firm click")
        XCTAssertEqual(clicks(.limits, [0.04, 0.01, 0.0, 0.0]), [.medium])
        XCTAssertEqual(clicks(.off, toTop), [])
    }

    func testEveryTenPercentIsRateLimited() {
        let fast = (1...9).map { Double($0) / 10 + 0.05 }
        XCTAssertLessThanOrEqual(clicks(.everyStep, fast, interval: 0.005).count, 2)
    }

    func testResetStartsANewGesture() {
        var feedback = VolumeHapticFeedback(mode: .startAndLimits)
        XCTAssertEqual(feedback.feedback(forLevel: 0.5, at: 0), .weak)
        XCTAssertNil(feedback.feedback(forLevel: 0.6, at: 1))
        feedback.reset()
        XCTAssertEqual(feedback.feedback(forLevel: 0.6, at: 2), .weak)
    }

    func testLegacyHapticSwitchIsMigrated() throws {
        let off = try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"volumeHaptics": false}"#.utf8))
        XCTAssertEqual(off.volumeHapticMode, .off)
        let on = try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"volumeHaptics": true}"#.utf8))
        XCTAssertEqual(on.volumeHapticMode, .everyStep)
        let encoded = String(decoding: try JSONEncoder().encode(on), as: UTF8.self)
        XCTAssertFalse(encoded.contains("\"volumeHaptics\""), "The old key isn't written back")
    }
}
