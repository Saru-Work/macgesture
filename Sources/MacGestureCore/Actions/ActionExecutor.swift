import AppKit
import Foundation

public struct ConfirmationRequest: Sendable {
    public var title: String
    public var message: String
    /// The exact command or path, shown verbatim.
    public var detail: String
    public var isDestructive: Bool
}

/// Dispatches actions to their performers and turns every outcome, including
/// missing permissions and unsupported operations, into an `ActionResult`.
@MainActor
public final class ActionExecutor {
    public typealias ConfirmationHandler = @MainActor (ConfirmationRequest) async -> Bool

    private let windowManager = WindowManager()
    /// MacGesture's own windows must be handled on the main thread.
    private var ownWindows = WindowOperator()
    private let confirm: ConfirmationHandler
    public let volume: VolumeController

    public init(volume: VolumeController = VolumeController(), confirm: @escaping ConfirmationHandler) {
        self.volume = volume
        self.confirm = confirm
    }

    /// - Parameter magnitude: steps carried by a continuous gesture update.
    ///   Volume steps scale with it; other actions run once per update.
    public func perform(_ action: GestureAction, mappingName: String, magnitude: Int = 1) async -> ActionResult {
        do throws(ActionError) {
            if let problem = ActionValidator.problem(with: action) {
                throw .invalidConfiguration(problem)
            }
            if case .volume(let command) = action {
                return .success(try adjustVolume(command, magnitude: magnitude))
            }
            return try await run(action, mappingName: mappingName)
        } catch {
            return .failure(error)
        }
    }

    private func run(_ action: GestureAction, mappingName: String) async throws(ActionError) -> ActionResult {
        switch action {
        case .none:
            return .success("No action")

        case .keyboardShortcut(let combo):
            try KeyboardEventSynthesizer.press(combo)
            return .success("Pressed \(combo.displayName)")

        case .window(let command):
            guard let app = NSWorkspace.shared.frontmostApplication else {
                throw .noTargetWindow
            }
            let screens = ScreenGeometry.current()
            if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                return .success(try ownWindows.perform(command, targetPID: app.processIdentifier, screens: screens))
            }
            return .success(try await windowManager.perform(command, targetPID: app.processIdentifier, screens: screens))

        case .media(let command):
            try MediaKeyController.send(command)
            return .success(command.displayName)

        case .volume(let command):
            return .success(try adjustVolume(command, magnitude: 1))

        case .system(let feature):
            return .success(try await SystemFeatureController.trigger(feature))

        case .launchApplication(let app):
            return .success(try await openApplication(app))

        case .openURL(let string):
            guard let url = URL(string: string) else {
                throw .invalidConfiguration("“\(string)” is not a valid URL.")
            }
            guard NSWorkspace.shared.open(url) else {
                throw .executionFailed("No application can open \(url.scheme ?? "this") links.")
            }
            return .success("Opened \(url.host() ?? string)")

        case .runScript(let script):
            let executable = try ExecutableValidator.validate(path: script.executablePath)
            if script.requiresConfirmation {
                let approved = await confirm(ConfirmationRequest(
                    title: "Run “\(executable.lastPathComponent)”?",
                    message: "The gesture “\(mappingName)” wants to run this script.",
                    detail: ([executable.path] + script.arguments).joined(separator: " "),
                    isDestructive: false
                ))
                guard approved else { return .cancelled("Script not run") }
            }
            return .success(try await CommandRunner.run(executable: executable, arguments: script.arguments, timeout: script.timeout))

        case .shellCommand(let shell):
            let destructive = DangerousCommandDetector.isPotentiallyDestructive(shell.command)
            if shell.requiresConfirmation || destructive {
                let approved = await confirm(ConfirmationRequest(
                    title: destructive ? "Run a potentially destructive command?" : "Run shell command?",
                    message: "The gesture “\(mappingName)” wants to run this command"
                        + (destructive ? ". It may delete or change files or system settings." : "."),
                    detail: shell.command,
                    isDestructive: destructive
                ))
                guard approved else { return .cancelled("Command not run") }
            }
            _ = try await CommandRunner.run(
                executable: URL(fileURLWithPath: CommandRunner.shellPath),
                arguments: ["-c", shell.command],
                timeout: shell.timeout
            )
            return .success("Shell command finished")

        case .runShortcut(let name):
            guard FileManager.default.isExecutableFile(atPath: CommandRunner.shortcutsPath) else {
                throw .unsupported("The shortcuts command-line tool isn't available.")
            }
            _ = try await CommandRunner.run(
                executable: URL(fileURLWithPath: CommandRunner.shortcutsPath),
                arguments: ["run", name],
                timeout: 60
            )
            return .success("Ran shortcut “\(name)”")
        }
    }

    /// Core Audio first; if the output device has no software volume, fall
    /// back to the system volume keys, which macOS routes to the device.
    private func adjustVolume(_ command: VolumeCommand, magnitude: Int) throws(ActionError) -> String {
        do {
            return try volume.perform(command, magnitude: magnitude).message
        } catch .unsupported(let reason) {
            let key: MediaKeyController.VolumeKey
            switch command {
            case .up: key = .up
            case .down: key = .down
            case .toggleMute: key = .mute
            case .set: throw .unsupported(reason)
            }
            guard CGPreflightPostEventAccess() else {
                throw .unsupported("\(reason) The volume-key fallback needs Accessibility permission.")
            }
            try MediaKeyController.send(key)
            return "Volume key sent (device has no software volume)"
        }
    }

    private func openApplication(_ app: ApplicationReference) async throws(ActionError) -> String {
        var url: URL?
        if let identifier = app.bundleIdentifier {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        }
        if url == nil, !app.path.isEmpty, FileManager.default.fileExists(atPath: app.path) {
            url = URL(fileURLWithPath: app.path)
        }
        guard let url, url.pathExtension == "app" else {
            throw .invalidConfiguration("“\(app.name)” could not be found. It may have been moved or deleted.")
        }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw .executionFailed("Couldn't open \(app.name): \(error.localizedDescription)")
        }
        return "Opened \(app.name)"
    }
}
