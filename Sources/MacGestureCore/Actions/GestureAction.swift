import Foundation

/// Everything a gesture can do. Actions are data: they are only ever created
/// from the user's configuration, never from touch input.
public enum GestureAction: Codable, Hashable, Sendable {
    case none
    case keyboardShortcut(combo: KeyCombo)
    case window(command: WindowCommand)
    case media(command: MediaCommand)
    case volume(command: VolumeCommand)
    case system(feature: SystemFeature)
    case launchApplication(app: ApplicationReference)
    case openURL(url: String)
    case runScript(script: ScriptAction)
    case shellCommand(command: ShellCommandAction)
    case runShortcut(name: String)

    public var category: ActionCategory {
        switch self {
        case .none: .none
        case .keyboardShortcut: .keyboard
        case .window: .window
        case .media: .media
        case .volume: .volume
        case .system: .system
        case .launchApplication: .application
        case .openURL: .url
        case .runScript: .script
        case .shellCommand: .shell
        case .runShortcut: .shortcut
        }
    }

    public var summary: String {
        switch self {
        case .none: "No action"
        case .keyboardShortcut(let combo): "Press \(combo.displayName)"
        case .window(let command): "Window: \(command.displayName)"
        case .media(let command): command.displayName
        case .volume(let command): command.displayName
        case .system(let feature): feature.displayName
        case .launchApplication(let app): "Open \(app.name)"
        case .openURL(let url): "Open \(url)"
        case .runScript(let script): "Run \((script.executablePath as NSString).lastPathComponent)"
        case .shellCommand: "Run shell command"
        case .runShortcut(let name): "Run Shortcut “\(name)”"
        }
    }

    /// Whether macOS will block this action without Accessibility access.
    public var requiresAccessibility: Bool {
        switch self {
        case .keyboardShortcut, .window, .media: true
        case .system(let feature): feature.requiresAccessibility
        default: false
        }
    }
}

public enum ActionCategory: String, CaseIterable, Sendable, Identifiable {
    case none, keyboard, window, media, volume, system, application, url, script, shell, shortcut

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .keyboard: "Keyboard Shortcut"
        case .window: "Window Management"
        case .media: "Media"
        case .volume: "Volume"
        case .system: "System Feature"
        case .application: "Open Application"
        case .url: "Open URL"
        case .script: "Run Script"
        case .shell: "Shell Command"
        case .shortcut: "Shortcuts App"
        }
    }

    public var symbolName: String {
        switch self {
        case .none: "circle.slash"
        case .keyboard: "keyboard"
        case .window: "macwindow"
        case .media: "playpause"
        case .volume: "speaker.wave.2"
        case .system: "rectangle.3.group"
        case .application: "app"
        case .url: "link"
        case .script: "terminal"
        case .shell: "apple.terminal"
        case .shortcut: "square.2.layers.3d"
        }
    }

    /// A reasonable starting action when the user switches category.
    public var defaultAction: GestureAction {
        switch self {
        case .none: .none
        case .keyboard: .keyboardShortcut(combo: KeyboardPreset.all[0].combo)
        case .window: .window(command: .maximize)
        case .media: .media(command: .playPause)
        case .volume: .volume(command: .up(step: VolumeCommand.defaultStep))
        case .system: .system(feature: .missionControl)
        case .application: .launchApplication(app: ApplicationReference(bundleIdentifier: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app", name: "Finder"))
        case .url: .openURL(url: "https://")
        case .script: .runScript(script: ScriptAction(executablePath: ""))
        case .shell: .shellCommand(command: ShellCommandAction(command: ""))
        case .shortcut: .runShortcut(name: "")
        }
    }
}

public enum WindowCommand: String, Codable, CaseIterable, Sendable, Identifiable {
    case minimize, maximize, toggleFullScreen, center
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case moveToNextDisplay

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .minimize: "Minimize"
        case .maximize: "Maximize (Toggle)"
        case .toggleFullScreen: "Toggle Full Screen"
        case .center: "Center"
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        case .leftTwoThirds: "Left Two Thirds"
        case .rightTwoThirds: "Right Two Thirds"
        case .topLeftQuarter: "Top-Left Quarter"
        case .topRightQuarter: "Top-Right Quarter"
        case .bottomLeftQuarter: "Bottom-Left Quarter"
        case .bottomRightQuarter: "Bottom-Right Quarter"
        case .moveToNextDisplay: "Move to Next Display"
        }
    }
}

public enum MediaCommand: String, Codable, CaseIterable, Sendable, Identifiable {
    case playPause, nextTrack, previousTrack

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .playPause: "Play/Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        }
    }
}

public enum VolumeCommand: Codable, Hashable, Sendable {
    /// Matches the 1/16 steps of the hardware volume keys.
    public static let defaultStep = 1.0 / 16

    case up(step: Double)
    case down(step: Double)
    case toggleMute
    case set(level: Double)

    public var displayName: String {
        switch self {
        case .up: "Volume Up"
        case .down: "Volume Down"
        case .toggleMute: "Toggle Mute"
        case .set(let level): "Set Volume to \(Int((level * 100).rounded()))%"
        }
    }
}

/// Built-in macOS features reached through public means: launching the
/// feature's app, or posting the user's configured system shortcut.
public enum SystemFeature: String, Codable, CaseIterable, Sendable, Identifiable {
    case missionControl
    case applicationWindows
    case showDesktop
    case moveSpaceLeft
    case moveSpaceRight
    case appsLauncher
    case spotlight

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .missionControl: "Mission Control"
        case .applicationWindows: "Application Windows"
        case .showDesktop: "Show Desktop"
        case .moveSpaceLeft: "Move Left a Space"
        case .moveSpaceRight: "Move Right a Space"
        case .appsLauncher: "Apps / Launchpad"
        case .spotlight: "Spotlight"
        }
    }

    public var requiresAccessibility: Bool {
        switch self {
        case .missionControl, .appsLauncher: false
        default: true
        }
    }

    /// How the feature is triggered, shown so users know what it depends on.
    public var mechanismDescription: String {
        switch self {
        case .missionControl: "Opens Mission Control.app."
        case .appsLauncher: "Opens Apps.app (or Launchpad.app on older macOS)."
        case .applicationWindows, .showDesktop, .moveSpaceLeft, .moveSpaceRight:
            "Posts the shortcut set in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control. Fails if that shortcut is turned off."
        case .spotlight:
            "Posts the Spotlight shortcut set in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Spotlight."
        }
    }
}

public struct ApplicationReference: Codable, Hashable, Sendable {
    public var bundleIdentifier: String?
    public var path: String
    public var name: String

    public init(bundleIdentifier: String?, path: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.name = name
    }
}

/// Runs an executable directly (no shell), with fixed arguments.
public struct ScriptAction: Codable, Hashable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var requiresConfirmation: Bool
    public var timeout: TimeInterval

    public init(executablePath: String, arguments: [String] = [], requiresConfirmation: Bool = false, timeout: TimeInterval = 30) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.requiresConfirmation = requiresConfirmation
        self.timeout = timeout
    }
}

/// A command line run through `/bin/zsh -c`. Confirmation defaults to on and
/// is forced for commands that look destructive.
public struct ShellCommandAction: Codable, Hashable, Sendable {
    public var command: String
    public var requiresConfirmation: Bool
    public var timeout: TimeInterval

    public init(command: String, requiresConfirmation: Bool = true, timeout: TimeInterval = 30) {
        self.command = command
        self.requiresConfirmation = requiresConfirmation
        self.timeout = timeout
    }
}
