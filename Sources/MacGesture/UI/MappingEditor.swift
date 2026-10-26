import MacGestureCore
import SwiftUI

struct MappingEditor: View {
    @Bindable var model: AppModel
    @State var draft: GestureMapping
    let isNew: Bool
    let onSave: (GestureMapping) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var testResult: ActionResult?
    @State private var isTesting = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                gestureSection
                Section("Action") {
                    ActionEditor(action: $draft.action)
                }
                if !issues.isEmpty {
                    Section("Issues") {
                        ForEach(issues) { IssueRow(issue: $0) }
                    }
                }
                testSection
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Toggle("Enabled", isOn: $draft.isEnabled)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.trigger.isValid)
            }
            .padding(14)
        }
        .frame(width: 580, height: 700)
        .onDisappear { model.endCapture() }
    }

    // MARK: Gesture

    private var gestureSection: some View {
        Section("Gesture") {
            TextField("Name", text: $draft.name, prompt: Text(draft.trigger.displayName.capitalizedFirstLetter))
            Picker("Type", selection: kind) {
                ForEach(GestureKind.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Fingers", selection: fingers) {
                ForEach(Array(GestureKind.fingerRange), id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(draft.trigger.kind.allowedFingers.count == 1)
            if draft.trigger.kind == .anchorSwipe {
                Text("One finger holds still while a second slides vertically. The action repeats as the finger moves; volume actions scale with distance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if draft.trigger.kind.validDirections != [.none] {
                Picker("Direction", selection: $draft.trigger.direction) {
                    ForEach(draft.trigger.kind.validDirections) { direction in
                        Label(direction.displayName, systemImage: direction.symbolName).tag(direction)
                    }
                }
            }
            Toggle("Custom sensitivity", isOn: customSensitivity)
            if let sensitivity = draft.sensitivity {
                Slider(value: Binding(get: { sensitivity }, set: { draft.sensitivity = $0 }), in: 0...1) {
                    Text("Sensitivity")
                } minimumValueLabel: {
                    Text("Less")
                } maximumValueLabel: {
                    Text("More")
                }
            }
            Toggle("Extra cooldown for this gesture", isOn: customCooldown)
            if let cooldown = draft.cooldown {
                Stepper(value: Binding(get: { cooldown }, set: { draft.cooldown = $0 }), in: 0.5...30, step: 0.5) {
                    Text("Wait \(cooldown, format: .number.precision(.fractionLength(1)))s before it can fire again")
                }
            }
        }
    }

    private var kind: Binding<GestureKind> {
        Binding {
            draft.trigger.kind
        } set: { newKind in
            draft.trigger = GestureTrigger(kind: newKind, fingers: draft.trigger.fingers, direction: draft.trigger.direction)
        }
    }

    private var fingers: Binding<Int> {
        Binding {
            draft.trigger.fingers
        } set: { count in
            draft.trigger = GestureTrigger(kind: draft.trigger.kind, fingers: count, direction: draft.trigger.direction)
        }
    }

    private var customSensitivity: Binding<Bool> {
        Binding {
            draft.sensitivity != nil
        } set: { enabled in
            draft.sensitivity = enabled ? model.configuration.recognition.sensitivity : nil
        }
    }

    private var customCooldown: Binding<Bool> {
        Binding {
            draft.cooldown != nil
        } set: { enabled in
            draft.cooldown = enabled ? 2 : nil
        }
    }

    // MARK: Issues

    private var issues: [MappingIssue] {
        var profile = model.activeProfile
        var probe = draft
        probe.isEnabled = true // Show what would happen once enabled.
        if let index = profile.mappings.firstIndex(where: { $0.id == draft.id }) {
            profile.mappings[index] = probe
        } else {
            profile.mappings.append(probe)
        }
        return MappingConflictDetector.issues(in: profile, system: model.systemGestures)
            .filter { $0.mappingIDs.contains(draft.id) }
    }

    // MARK: Testing

    private var testSection: some View {
        Section {
            captureRow
            HStack {
                Button {
                    runAction()
                } label: {
                    Label("Run Action Now", systemImage: "play")
                }
                .disabled(isTesting || draft.action == .none)
                if isTesting {
                    ProgressView().controlSize(.small)
                }
                if let testResult {
                    Label(testResult.message, systemImage: testResult.isSuccess ? StatusStyle.ok.symbolName : StatusStyle.error.symbolName)
                        .foregroundStyle(testResult.isSuccess ? .green : .red)
                        .lineLimit(3)
                }
            }
        } header: {
            Text("Test Before Saving")
        } footer: {
            Text("Gesture testing uses default thresholds and never runs actions. “Run Action Now” performs the action immediately, exactly as the gesture would.")
        }
    }

    @ViewBuilder
    private var captureRow: some View {
        switch model.capture {
        case nil:
            Button {
                model.beginCapture()
            } label: {
                Label("Try Gesture on Trackpad…", systemImage: "hand.tap")
            }
        case .listening:
            HStack {
                ProgressView().controlSize(.small)
                Text("Perform \(draft.trigger.displayName) on your trackpad…")
                Spacer()
                Button("Stop") { model.endCapture() }
            }
        case .captured(let trigger, let source):
            HStack {
                if trigger == draft.trigger {
                    Label("Recognized \(trigger.displayName)", systemImage: StatusStyle.ok.symbolName)
                        .foregroundStyle(.green)
                } else {
                    Label("Recognized \(trigger.displayName), not \(draft.trigger.displayName)", systemImage: StatusStyle.warning.symbolName)
                        .foregroundStyle(.orange)
                }
                SourceBadge(source: source)
                Spacer()
                Button("Try Again") { model.beginCapture() }
                Button("Done") { model.endCapture() }
            }
        }
    }

    private func runAction() {
        isTesting = true
        testResult = nil
        Task {
            testResult = await model.performNow(draft.action, name: draft.displayName)
            isTesting = false
        }
    }
}
