import Foundation

public enum ActionError: Error, LocalizedError, Sendable, Equatable {
    case permissionRequired(PermissionKind)
    case unsupported(String)
    case invalidConfiguration(String)
    case noTargetWindow
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionRequired(let permission): "\(permission.displayName) permission is required."
        case .unsupported(let reason): reason
        case .invalidConfiguration(let reason): reason
        case .noTargetWindow: "No focused window to act on."
        case .executionFailed(let reason): reason
        }
    }
}

public enum ActionResult: Sendable, Equatable {
    case success(String)
    case failure(ActionError)
    case cancelled(String)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .success(let message): message
        case .failure(let error): error.localizedDescription
        case .cancelled(let reason): reason
        }
    }
}
