import Foundation
import os

/// Runs configured executables. Output is discarded rather than logged, since
/// it may contain personal data; only the exit status is reported.
public enum CommandRunner {
    public static let shellPath = "/bin/zsh"
    public static let shortcutsPath = "/usr/bin/shortcuts"

    /// Inherited environment plus common tool locations, because apps launched
    /// from Finder get a minimal PATH.
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = (existing + extra.filter { !existing.contains($0) }).joined(separator: ":")
        return environment
    }

    public static func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws(ActionError) -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let handle = ProcessHandle(process)

        let outcome: (status: Int32, reason: Process.TerminationReason)
        do {
            outcome = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: (finished.terminationStatus, finished.terminationReason))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + max(timeout, 1)) {
                    handle.terminateIfRunning()
                }
            }
        } catch {
            throw .executionFailed("Couldn't start \(executable.lastPathComponent): \(error.localizedDescription)")
        }

        let name = executable.lastPathComponent
        switch (outcome.reason, outcome.status) {
        case (.exit, 0):
            return "\(name) finished"
        case (.exit, let status):
            throw .executionFailed("\(name) exited with status \(status).")
        case (.uncaughtSignal, let signal):
            throw .executionFailed(handle.timedOut ? "\(name) timed out after \(Int(timeout))s." : "\(name) was terminated (signal \(signal)).")
        @unknown default:
            throw .executionFailed("\(name) ended unexpectedly.")
        }
    }
}

/// Lets the timeout path terminate a process from another thread.
private final class ProcessHandle: @unchecked Sendable {
    // Process's isRunning/terminate are thread-safe; the flag is lock-protected.
    private let process: Process
    private let didTimeOut = OSAllocatedUnfairLock(initialState: false)

    init(_ process: Process) {
        self.process = process
    }

    var timedOut: Bool {
        didTimeOut.withLock { $0 }
    }

    func terminateIfRunning() {
        guard process.isRunning else { return }
        didTimeOut.withLock { $0 = true }
        process.terminate()
    }
}
