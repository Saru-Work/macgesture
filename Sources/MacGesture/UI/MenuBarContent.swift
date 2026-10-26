import MacGestureCore
import SwiftUI

struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)

        if let warning {
            Button("⚠︎ \(warning)") { open(.permissions) }
        }

        Toggle("Gestures Enabled", isOn: $model.isEnabled)
            .keyboardShortcut("e")

        Divider()

        Picker("Profile", selection: $model.activeProfileID) {
            ForEach(model.configuration.profiles) { profile in
                Text(profile.name).tag(profile.id)
            }
        }

        Divider()

        Button("Open MacGesture…") { open(.dashboard) }
            .keyboardShortcut(",")
        Button("Edit Gestures…") { open(.gestures) }
        Button("Live Test…") { open(.liveTest) }

        Divider()

        Button("Quit MacGesture") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        guard model.isEnabled else { return "MacGesture — Paused" }
        return model.inputState.isRunning ? "MacGesture — Active" : "MacGesture — \(model.inputState.summary)"
    }

    private var warning: String? {
        if !model.permissions.allGranted, !model.actionsNeedingPermission.isEmpty {
            return "Accessibility permission needed"
        }
        return nil
    }

    private func open(_ section: AppSection) {
        model.selectedSection = section
        bringForward(openWindow, id: WindowID.main)
    }
}
