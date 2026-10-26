import Foundation

/// Where a frame came from. Simulated frames are never presented as hardware input.
public enum InputSourceKind: String, Sendable, Codable, Hashable {
    case hardware
    case simulated

    public var displayName: String {
        switch self {
        case .hardware: "Trackpad"
        case .simulated: "Simulated"
        }
    }
}

public struct TrackpadDevice: Sendable, Hashable, Identifiable {
    /// Built-in 13"–15" MacBook trackpads are roughly this size; used when the
    /// backend cannot report physical dimensions.
    public static let fallbackSurfaceSize = SIMD2<Double>(122, 74)

    public static let simulated = TrackpadDevice(
        id: .max,
        name: "Simulated Trackpad",
        isBuiltIn: false,
        surfaceSize: fallbackSurfaceSize,
        source: .simulated
    )

    public var id: UInt64
    public var name: String
    public var isBuiltIn: Bool
    /// Physical surface size in millimetres.
    public var surfaceSize: SIMD2<Double>
    public var source: InputSourceKind

    public init(id: UInt64, name: String, isBuiltIn: Bool, surfaceSize: SIMD2<Double>, source: InputSourceKind) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.surfaceSize = surfaceSize
        self.source = source
    }
}

/// One finger in contact with the surface.
public struct TouchPoint: Sendable, Hashable {
    /// Stable for as long as the finger stays on the surface.
    public var id: Int
    /// Normalized 0...1 with the origin at the bottom-left of the surface.
    public var position: SIMD2<Double>
    /// Normalized units per second, if the backend reports it.
    public var velocity: SIMD2<Double>
    /// Contact area proxy. Fingers are typically 0.3–0.8; palms are larger.
    public var size: Double

    public init(id: Int, position: SIMD2<Double>, velocity: SIMD2<Double> = .zero, size: Double = 0.5) {
        self.id = id
        self.position = position
        self.velocity = velocity
        self.size = size
    }
}

/// The set of fingers touching one device at one instant. An empty frame
/// means every finger has lifted.
public struct TouchFrame: Sendable {
    /// Seconds on a monotonic clock. Only differences are meaningful.
    public var timestamp: TimeInterval
    public var device: TrackpadDevice
    public var touches: [TouchPoint]

    public init(timestamp: TimeInterval, device: TrackpadDevice, touches: [TouchPoint]) {
        self.timestamp = timestamp
        self.device = device
        self.touches = touches
    }

    public var source: InputSourceKind { device.source }
}
