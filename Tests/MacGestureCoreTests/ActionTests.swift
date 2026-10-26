import XCTest
@testable import MacGestureCore

final class ActionTests: XCTestCase {
    // MARK: - Window geometry

    private let area = CGRect(x: 0, y: 80, width: 1200, height: 720)

    func testHalvesThirdsAndQuarters() {
        let current = CGRect(x: 100, y: 100, width: 400, height: 300)
        func frame(_ command: WindowCommand) -> CGRect? {
            WindowLayout.targetFrame(for: command, in: area, current: current)
        }
        XCTAssertEqual(frame(.maximize), area)
        XCTAssertEqual(frame(.leftHalf), CGRect(x: 0, y: 80, width: 600, height: 720))
        XCTAssertEqual(frame(.rightHalf), CGRect(x: 600, y: 80, width: 600, height: 720))
        XCTAssertEqual(frame(.topHalf), CGRect(x: 0, y: 440, width: 1200, height: 360), "Cocoa y-up: top half has the larger y")
        XCTAssertEqual(frame(.bottomHalf), CGRect(x: 0, y: 80, width: 1200, height: 360))
        XCTAssertEqual(frame(.centerThird), CGRect(x: 400, y: 80, width: 400, height: 720))
        XCTAssertEqual(frame(.rightTwoThirds), CGRect(x: 400, y: 80, width: 800, height: 720))
        XCTAssertEqual(frame(.topLeftQuarter), CGRect(x: 0, y: 440, width: 600, height: 360))
        XCTAssertEqual(frame(.bottomRightQuarter), CGRect(x: 600, y: 80, width: 600, height: 360))
        XCTAssertEqual(frame(.center), CGRect(x: 400, y: 290, width: 400, height: 300))
        XCTAssertNil(frame(.minimize))
    }

    func testCoordinateFlipIsItsOwnInverse() {
        let cocoa = CGRect(x: 10, y: 600, width: 300, height: 200)
        let ax = WindowLayout.flip(cocoa, primaryHeight: 900)
        XCTAssertEqual(ax, CGRect(x: 10, y: 100, width: 300, height: 200))
        XCTAssertEqual(WindowLayout.flip(ax, primaryHeight: 900), cocoa)
    }

    func testScreenSelectionPrefersLargestOverlap() {
        let screens = [
            ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 775)),
            ScreenGeometry(frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        ]
        XCTAssertEqual(WindowLayout.screenIndex(for: CGRect(x: 900, y: 100, width: 400, height: 300), in: screens), 1)
        XCTAssertEqual(WindowLayout.screenIndex(for: CGRect(x: 100, y: 100, width: 400, height: 300), in: screens), 0)
    }

    func testTransferBetweenDisplaysStaysInside() {
        let from = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let to = CGRect(x: 1000, y: 0, width: 500, height: 400)
        let result = WindowLayout.transfer(CGRect(x: 500, y: 400, width: 500, height: 400), from: from, to: to)
        XCTAssertEqual(result, CGRect(x: 1250, y: 200, width: 250, height: 200))
        XCTAssertTrue(to.contains(result))
    }

    // MARK: - Validation

    func testExecutableValidation() throws {
        XCTAssertNoThrow(try ExecutableValidator.validate(path: "/usr/bin/true"))
        XCTAssertThrowsError(try ExecutableValidator.validate(path: "")) { XCTAssertEqual($0 as? ActionError, .invalidConfiguration("Choose an executable file.")) }
        XCTAssertThrowsError(try ExecutableValidator.validate(path: "bin/true"))
        XCTAssertThrowsError(try ExecutableValidator.validate(path: "/definitely/not/here"))
        XCTAssertThrowsError(try ExecutableValidator.validate(path: "/usr/bin"), "Directories are not executables")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plain = directory.appendingPathComponent("plain.sh")
        try Data("#!/bin/sh\n".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        XCTAssertThrowsError(try ExecutableValidator.validate(path: plain.path), "Not executable")

        let shared = directory.appendingPathComponent("shared.sh")
        try Data("#!/bin/sh\n".utf8).write(to: shared)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: shared.path)
        XCTAssertThrowsError(try ExecutableValidator.validate(path: shared.path), "World-writable scripts are refused")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path)
        XCTAssertNoThrow(try ExecutableValidator.validate(path: shared.path))
    }

    func testDestructiveCommandDetection() {
        for command in ["rm -rf ~/Documents", "sudo reboot", "echo hi > ~/.zshrc", "cd /tmp && /bin/rm x", "git reset --hard", "killall Finder", "$(rm x)"] {
            XCTAssertTrue(DangerousCommandDetector.isPotentiallyDestructive(command), command)
        }
        for command in ["open -a Safari", "say hello", "echo hi >> log.txt", "ls 2>&1", "curl -s https://example.com > /dev/null", "osascript -e 'beep'"] {
            XCTAssertFalse(DangerousCommandDetector.isPotentiallyDestructive(command), command)
        }
    }

    func testActionConfigurationProblems() {
        XCTAssertNil(ActionValidator.problem(with: .media(command: .playPause)))
        XCTAssertNotNil(ActionValidator.problem(with: .keyboardShortcut(combo: KeyCombo(keyCode: 55))), "Modifier-only")
        XCTAssertNotNil(ActionValidator.problem(with: .openURL(url: "https://")))
        XCTAssertNotNil(ActionValidator.problem(with: .openURL(url: "not a url")))
        XCTAssertNil(ActionValidator.problem(with: .openURL(url: "https://example.com")))
        XCTAssertNotNil(ActionValidator.problem(with: .shellCommand(command: ShellCommandAction(command: "  "))))
        XCTAssertNotNil(ActionValidator.problem(with: .runShortcut(name: "")))
        XCTAssertNotNil(ActionValidator.problem(with: .volume(command: .set(level: 1.5))))
    }

    @MainActor
    func testExecutorReportsInvalidConfigurationWithoutRunning() async {
        let executor = ActionExecutor { _ in
            XCTFail("Should not ask for confirmation")
            return false
        }
        let result = await executor.perform(.runScript(script: ScriptAction(executablePath: "relative")), mappingName: "Test")
        guard case .failure(.invalidConfiguration) = result else {
            return XCTFail("Expected invalid configuration, got \(result)")
        }
    }

    @MainActor
    func testDeclinedConfirmationDoesNotRun() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("mg-\(UUID().uuidString)")
        var asked: ConfirmationRequest?
        let executor = ActionExecutor { request in
            asked = request
            return false
        }
        let result = await executor.perform(.shellCommand(command: ShellCommandAction(command: "touch \(marker.path)", requiresConfirmation: true)), mappingName: "Test")
        XCTAssertEqual(result, .cancelled("Command not run"))
        XCTAssertNotNil(asked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor
    func testDestructiveCommandForcesConfirmation() async {
        var asked: ConfirmationRequest?
        let executor = ActionExecutor { request in
            asked = request
            return false
        }
        _ = await executor.perform(.shellCommand(command: ShellCommandAction(command: "rm /tmp/nothing-here", requiresConfirmation: false)), mappingName: "Test")
        XCTAssertEqual(asked?.isDestructive, true)
    }

    @MainActor
    func testScriptRunsAndReportsExitStatus() async {
        let executor = ActionExecutor { _ in true }
        let success = await executor.perform(.runScript(script: ScriptAction(executablePath: "/usr/bin/true")), mappingName: "Test")
        XCTAssertTrue(success.isSuccess)
        let failure = await executor.perform(.runScript(script: ScriptAction(executablePath: "/usr/bin/false")), mappingName: "Test")
        XCTAssertEqual(failure, .failure(.executionFailed("false exited with status 1.")))
    }

    @MainActor
    func testScriptTimeout() async {
        let executor = ActionExecutor { _ in true }
        let result = await executor.perform(.runScript(script: ScriptAction(executablePath: "/bin/sleep", arguments: ["5"], timeout: 1)), mappingName: "Test")
        XCTAssertEqual(result, .failure(.executionFailed("sleep timed out after 1s.")))
    }

    @MainActor
    func testMissingPermissionFailsClearlyInsteadOfCrashing() async throws {
        let permissions = PermissionChecker.current()
        try XCTSkipIf(permissions.postEvents || permissions.accessibility, "This process has Accessibility; the denial path can't be exercised")
        let executor = ActionExecutor { _ in true }
        let key = await executor.perform(.keyboardShortcut(combo: KeyCombo(keyCode: 0, modifiers: .command)), mappingName: "Test")
        XCTAssertEqual(key, .failure(.permissionRequired(.postEvents)))
        let media = await executor.perform(.media(command: .playPause), mappingName: "Test")
        XCTAssertEqual(media, .failure(.permissionRequired(.postEvents)))
        let window = await executor.perform(.window(command: .leftHalf), mappingName: "Test")
        XCTAssertEqual(window, .failure(.permissionRequired(.accessibility)))
    }

    // MARK: - Keyboard model

    func testKeyComboDisplayAndFlags() {
        let combo = KeyCombo(keyCode: 17, modifiers: [.command, .shift, .control, .option])
        XCTAssertEqual(combo.displayName, "⌃⌥⇧⌘T")
        XCTAssertTrue(combo.modifiers.eventFlags.contains(.maskCommand))
        XCTAssertTrue(KeyCombo(keyCode: 123).impliedFlags.contains(.maskSecondaryFn), "Arrow keys carry fn")
        XCTAssertTrue(KeyCombo(keyCode: 103).impliedFlags.contains(.maskSecondaryFn), "F11 carries fn")
        XCTAssertEqual(KeyCombo(keyCode: 0).impliedFlags, [])
    }

    func testSymbolicHotKeyModifierDecoding() {
        XCTAssertEqual(SymbolicHotKeys.modifiers(fromHotKeyFlags: 0x40000), .control)
        XCTAssertEqual(SymbolicHotKeys.modifiers(fromHotKeyFlags: 0x40000 | 0x800000), .control, "fn bit ignored")
        XCTAssertEqual(SymbolicHotKeys.modifiers(fromHotKeyFlags: 0x100000 | 0x20000), [.command, .shift])
    }

    func testActionsRoundTripThroughJSON() throws {
        let actions: [GestureAction] = [
            .none,
            .keyboardShortcut(combo: KeyCombo(keyCode: 48, modifiers: .command)),
            .window(command: .topRightQuarter),
            .media(command: .nextTrack),
            .volume(command: .down(step: 0.1)),
            .system(feature: .moveSpaceLeft),
            .launchApplication(app: ApplicationReference(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app", name: "Safari")),
            .openURL(url: "https://example.com"),
            .runScript(script: ScriptAction(executablePath: "/usr/bin/true", arguments: ["x"])),
            .shellCommand(command: ShellCommandAction(command: "say hi")),
            .runShortcut(name: "Morning"),
        ]
        let data = try JSONEncoder().encode(actions)
        XCTAssertEqual(try JSONDecoder().decode([GestureAction].self, from: data), actions)
    }
}
