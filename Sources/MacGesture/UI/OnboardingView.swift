import MacGestureCore
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var step = 0
    @State private var sawHardwareTouches = false

    private let stepCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: trackpad
                case 2: permissions
                default: overlaps
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)

            Divider()
            HStack {
                Text("Step \(step + 1) of \(stepCount)")
                    .foregroundStyle(.secondary)
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Button(step == stepCount - 1 ? "Done" : "Continue") {
                    if step == stepCount - 1 { finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 460)
        .onChange(of: step) { oldStep, newStep in
            // Live finger counts only while the trackpad step is showing.
            if oldStep == 1 { model.endDiagnostics() }
            if newStep == 1 { model.beginDiagnostics() }
        }
        .onChange(of: model.diagnostics?.touches.count) { _, count in
            if let count, count > 0, model.diagnostics?.source == .hardware {
                sawHardwareTouches = true
            }
        }
        .onDisappear {
            if step == 1 { model.endDiagnostics() }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Welcome to MacGesture").font(.largeTitle.bold())
            Text("Add your own trackpad gestures — taps, swipes, pinches, rotations, circles, and holds — and map them to shortcuts, window layouts, media, volume, apps, and scripts.")
            Label {
                Text("MacGesture reads the trackpad through Apple's private MultitouchSupport framework. It's not an Apple-supported API, so a macOS update could break it. MacGesture will tell you if that happens instead of failing silently.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "info.circle")
            }
        }
    }

    private var trackpad: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Check Your Trackpad").font(.title.bold())
            StatusBadge(text: model.inputState.summary, style: model.inputState.isRunning ? .ok : .error)
            if let detail = model.inputState.detail {
                Text(detail).foregroundStyle(.secondary)
            }
            Text("Rest three fingers on the trackpad.")
            HStack(spacing: 10) {
                let count = model.diagnostics?.source == .hardware ? model.diagnostics?.touches.count ?? 0 : 0
                Text("\(count)")
                    .font(.system(size: 40, weight: .bold).monospacedDigit())
                Text(count == 1 ? "finger detected" : "fingers detected")
                    .foregroundStyle(.secondary)
            }
            if sawHardwareTouches {
                Label("Real trackpad input is working.", systemImage: StatusStyle.ok.symbolName)
                    .foregroundStyle(.green)
            } else if model.inputState.isRunning {
                Text("If the count stays at zero while you touch the trackpad, the private framework isn't delivering data on this Mac. Continue to set up MacGesture anyway; the Live Test simulator still works.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow Actions").font(.title.bold())
            Text("Reading the trackpad needs no permission. To press shortcuts, send media keys, and move windows, macOS requires Accessibility access. You can skip this and grant it later; those actions will report that permission is missing.")
            ForEach(PermissionKind.allCases) { permission in
                PermissionRow(permission: permission, granted: model.permissions.isGranted(permission)) {
                    model.request(permission)
                } openSettings: {
                    model.openSettings(for: permission)
                }
            }
        }
    }

    private var overlaps: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("macOS Gestures").font(.title.bold())
            Text("MacGesture can't stop macOS from responding to its own gestures. The default gestures avoid the ones macOS uses. If you map a gesture macOS also uses (for example a three-finger swipe up), turn the macOS version off in Trackpad settings.")
            let warnings = model.mappingIssues.filter { $0.severity == .warning }
            if warnings.isEmpty {
                Label("Your current gestures don't overlap with enabled macOS gestures.", systemImage: StatusStyle.ok.symbolName)
                    .foregroundStyle(.green)
            } else {
                ForEach(warnings) { IssueRow(issue: $0) }
            }
            Button("Open Trackpad Settings…") { model.openTrackpadSettings() }
        }
    }

    private func finish() {
        model.configuration.general.hasCompletedOnboarding = true
        dismissWindow(id: WindowID.onboarding)
        model.selectedSection = .dashboard
        bringForward(openWindow, id: WindowID.main)
    }
}
