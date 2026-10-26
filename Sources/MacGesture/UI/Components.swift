import MacGestureCore
import SwiftUI

enum StatusStyle {
    case ok, warning, error, neutral, info

    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        case .neutral: .secondary
        case .info: .blue
        }
    }

    var symbolName: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .neutral: "circle.dashed"
        case .info: "info.circle.fill"
        }
    }
}

extension MappingIssue.Severity {
    var style: StatusStyle {
        switch self {
        case .note: .info
        case .warning: .warning
        case .error: .error
        }
    }
}

struct StatusBadge: View {
    let text: String
    let style: StatusStyle

    var body: some View {
        Label(text, systemImage: style.symbolName)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(style.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(style.color.opacity(0.12), in: Capsule())
    }
}

/// Visually distinguishes real trackpad input from simulated input everywhere.
struct SourceBadge: View {
    let source: InputSourceKind

    var body: some View {
        Text(source == .hardware ? "TRACKPAD" : "SIMULATED")
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(source == .hardware ? Color.green : Color.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(source == .hardware ? Color.green : Color.orange, lineWidth: 1))
            .accessibilityLabel(source == .hardware ? "From trackpad" : "Simulated input")
    }
}

struct NoticeBanner: View {
    let text: String
    let style: StatusStyle
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: style.symbolName)
                .foregroundStyle(style.color)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let dismiss {
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(style.color.opacity(0.1))
    }
}

struct IssueRow: View {
    let issue: MappingIssue

    var body: some View {
        Label {
            Text(issue.message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: issue.severity.style.symbolName)
                .foregroundStyle(issue.severity.style.color)
        }
        .font(.callout)
    }
}

struct GestureGlyph: View {
    let trigger: GestureTrigger

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28, height: 28)
            Text("\(trigger.fingers)")
                .font(.caption2.weight(.bold))
                .padding(2)
                .background(.background, in: Circle())
        }
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch trigger.kind {
        case .swipe, .pinch, .rotate: trigger.direction.symbolName
        case .circle: trigger.direction == .clockwise ? "arrow.clockwise.circle" : "arrow.counterclockwise.circle"
        case .tap: "hand.tap"
        case .hold: "hand.raised"
        case .anchorSwipe: trigger.direction == .up ? "arrow.up.to.line" : "arrow.down.to.line"
        }
    }
}

extension ActivityEntry.Outcome {
    var style: StatusStyle {
        switch self {
        case .success: .ok
        case .failure: .error
        case .skipped: .neutral
        case .pending: .info
        }
    }

    var text: String {
        switch self {
        case .success(let message), .failure(let message), .skipped(let message): message
        case .pending: "Running…"
        }
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(spacing: 10) {
            GestureGlyph(trigger: entry.trigger)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.mappingName ?? entry.trigger.displayName.capitalizedFirstLetter)
                        .fontWeight(.medium)
                    SourceBadge(source: entry.source)
                }
                Text(entry.trigger.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(entry.outcome.text, systemImage: entry.outcome.style.symbolName)
                .font(.callout)
                .foregroundStyle(entry.outcome.style.color)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
            Text(entry.date, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension String {
    var capitalizedFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }
}
