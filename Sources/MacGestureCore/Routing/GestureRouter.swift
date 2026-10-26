import Foundation

public enum RouteDecision: Sendable, Hashable {
    case execute(GestureMapping)
    case noMapping
    case coolingDown(remaining: TimeInterval)
    case disabled
    /// Recognized during diagnostics or capture; deliberately not routed.
    case suppressed(reason: String)

    public var summary: String {
        switch self {
        case .execute(let mapping): mapping.action.summary
        case .noMapping: "No mapping"
        case .coolingDown(let remaining): String(format: "Cooling down (%.2fs)", remaining)
        case .disabled: "Gestures paused"
        case .suppressed(let reason): reason
        }
    }
}

/// Matches recognized gestures to the active profile's mappings and applies
/// cooldowns so one physical motion can't trigger a burst of actions.
public struct GestureRouter: Sendable {
    public private(set) var profile: GestureProfile
    public var cooldown: TimeInterval

    private var table: [GestureTrigger: GestureMapping] = [:]
    private var lastExecution: TimeInterval?
    private var lastExecutionByMapping: [UUID: TimeInterval] = [:]

    public init(profile: GestureProfile, cooldown: TimeInterval) {
        self.profile = profile
        self.cooldown = cooldown
        rebuildTable()
    }

    public mutating func update(profile: GestureProfile, cooldown: TimeInterval) {
        self.profile = profile
        self.cooldown = cooldown
        rebuildTable()
    }

    /// The mapping that would run for a trigger: the first enabled one, in
    /// list order, when duplicates exist.
    public func mapping(for trigger: GestureTrigger) -> GestureMapping? {
        table[trigger]
    }

    public mutating func route(_ event: GestureEvent, now: TimeInterval, isEnabled: Bool = true) -> RouteDecision {
        guard isEnabled else { return .disabled }
        guard let mapping = table[event.trigger] else { return .noMapping }

        if event.trigger.kind.isContinuous {
            // Updates of one continuous gesture are already rate-limited by its
            // recognizer and must not be cut off by cooldowns. They still start
            // the global cooldown, so a discrete gesture can't fire right after.
            lastExecution = now
            return .execute(mapping)
        }

        var remaining = 0.0
        if let lastExecution {
            remaining = max(remaining, cooldown - (now - lastExecution))
        }
        if let mappingCooldown = mapping.cooldown, let last = lastExecutionByMapping[mapping.id] {
            remaining = max(remaining, mappingCooldown - (now - last))
        }
        if remaining > 0 {
            return .coolingDown(remaining: remaining)
        }

        lastExecution = now
        lastExecutionByMapping[mapping.id] = now
        return .execute(mapping)
    }

    public mutating func resetCooldowns() {
        lastExecution = nil
        lastExecutionByMapping.removeAll()
    }

    /// The gestures the recognizer should listen for, with per-mapping
    /// sensitivity converted into a threshold multiplier.
    public static func armedGestures(for profile: GestureProfile, globalSensitivity: Double) -> ArmedGestures {
        let globalScale = RecognitionSettings.thresholdScale(forSensitivity: globalSensitivity)
        var triggers: [GestureTrigger: Double] = [:]
        for mapping in profile.mappings where mapping.isEnabled && mapping.trigger.isValid && triggers[mapping.trigger] == nil {
            let scale = mapping.sensitivity.map { RecognitionSettings.thresholdScale(forSensitivity: $0) / globalScale } ?? 1
            triggers[mapping.trigger] = scale
        }
        return ArmedGestures(triggers: triggers)
    }

    private mutating func rebuildTable() {
        table.removeAll(keepingCapacity: true)
        for mapping in profile.mappings where mapping.isEnabled && table[mapping.trigger] == nil {
            table[mapping.trigger] = mapping
        }
        let liveIDs = Set(table.values.map(\.id))
        lastExecutionByMapping = lastExecutionByMapping.filter { liveIDs.contains($0.key) }
    }
}
