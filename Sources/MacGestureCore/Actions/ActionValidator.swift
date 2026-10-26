import Darwin
import Foundation

/// Configuration-time and run-time checks for actions.
public enum ActionValidator {
    /// A user-facing description of what's wrong with an action's
    /// configuration, or nil if it can be attempted.
    public static func problem(with action: GestureAction) -> String? {
        switch action {
        case .none:
            return nil
        case .keyboardShortcut(let combo):
            return KeyCodeNames.modifierKeyCodes.contains(combo.keyCode) ? "A shortcut needs a non-modifier key." : nil
        case .volume(.set(let level)):
            return (0...1).contains(level) ? nil : "Volume level must be between 0% and 100%."
        case .volume(.up(let step)), .volume(.down(let step)):
            return step > 0 && step <= 1 ? nil : "Volume step must be between 0% and 100%."
        case .launchApplication(let app):
            return app.path.isEmpty && app.bundleIdentifier == nil ? "Choose an application." : nil
        case .openURL(let string):
            guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
                  !string.dropFirst(scheme.count + 1).drop(while: { $0 == "/" }).isEmpty else {
                return "Enter a complete URL, including its scheme (for example https://)."
            }
            if ["http", "https"].contains(scheme), url.host()?.isEmpty != false {
                return "Web addresses need a host name."
            }
            return nil
        case .runScript(let script):
            do {
                _ = try ExecutableValidator.validate(path: script.executablePath)
                return nil
            } catch {
                return error.localizedDescription
            }
        case .shellCommand(let command):
            return command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a command." : nil
        case .runShortcut(let name):
            return name.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter the name of a shortcut from the Shortcuts app." : nil
        case .window, .media, .volume, .system:
            return nil
        }
    }
}

/// Validates executables before they are run.
public enum ExecutableValidator {
    /// Returns the resolved file URL, or throws a descriptive error.
    public static func validate(path: String) throws(ActionError) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw .invalidConfiguration("Choose an executable file.")
        }
        guard trimmed.hasPrefix("/"), !trimmed.contains("\0") else {
            throw .invalidConfiguration("Script paths must be absolute.")
        }
        let url = URL(fileURLWithPath: trimmed).resolvingSymlinksInPath()

        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw .invalidConfiguration("“\(trimmed)” does not exist.")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw .invalidConfiguration("“\(trimmed)” is not a regular file.")
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw .invalidConfiguration("“\(trimmed)” is not executable (try chmod +x).")
        }
        // A script anyone else can rewrite could be swapped for something else
        // and then launched by a gesture.
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw .invalidConfiguration("“\(trimmed)” is writable by other users; refusing to run it.")
        }
        return url
    }
}

/// Flags shell commands that can destroy data or disrupt the system, so they
/// always require confirmation no matter how the mapping is configured.
public enum DangerousCommandDetector {
    private static let dangerousWords: Set<String> = [
        "rm", "rmdir", "srm", "unlink", "mv", "dd", "shred", "truncate", "mkfs", "newfs_apfs", "newfs_hfs",
        "diskutil", "fdisk", "gpt", "asr", "sudo", "su", "doas", "shutdown", "reboot", "halt",
        "kill", "killall", "pkill", "launchctl", "chmod", "chown", "chflags", "csrutil", "nvram",
        "tmutil", "pmset", "networksetup", "security", "crontab",
    ]

    private static let dangerousPhrases = ["reset --hard", "clean -f", "defaults delete", "push --force", "push -f"]

    public static func isPotentiallyDestructive(_ command: String) -> Bool {
        // Output redirection that may overwrite a file (appending and
        // discarding to /dev/null are fine).
        let withoutNull = command.replacingOccurrences(of: #"[0-9&]?>\s*/dev/null"#, with: "", options: .regularExpression)
        if withoutNull.range(of: #"(^|[^>&0-9])>(?!>|&)"#, options: .regularExpression) != nil {
            return true
        }
        if dangerousPhrases.contains(where: command.contains) {
            return true
        }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";|&()`$"))
        return command.components(separatedBy: separators).contains { word in
            !word.isEmpty && dangerousWords.contains((word as NSString).lastPathComponent)
        }
    }
}
