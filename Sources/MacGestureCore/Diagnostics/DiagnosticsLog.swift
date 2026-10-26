import Foundation
import os

/// Writes to the unified log and, unless logging is off, to
/// ~/Library/Logs/MacGesture/MacGesture.log. Callers log gesture names, action
/// categories, and outcomes only: never command text, script arguments,
/// script output, or URLs.
public final class DiagnosticsLog: Sendable {
    public static let shared = DiagnosticsLog()

    public let fileURL: URL
    private let logger = Logger(subsystem: "local.macgesture.MacGesture", category: "events")
    private let level = OSAllocatedUnfairLock(initialState: LogLevel.standard)
    private let queue = DispatchQueue(label: "MacGesture.log", qos: .utility)
    private static let maximumSize = 1_000_000

    public init(directory: URL? = nil) {
        let logs = directory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MacGesture", isDirectory: true)
        fileURL = logs.appendingPathComponent("MacGesture.log")
    }

    public func setLevel(_ newLevel: LogLevel) {
        level.withLock { $0 = newLevel }
    }

    public func info(_ message: String) {
        write(message, minimum: .standard, type: .info)
    }

    public func debug(_ message: String) {
        write(message, minimum: .verbose, type: .debug)
    }

    public func error(_ message: String) {
        write(message, minimum: .standard, type: .error)
    }

    private func write(_ message: String, minimum: LogLevel, type: OSLogType) {
        let current = level.withLock { $0 }
        guard current != .off, current == .verbose || minimum == .standard else { return }
        logger.log(level: type, "\(message, privacy: .public)")

        let line = "\(Date().ISO8601Format()) \(message)\n"
        let url = fileURL
        queue.async {
            Self.append(line, to: url)
        }
    }

    private static func append(_ line: String, to url: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int, size > maximumSize {
            let rotated = url.appendingPathExtension("1")
            try? fileManager.removeItem(at: rotated)
            try? fileManager.moveItem(at: url, to: rotated)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
