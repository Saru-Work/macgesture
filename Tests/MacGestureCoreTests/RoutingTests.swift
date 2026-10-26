import os
import XCTest
@testable import MacGestureCore

final class RoutingTests: XCTestCase {
    private func event(_ trigger: GestureTrigger) -> GestureEvent {
        GestureEvent(trigger: trigger, timestamp: 0, source: .simulated, deviceID: 1, score: 1, metrics: GestureMetrics())
    }

    private func profile(_ mappings: [GestureMapping]) -> GestureProfile {
        GestureProfile(name: "Test", mappings: mappings)
    }

    func testRoutesToEnabledMapping() {
        let mapping = GestureMapping(trigger: .swipe(3, .left), action: .media(command: .playPause))
        var router = GestureRouter(profile: profile([mapping]), cooldown: 0.3)
        XCTAssertEqual(router.route(event(.swipe(3, .left)), now: 10), .execute(mapping))
        XCTAssertEqual(router.route(event(.swipe(3, .right)), now: 20), .noMapping)
    }

    func testDisabledMappingAndPausedEngine() {
        let mapping = GestureMapping(isEnabled: false, trigger: .tap(3), action: .media(command: .playPause))
        var router = GestureRouter(profile: profile([mapping]), cooldown: 0)
        XCTAssertEqual(router.route(event(.tap(3)), now: 1), .noMapping)
        XCTAssertEqual(router.route(event(.tap(3)), now: 1, isEnabled: false), .disabled)
    }

    func testFirstDuplicateWins() {
        let first = GestureMapping(name: "First", trigger: .tap(4), action: .media(command: .playPause))
        let second = GestureMapping(name: "Second", trigger: .tap(4), action: .media(command: .nextTrack))
        var router = GestureRouter(profile: profile([first, second]), cooldown: 0)
        XCTAssertEqual(router.route(event(.tap(4)), now: 1), .execute(first))
    }

    func testGlobalCooldown() {
        let a = GestureMapping(trigger: .tap(3), action: .media(command: .playPause))
        let b = GestureMapping(trigger: .tap(4), action: .media(command: .nextTrack))
        var router = GestureRouter(profile: profile([a, b]), cooldown: 0.5)
        XCTAssertEqual(router.route(event(.tap(3)), now: 10), .execute(a))
        guard case .coolingDown(let remaining) = router.route(event(.tap(4)), now: 10.2) else {
            return XCTFail("Expected cooldown")
        }
        XCTAssertEqual(remaining, 0.3, accuracy: 0.001)
        XCTAssertEqual(router.route(event(.tap(4)), now: 10.6), .execute(b))
    }

    func testPerMappingCooldown() {
        let a = GestureMapping(trigger: .tap(3), action: .media(command: .playPause), cooldown: 2)
        let b = GestureMapping(trigger: .tap(4), action: .media(command: .nextTrack))
        var router = GestureRouter(profile: profile([a, b]), cooldown: 0.1)
        XCTAssertEqual(router.route(event(.tap(3)), now: 0), .execute(a))
        XCTAssertEqual(router.route(event(.tap(4)), now: 0.5), .execute(b))
        if case .execute = router.route(event(.tap(3)), now: 1) { XCTFail("Per-mapping cooldown ignored") }
        XCTAssertEqual(router.route(event(.tap(3)), now: 2.5), .execute(a))
    }

    func testArmedGesturesFromProfile() {
        let mappings = [
            GestureMapping(trigger: .swipe(3, .upLeft), action: .none, sensitivity: 1),
            GestureMapping(isEnabled: false, trigger: .pinch(3, .pinchIn), action: .none),
            GestureMapping(trigger: .circle(4, .clockwise), action: .none),
        ]
        let armed = GestureRouter.armedGestures(for: profile(mappings), globalSensitivity: 0.5)
        XCTAssertTrue(armed.isArmed(.swipe(3, .upLeft)))
        XCTAssertFalse(armed.isArmed(.pinch(3, .pinchIn)))
        XCTAssertTrue(armed.allowsDiagonalSwipes(fingers: 3))
        XCTAssertFalse(armed.allowsDiagonalSwipes(fingers: 4))
        XCTAssertTrue(armed.hasArmed(.circle, fingers: 4))
        XCTAssertEqual(armed.thresholdScale(for: .swipe(3, .upLeft)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(armed.thresholdScale(for: .circle(4, .clockwise)), 1)
    }

    // MARK: - Engine integration

    func testEngineRecognizesAndRoutes() {
        let mapping = GestureMapping(trigger: .swipe(3, .left), action: .media(command: .playPause))
        let configuration = AppConfiguration(profiles: [profile([mapping])])
        let engine = GestureEngine(configuration: configuration, clock: { 0 }, output: { _ in })
        let outputs = engine.processSynchronously(SyntheticGestureGenerator().swipe(fingers: 3, direction: .left))
        let decisions = outputs.compactMap { output -> RouteDecision? in
            if case .recognized(_, let decision) = output { return decision }
            return nil
        }
        XCTAssertEqual(decisions, [.execute(mapping)])
    }

    func testEngineCooldownAcrossGestures() {
        let clock = OSAllocatedUnfairLock(initialState: 100.0)
        let mapping = GestureMapping(trigger: .tap(3), action: .media(command: .playPause))
        var configuration = AppConfiguration(profiles: [profile([mapping])])
        configuration.general.cooldown = 1
        let engine = GestureEngine(configuration: configuration, clock: { clock.withLock { $0 } }, output: { _ in })

        var generator = SyntheticGestureGenerator()
        func decisions() -> [RouteDecision] {
            generator.startTime += 10
            return engine.processSynchronously(generator.tap(fingers: 3)).compactMap {
                if case .recognized(_, let decision) = $0 { return decision }
                return nil
            }
        }
        XCTAssertEqual(decisions(), [.execute(mapping)])
        clock.withLock { $0 += 0.4 }
        guard case .coolingDown = decisions().first else { return XCTFail("Expected cooldown") }
        clock.withLock { $0 += 1 }
        XCTAssertEqual(decisions(), [.execute(mapping)])
    }

    func testEngineDiagnosticsModeSuppressesActions() {
        let configuration = AppConfiguration(profiles: [profile([GestureMapping(trigger: .tap(3), action: .media(command: .playPause))])])
        let engine = GestureEngine(configuration: configuration, clock: { 0 }, output: { _ in })
        engine.setMode(.diagnoseAll)
        let outputs = engine.processSynchronously(SyntheticGestureGenerator().pinch(fingers: 4, scale: 0.5))
        let recognized = outputs.compactMap { output -> (GestureTrigger, RouteDecision)? in
            if case .recognized(let event, let decision) = output { return (event.trigger, decision) }
            return nil
        }
        XCTAssertEqual(recognized.map(\.0), [.pinch(4, .pinchIn)])
        if case .suppressed = recognized.first?.1 {} else { XCTFail("Diagnostics must not route to actions") }
    }

    func testEnginePausedDoesNothingWithoutDiagnostics() {
        var configuration = AppConfiguration(profiles: [profile([GestureMapping(trigger: .tap(3), action: .none)])])
        configuration.general.isEnabled = false
        let engine = GestureEngine(configuration: configuration, clock: { 0 }, output: { _ in })
        XCTAssertTrue(engine.processSynchronously(SyntheticGestureGenerator().tap(fingers: 3)).isEmpty)
    }

    func testEngineKeepsDevicesSeparate() {
        let configuration = AppConfiguration(profiles: [profile([GestureMapping(trigger: .tap(4), action: .none)])])
        let engine = GestureEngine(configuration: configuration, clock: { 0 }, output: { _ in })
        // Two fingers on each of two trackpads must not add up to a 4-finger tap.
        var second = SyntheticGestureGenerator(device: TrackpadDevice(id: 7, name: "B", isBuiltIn: false, surfaceSize: SIMD2(160, 115), source: .hardware))
        second.startTime = SyntheticGestureGenerator().startTime
        let a = SyntheticGestureGenerator().tap(fingers: 2)
        let b = second.tap(fingers: 2)
        let interleaved = zip(a, b).flatMap { [$0, $1] }
        let recognized = engine.processSynchronously(interleaved).filter {
            if case .recognized = $0 { return true }
            return false
        }
        XCTAssertTrue(recognized.isEmpty)
    }

    // MARK: - Conflicts

    func testConflictDetection() {
        let duplicateA = GestureMapping(name: "A", trigger: .tap(3), action: .media(command: .playPause))
        let duplicateB = GestureMapping(name: "B", trigger: .tap(3), action: .media(command: .nextTrack))
        let badScript = GestureMapping(name: "Script", trigger: .tap(4), action: .runScript(script: ScriptAction(executablePath: "relative/path")))
        let overlap = GestureMapping(name: "Spaces", trigger: .swipe(4, .left), action: .none)
        let swipe = GestureMapping(name: "Swipe", trigger: .swipe(3, .up), action: .none)
        let circle = GestureMapping(name: "Circle", trigger: .circle(3, .clockwise), action: .none)

        var system = SystemGestureSettings()
        system.fourFingerHorizontalSwipe = true
        let issues = MappingConflictDetector.issues(
            in: profile([duplicateA, duplicateB, badScript, overlap, swipe, circle]),
            system: system
        )
        XCTAssertTrue(issues.contains { $0.severity == .error && Set($0.mappingIDs) == [duplicateA.id, duplicateB.id] })
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.mappingIDs == [badScript.id] })
        XCTAssertTrue(issues.contains { $0.severity == .warning && $0.mappingIDs == [overlap.id] })
        XCTAssertTrue(issues.contains { $0.severity == .note && $0.mappingIDs == [swipe.id] })
        XCTAssertEqual(issues.first?.severity, .error, "Errors sort first")
    }

    func testSystemOverlapRules() {
        var system = SystemGestureSettings()
        XCTAssertNotNil(system.overlap(with: .pinch(2, .pinchIn)))
        XCTAssertNil(system.overlap(with: .swipe(3, .left)))
        system.threeFingerHorizontalSwipe = true
        XCTAssertNotNil(system.overlap(with: .swipe(3, .left)))
        XCTAssertNil(system.overlap(with: .swipe(3, .up)))
        XCTAssertNotNil(system.overlap(with: .swipe(3, .upLeft)))
        system.threeFingerDrag = true
        XCTAssertNotNil(system.overlap(with: .circle(3, .clockwise)))
        XCTAssertNil(system.overlap(with: .rotate(3, .clockwise)))
    }
}
