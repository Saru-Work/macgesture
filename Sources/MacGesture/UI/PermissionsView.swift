import MacGestureCore
import SwiftUI

struct PermissionsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases) { permission in
                    PermissionRow(permission: permission, granted: model.permissions.isGranted(permission)) {
                        model.request(permission)
                    } openSettings: {
                        model.openSettings(for: permission)
                    }
                }
            } header: {
                Text("Required for actions")
            } footer: {
                Text("Reading the trackpad needs no permission. Keyboard shortcuts, media keys, window management, and system features that post shortcuts are blocked by macOS until MacGesture is allowed under Privacy & Security ▸ Accessibility. Volume, app launching, URLs, scripts, and Mission Control work without it.")
            }

            if !model.permissions.allGranted {
                Section("Already switched on in System Settings?") {
                    if model.permissions.accessibility, !model.permissions.postEvents {
                        Text("Accessibility is granted, but keyboard-event access hasn't caught up in this running copy of MacGesture.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Relaunch MacGesture") { model.relaunch() }
                    } else {
                        Text("If MacGesture is listed and switched on but still shows as not granted here, the entry belongs to an earlier build of the app. macOS identifies apps by their code signature, so that entry doesn't apply to this copy. Reset it, then switch MacGesture on again when asked.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Reset Permission Entry and Ask Again") { model.resetPermissionEntries() }
                    }
                    if model.isAdHocSigned {
                        Label("This build is ad-hoc signed, so every rebuild needs permission granted again. Build with MACGESTURE_SIGN_IDENTITY set to keep the grant (see README).", systemImage: StatusStyle.info.symbolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !model.actionsNeedingPermission.isEmpty {
                Section("Gestures that need Accessibility") {
                    ForEach(model.actionsNeedingPermission) { mapping in
                        LabeledContent(mapping.displayName, value: mapping.action.summary)
                    }
                }
            }

            Section("Troubleshooting") {
                VStack(alignment: .leading, spacing: 8) {
                    troubleshooting("MacGesture is listed and switched on, but still shows as not granted",
                                    "macOS ties the grant to the app's code signature. After rebuilding or moving the app, remove MacGesture from the Accessibility list with the − button, then add it again (or click Request Access).")
                    troubleshooting("Nothing happens when a gesture is recognized",
                                    "Open the Dashboard: Recent Activity shows whether the gesture was recognized and why the action failed.")
                    troubleshooting("macOS also reacts to my gesture",
                                    "MacGesture can observe the trackpad but can't block macOS's own gestures. Turn the overlapping gesture off in System Settings ▸ Trackpad ▸ More Gestures.")
                }
                HStack {
                    Button("Check Again") { model.refreshSystemState() }
                    Button("Open Trackpad Settings…") { model.openTrackpadSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshSystemState() }
    }

    private func troubleshooting(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.medium)
            Text(body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PermissionRow: View {
    let permission: PermissionKind
    let granted: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.title2)
                .foregroundStyle(granted ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(permission.displayName).fontWeight(.medium)
                Text(permission.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(granted ? "Granted" : "Not granted")
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .orange)
            }
            Spacer()
            if !granted {
                VStack(alignment: .trailing) {
                    Button("Request Access", action: request)
                    Button("Open System Settings…", action: openSettings)
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}
