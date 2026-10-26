import MacGestureCore
import SwiftUI

struct LiveTestView: View {
    @Bindable var model: AppModel
    @State private var simulatedFingers = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("Recognize", selection: $model.liveTestMode) {
                        ForEach(LiveTestMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                    Spacer()
                    StatusBadge(text: "Trackpad: \(model.inputState.summary)", style: model.inputState.isRunning ? .ok : .warning)
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        TouchCanvas(model: model, simulatedFingers: simulatedFingers)
                            .frame(minWidth: 320, idealWidth: 420)
                        recognizerState
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 12) {
                        simulator
                        recent
                    }
                    .frame(width: 300)
                }
            }
            .padding(20)
        }
        .onAppear { model.beginDiagnostics() }
        .onDisappear { model.endDiagnostics() }
    }

    // MARK: Recognizer state

    private var recognizerState: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let diagnostics = model.diagnostics {
                    HStack {
                        Text(diagnostics.phase.displayName)
                            .font(.headline)
                        Spacer()
                        SourceBadge(source: diagnostics.source)
                    }
                    ThresholdMeter(name: "Swipe", value: diagnostics.progress.swipe)
                    ThresholdMeter(name: "Pinch", value: diagnostics.progress.pinch)
                    ThresholdMeter(name: "Rotate", value: diagnostics.progress.rotate)
                    ThresholdMeter(name: "Circle", value: diagnostics.progress.circle)
                    ThresholdMeter(name: "Hold", value: diagnostics.progress.hold)
                    Label(diagnostics.anchor.displayName, systemImage: "hand.point.up")
                        .font(.callout)
                        .foregroundStyle(diagnostics.anchor.movingFingerID != nil ? Color.accentColor : .secondary)
                        .accessibilityLabel("Anchor gesture: \(diagnostics.anchor.displayName)")
                    Divider()
                    metrics(diagnostics.metrics)
                } else {
                    Text("Waiting for input. Touch the trackpad, or use the simulator.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .padding(4)
        } label: {
            Label("Recognizer", systemImage: "gauge.with.needle")
        }
    }

    private func metrics(_ metrics: GestureMetrics) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                metric("Fingers", "\(metrics.fingers)")
                metric("Move", String(format: "%.1f, %.1f mm", metrics.translation.x, metrics.translation.y))
            }
            GridRow {
                metric("Scale", String(format: "%.2f×", metrics.scale))
                metric("Rotation", String(format: "%.0f°", metrics.rotation))
            }
            GridRow {
                metric("Path turn", String(format: "%.0f°", metrics.turn))
                metric("Straightness", String(format: "%.2f", metrics.straightness))
            }
            GridRow {
                metric("Duration", String(format: "%.2fs", metrics.duration))
                metric("Max finger move", String(format: "%.1f mm", metrics.maxFingerMovement))
            }
        }
        .font(.caption.monospacedDigit())
    }

    private func metric(_ name: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(.secondary)
            Text(value)
        }
    }

    // MARK: Simulator

    private var simulator: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Fingers", selection: $simulatedFingers) {
                    ForEach(Array(GestureKind.fingerRange), id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)

                Text("Swipe").font(.caption).foregroundStyle(.secondary)
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        swipeButton(.upLeft)
                        swipeButton(.up)
                        swipeButton(.upRight)
                    }
                    GridRow {
                        swipeButton(.left)
                        Color.clear.frame(width: 1, height: 1)
                        swipeButton(.right)
                    }
                    GridRow {
                        swipeButton(.downLeft)
                        swipeButton(.down)
                        swipeButton(.downRight)
                    }
                }

                Text("Other").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    simulateButton("Tap", "hand.tap") { $0.tap(fingers: simulatedFingers) }
                    simulateButton("Hold", "hand.raised") { $0.hold(fingers: simulatedFingers) }
                    simulateButton("Pinch In", GestureDirection.pinchIn.symbolName) { $0.pinch(fingers: simulatedFingers, scale: 0.5) }
                    simulateButton("Pinch Out", GestureDirection.pinchOut.symbolName) { $0.pinch(fingers: simulatedFingers, scale: 1.8) }
                    simulateButton("Rotate ↻", "arrow.clockwise") { $0.rotate(fingers: simulatedFingers, degrees: -60) }
                    simulateButton("Rotate ↺", "arrow.counterclockwise") { $0.rotate(fingers: simulatedFingers, degrees: 60) }
                    simulateButton("Circle ↻", "arrow.clockwise.circle") { $0.circle(fingers: simulatedFingers, clockwise: true) }
                    simulateButton("Circle ↺", "arrow.counterclockwise.circle") { $0.circle(fingers: simulatedFingers, clockwise: false) }
                    simulateButton("Anchor + Up", "arrow.up.to.line") { $0.anchorSwipe(distance: 25) }
                    simulateButton("Anchor + Down", "arrow.down.to.line") { $0.anchorSwipe(distance: -25) }
                }

                Toggle("Run mapped actions for simulated gestures", isOn: $model.runActionsForSimulatedGestures)
                    .font(.callout)
                Text("Simulated input is generated in software and always labelled SIMULATED. It does not test the trackpad. You can also drag on the trackpad diagram.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        } label: {
            Label("Simulator", systemImage: "cursorarrow.motionlines")
        }
    }

    private func swipeButton(_ direction: GestureDirection) -> some View {
        Button {
            model.simulate(SyntheticGestureGenerator().swipe(fingers: simulatedFingers, direction: direction))
        } label: {
            Image(systemName: direction.symbolName)
                .frame(width: 44, height: 22)
        }
        .accessibilityLabel("Simulate \(simulatedFingers)-finger swipe \(direction.displayName)")
    }

    private func simulateButton(_ title: String, _ symbol: String, frames: @escaping (SyntheticGestureGenerator) -> [TouchFrame]) -> some View {
        Button {
            model.simulate(frames(SyntheticGestureGenerator()))
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Simulate \(simulatedFingers)-finger \(title)")
    }

    // MARK: Recent

    private var recent: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if model.activity.isEmpty {
                    Text("Nothing recognized yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.activity.prefix(8)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.trigger.displayName).fontWeight(.medium)
                            Spacer()
                            SourceBadge(source: entry.source)
                        }
                        Label(entry.outcome.text, systemImage: entry.outcome.style.symbolName)
                            .font(.caption)
                            .foregroundStyle(entry.outcome.style.color)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Recognized", systemImage: "list.bullet")
        }
    }
}

private struct ThresholdMeter: View {
    let name: String
    let value: Double

    var body: some View {
        HStack {
            Text(name)
                .frame(width: 52, alignment: .leading)
            ProgressView(value: min(value, 1))
                .tint(value >= 1 ? .green : .accentColor)
            Text("\(Int((value * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(Int((value * 100).rounded())) percent of threshold")
    }
}

/// Draws the touches the recognizer sees. Dragging on it injects simulated
/// fingers that follow the pointer.
private struct TouchCanvas: View {
    let model: AppModel
    let simulatedFingers: Int
    @State private var dragging = false

    var body: some View {
        let device = model.diagnostics?.device ?? .simulated
        let aspect = device.surfaceSize.x / device.surfaceSize.y
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.separator)

                if let diagnostics = model.diagnostics, !diagnostics.touches.isEmpty {
                    let tint: Color = diagnostics.source == .hardware ? .accentColor : .orange
                    let centroid = diagnostics.touches.reduce(SIMD2<Double>.zero) { $0 + $1.position } / Double(diagnostics.touches.count)
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                        .position(point(centroid, in: size))
                    ForEach(diagnostics.touches, id: \.id) { touch in
                        Circle()
                            .fill((touch.id == diagnostics.anchor.anchorID ? Color.orange : tint).opacity(0.75))
                            .overlay(Circle().stroke(Color.orange, lineWidth: touch.id == diagnostics.anchor.anchorID ? 3 : 0).padding(-4))
                            .overlay(Text("\(touch.id)").font(.caption2.bold()).foregroundStyle(.white))
                            .frame(width: 30, height: 30)
                            .position(point(touch.position, in: size))
                    }
                } else {
                    Text("Touch the trackpad, or drag here to simulate \(simulatedFingers) fingers.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let diagnostics = model.diagnostics {
                    HStack {
                        SourceBadge(source: diagnostics.source)
                        Text(diagnostics.device.name).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(in: size))
        }
        .aspectRatio(aspect, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        guard let diagnostics = model.diagnostics else { return "Trackpad diagram, no touches" }
        return "Trackpad diagram, \(diagnostics.touches.count) \(diagnostics.source == .hardware ? "real" : "simulated") touches"
    }

    private func point(_ normalized: SIMD2<Double>, in size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: (1 - normalized.y) * size.height)
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragging = true
                let center = SIMD2(Double(value.location.x / size.width), Double(1 - value.location.y / size.height))
                let device = TrackpadDevice.simulated
                let generator = SyntheticGestureGenerator(device: device)
                let touches = generator.restingOffsets(fingers: simulatedFingers).enumerated().map { index, offset in
                    TouchPoint(id: index + 1, position: center + offset / device.surfaceSize)
                }
                model.injectSimulated(TouchFrame(timestamp: ProcessInfo.processInfo.systemUptime, device: device, touches: touches))
            }
            .onEnded { _ in
                dragging = false
                model.injectSimulated(TouchFrame(timestamp: ProcessInfo.processInfo.systemUptime, device: .simulated, touches: []))
            }
    }
}
