import Foundation
import IOKit

/// Watches IOKit for multitouch devices appearing or disappearing (for
/// example a Magic Trackpad connecting) so the input backend can restart.
public final class MultitouchDeviceMonitor: @unchecked Sendable {
    // All mutable state is confined to `queue`.
    private let queue = DispatchQueue(label: "MacGesture.device-monitor")
    private let onChange: @Sendable () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        // Synchronize with the queue so no callback can observe a freed monitor.
        queue.sync { tearDown() }
    }

    public func start() {
        queue.sync {
            guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
            self.port = port
            IONotificationPortSetDispatchQueue(port, queue)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                let result = IOServiceAddMatchingNotification(
                    port, type, IOServiceMatching("AppleMultitouchDevice"),
                    deviceMonitorCallback, refcon, &iterator
                )
                guard result == KERN_SUCCESS else { continue }
                // Draining arms the notification; existing devices are not changes.
                Self.drain(iterator)
                iterators.append(iterator)
            }
        }
    }

    public func stop() {
        queue.sync { tearDown() }
    }

    private func tearDown() {
        for iterator in iterators {
            IOObjectRelease(iterator)
        }
        iterators.removeAll()
        if let port {
            IONotificationPortDestroy(port)
        }
        port = nil
    }

    fileprivate func handle(_ iterator: io_iterator_t) {
        if Self.drain(iterator) > 0 {
            onChange()
        }
    }

    @discardableResult
    private static func drain(_ iterator: io_iterator_t) -> Int {
        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            count += 1
        }
        return count
    }
}

private func deviceMonitorCallback(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refcon else { return }
    Unmanaged<MultitouchDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(iterator)
}
