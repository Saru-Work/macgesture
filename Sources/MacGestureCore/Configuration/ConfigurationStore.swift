import Foundation

/// Upgrades raw configuration JSON one schema version at a time.
public struct ConfigurationMigrator {
    public typealias Step = (inout [String: Any]) throws -> Void

    public enum MigrationError: Error, LocalizedError, Equatable {
        case missingVersion
        case missingStep(from: Int)

        public var errorDescription: String? {
            switch self {
            case .missingVersion: "The configuration file has no schema version."
            case .missingStep(let version): "No migration is available from schema version \(version)."
            }
        }
    }

    /// Keyed by the version the step upgrades *from*.
    public var steps: [Int: Step]
    public var targetVersion: Int

    public static var standard: ConfigurationMigrator {
        ConfigurationMigrator(steps: [1: addAnchorSwipeMappings], targetVersion: AppConfiguration.currentSchemaVersion)
    }

    /// 1 → 2: introduces the `anchorSwipe` gesture kind (which schema 1
    /// readers can't decode) and adds the anchor volume mappings to every
    /// profile that doesn't already use the gesture. Nothing else changes.
    static func addAnchorSwipeMappings(_ json: inout [String: Any]) throws {
        guard var profiles = json["profiles"] as? [[String: Any]] else { return }
        let encoded = try JSONEncoder().encode(DefaultConfiguration.anchorVolumeMappings())
        let template = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]] ?? []
        for index in profiles.indices {
            var mappings = profiles[index]["mappings"] as? [[String: Any]] ?? []
            let usesAnchor = mappings.contains { ($0["trigger"] as? [String: Any])?["kind"] as? String == GestureKind.anchorSwipe.rawValue }
            guard !usesAnchor else { continue }
            for var mapping in template {
                mapping["id"] = UUID().uuidString
                mappings.append(mapping)
            }
            profiles[index]["mappings"] = mappings
        }
        json["profiles"] = profiles
    }

    public init(steps: [Int: Step], targetVersion: Int) {
        self.steps = steps
        self.targetVersion = targetVersion
    }

    public func migrate(_ json: inout [String: Any]) throws {
        guard var version = json["schemaVersion"] as? Int else {
            throw MigrationError.missingVersion
        }
        while version < targetVersion {
            guard let step = steps[version] else {
                throw MigrationError.missingStep(from: version)
            }
            try step(&json)
            version += 1
            json["schemaVersion"] = version
        }
    }
}

public enum ConfigurationLoadIssue: Equatable, Sendable {
    /// No file existed; defaults were created.
    case createdDefaults
    /// The file was unreadable and was moved aside before loading defaults.
    case recoveredFromCorruptFile(backup: URL, reason: String)
    /// The file came from a newer MacGesture. It is left untouched and changes
    /// are not saved until the user resets or upgrades.
    case newerSchema(version: Int)
    /// The file was upgraded from an older schema (a backup was kept).
    case migrated(from: Int, backup: URL)

    public var blocksSaving: Bool {
        if case .newerSchema = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .createdDefaults:
            "Created a new configuration with default gestures."
        case .recoveredFromCorruptFile(let backup, let reason):
            "The configuration file could not be read (\(reason)). It was moved to \(backup.lastPathComponent) and defaults were loaded."
        case .newerSchema(let version):
            "The configuration was written by a newer version of MacGesture (schema \(version)). Changes will not be saved, to avoid damaging it."
        case .migrated(let version, let backup):
            "Upgraded the configuration from schema \(version). The previous file was kept as \(backup.lastPathComponent)."
        }
    }
}

public struct ConfigurationLoadResult: Sendable {
    public var configuration: AppConfiguration
    public var issue: ConfigurationLoadIssue?
}

/// Reads and writes `configuration.json` in Application Support.
public struct ConfigurationStore: Sendable {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("configuration.json") }

    private let migratorFactory: @Sendable () -> ConfigurationMigrator

    public init(directory: URL, migrator: @escaping @Sendable () -> ConfigurationMigrator = { .standard }) {
        self.directory = directory
        self.migratorFactory = migrator
    }

    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("MacGesture", isDirectory: true)
    }

    public func load() -> ConfigurationLoadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ConfigurationLoadResult(configuration: DefaultConfiguration.make(), issue: .createdDefaults)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let migrator = migratorFactory()
            let version = json["schemaVersion"] as? Int
            if let version, version > migrator.targetVersion {
                var fallback = DefaultConfiguration.make()
                // Best effort: if the newer file happens to decode, show it read-only.
                if let decoded = try? JSONDecoder().decode(AppConfiguration.self, from: data) {
                    fallback = decoded
                }
                return ConfigurationLoadResult(configuration: fallback, issue: .newerSchema(version: version))
            }

            var issue: ConfigurationLoadIssue?
            var payload = data
            if let version, version < migrator.targetVersion {
                try migrator.migrate(&json)
                let backup = try backupCopy(suffix: "v\(version)")
                issue = .migrated(from: version, backup: backup)
                payload = try JSONSerialization.data(withJSONObject: json)
            }

            var configuration = try JSONDecoder().decode(AppConfiguration.self, from: payload)
            configuration.schemaVersion = AppConfiguration.currentSchemaVersion
            configuration.normalize()
            return ConfigurationLoadResult(configuration: configuration, issue: issue)
        } catch {
            let reason = Self.describe(error)
            let backup = (try? moveAside(suffix: "corrupt")) ?? fileURL
            return ConfigurationLoadResult(
                configuration: DefaultConfiguration.make(),
                issue: .recoveredFromCorruptFile(backup: backup, reason: reason)
            )
        }
    }

    public func save(_ configuration: AppConfiguration) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: fileURL, options: .atomic)
    }

    public func reset() throws -> AppConfiguration {
        let configuration = DefaultConfiguration.make()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try moveAside(suffix: "before-reset")
        }
        try save(configuration)
        return configuration
    }

    private func timestampedURL(suffix: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("configuration.\(suffix)-\(formatter.string(from: Date())).json")
    }

    private func moveAside(suffix: String) throws -> URL {
        let destination = timestampedURL(suffix: suffix)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: fileURL, to: destination)
        return destination
    }

    private func backupCopy(suffix: String) throws -> URL {
        let destination = timestampedURL(suffix: suffix)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: fileURL, to: destination)
        return destination
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "missing “\(key.stringValue)”"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context), DecodingError.dataCorrupted(let context):
            context.debugDescription
        default: error.localizedDescription
        }
    }
}
