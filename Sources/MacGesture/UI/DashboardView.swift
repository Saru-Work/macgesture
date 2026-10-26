import MacGestureCore
import SwiftUI

struct DashboardView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow {
                        engineCard
                        inputCard
                    }
                    GridRow {
                        permissionCard
                        profileCard
                    }
                }

                let overlaps = model.mappingIssues.filter { $0.severity == .warning }
                if !overlaps.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(overlaps) { IssueRow(issue: $0) }
                            Button("Open Trackpad Settings…") { model.openTrackpadSettings() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    } label: {
                        Label("Overlaps with macOS gestures", systemImage: "exclamationmark.triangle")
                    }
                }

                GroupBox {
                    if model.activity.isEmpty {
                        Text("No gestures yet. Try one on your trackpad, or use Live Test.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(model.activity.prefix(25)) { entry in
                                ActivityRow(entry: entry)
                                Divider()
                            }
                        }
                        .padding(4)
                    }
                } label: {
                    HStack {
                        Label("Recent Activity", systemImage: "clock")
                        Spacer()
                        if !model.activity.isEmpty {
                            Button("Clear") { model.clearActivity() }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var engineCard: some View {
        DashboardCard(title: "Gesture Engine", systemImage: "hand.point.up.left") {
            StatusBadge(text: model.isEnabled ? "Active" : "Paused", style: model.isEnabled ? .ok : .neutral)
            Toggle("Process gestures", isOn: $model.isEnabled)
            Text("Cooldown \(model.configuration.general.cooldown, format: .number.precision(.fractionLength(2)))s · Sensitivity \(Int(model.configuration.recognition.sensitivity * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var inputCard: some View {
        DashboardCard(title: "Trackpad Input", systemImage: "rectangle.and.hand.point.up.left") {
            StatusBadge(text: model.inputState.summary, style: inputStyle)
            if let detail = model.inputState.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if let last = model.lastHardwareFrame {
                Text("Last trackpad activity \(last, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Backend: private MultitouchSupport framework (unsupported by Apple; may break in macOS updates).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.inputState.isRunning, model.isEnabled {
                Button("Retry") { model.restartInput() }
            }
        }
    }

    private var inputStyle: StatusStyle {
        switch model.inputState {
        case .running: .ok
        case .stopped: .neutral
        case .noDevices: .warning
        case .unavailable, .failed: .error
        }
    }

    private var permissionCard: some View {
        DashboardCard(title: "Permissions", systemImage: "lock.shield") {
            if model.permissions.allGranted {
                StatusBadge(text: "Accessibility granted", style: .ok)
            } else {
                StatusBadge(text: "Accessibility not granted", style: model.actionsNeedingPermission.isEmpty ? .neutral : .warning)
                Text("\(model.actionsNeedingPermission.count) enabled gesture(s) need it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Fix…") { model.selectedSection = .permissions }
            }
        }
    }

    private var profileCard: some View {
        DashboardCard(title: "Profile", systemImage: "person.crop.rectangle.stack") {
            Picker("Active profile", selection: $model.activeProfileID) {
                ForEach(model.configuration.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .labelsHidden()
            let enabled = model.activeProfile.mappings.filter(\.isEnabled).count
            Text("\(enabled) of \(model.activeProfile.mappings.count) gestures enabled")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Edit Gestures…") { model.selectedSection = .gestures }
        }
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(4)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}
