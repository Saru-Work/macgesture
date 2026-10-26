import Foundation

public struct MappingIssue: Sendable, Hashable, Identifiable {
    public enum Severity: Int, Sendable, Comparable {
        case note, warning, error

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String { "\(severity)-\(mappingIDs.map(\.uuidString).joined())-\(message)" }
    public var mappingIDs: [UUID]
    public var severity: Severity
    public var message: String
}

/// Static checks over a profile, shown in the editor before anything runs.
public enum MappingConflictDetector {
    public static func issues(in profile: GestureProfile, system: SystemGestureSettings) -> [MappingIssue] {
        var issues: [MappingIssue] = []
        let enabled = profile.mappings.filter(\.isEnabled)

        var byTrigger: [GestureTrigger: [GestureMapping]] = [:]
        for mapping in enabled {
            byTrigger[mapping.trigger, default: []].append(mapping)
        }
        for (trigger, mappings) in byTrigger where mappings.count > 1 {
            issues.append(MappingIssue(
                mappingIDs: mappings.map(\.id),
                severity: .error,
                message: "\(mappings.count) enabled mappings use \(trigger.displayName). Only “\(mappings[0].displayName)” will run."
            ))
        }

        for mapping in enabled {
            if !mapping.trigger.isValid {
                issues.append(MappingIssue(mappingIDs: [mapping.id], severity: .error, message: "“\(mapping.displayName)” has an invalid gesture."))
            }
            if let problem = ActionValidator.problem(with: mapping.action) {
                issues.append(MappingIssue(mappingIDs: [mapping.id], severity: .error, message: "“\(mapping.displayName)”: \(problem)"))
            }
            if let overlap = system.overlap(with: mapping.trigger) {
                issues.append(MappingIssue(mappingIDs: [mapping.id], severity: .warning, message: "“\(mapping.displayName)”: \(overlap)"))
            }
        }

        let circleFingers = Set(enabled.filter { $0.trigger.kind == .circle }.map(\.trigger.fingers))
        let delayedSwipes = enabled.filter { $0.trigger.kind == .swipe && circleFingers.contains($0.trigger.fingers) }
        if !delayedSwipes.isEmpty {
            issues.append(MappingIssue(
                mappingIDs: delayedSwipes.map(\.id),
                severity: .note,
                message: "Circles use the same finger count as some swipes, so those swipes fire when your fingers lift instead of mid-motion."
            ))
        }

        return issues.sorted { lhs, rhs in
            lhs.severity != rhs.severity ? lhs.severity > rhs.severity : lhs.message < rhs.message
        }
    }

    /// Enabled mappings other than `mapping` that use the same trigger.
    public static func duplicates(of mapping: GestureMapping, in profile: GestureProfile) -> [GestureMapping] {
        profile.mappings.filter { $0.id != mapping.id && $0.isEnabled && $0.trigger == mapping.trigger }
    }
}
