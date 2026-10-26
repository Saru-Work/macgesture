import AppKit
import MacGestureCore
import Observation
import Security
import ServiceManagement

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, gestures, liveTest, permissions, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .gestures: "Gestures"
        case .liveTest: "Live Test"
        case .permissions: "Permissions"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .gestures: "hand.draw"
        case .liveTest: "waveform.path.ecg"
        case .permissions: "lock.shield"
        case .settings: "gearshape"
        }
    }
}

enum InputState: Equatable {
    case stopped
    case running(devices: [TrackpadDevice])
    case noDevices
    case unavailable(reason: String)
    case failed(reason: String)

    var summary: String {
        switch self {
        case .stopped: "Stopped"
        case .running(let devices): devices.map(\.name).joined(separator: ", ")
        case .noDevices: "No trackpad found"
        case .unavailable: "Unavailable on this macOS"
        case .failed: "Failed to start"
        }
    }

    var detail: String? {
        switch self {
        case .unavailable(let reason), .failed(let reason): reason
        default: nil
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

struct ActivityEntry: Identifiable {
    enum Outcome {
        case success(String)
        case failure(String)
        case skipped(String)
        case pending
    }

    let id = UUID()
    var date: Date
    var trigger: GestureTrigger
    let source: InputSourceKind
    var mappingName: String?
    var outcome: Outcome
}

enum LiveTestMode: String, CaseIterable, Identifiable {
    case activeProfile
    case allGestures

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activeProfile: "Active Profile"
        case .allGestures: "All Gestures (no actions)"
        }
    }
}

enum CaptureState: Equatable {
    case listening
    case captured(GestureTrigger, InputSourceKind)
}

/// App-wide state: configuration, the input/recognition pipeline, permissions,
/// and recent activity. Everything here runs on the main actor; the engine
/// does its work on its own queue and reports back here.
@MainActor
@Observable
final class AppModel {
    // MARK: Configuration

    var configuration: AppConfiguration {
        didSet { configurationDidChange(from: oldValue) }
    }

    private(set) var configurationNotice: String?
    private(set) var savingBlocked = false

    // MARK: Status

    private(set) var inputState = InputState.stopped
    private(set) var permissions = PermissionChecker.current()
    private(set) var systemGestures = SystemGestureSettings.current()
    private(set) var activity: [ActivityEntry] = []
    private(set) var diagnostics: EngineDiagnostics?
    private(set) var lastHardwareFrame: Date?
    private(set) var launchAtLoginStatus = SMAppService.mainApp.status

    // MARK: Live testing

    var selectedSection: AppSection = .dashboard
    var liveTestMode = LiveTestMode.activeProfile {
        didSet { updateEngineMode() }
    }
    var runActionsForSimulatedGestures = false
    private(set) var capture: CaptureState?

    // MARK: Pipeline

    @ObservationIgnored let simulator = SimulatedInputProvider()
    @ObservationIgnored private let hardware: any TrackpadInputProvider = MultitouchSupportProvider()
    @ObservationIgnored private var engine: GestureEngine!
    @ObservationIgnored private var executor: ActionExecutor!
    @ObservationIgnored private var deviceMonitor: MultitouchDeviceMonitor?
    @ObservationIgnored private let store: ConfigurationStore?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var diagnosticsClients = 0
    @ObservationIgnored private var awaitingConfirmation = false
    @ObservationIgnored private let log = DiagnosticsLog.shared
    @ObservationIgnored let inputSuppressor = InputSuppressor()
    /// The activity row updated by the current continuous gesture, if any.
    @ObservationIgnored private var continuousEntryID: UUID?
    @ObservationIgnored private var volumeHaptics = VolumeHapticFeedback()

    private(set) var inputSuppressionStatus = InputSuppressor.Status.stopped

    init() {
        var notice: String?
        var blocked = false
        var store: ConfigurationStore?
        let loaded: AppConfiguration
        do {
            store = ConfigurationStore(directory: try ConfigurationStore.defaultDirectory())
            let result = store!.load()
            loaded = result.configuration
            if let issue = result.issue, issue != .createdDefaults {
                notice = issue.message
            }
            blocked = result.issue?.blocksSaving ?? false
        } catch {
            loaded = DefaultConfiguration.make()
            notice = "Application Support is unavailable (\(error.localizedDescription)). Changes won't be saved."
            blocked = true
        }
        self.store = store
        self.configuration = loaded
        self.configurationNotice = notice
        self.savingBlocked = blocked
        log.setLevel(loaded.general.logLevel)

        let suppressor = inputSuppressor
        engine = GestureEngine(configuration: loaded, continuousGestureObserver: { active in
            // Called on the recognition queue so input is blocked without
            // waiting for the main thread.
            suppressor.setActive(active)
        }) { [weak self] output in
            // Main-queue hop preserves the engine's output order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handle(output)
                }
            }
        }
        executor = ActionExecutor { [weak self] request in
            await self?.confirm(request) ?? false
        }
        let engine = engine!
        try? simulator.start { frame in engine.ingest(frame) }
        if !blocked {
            scheduleSave(immediately: true)
        }
    }

    // MARK: Lifecycle

    func start() {
        log.info("MacGesture started; backend: \(hardware.displayName)")
        let monitor = MultitouchDeviceMonitor { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.scheduleInputRestart(reason: "Trackpad added or removed") }
            }
        }
        monitor.start()
        deviceMonitor = monitor

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopHardware(reason: "System sleeping") }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleInputRestart(reason: "System woke") }
        }
        center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopHardware(reason: "User session inactive") }
        }
        center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleInputRestart(reason: "User session active") }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemState() }
        }

        // Permissions can change at any time in System Settings; polling is the
        // only way to notice. Both checks are cheap.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        refreshInput()
        refreshInputSuppression()
    }

    func shutdown() {
        inputSuppressor.stop()
        hardware.stop()
        simulator.stop()
        deviceMonitor?.stop()
        flushSave()
    }

    // MARK: Enable / profiles

    var isEnabled: Bool {
        get { configuration.general.isEnabled }
        set { configuration.general.isEnabled = newValue }
    }

    var activeProfileID: UUID {
        get { configuration.activeProfileID }
        set { configuration.activeProfileID = newValue }
    }

    var activeProfile: GestureProfile {
        get { configuration.activeProfile }
        set { configuration.activeProfile = newValue }
    }

    var mappingIssues: [MappingIssue] {
        MappingConflictDetector.issues(in: activeProfile, system: systemGestures)
    }

    func issues(for mapping: GestureMapping) -> [MappingIssue] {
        mappingIssues.filter { $0.mappingIDs.contains(mapping.id) }
    }

    func resetConfiguration() {
        guard let store else { return }
        do {
            let fresh = try store.reset()
            savingBlocked = false
            configuration = fresh
            configurationNotice = "Configuration reset to defaults. The previous file was kept in the configuration folder."
            log.info("Configuration reset to defaults")
        } catch {
            configurationNotice = "Couldn't reset the configuration: \(error.localizedDescription)"
        }
    }

    func dismissConfigurationNotice() {
        configurationNotice = nil
    }

    var configurationDirectory: URL? { store?.directory }
    var logFileURL: URL { log.fileURL }

    private func configurationDidChange(from old: AppConfiguration) {
        guard configuration != old else { return }
        engine.apply(configuration)
        if configuration.general.logLevel != old.general.logLevel {
            log.setLevel(configuration.general.logLevel)
        }
        if configuration.general.isEnabled != old.general.isEnabled {
            log.info(configuration.general.isEnabled ? "Gestures enabled" : "Gestures paused")
            refreshInput()
        }
        if configuration.activeProfileID != old.activeProfileID {
            log.info("Switched to profile “\(configuration.activeProfile.name)”")
        }
        refreshInputSuppression()
        scheduleSave()
    }

    private func scheduleSave(immediately: Bool = false) {
        guard !savingBlocked, let store else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard !Task.isCancelled, let self else { return }
            do {
                try store.save(self.configuration)
            } catch {
                self.configurationNotice = "Couldn't save the configuration: \(error.localizedDescription)"
                self.log.error("Save failed: \(error.localizedDescription)")
            }
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        guard !savingBlocked, let store else { return }
        try? store.save(configuration)
    }

    // MARK: Input

    /// Hardware input runs while gestures are enabled, or while something is
    /// watching it (live test, gesture capture).
    func refreshInput() {
        let needed = configuration.general.isEnabled || diagnosticsClients > 0 || capture != nil
        if needed, !hardware.isRunning {
            startHardware()
        } else if !needed, hardware.isRunning {
            stopHardware(reason: "Gestures paused")
        }
    }

    func restartInput() {
        stopHardware(reason: "Restart requested")
        refreshInput()
    }

    private func startHardware() {
        switch hardware.availability() {
        case .unavailable(let reason):
            inputState = .unavailable(reason: reason)
            log.error("Trackpad backend unavailable: \(reason)")
        case .noDevices:
            inputState = .noDevices
            log.info("No multitouch devices attached")
        case .available(let devices):
            let engine = engine!
            do {
                try hardware.start { frame in engine.ingest(frame) }
                inputState = .running(devices: devices)
                log.info("Trackpad input started: \(devices.map(\.name).joined(separator: ", "))")
            } catch {
                inputState = .failed(reason: error.localizedDescription)
                log.error("Trackpad input failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopHardware(reason: String) {
        restartTask?.cancel()
        guard hardware.isRunning else { return }
        hardware.stop()
        engine.reset()
        inputState = .stopped
        log.info("Trackpad input stopped: \(reason)")
    }

    private func scheduleInputRestart(reason: String) {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            // Let devices finish enumerating after wake or hot-plug.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.log.info("Restarting trackpad input: \(reason)")
            if self.hardware.isRunning {
                self.hardware.stop()
                self.engine.reset()
            }
            self.inputState = .stopped
            self.refreshInput()
        }
    }

    // MARK: Diagnostics and capture

    /// Live views call this while visible so the engine only produces
    /// diagnostics when someone is looking.
    func beginDiagnostics() {
        diagnosticsClients += 1
        if diagnosticsClients == 1 {
            engine.setDiagnosticsRate(30)
        }
        refreshInput()
    }

    func endDiagnostics() {
        diagnosticsClients = max(0, diagnosticsClients - 1)
        if diagnosticsClients == 0 {
            engine.setDiagnosticsRate(nil)
            diagnostics = nil
        }
        refreshInput()
    }

    /// Listens for the next gesture of any kind without running actions.
    func beginCapture() {
        capture = .listening
        updateEngineMode()
        refreshInput()
    }

    func endCapture() {
        capture = nil
        updateEngineMode()
        refreshInput()
    }

    private func updateEngineMode() {
        engine.setMode(capture != nil || liveTestMode == .allGestures ? .diagnoseAll : .normal)
    }

    func simulate(_ frames: [TouchFrame]) {
        simulator.play(frames)
    }

    func injectSimulated(_ frame: TouchFrame) {
        simulator.inject(frame)
    }

    // MARK: Engine output

    private func handle(_ output: EngineOutput) {
        switch output {
        case .anchorGestureStopped(let reason):
            log.info("Anchor gesture stopped early: \(reason)")
        case .diagnostics(let snapshot):
            diagnostics = snapshot
            if snapshot.source == .hardware {
                lastHardwareFrame = Date()
            }
        case .recognized(let event, let decision):
            if event.source == .hardware {
                lastHardwareFrame = Date()
            }
            if capture == .listening {
                capture = .captured(event.trigger, event.source)
            }
            route(event, decision)
        }
    }

    private func route(_ event: GestureEvent, _ decision: RouteDecision) {
        let sourceLabel = event.source == .simulated ? " [simulated]" : ""
        switch decision {
        case .execute(let mapping):
            if event.source == .simulated, !runActionsForSimulatedGestures {
                record(event, mapping: mapping, .skipped("Simulated — action not run"))
                return
            }
            if awaitingConfirmation {
                record(event, mapping: mapping, .skipped("Ignored while a confirmation is open"))
                return
            }
            let entryID = record(event, mapping: mapping, .pending)
            if !event.isContinuation {
                volumeHaptics.reset()
            }
            if !event.isContinuation {
                log.info("\(event.trigger.displayName)\(sourceLabel) → \(mapping.displayName) (\(mapping.action.category.displayName))")
            }
            Task {
                let result = await executor.perform(mapping.action, mappingName: mapping.displayName, magnitude: event.magnitude)
                self.complete(entryID: entryID, with: result, mapping: mapping)
            }
        case .noMapping:
            if !event.isContinuation {
                log.debug("\(event.trigger.displayName)\(sourceLabel): no mapping")
            }
            record(event, mapping: nil, .skipped("No mapping"))
        case .coolingDown, .disabled, .suppressed:
            if !event.isContinuation {
                log.debug("\(event.trigger.displayName)\(sourceLabel): \(decision.summary)")
            }
            record(event, mapping: nil, .skipped(decision.summary))
        }
    }

    @discardableResult
    private func record(_ event: GestureEvent, mapping: GestureMapping?, _ outcome: ActivityEntry.Outcome) -> UUID {
        // A continuous gesture updates one row instead of adding ~30 a second.
        if event.trigger.kind.isContinuous {
            if event.isContinuation, let id = continuousEntryID, let index = activity.firstIndex(where: { $0.id == id }) {
                activity[index].date = Date()
                activity[index].trigger = event.trigger
                activity[index].mappingName = mapping?.displayName
                if case .pending = outcome {} else { activity[index].outcome = outcome }
                return id
            }
        }
        let entry = ActivityEntry(date: Date(), trigger: event.trigger, source: event.source, mappingName: mapping?.displayName, outcome: outcome)
        activity.insert(entry, at: 0)
        continuousEntryID = event.trigger.kind.isContinuous ? entry.id : nil
        if activity.count > 100 {
            activity.removeLast(activity.count - 100)
        }
        return entry.id
    }

    private func complete(entryID: UUID, with result: ActionResult, mapping: GestureMapping) {
        let outcome: ActivityEntry.Outcome
        switch result {
        case .success(let message):
            outcome = .success(message)
            if case .volume = mapping.action {
                volumeChanged()
            }
        case .failure(let error):
            outcome = .failure(error.localizedDescription)
            log.error("“\(mapping.displayName)” failed: \(error.localizedDescription)")
            if case .permissionRequired = error {
                refreshPermissions()
            }
        case .cancelled(let reason):
            outcome = .skipped(reason)
            log.info("“\(mapping.displayName)” cancelled by user")
        }
        if let index = activity.firstIndex(where: { $0.id == entryID }) {
            activity[index].outcome = outcome
        }
    }

    /// Runs an action directly, e.g. "Run Action Now" in the editor.
    func performNow(_ action: GestureAction, name: String) async -> ActionResult {
        log.info("Manual test of “\(name)” (\(action.category.displayName))")
        let result = await executor.perform(action, mappingName: name)
        if case .failure(.permissionRequired) = result {
            refreshPermissions()
        }
        return result
    }

    func clearActivity() {
        activity.removeAll()
    }

    // MARK: Confirmation

    private func confirm(_ request: ConfirmationRequest) async -> Bool {
        awaitingConfirmation = true
        defer { awaitingConfirmation = false }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = "\(request.message)\n\n\(request.detail)"
        alert.alertStyle = request.isDestructive ? .critical : .warning
        let run = alert.addButton(withTitle: request.isDestructive ? "Run Anyway" : "Run")
        let cancel = alert.addButton(withTitle: "Cancel")
        if request.isDestructive {
            // Make Cancel the default so a stray Return can't approve it.
            run.hasDestructiveAction = true
            run.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Permissions and system state

    func refreshPermissions() {
        let current = PermissionChecker.current()
        if current != permissions {
            log.info("Permissions changed: accessibility=\(current.accessibility) events=\(current.postEvents)")
            permissions = current
            refreshInputSuppression()
        }
    }

    // MARK: Volume feedback

    private func volumeChanged() {
        volumeHaptics.mode = configuration.general.volumeHapticMode
        if volumeHaptics.mode != .off, let change = try? executor.volume.current(),
           let strength = volumeHaptics.feedback(forLevel: change.isMuted ? 0 : change.level, at: ProcessInfo.processInfo.systemUptime) {
            TrackpadHaptics.play(strength)
        }
    }

    // MARK: Anchor finger + vertical swipe

    var anchorMappings: [GestureMapping] {
        activeProfile.mappings.filter { $0.trigger.kind == .anchorSwipe }
    }

    /// Enables or disables the anchor gesture in the active profile, adding
    /// the default volume mappings if the profile has none.
    var anchorGestureEnabled: Bool {
        get { anchorMappings.contains(where: \.isEnabled) }
        set {
            var profile = activeProfile
            if newValue, !profile.mappings.contains(where: { $0.trigger.kind == .anchorSwipe }) {
                profile.mappings.append(contentsOf: DefaultConfiguration.anchorVolumeMappings())
            } else {
                for index in profile.mappings.indices where profile.mappings[index].trigger.kind == .anchorSwipe {
                    profile.mappings[index].isEnabled = newValue
                }
            }
            activeProfile = profile
        }
    }

    /// The scroll-blocking event tap runs only while it can be useful.
    func refreshInputSuppression() {
        let wanted = configuration.general.suppressScrollDuringAnchorGesture && anchorGestureEnabled && permissions.accessibility
        if wanted {
            inputSuppressor.start()
        } else {
            inputSuppressor.stop()
        }
        let status = inputSuppressor.status
        if status != inputSuppressionStatus {
            if case .failed(let reason) = status {
                log.error("Scroll suppression unavailable: \(reason)")
            }
            inputSuppressionStatus = status
        }
    }

    func request(_ permission: PermissionKind) {
        PermissionChecker.request(permission)
        refreshPermissions()
    }

    /// Clears this app's entries from the privacy database and asks again.
    /// Needed when System Settings shows MacGesture switched on but macOS still
    /// refuses it: the entry belongs to an earlier build with a different
    /// code signature.
    func resetPermissionEntries() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        for service in ["Accessibility", "PostEvent"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                log.error("tccutil reset \(service) failed: \(error.localizedDescription)")
            }
        }
        log.info("Reset privacy entries; requesting Accessibility again")
        refreshPermissions()
        request(.accessibility)
    }

    /// Starts a fresh copy of the app and quits this one. Some permission
    /// checks only reflect a new grant in a newly launched process.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// Ad-hoc signatures change on every build, which silently invalidates
    /// existing privacy grants.
    let isAdHocSigned: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32 else {
            return false
        }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }()

    func openSettings(for permission: PermissionKind) {
        if let url = permission.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    func openTrackpadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshSystemState() {
        refreshPermissions()
        let gestures = SystemGestureSettings.current()
        if gestures != systemGestures {
            systemGestures = gestures
        }
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    var actionsNeedingPermission: [GestureMapping] {
        activeProfile.mappings.filter { $0.isEnabled && $0.action.requiresAccessibility }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                configurationNotice = "Couldn't change the login item: \(error.localizedDescription)"
            }
            launchAtLoginStatus = SMAppService.mainApp.status
        }
    }
}
