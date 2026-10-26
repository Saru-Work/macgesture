import Foundation
import os

/// Generates touch frames in software for the live simulator and tests.
/// Every frame it emits is labelled `.simulated`; it never stands in for
/// hardware detection.
public final class SimulatedInputProvider: TrackpadInputProvider {
    private struct State {
        var handler: (@Sendable (TouchFrame) -> Void)?
        var generation = 0
    }

    public let kind = InputSourceKind.simulated
    public let displayName = "Simulator"

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "MacGesture.simulator", qos: .userInteractive)

    public init() {}

    public var isRunning: Bool {
        state.withLock { $0.handler != nil }
    }

    public func availability() -> InputProviderAvailability {
        .available(devices: [.simulated])
    }

    public func start(handler: @escaping @Sendable (TouchFrame) -> Void) throws {
        try state.withLock { state in
            guard state.handler == nil else { throw InputProviderError.alreadyRunning }
            state.handler = handler
        }
    }

    public func stop() {
        state.withLock { state in
            state.handler = nil
            state.generation += 1
        }
        // Drain anything already queued so no delivery is in flight.
        queue.sync {}
    }

    /// Delivers a single frame immediately, relabelled as simulated.
    public func inject(_ frame: TouchFrame) {
        var relabelled = frame
        relabelled.device = .simulated
        let delivery = relabelled
        queue.async { [weak self] in
            self?.deliver(delivery, generation: nil)
        }
    }

    /// Replays a recorded or generated sequence with its original timing,
    /// cancelling any sequence that is still playing.
    public func play(_ frames: [TouchFrame]) {
        guard let first = frames.first else { return }
        let generation = state.withLock { state in
            state.generation += 1
            return state.generation
        }
        let start = DispatchTime.now()
        let clockBase = ProcessInfo.processInfo.systemUptime
        for frame in frames {
            let offset = frame.timestamp - first.timestamp
            var retimed = frame
            retimed.timestamp = clockBase + offset
            retimed.device = .simulated
            let delivery = retimed
            queue.asyncAfter(deadline: start + offset) { [weak self] in
                self?.deliver(delivery, generation: generation)
            }
        }
    }

    private func deliver(_ frame: TouchFrame, generation: Int?) {
        let handler = state.withLock { state -> (@Sendable (TouchFrame) -> Void)? in
            if let generation, generation != state.generation { return nil }
            return state.handler
        }
        handler?(frame)
    }
}
