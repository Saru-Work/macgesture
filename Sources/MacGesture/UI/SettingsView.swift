import MacGestureCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var confirmingReset = false
    @State private var renamingProfile: GestureProfile?
    @State private var newProfileName = ""

    var body: some View {
        Form {
            generalSection
            recognitionSection
            AnchorGestureSettings(model: model)
            profilesSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .alert("Reset all settings?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { model.resetConfiguration() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All profiles and gestures are replaced with the defaults. The current configuration is kept as a backup file.")
        }
        .alert("Rename Profile", isPresented: Binding(get: { renamingProfile != nil }, set: { if !$0 { renamingProfile = nil } })) {
            TextField("Name", text: $newProfileName)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section("General") {
            Toggle("Process gestures", isOn: $model.isEnabled)
            Toggle("Open at login", isOn: $model.launchAtLogin)
            if model.launchAtLoginStatus == .requiresApproval {
                Label("Approve MacGesture in System Settings ▸ General ▸ Login Items.", systemImage: StatusStyle.warning.symbolName)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Cooldown") {
                HStack {
                    Slider(value: $model.configuration.general.cooldown, in: 0...2, step: 0.05)
                        .frame(maxWidth: 240)
                    Text("\(model.configuration.general.cooldown, format: .number.precision(.fractionLength(2)))s")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
            Text("Ignore further gestures for this long after an action runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Recognition

    private var recognitionSection: some View {
        Section {
            LabeledContent("Sensitivity") {
                HStack {
                    Text("Less").font(.caption)
                    Slider(value: $model.configuration.recognition.sensitivity, in: 0...1)
                        .frame(maxWidth: 240)
                        .accessibilityValue("\(Int(model.configuration.recognition.sensitivity * 100)) percent")
                    Text("More").font(.caption)
                }
            }
            DisclosureGroup("Advanced thresholds") {
                threshold("Swipe distance", \.swipeDistance, 6...40, "mm")
                threshold("Swipe straightness", \.swipeMinimumStraightness, 0.4...0.95, "")
                threshold("Diagonal tolerance", \.diagonalTolerance, 5...22, "°")
                threshold("Pinch change", \.pinchThreshold, 0.08...0.6, "×")
                threshold("Rotation", \.rotationThreshold, 8...90, "°")
                threshold("Circle turn", \.circleMinimumTurn, 200...540, "°")
                threshold("Tap max duration", \.tapMaximumDuration, 0.1...0.5, "s")
                threshold("Tap max movement", \.tapMaximumMovement, 1...8, "mm")
                threshold("Hold duration", \.holdDuration, 0.3...2, "s")
                threshold("Hold max movement", \.holdMaximumMovement, 1...8, "mm")
                threshold("Palm size limit", \.maximumContactSize, 1...6, "")
                Button("Restore Default Thresholds") {
                    let sensitivity = model.configuration.recognition.sensitivity
                    model.configuration.recognition = RecognitionSettings()
                    model.configuration.recognition.sensitivity = sensitivity
                }
            }
        } header: {
            Text("Recognition")
        } footer: {
            Text("Distances are physical millimetres on the trackpad. Sensitivity scales all movement thresholds (halved at most sensitive, doubled at least). Use Live Test to see how close a motion comes to each threshold.")
        }
    }

    private func threshold(_ title: String, _ keyPath: WritableKeyPath<RecognitionSettings, Double>, _ range: ClosedRange<Double>, _ unit: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(
                    get: { model.configuration.recognition[keyPath: keyPath] },
                    set: { model.configuration.recognition[keyPath: keyPath] = $0 }
                ), in: range)
                .frame(maxWidth: 220)
                Text(String(format: range.upperBound <= 2 ? "%.2f%@" : "%.0f%@", model.configuration.recognition[keyPath: keyPath], unit))
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    // MARK: Profiles

    private var profilesSection: some View {
        Section {
            ForEach(model.configuration.profiles) { profile in
                HStack {
                    Image(systemName: profile.id == model.activeProfileID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(profile.id == model.activeProfileID ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                    Text(profile.name)
                    Text("\(profile.mappings.count) gestures")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if profile.id != model.activeProfileID {
                        Button("Activate") { model.activeProfileID = profile.id }
                    }
                    Menu {
                        Button("Rename…") {
                            newProfileName = profile.name
                            renamingProfile = profile
                        }
                        Button("Duplicate") { duplicate(profile) }
                        Button("Delete", role: .destructive) { delete(profile) }
                            .disabled(model.configuration.profiles.count == 1)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Options for \(profile.name)")
                }
            }
            Button {
                let profile = GestureProfile(name: "New Profile")
                model.configuration.profiles.append(profile)
            } label: {
                Label("New Profile", systemImage: "plus")
            }
        } header: {
            Text("Profiles")
        } footer: {
            Text("Switch profiles quickly from the menu bar.")
        }
    }

    private func duplicate(_ profile: GestureProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name = "\(profile.name) Copy"
        copy.mappings = profile.mappings.map { mapping in
            var fresh = mapping
            fresh.id = UUID()
            return fresh
        }
        model.configuration.profiles.append(copy)
    }

    private func delete(_ profile: GestureProfile) {
        guard model.configuration.profiles.count > 1 else { return }
        var configuration = model.configuration
        configuration.profiles.removeAll { $0.id == profile.id }
        if configuration.activeProfileID == profile.id {
            configuration.activeProfileID = configuration.profiles[0].id
        }
        model.configuration = configuration
    }

    private func rename() {
        guard let profile = renamingProfile else { return }
        let name = newProfileName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let index = model.configuration.profiles.firstIndex(where: { $0.id == profile.id }) {
            model.configuration.profiles[index].name = name
        }
        renamingProfile = nil
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        Section {
            Picker("Logging", selection: $model.configuration.general.logLevel) {
                ForEach(LogLevel.allCases) { Text($0.displayName).tag($0) }
            }
            Text("Logs record gesture names, action types, and results. They never include command text, script output, or URLs.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Show Log in Finder") {
                    NSWorkspace.shared.selectFile(model.logFileURL.path, inFileViewerRootedAtPath: model.logFileURL.deletingLastPathComponent().path)
                }
                if let directory = model.configurationDirectory {
                    Button("Open Configuration Folder") { NSWorkspace.shared.open(directory) }
                }
                Button("Restart Trackpad Input") { model.restartInput() }
            }
            LabeledContent("Input backend", value: "MultitouchSupport.framework (private)")
            LabeledContent("Status", value: model.inputState.detail ?? model.inputState.summary)
            LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            Button("Reset to Defaults…", role: .destructive) { confirmingReset = true }
        } header: {
            Text("Diagnostics")
        }
    }
}
