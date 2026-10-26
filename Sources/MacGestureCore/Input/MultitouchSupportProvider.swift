import CMultitouchBridge
import Foundation
import os

/// Raw touch states reported by the private MultitouchSupport framework.
public enum MultitouchContactState: Int32, Sendable {
    case notTracking = 0
    case startInRange
    case hoverInRange
    case makeTouch
    case touching
    case breakTouch
    case lingerInRange
    case outOfRange

    /// Only contacts that are actually pressing the surface take part in
    /// recognition; hovering and lifting contacts are discarded.
    public static func isInContact(_ rawState: Int32) -> Bool {
        rawState == MultitouchContactState.makeTouch.rawValue || rawState == MultitouchContactState.touching.rawValue
    }
}

/// Real trackpad input through Apple's PRIVATE MultitouchSupport.framework.
///
/// - Important: This is undocumented API. It is not App Store compatible,
///   cannot run in the App Sandbox, and may break in any macOS update. It only
///   observes touches: it cannot suppress macOS's own trackpad gestures.
public final class MultitouchSupportProvider: TrackpadInputProvider {
    public let kind = InputSourceKind.hardware
    public let displayName = "MultitouchSupport (private framework)"

    private let activeSink = OSAllocatedUnfairLock<FrameSink?>(initialState: nil)

    public init() {}

    public var isRunning: Bool {
        activeSink.withLock { $0 != nil }
    }

    public func availability() -> InputProviderAvailability {
        let status = MGBridgeLoad()
        guard status == MG_BRIDGE_OK else {
            return .unavailable(reason: InputProviderError(bridgeStatus: status).localizedDescription)
        }
        let devices = Self.attachedDevices()
        return devices.isEmpty ? .noDevices : .available(devices: devices)
    }

    public static func attachedDevices() -> [TrackpadDevice] {
        var buffer = [MGDeviceInfo](repeating: MGDeviceInfo(), count: Int(MG_BRIDGE_MAX_DEVICES))
        let count = MGBridgeCopyDevices(&buffer, Int32(buffer.count))
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).enumerated().map { index, info in
            TrackpadDevice(bridgeInfo: info, fallbackID: UInt64(index + 1))
        }
    }

    public func start(handler: @escaping @Sendable (TouchFrame) -> Void) throws {
        try activeSink.withLock { sink in
            guard sink == nil else { throw InputProviderError.alreadyRunning }
            let newSink = FrameSink(handler: handler)
            // The bridge holds an unretained pointer; `activeSink` keeps the
            // sink alive until MGBridgeStop guarantees no callback is in flight.
            let status = MGBridgeStart(bridgeFrameCallback, Unmanaged.passUnretained(newSink).toOpaque())
            guard status == MG_BRIDGE_OK else {
                throw InputProviderError(bridgeStatus: status)
            }
            sink = newSink
        }
    }

    public func stop() {
        activeSink.withLock { sink in
            guard sink != nil else { return }
            MGBridgeStop()
            sink = nil
        }
    }
}

extension InputProviderError {
    init(bridgeStatus: Int32) {
        switch bridgeStatus {
        case MG_BRIDGE_FRAMEWORK_UNAVAILABLE: self = .frameworkUnavailable
        case MG_BRIDGE_SYMBOLS_MISSING: self = .symbolsMissing
        case MG_BRIDGE_NO_DEVICES: self = .noDevices
        case MG_BRIDGE_ALREADY_RUNNING: self = .alreadyRunning
        default: self = .failed(code: bridgeStatus)
        }
    }
}

extension TrackpadDevice {
    init(bridgeInfo info: MGDeviceInfo, fallbackID: UInt64) {
        let size: SIMD2<Double> = info.surfaceWidth > 0 && info.surfaceHeight > 0
            ? SIMD2(Double(info.surfaceWidth) / 100, Double(info.surfaceHeight) / 100)
            : TrackpadDevice.fallbackSurfaceSize
        self.init(
            id: info.deviceID != 0 ? info.deviceID : fallbackID,
            name: info.isBuiltIn ? "Built-in Trackpad" : "External Trackpad",
            isBuiltIn: info.isBuiltIn,
            surfaceSize: size,
            source: .hardware
        )
    }
}

/// Converts bridge frames into `TouchFrame`s. Called on the framework's thread.
private final class FrameSink: Sendable {
    private struct State {
        var devices: [UInt64: TrackpadDevice] = [:]
        var idleDevices: Set<UInt64> = []
    }

    let handler: @Sendable (TouchFrame) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(handler: @escaping @Sendable (TouchFrame) -> Void) {
        self.handler = handler
    }

    func receive(device info: MGDeviceInfo, contacts: UnsafePointer<MGContact>?, count: Int, timestamp: Double) {
        var touches: [TouchPoint] = []
        if let contacts, count > 0 {
            touches.reserveCapacity(count)
            for index in 0..<count {
                let contact = contacts[index]
                guard MultitouchContactState.isInContact(contact.state) else { continue }
                touches.append(TouchPoint(
                    id: Int(contact.identifier),
                    position: SIMD2(Double(contact.x), Double(contact.y)),
                    velocity: SIMD2(Double(contact.velocityX), Double(contact.velocityY)),
                    size: Double(contact.size)
                ))
            }
        }

        let isEmpty = touches.isEmpty
        let device: TrackpadDevice? = state.withLock { state in
            let key = info.deviceID
            // The framework keeps sending hover/linger frames after a lift;
            // forward a single empty frame and drop the rest.
            if isEmpty {
                guard state.idleDevices.insert(key).inserted else { return nil }
            } else {
                state.idleDevices.remove(key)
            }
            if let cached = state.devices[key] { return cached }
            let device = TrackpadDevice(bridgeInfo: info, fallbackID: 1)
            state.devices[key] = device
            return device
        }
        guard let device else { return }
        handler(TouchFrame(timestamp: timestamp, device: device, touches: touches))
    }
}

private let bridgeFrameCallback: MGFrameCallback = { device, contacts, count, timestamp, context in
    guard let device, let context else { return }
    let sink = Unmanaged<FrameSink>.fromOpaque(context).takeUnretainedValue()
    sink.receive(device: device.pointee, contacts: contacts, count: Int(count), timestamp: timestamp)
}
