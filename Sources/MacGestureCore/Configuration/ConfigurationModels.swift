import Foundation

public struct GestureMapping: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var trigger: GestureTrigger
    public var action: GestureAction
    /// Overrides the global sensitivity for this gesture when set.
    public var sensitivity: Double?
    /// Minimum seconds between two firings of this mapping, in addition to
    /// the global cooldown.
    public var cooldown: TimeInterval?

    public init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        trigger: GestureTrigger,
        action: GestureAction,
        sensitivity: Double? = nil,
        cooldown: TimeInterval? = nil
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.action = action
        self.sensitivity = sensitivity
        self.cooldown = cooldown
    }

    public var displayName: String {
        name.isEmpty ? trigger.displayName.capitalizedFirst : name
    }

    /// A copy with a fresh identity, disabled so it can't immediately clash
    /// with the original.
    public func duplicated() -> GestureMapping {
        var copy = self
        copy.id = UUID()
        copy.name = "\(displayName) Copy"
        copy.isEnabled = false
        return copy
    }
}

public struct GestureProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var mappings: [GestureMapping]

    public init(id: UUID = UUID(), name: String, mappings: [GestureMapping] = []) {
        self.id = id
        self.name = name
        self.mappings = mappings
    }
}

public enum LogLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, standard, verbose

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .standard: "Standard"
        case .verbose: "Verbose"
        }
    }
}

public struct GeneralSettings: Codable, Hashable, Sendable {
    public var isEnabled = true
    /// Seconds after any action during which further gestures are ignored.
    public var cooldown: TimeInterval = 0.35
    public var logLevel: LogLevel = .standard
    public var hasCompletedOnboarding = false
    /// Discard the two-finger scroll macOS produces during the anchor gesture.
    public var suppressScrollDuringAnchorGesture = true
    /// When to click the trackpad as gestures change the volume.
    public var volumeHapticMode = VolumeHapticMode.everyStep

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case isEnabled, cooldown, logLevel, hasCompletedOnboarding
        case suppressScrollDuringAnchorGesture, volumeHapticMode
        case legacyVolumeHaptics = "volumeHaptics"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(cooldown, forKey: .cooldown)
        try container.encode(logLevel, forKey: .logLevel)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try container.encode(suppressScrollDuringAnchorGesture, forKey: .suppressScrollDuringAnchorGesture)
        try container.encode(volumeHapticMode, forKey: .volumeHapticMode)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GeneralSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        cooldown = try container.decodeIfPresent(TimeInterval.self, forKey: .cooldown) ?? defaults.cooldown
        logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? defaults.logLevel
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? defaults.hasCompletedOnboarding
        suppressScrollDuringAnchorGesture = try container.decodeIfPresent(Bool.self, forKey: .suppressScrollDuringAnchorGesture) ?? defaults.suppressScrollDuringAnchorGesture
        if let mode = try container.decodeIfPresent(VolumeHapticMode.self, forKey: .volumeHapticMode) {
            volumeHapticMode = mode
        } else if try container.decodeIfPresent(Bool.self, forKey: .legacyVolumeHaptics) == false {
            // Earlier builds stored an on/off switch.
            volumeHapticMode = .off
        }

    }
}

/// The complete persisted state. Bump `currentSchemaVersion` and register a
/// step in `ConfigurationMigrator` whenever the encoded shape changes in a way
/// tolerant decoding can't absorb.
public struct AppConfiguration: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var profiles: [GestureProfile]
    public var activeProfileID: UUID
    public var general: GeneralSettings
    public var recognition: RecognitionSettings

    public init(
        profiles: [GestureProfile],
        activeProfileID: UUID? = nil,
        general: GeneralSettings = GeneralSettings(),
        recognition: RecognitionSettings = RecognitionSettings()
    ) {
        precondition(!profiles.isEmpty, "A configuration needs at least one profile")
        self.schemaVersion = Self.currentSchemaVersion
        self.profiles = profiles
        self.activeProfileID = activeProfileID ?? profiles[0].id
        self.general = general
        self.recognition = recognition
    }

    public var activeProfile: GestureProfile {
        get { profiles.first { $0.id == activeProfileID } ?? profiles[0] }
        set {
            if let index = profiles.firstIndex(where: { $0.id == newValue.id }) {
                profiles[index] = newValue
            }
        }
    }

    /// Repairs references that could make the app misbehave after a manual
    /// edit or partial migration.
    public mutating func normalize() {
        if profiles.isEmpty {
            profiles = [DefaultConfiguration.defaultProfile()]
        }
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = profiles[0].id
        }
        recognition.sensitivity = min(max(recognition.sensitivity, 0), 1)
        general.cooldown = min(max(general.cooldown, 0), 5)
    }
}

extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
