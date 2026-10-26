import Foundation

/// A throttled view of recognizer state for the live testing UI.
public struct EngineDiagnostics: Sendable {
    public var device: TrackpadDevice
    public var touches: [TouchPoint]
    public var phase: RecognitionPhase
    public var metrics: GestureMetrics
    public var progress: RecognitionProgress
    public var anchor: AnchorSwipeState
    public var timestamp: TimeInterval

    public var source: InputSourceKind { device.source }
}

public enum EngineOutput: Sendable {
    case recognized(GestureEvent, RouteDecision)
    case diagnostics(EngineDiagnostics)
    /// An anchor gesture that had started was stopped early, and why.
    case anchorGestureStopped(reason: String)
}

public enum RecognitionMode: Sendable, Equatable {
    /// Recognize the active profile's gestures and route them to actions.
    case normal
    /// Recognize every gesture type with default thresholds; nothing is routed.
    case diagnoseAll
}

/// The input → recognition → routing pipeline. Frames may arrive on any
/// thread; all processing happens in order on a private serial queue, and
/// results are handed to `output` on that queue.
public final class GestureEngine: @unchecked Sendable {
    /// The recognizers for one device. The anchor recognizer can claim a
    /// touch cycle, which cancels the regular recognizer's cycle so a single
    /// motion can't trigger competing mappings.
    private struct DeviceRecognizers {
        var regular: GestureRecognizer
        var anchor: AnchorSwipeRecognizer
    }

    // All mutable state below is confined to `queue`.
    private let queue = DispatchQueue(label: "MacGesture.recognition", qos: .userInteractive)
    private let output: @Sendable (EngineOutput) -> Void
    private let clock: @Sendable () -> TimeInterval
    private let continuousGestureObserver: (@Sendable (Bool) -> Void)?

    private var devices: [UInt64: DeviceRecognizers] = [:]
    private var router: GestureRouter
    private var settings: RecognitionSettings
    private var profileArmed: ArmedGestures
    private var isEnabled: Bool
    private var mode = RecognitionMode.normal
    private var diagnosticsInterval: TimeInterval?
    private var lastDiagnosticsTime: TimeInterval = 0
    private var lastDiagnosticsPhase: RecognitionPhase?
    private var lastDiagnosticsAnchor: AnchorSwipeState?
    private var continuousActive = false

    /// - Parameter continuousGestureObserver: called on the recognition queue
    ///   when a continuous gesture (anchor swipe) starts or stops owning the
    ///   trackpad, e.g. to suppress scrolling meanwhile.
    public init(
        configuration: AppConfiguration,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        continuousGestureObserver: (@Sendable (Bool) -> Void)? = nil,
        output: @escaping @Sendable (EngineOutput) -> Void
    ) {
        self.output = output
        self.clock = clock
        self.continuousGestureObserver = continuousGestureObserver
        settings = configuration.recognition
        isEnabled = configuration.general.isEnabled
        router = GestureRouter(profile: configuration.activeProfile, cooldown: configuration.general.cooldown)
        profileArmed = GestureRouter.armedGestures(for: configuration.activeProfile, globalSensitivity: configuration.recognition.sensitivity)
    }

    public func ingest(_ frame: TouchFrame) {
        queue.async { [self] in
            process(frame, emit: output)
        }
    }

    public func apply(_ configuration: AppConfiguration) {
        queue.async { [self] in
            settings = configuration.recognition
            isEnabled = configuration.general.isEnabled
            router.update(profile: configuration.activeProfile, cooldown: configuration.general.cooldown)
            profileArmed = GestureRouter.armedGestures(for: configuration.activeProfile, globalSensitivity: configuration.recognition.sensitivity)
            refreshRecognizers()
        }
    }

    public func setMode(_ mode: RecognitionMode) {
        queue.async { [self] in
            guard self.mode != mode else { return }
            self.mode = mode
            refreshRecognizers()
        }
    }

    /// Enables throttled diagnostics at the given rate (Hz), or disables them.
    public func setDiagnosticsRate(_ rate: Double?) {
        queue.async { [self] in
            diagnosticsInterval = rate.map { 1 / max($0, 1) }
        }
    }

    /// Abandons in-progress gestures, e.g. after the input backend restarts.
    public func reset() {
        queue.async { [self] in
            devices.removeAll()
            updateContinuousActivity()
        }
    }

    /// Processes frames synchronously and returns everything emitted. For tests.
    public func processSynchronously(_ frames: [TouchFrame]) -> [EngineOutput] {
        queue.sync {
            var collected: [EngineOutput] = []
            for frame in frames {
                process(frame) { collected.append($0) }
            }
            return collected
        }
    }

    // MARK: - Queue-confined

    private var activeArmed: ArmedGestures {
        mode == .diagnoseAll ? .everything : profileArmed
    }

    private var activeSettings: RecognitionSettings {
        if mode == .diagnoseAll {
            // Default thresholds, but keep the user's anchor-gesture tuning:
            // live test is where they check it.
            var defaults = RecognitionSettings()
            defaults.anchorMinimumHold = settings.anchorMinimumHold
            defaults.anchorMovementTolerance = settings.anchorMovementTolerance
            defaults.anchorDeadZone = settings.anchorDeadZone
            defaults.anchorStepDistance = settings.anchorStepDistance
            return defaults
        }
        return settings
    }

    private func makeRecognizers() -> DeviceRecognizers {
        DeviceRecognizers(
            regular: GestureRecognizer(settings: activeSettings, armed: activeArmed),
            anchor: AnchorSwipeRecognizer(settings: activeSettings, armed: activeArmed)
        )
    }

    private func refreshRecognizers() {
        for key in devices.keys {
            devices[key] = makeRecognizers()
        }
        updateContinuousActivity()
    }

    private func process(_ frame: TouchFrame, emit: (EngineOutput) -> Void) {
        let diagnosing = diagnosticsInterval != nil
        guard isEnabled || diagnosing || mode == .diagnoseAll else { return }

        let deviceID = frame.device.id
        var recognizers = devices[deviceID] ?? makeRecognizers()

        var anchorEvent: GestureEvent?
        if activeArmed.armsAnchorSwipe {
            let before = recognizers.anchor.state
            anchorEvent = recognizers.anchor.process(frame, mayActivate: !recognizers.regular.hasRecognizedInCycle)
            if recognizers.anchor.claimsCycle, case .cancelled(let reason) = recognizers.anchor.state, before != recognizers.anchor.state {
                emit(.anchorGestureStopped(reason: reason))
            }
            if recognizers.anchor.claimsCycle {
                recognizers.regular.cancelCycle(reason: "Anchor gesture in progress")
            }
        }
        let regularEvent = recognizers.regular.process(frame)
        devices[deviceID] = recognizers
        updateContinuousActivity()

        var emitted = false
        for event in [anchorEvent, regularEvent].compactMap({ $0 }) {
            let decision: RouteDecision = mode == .diagnoseAll
                ? .suppressed(reason: "Diagnostics mode: actions are not run")
                : router.route(event, now: clock(), isEnabled: isEnabled)
            emit(.recognized(event, decision))
            emitted = true
        }
        emitDiagnostics(for: frame, recognizers: recognizers, emit: emit, force: emitted)
    }

    private func updateContinuousActivity() {
        let active = devices.values.contains { $0.anchor.claimsCycle }
        guard active != continuousActive else { return }
        continuousActive = active
        continuousGestureObserver?(active)
    }

    private func emitDiagnostics(for frame: TouchFrame, recognizers: DeviceRecognizers, emit: (EngineOutput) -> Void, force: Bool) {
        guard let interval = diagnosticsInterval else { return }
        let now = clock()
        let changed = recognizers.regular.phase != lastDiagnosticsPhase || recognizers.anchor.state != lastDiagnosticsAnchor
        guard force || changed || frame.touches.isEmpty || now - lastDiagnosticsTime >= interval else { return }
        lastDiagnosticsTime = now
        lastDiagnosticsPhase = recognizers.regular.phase
        lastDiagnosticsAnchor = recognizers.anchor.state
        emit(.diagnostics(EngineDiagnostics(
            device: frame.device,
            touches: frame.touches,
            phase: recognizers.regular.phase,
            metrics: recognizers.regular.metrics,
            progress: recognizers.regular.progress,
            anchor: recognizers.anchor.state,
            timestamp: frame.timestamp
        )))
    }
}
