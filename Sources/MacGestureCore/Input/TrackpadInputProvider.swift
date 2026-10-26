import Foundation

public enum InputProviderAvailability: Sendable, Equatable {
    case available(devices: [TrackpadDevice])
    case noDevices
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

public enum InputProviderError: Error, LocalizedError, Equatable, Sendable {
    case frameworkUnavailable
    case symbolsMissing
    case noDevices
    case alreadyRunning
    case failed(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            "MultitouchSupport.framework could not be loaded on this version of macOS."
        case .symbolsMissing:
            "MultitouchSupport.framework loaded, but required functions are missing. This macOS version changed the private API."
        case .noDevices:
            "No multitouch trackpad is attached."
        case .alreadyRunning:
            "The trackpad backend is already running."
        case .failed(let code):
            "The trackpad backend failed to start (code \(code))."
        }
    }
}

/// A source of normalized touch frames. Recognition, routing, and UI depend
/// only on this protocol, never on a specific backend.
public protocol TrackpadInputProvider: AnyObject, Sendable {
    var kind: InputSourceKind { get }
    var displayName: String { get }
    var isRunning: Bool { get }

    func availability() -> InputProviderAvailability

    /// Begins delivering frames. The handler may be called on any thread,
    /// but never concurrently with itself.
    func start(handler: @escaping @Sendable (TouchFrame) -> Void) throws

    /// Stops delivery. No handler call is in flight once this returns.
    func stop()
}
