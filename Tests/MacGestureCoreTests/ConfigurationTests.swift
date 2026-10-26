import XCTest
@testable import MacGestureCore

final class ConfigurationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacGestureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: ConfigurationStore(directory: directory).fileURL)
    }

    func testDefaultsAreValidAndConflictFree() {
        let configuration = DefaultConfiguration.make()
        XCTAssertGreaterThanOrEqual(configuration.profiles.count, 1)
        for profile in configuration.profiles {
            let errors = MappingConflictDetector.issues(in: profile, system: SystemGestureSettings()).filter { $0.severity == .error }
            XCTAssertTrue(errors.isEmpty, "\(profile.name): \(errors.map(\.message))")
            XCTAssertTrue(profile.mappings.allSatisfy(\.trigger.isValid))
        }
    }

    func testDefaultEnabledMappingsAvoidEveryMacOSGesture() {
        // Worst case: every built-in macOS trackpad gesture switched on.
        var everything = SystemGestureSettings.assumedDefaults
        everything.threeFingerHorizontalSwipe = true
        everything.threeFingerTap = true
        for profile in DefaultConfiguration.make().profiles {
            let warnings = MappingConflictDetector.issues(in: profile, system: everything).filter { $0.severity >= .warning }
            XCTAssertTrue(warnings.isEmpty, "\(profile.name): \(warnings.map(\.message))")
            // The anchor gesture is the one deliberate two-finger default; its
            // scroll overlap is handled by scroll suppression.
            XCTAssertTrue(profile.mappings.filter(\.isEnabled).allSatisfy { $0.trigger.fingers > 2 || $0.trigger.kind == .anchorSwipe })
        }
    }

    func testMissingFileCreatesDefaults() {
        let result = ConfigurationStore(directory: directory).load()
        XCTAssertEqual(result.issue, .createdDefaults)
        XCTAssertEqual(result.configuration.schemaVersion, AppConfiguration.currentSchemaVersion)
    }

    func testRoundTripPersistsEverything() throws {
        let store = ConfigurationStore(directory: directory)
        var configuration = DefaultConfiguration.make()
        configuration.general.isEnabled = false
        configuration.general.cooldown = 1.25
        configuration.recognition.sensitivity = 0.8
        configuration.recognition.swipeDistance = 20
        configuration.profiles[0].mappings.append(GestureMapping(
            name: "Script",
            trigger: .circle(4, .counterclockwise),
            action: .runScript(script: ScriptAction(executablePath: "/usr/bin/true", arguments: ["a b", "c"], requiresConfirmation: true)),
            sensitivity: 0.2,
            cooldown: 3
        ))
        configuration.profiles[0].mappings.append(GestureMapping(trigger: .tap(5), action: .volume(command: .set(level: 0.3))))
        configuration.profiles[0].mappings.append(GestureMapping(trigger: .hold(3), action: .launchApplication(app: ApplicationReference(bundleIdentifier: nil, path: "/Applications/Safari.app", name: "Safari"))))
        configuration.activeProfileID = configuration.profiles[1].id
        try store.save(configuration)

        let loaded = store.load()
        XCTAssertNil(loaded.issue)
        XCTAssertEqual(loaded.configuration, configuration)
    }

    func testCorruptFileIsMovedAsideAndDefaultsLoaded() throws {
        try write("{ not json")
        let result = ConfigurationStore(directory: directory).load()
        guard case .recoveredFromCorruptFile(let backup, _) = result.issue else {
            return XCTFail("Expected recovery, got \(String(describing: result.issue))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ConfigurationStore(directory: directory).fileURL.path))
        XCTAssertFalse(result.configuration.profiles.isEmpty)
    }

    func testNewerSchemaIsNotOverwritten() throws {
        try write(#"{"schemaVersion": 99, "something": "new"}"#)
        let result = ConfigurationStore(directory: directory).load()
        XCTAssertEqual(result.issue, .newerSchema(version: 99))
        XCTAssertTrue(result.issue?.blocksSaving == true)
        let onDisk = try String(contentsOf: ConfigurationStore(directory: directory).fileURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("something"), "The newer file must be left untouched")
    }

    func testMissingOptionalSettingsFallBackToDefaults() throws {
        // A file from a build that predates most recognition and general settings.
        let profileID = UUID()
        try write("""
        {"schemaVersion": 2, "activeProfileID": "\(profileID)",
         "profiles": [{"id": "\(profileID)", "name": "Old", "mappings": []}],
         "general": {"isEnabled": false},
         "recognition": {"sensitivity": 0.9}}
        """)
        let result = ConfigurationStore(directory: directory).load()
        XCTAssertNil(result.issue)
        XCTAssertFalse(result.configuration.general.isEnabled)
        XCTAssertEqual(result.configuration.general.cooldown, GeneralSettings().cooldown)
        XCTAssertEqual(result.configuration.recognition.sensitivity, 0.9)
        XCTAssertEqual(result.configuration.recognition.swipeDistance, RecognitionSettings().swipeDistance)
    }

    func testDanglingActiveProfileIsRepaired() throws {
        let profileID = UUID()
        try write("""
        {"schemaVersion": 2, "activeProfileID": "\(UUID())",
         "profiles": [{"id": "\(profileID)", "name": "Only", "mappings": []}],
         "general": {}, "recognition": {"sensitivity": 7}}
        """)
        let result = ConfigurationStore(directory: directory).load()
        XCTAssertEqual(result.configuration.activeProfileID, profileID)
        XCTAssertEqual(result.configuration.recognition.sensitivity, 1, "Clamped")
    }

    func testMigrationStepsRunInOrderAndKeepBackup() throws {
        // Simulates a future schema 2 that renamed "profiles" → "profileList"
        // and back, to exercise the migration machinery end to end.
        let profileID = UUID()
        try write("""
        {"schemaVersion": 0, "activeProfileID": "\(profileID)",
         "legacyProfiles": [{"id": "\(profileID)", "name": "Legacy", "mappings": []}],
         "general": {}, "recognition": {}}
        """)
        let store = ConfigurationStore(directory: directory) {
            ConfigurationMigrator(steps: [
                0: { json in
                    json["profiles"] = json["legacyProfiles"]
                    json["legacyProfiles"] = nil
                },
            ], targetVersion: 1)
        }
        let result = store.load()
        guard case .migrated(from: 0, let backup) = result.issue else {
            return XCTFail("Expected migration, got \(String(describing: result.issue))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(result.configuration.profiles.map(\.name), ["Legacy"])
        XCTAssertEqual(result.configuration.schemaVersion, AppConfiguration.currentSchemaVersion)
    }

    func testMigratorReportsMissingStep() {
        var json: [String: Any] = ["schemaVersion": 0]
        XCTAssertThrowsError(try ConfigurationMigrator(steps: [:], targetVersion: 2).migrate(&json)) { error in
            XCTAssertEqual(error as? ConfigurationMigrator.MigrationError, .missingStep(from: 0))
        }
    }

    func testResetBacksUpPreviousConfiguration() throws {
        let store = ConfigurationStore(directory: directory)
        var configuration = DefaultConfiguration.make()
        configuration.general.cooldown = 4
        try store.save(configuration)
        let reset = try store.reset()
        XCTAssertEqual(reset.general.cooldown, GeneralSettings().cooldown)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("before-reset") }
        XCTAssertEqual(backups.count, 1)
    }

    func testDuplicatedMappingGetsNewIdentityAndIsDisabled() {
        let mapping = GestureMapping(name: "Original", trigger: .tap(3), action: .none)
        let copy = mapping.duplicated()
        XCTAssertNotEqual(copy.id, mapping.id)
        XCTAssertFalse(copy.isEnabled)
        XCTAssertEqual(copy.trigger, mapping.trigger)
    }

    func testTriggerNormalizesInvalidDirection() {
        XCTAssertEqual(GestureTrigger(kind: .tap, fingers: 3, direction: .left).direction, GestureDirection.none)
        XCTAssertEqual(GestureTrigger(kind: .pinch, fingers: 3, direction: .up).direction, .pinchIn)
        XCTAssertFalse(GestureTrigger.tap(1).isValid)
        XCTAssertFalse(GestureTrigger.tap(6).isValid)
    }
}
