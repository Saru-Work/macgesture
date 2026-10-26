import MacGestureCore
import SwiftUI

/// The "Anchor Finger + Vertical Swipe" section in Settings.
struct AnchorGestureSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Toggle("Enable", isOn: $model.anchorGestureEnabled)
            HStack(alignment: .top, spacing: 16) {
                AnchorTutorial()
                    .frame(width: 200, height: 130)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hold one finger still, then slide a second finger up or down. Up raises the volume, down lowers it. Lift either finger to stop.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Rest the anchor for a moment before the second finger lands. Two fingers landing together are treated as a normal scroll and ignored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LabeledContent("Volume sensitivity") {
                HStack {
                    Text("Less").font(.caption)
                    Slider(value: sensitivity, in: 0...1)
                        .frame(maxWidth: 200)
                        .accessibilityValue("\(percentPerCentimetre) percent per centimetre")
                    Text("More").font(.caption)
                }
            }
            Text("About \(percentPerCentimetre)% volume per centimetre of movement.")
                .font(.caption)
                .foregroundStyle(.secondary)
            slider("Minimum movement", \.anchorDeadZone, 1...10, "mm", help: "How far the second finger moves before the volume starts to change.")
            slider("Anchor movement tolerance", \.anchorMovementTolerance, 2...10, "mm", help: "How far the anchor may drift before the gesture stops.")
            slider("Anchor hold time", \.anchorMinimumHold, 0.1...0.6, "s", help: "How long the anchor rests alone before a second finger counts.")

            Picker("Haptic feedback", selection: $model.configuration.general.volumeHapticMode) {
                ForEach(VolumeHapticMode.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Hold scrolling and the pointer still while adjusting", isOn: $model.configuration.general.suppressScrollDuringAnchorGesture)
            scrollStatus

            AnchorLiveIndicator(model: model)
        } header: {
            Text("Anchor Finger + Vertical Swipe")
        } footer: {
            Text("Remap it under Gestures (“Anchor finger + swipe up/down”). Changes the system output volume only, not microphone or per-app levels.")
        }
        .onAppear { model.beginDiagnostics() }
        .onDisappear { model.endDiagnostics() }
    }

    /// Maps 0...1 onto a step distance of 3.0...0.6 mm.
    private var sensitivity: Binding<Double> {
        Binding {
            (3.0 - model.configuration.recognition.anchorStepDistance) / 2.4
        } set: { value in
            model.configuration.recognition.anchorStepDistance = 3.0 - 2.4 * value
        }
    }

    private var percentPerCentimetre: Int {
        let step: Double
        if case .volume(.up(let size)) = model.anchorMappings.first(where: { $0.trigger.direction == .up })?.action {
            step = size
        } else {
            step = DefaultConfiguration.anchorVolumeStep
        }
        return Int((step * 10 / model.configuration.recognition.anchorStepDistance * 100).rounded())
    }

    @ViewBuilder
    private var scrollStatus: some View {
        if model.configuration.general.suppressScrollDuringAnchorGesture {
            switch model.inputSuppressionStatus {
            case .running:
                EmptyView()
            case .stopped:
                if !model.permissions.accessibility {
                    Label("Needs Accessibility permission. Without it, the page may scroll or the pointer may move while you adjust the volume.", systemImage: StatusStyle.warning.symbolName)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            case .failed(let reason):
                Label(reason, systemImage: StatusStyle.error.symbolName)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } else {
            Text("macOS may treat the moving finger as a scroll or as pointer movement, so the page may scroll or the pointer may move while you adjust.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<RecognitionSettings, Double>, _ range: ClosedRange<Double>, _ unit: String, help: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(
                    get: { model.configuration.recognition[keyPath: keyPath] },
                    set: { model.configuration.recognition[keyPath: keyPath] = $0 }
                ), in: range)
                .frame(maxWidth: 200)
                Text(String(format: unit == "s" ? "%.2f s" : "%.1f mm", model.configuration.recognition[keyPath: keyPath]))
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
            }
        }
        .help(help)
    }
}

/// Shows whether the anchor and second finger are currently detected.
struct AnchorLiveIndicator: View {
    let model: AppModel

    var body: some View {
        let diagnostics = model.diagnostics
        let state = diagnostics?.anchor ?? .idle
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Live check").fontWeight(.medium)
                Spacer()
                if let diagnostics, !diagnostics.touches.isEmpty {
                    SourceBadge(source: diagnostics.source)
                }
            }
            HStack(spacing: 16) {
                indicator("Anchor", detected: state.anchorID != nil, detail: state.anchorID.map { "finger \($0)" })
                indicator("Second finger", detected: state.movingFingerID != nil, detail: state.movingFingerID.map { "finger \($0)" })
            }
            Text(state.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Simulate Up") {
                    model.simulate(SyntheticGestureGenerator().anchorSwipe(distance: 25))
                }
                Button("Simulate Down") {
                    model.simulate(SyntheticGestureGenerator().anchorSwipe(distance: -25))
                }
                Text("Simulated input is labelled SIMULATED and only changes the volume if “Run mapped actions for simulated gestures” is on in Live Test.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func indicator(_ title: String, detected: Bool, detail: String?) -> some View {
        Label {
            Text(detected ? "\(title): \(detail ?? "detected")" : "\(title): not detected")
        } icon: {
            Image(systemName: detected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(detected ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An animated diagram: the anchor stays put while the second finger slides.
struct AnchorTutorial: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            let offset = sin(phase * 1.6)
            Canvas { context, size in
                let pad = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
                context.fill(Path(roundedRect: pad, cornerRadius: 12), with: .color(.secondary.opacity(0.12)))
                context.stroke(Path(roundedRect: pad, cornerRadius: 12), with: .color(.secondary.opacity(0.4)))

                let anchor = CGPoint(x: pad.minX + pad.width * 0.3, y: pad.midY)
                let pulse = 14 + 4 * (0.5 + 0.5 * sin(phase * 4))
                context.stroke(Path(ellipseIn: CGRect(x: anchor.x - pulse, y: anchor.y - pulse, width: pulse * 2, height: pulse * 2)), with: .color(.orange.opacity(0.6)), lineWidth: 2)
                context.fill(Path(ellipseIn: CGRect(x: anchor.x - 10, y: anchor.y - 10, width: 20, height: 20)), with: .color(.orange))
                context.draw(Text("hold").font(.caption2), at: CGPoint(x: anchor.x, y: anchor.y + 26))

                let travel = pad.height * 0.3
                let finger = CGPoint(x: pad.minX + pad.width * 0.68, y: pad.midY - offset * travel)
                var track = Path()
                track.move(to: CGPoint(x: finger.x, y: pad.midY - travel))
                track.addLine(to: CGPoint(x: finger.x, y: pad.midY + travel))
                context.stroke(track, with: .color(.accentColor.opacity(0.35)), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                context.fill(Path(ellipseIn: CGRect(x: finger.x - 10, y: finger.y - 10, width: 20, height: 20)), with: .color(.accentColor))
                context.draw(Image(systemName: offset > 0 ? "speaker.plus.fill" : "speaker.minus.fill"), at: CGPoint(x: pad.maxX - 18, y: pad.minY + 18))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Animation: one finger holds still while a second finger slides up and down")
    }
}
