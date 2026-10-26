import AppKit
import MacGestureCore
import SwiftUI
import UniformTypeIdentifiers

struct ActionEditor: View {
    @Binding var action: GestureAction

    var body: some View {
        Picker("Action", selection: category) {
            ForEach(ActionCategory.allCases) { category in
                Label(category.displayName, systemImage: category.symbolName).tag(category)
            }
        }

        switch action {
        case .none:
            EmptyView()

        case .keyboardShortcut(let combo):
            KeyRecorderField(combo: Binding(get: { combo }, set: { action = .keyboardShortcut(combo: $0) }))
            Menu("Presets") {
                ForEach(KeyboardPreset.all) { preset in
                    Button("\(preset.name)  \(preset.combo.displayName)") {
                        action = .keyboardShortcut(combo: preset.combo)
                    }
                }
            }

        case .window(let command):
            Picker("Window", selection: Binding(get: { command }, set: { action = .window(command: $0) })) {
                ForEach(WindowCommand.allCases) { Text($0.displayName).tag($0) }
            }
            Text("Acts on the focused window of the frontmost app. Some apps don't allow resizing or set a minimum size.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .media(let command):
            Picker("Media", selection: Binding(get: { command }, set: { action = .media(command: $0) })) {
                ForEach(MediaCommand.allCases) { Text($0.displayName).tag($0) }
            }
            Text("Sent like the keyboard's media keys, to whichever app is playing.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .volume(let command):
            VolumeEditor(command: Binding(get: { command }, set: { action = .volume(command: $0) }))

        case .system(let feature):
            Picker("Feature", selection: Binding(get: { feature }, set: { action = .system(feature: $0) })) {
                ForEach(SystemFeature.allCases) { Text($0.displayName).tag($0) }
            }
            Text(feature.mechanismDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

        case .launchApplication(let app):
            ApplicationPicker(app: Binding(get: { app }, set: { action = .launchApplication(app: $0) }))

        case .openURL(let url):
            TextField("URL", text: Binding(get: { url }, set: { action = .openURL(url: $0) }), prompt: Text("https://example.com"))
            validation

        case .runScript(let script):
            ScriptEditor(script: Binding(get: { script }, set: { action = .runScript(script: $0) }))
            validation

        case .shellCommand(let command):
            ShellCommandEditor(command: Binding(get: { command }, set: { action = .shellCommand(command: $0) }))
            validation

        case .runShortcut(let name):
            TextField("Shortcut name", text: Binding(get: { name }, set: { action = .runShortcut(name: $0) }), prompt: Text("Exact name from the Shortcuts app"))
            validation
        }
    }

    private var category: Binding<ActionCategory> {
        Binding {
            action.category
        } set: { newCategory in
            if newCategory != action.category {
                action = newCategory.defaultAction
            }
        }
    }

    @ViewBuilder
    private var validation: some View {
        if let problem = ActionValidator.problem(with: action) {
            Label(problem, systemImage: StatusStyle.warning.symbolName)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct VolumeEditor: View {
    @Binding var command: VolumeCommand

    private enum Kind: String, CaseIterable, Identifiable {
        case up, down, mute, set
        var id: String { rawValue }
        var title: String {
            switch self {
            case .up: "Volume Up"
            case .down: "Volume Down"
            case .mute: "Toggle Mute"
            case .set: "Set Level"
            }
        }
    }

    var body: some View {
        Picker("Volume", selection: kind) {
            ForEach(Kind.allCases) { Text($0.title).tag($0) }
        }
        switch command {
        case .up(let step), .down(let step):
            Slider(value: Binding(get: { step }, set: { newStep in
                command = if case .up = command { .up(step: newStep) } else { .down(step: newStep) }
            }), in: 0.02...0.25) {
                Text("Step \(Int((step * 100).rounded()))%")
            }
        case .set(let level):
            Slider(value: Binding(get: { level }, set: { command = .set(level: $0) }), in: 0...1) {
                Text("Level \(Int((level * 100).rounded()))%")
            }
        case .toggleMute:
            EmptyView()
        }
        Text("Changes the default output device through Core Audio. Some HDMI and DisplayPort outputs have fixed volume.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var kind: Binding<Kind> {
        Binding {
            switch command {
            case .up: .up
            case .down: .down
            case .toggleMute: .mute
            case .set: .set
            }
        } set: { newKind in
            switch newKind {
            case .up: command = .up(step: VolumeCommand.defaultStep)
            case .down: command = .down(step: VolumeCommand.defaultStep)
            case .mute: command = .toggleMute
            case .set: command = .set(level: 0.5)
            }
        }
    }
}

private struct ApplicationPicker: View {
    @Binding var app: ApplicationReference

    var body: some View {
        LabeledContent("Application") {
            HStack {
                if FileManager.default.fileExists(atPath: app.path) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                }
                Text(app.name)
                Button("Choose…", action: choose)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        app = ApplicationReference(bundleIdentifier: bundle?.bundleIdentifier, path: url.path, name: name)
    }
}

private struct ScriptEditor: View {
    @Binding var script: ScriptAction

    var body: some View {
        LabeledContent("Executable") {
            HStack {
                TextField("Path", text: $script.executablePath, prompt: Text("/Users/you/bin/script.sh"))
                    .labelsHidden()
                Button("Choose…", action: choose)
            }
        }
        LabeledContent("Arguments") {
            TextEditor(text: arguments)
                .font(.body.monospaced())
                .frame(minHeight: 44)
        }
        Text("One argument per line. Arguments are passed directly, without a shell.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Toggle("Ask before running", isOn: $script.requiresConfirmation)
        Stepper(value: $script.timeout, in: 1...600, step: 5) {
            Text("Stop after \(Int(script.timeout))s")
        }
    }

    private var arguments: Binding<String> {
        Binding {
            script.arguments.joined(separator: "\n")
        } set: { text in
            script.arguments = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.isEmpty }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        script.executablePath = url.path
    }
}

private struct ShellCommandEditor: View {
    @Binding var command: ShellCommandAction

    var body: some View {
        LabeledContent("Command") {
            TextEditor(text: $command.command)
                .font(.body.monospaced())
                .frame(minHeight: 60)
        }
        Text("Runs with /bin/zsh -c. Output is discarded; only success or failure is reported.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if DangerousCommandDetector.isPotentiallyDestructive(command.command) {
            Label("This command looks destructive, so MacGesture will always ask before running it.", systemImage: StatusStyle.warning.symbolName)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        Toggle("Ask before running", isOn: $command.requiresConfirmation)
        Stepper(value: $command.timeout, in: 1...600, step: 5) {
            Text("Stop after \(Int(command.timeout))s")
        }
    }
}

struct KeyRecorderField: View {
    @Binding var combo: KeyCombo
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent("Shortcut") {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "Type a shortcut (Esc cancels)" : combo.displayName)
                    .font(.body.monospaced())
                    .frame(minWidth: 180)
            }
            .accessibilityHint(isRecording ? "Press the key combination to record" : "Click to record a new shortcut")
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = KeyModifiers(event.modifierFlags)
            if event.keyCode == 53, modifiers.isEmpty {
                stopRecording()
                return nil
            }
            if !KeyCodeNames.modifierKeyCodes.contains(event.keyCode) {
                combo = KeyCombo(keyCode: event.keyCode, modifiers: modifiers)
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}

extension KeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }
}
