import CoreGraphics
import Foundation
import os

/// Holds the page and the pointer still while a continuous trackpad gesture
/// is active.
///
/// MultitouchSupport can only observe touches, so while the anchor gesture's
/// second finger moves, macOS also acts on it: usually as a two-finger scroll,
/// and sometimes, when it decides the still anchor is a resting finger, as
/// pointer movement. This installs a session event tap (requires
/// Accessibility) on a dedicated thread. While active it:
///
/// * drops scroll-wheel events, plus trailing events right after release and
///   the momentum scroll that follows;
/// * drops pointer-movement events and returns the cursor to where it was
///   when the gesture started.
public final class InputSuppressor: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case stopped
        case running
        case failed(String)
    }

    public enum EventKind: Sendable {
        case scroll(momentum: Bool)
        case pointer
    }

    private struct State {
        var active = false
        var releasedAt: TimeInterval = -.infinity
        /// Cursor position (global, top-left origin) when the gesture began.
        var frozenCursor: CGPoint?
        var droppedEvents = 0
    }

    /// Momentum scrolling after lift is also swallowed for this long.
    private static let momentumWindow: TimeInterval = 1.0
    /// macOS can deliver the last events slightly after the raw touch data
    /// reports the lift; drop scroll and pointer events for this long.
    private static let releaseGrace: TimeInterval = 0.2

    private let state = OSAllocatedUnfairLock(initialState: State())
    // Tap lifecycle; only touched under `lifecycle`.
    private let lifecycle = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var currentStatus = Status.stopped

    public init() {}

    // The owner (AppModel) lives for the whole app session, so the tap's
    // unretained pointer to this object stays valid while the tap exists.
    deinit {
        stop()
    }

    public var status: Status {
        lifecycle.withLock { currentStatus }
    }

    public var droppedEventCount: Int {
        state.withLock { $0.droppedEvents }
    }

    /// Called from the recognition queue when the gesture starts or ends.
    public func setActive(_ active: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        // Reading the cursor location is thread-safe.
        let cursor = active ? CGEvent(source: nil)?.location : nil
        state.withLock { state in
            if state.active, !active {
                state.releasedAt = now
            }
            if active, !state.active {
                state.frozenCursor = cursor
            }
            state.active = active
        }
    }

    /// Whether an event arriving now should be discarded.
    func shouldDrop(_ kind: EventKind, now: TimeInterval) -> Bool {
        state.withLock { state in
            let sinceRelease = now - state.releasedAt
            let suppress: Bool = switch kind {
            case .scroll(let momentum):
                state.active || sinceRelease < Self.releaseGrace || (momentum && sinceRelease < Self.momentumWindow)
            case .pointer:
                state.active || sinceRelease < Self.releaseGrace
            }
            if suppress { state.droppedEvents += 1 }
            return suppress
        }
    }

    /// Installs the tap. Safe to call repeatedly; check `status` afterwards.
    public func start() {
        let ready = DispatchSemaphore(value: 0)
        let started = lifecycle.withLock { () -> Bool in
            guard thread == nil else { return false }
            let thread = Thread { [weak self] in
                guard let self else {
                    ready.signal()
                    return
                }
                self.runTap(signal: ready)
            }
            thread.name = "MacGesture.input-suppressor"
            thread.qualityOfService = .userInteractive
            self.thread = thread
            thread.start()
            return true
        }
        if started {
            ready.wait()
        }
    }

    public func stop() {
        lifecycle.lock()
        let loop = runLoop
        let port = tap
        thread = nil
        runLoop = nil
        tap = nil
        currentStatus = .stopped
        lifecycle.unlock()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop {
            CFRunLoopStop(loop)
        }
        setActive(false)
    }

    private func runTap(signal: DispatchSemaphore) {
        let types: [CGEventType] = [.scrollWheel, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: inputSuppressorCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            lifecycle.withLock {
                currentStatus = .failed("macOS refused the event tap. Accessibility permission is required.")
                thread = nil
            }
            signal.signal()
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes)
        lifecycle.withLock {
            tap = port
            runLoop = loop
            currentStatus = .running
        }
        signal.signal()
        CFRunLoopRun()
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables slow taps; turn it back on.
            if let port = lifecycle.withLock({ tap }) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
            return shouldDrop(.scroll(momentum: momentum), now: now) ? nil : Unmanaged.passUnretained(event)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard shouldDrop(.pointer, now: now) else { return Unmanaged.passUnretained(event) }
            // Dropping the event hides the movement from apps; the cursor
            // itself is drawn by the window server, so put it back.
            if let frozen = state.withLock({ $0.frozenCursor }), event.location != frozen {
                CGWarpMouseCursorPosition(frozen)
                // Warping briefly suppresses local input; re-associating cancels that.
                CGAssociateMouseAndMouseCursorPosition(1)
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

private func inputSuppressorCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputSuppressor>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
}
