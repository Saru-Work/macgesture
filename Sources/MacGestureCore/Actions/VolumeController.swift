import AudioToolbox
import CoreAudio
import Foundation

/// Reads and writes the system output volume. Implementations must only
/// touch the default *output* device, never input (microphone) levels or
/// per-app volumes.
public protocol VolumeBackend: Sendable {
    func volume() throws(ActionError) -> Double
    /// Sets the level (clamped to 0...1) and returns the level applied.
    @discardableResult
    func setVolume(_ level: Double) throws(ActionError) -> Double
    func isMuted() throws(ActionError) -> Bool
    func setMuted(_ muted: Bool) throws(ActionError)
}

/// Applies volume commands through a backend.
public struct VolumeController: Sendable {
    public struct Change: Sendable, Equatable {
        public var level: Double
        public var isMuted: Bool

        public var message: String {
            isMuted ? "Muted" : "Volume \(Int((level * 100).rounded()))%"
        }
    }

    public let backend: any VolumeBackend

    public init(backend: any VolumeBackend = CoreAudioVolume()) {
        self.backend = backend
    }

    /// - Parameter magnitude: how many steps to apply at once (continuous
    ///   gestures combine several steps into one update).
    @discardableResult
    public func perform(_ command: VolumeCommand, magnitude: Int = 1) throws(ActionError) -> Change {
        let steps = Double(max(magnitude, 1))
        switch command {
        case .up(let step):
            if try backend.isMuted() { try backend.setMuted(false) }
            return Change(level: try backend.setVolume(try backend.volume() + step * steps), isMuted: false)
        case .down(let step):
            return Change(level: try backend.setVolume(try backend.volume() - step * steps), isMuted: try backend.isMuted())
        case .set(let level):
            return Change(level: try backend.setVolume(level), isMuted: try backend.isMuted())
        case .toggleMute:
            let muted = try !backend.isMuted()
            try backend.setMuted(muted)
            return Change(level: try backend.volume(), isMuted: muted)
        }
    }

    public func current() throws(ActionError) -> Change {
        Change(level: try backend.volume(), isMuted: try backend.isMuted())
    }
}

/// The default output device's volume through Core Audio. Needs no
/// permission. Devices with fixed volume (many HDMI/DisplayPort outputs)
/// report `.unsupported` instead of silently doing nothing.
public struct CoreAudioVolume: VolumeBackend {
    public init() {}

    public func volume() throws(ActionError) -> Double {
        let device = try Self.defaultOutputDevice()
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address) else {
            throw .unsupported("The current output device doesn't support software volume control.")
        }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw .executionFailed("Couldn't read the volume (Core Audio error \(status)).")
        }
        return Double(value)
    }

    @discardableResult
    public func setVolume(_ level: Double) throws(ActionError) -> Double {
        let device = try Self.defaultOutputDevice()
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            throw .unsupported("The current output device's volume can't be changed by software.")
        }
        var value = Float32(min(max(level, 0), 1))
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        guard status == noErr else {
            throw .executionFailed("Couldn't set the volume (Core Audio error \(status)).")
        }
        return Double(value)
    }

    public func isMuted() throws(ActionError) -> Bool {
        let device = try Self.defaultOutputDevice()
        var address = Self.address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    public func setMuted(_ muted: Bool) throws(ActionError) {
        let device = try Self.defaultOutputDevice()
        var address = Self.address(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            throw .unsupported("The current output device can't be muted by software.")
        }
        var value = UInt32(muted ? 1 : 0)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else {
            throw .executionFailed("Couldn't change mute (Core Audio error \(status)).")
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Looked up on every call, so switching outputs (e.g. to AirPods) is followed.
    private static func defaultOutputDevice() throws(ActionError) -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw .unsupported("No default audio output device.")
        }
        return device
    }
}
