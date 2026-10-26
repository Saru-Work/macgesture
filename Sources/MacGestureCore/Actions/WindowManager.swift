import AppKit
import ApplicationServices

/// A display's frames in Cocoa coordinates (origin at the bottom-left of the
/// primary display, y up).
public struct ScreenGeometry: Sendable, Equatable {
    public var frame: CGRect
    public var visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    @MainActor
    public static func current() -> [ScreenGeometry] {
        NSScreen.screens.map { ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
}

/// Pure window geometry, separated from Accessibility calls for testing.
public enum WindowLayout {
    /// The frame (Cocoa coordinates) a command places a window in, or nil for
    /// commands that don't set a frame.
    public static func targetFrame(for command: WindowCommand, in area: CGRect, current: CGRect) -> CGRect? {
        let x = area.minX, y = area.minY, w = area.width, h = area.height
        let rect: CGRect
        switch command {
        case .maximize: rect = area
        case .center:
            let size = CGSize(width: min(current.width, w), height: min(current.height, h))
            rect = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        case .leftHalf: rect = CGRect(x: x, y: y, width: w / 2, height: h)
        case .rightHalf: rect = CGRect(x: x + w / 2, y: y, width: w / 2, height: h)
        case .topHalf: rect = CGRect(x: x, y: y + h / 2, width: w, height: h / 2)
        case .bottomHalf: rect = CGRect(x: x, y: y, width: w, height: h / 2)
        case .leftThird: rect = CGRect(x: x, y: y, width: w / 3, height: h)
        case .centerThird: rect = CGRect(x: x + w / 3, y: y, width: w / 3, height: h)
        case .rightThird: rect = CGRect(x: x + 2 * w / 3, y: y, width: w / 3, height: h)
        case .leftTwoThirds: rect = CGRect(x: x, y: y, width: 2 * w / 3, height: h)
        case .rightTwoThirds: rect = CGRect(x: x + w / 3, y: y, width: 2 * w / 3, height: h)
        case .topLeftQuarter: rect = CGRect(x: x, y: y + h / 2, width: w / 2, height: h / 2)
        case .topRightQuarter: rect = CGRect(x: x + w / 2, y: y + h / 2, width: w / 2, height: h / 2)
        case .bottomLeftQuarter: rect = CGRect(x: x, y: y, width: w / 2, height: h / 2)
        case .bottomRightQuarter: rect = CGRect(x: x + w / 2, y: y, width: w / 2, height: h / 2)
        case .minimize, .toggleFullScreen, .moveToNextDisplay: return nil
        }
        return rect.integral
    }

    /// Converts between Cocoa (y up from the primary display's bottom) and
    /// Accessibility (y down from its top) coordinates. The transform is its
    /// own inverse.
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The screen showing most of `rect` (Cocoa coordinates).
    public static func screenIndex(for rect: CGRect, in screens: [ScreenGeometry]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, screen) in screens.enumerated() {
            let overlap = screen.frame.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if best == nil || area > best!.area {
                best = (index, area)
            }
        }
        return best?.index
    }

    /// Maps a frame proportionally from one area to another.
    public static func transfer(_ rect: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        let scaleX = destination.width / source.width
        let scaleY = destination.height / source.height
        var result = CGRect(
            x: destination.minX + (rect.minX - source.minX) * scaleX,
            y: destination.minY + (rect.minY - source.minY) * scaleY,
            width: min(rect.width * scaleX, destination.width),
            height: min(rect.height * scaleY, destination.height)
        )
        result.origin.x = min(max(result.minX, destination.minX), destination.maxX - result.width)
        result.origin.y = min(max(result.minY, destination.minY), destination.maxY - result.height)
        return result.integral
    }

    public static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

/// Moves, resizes, and minimizes the focused window of an app via the
/// Accessibility API. Runs off the main thread because AX calls are
/// synchronous IPC to the target app.
public actor WindowManager {
    private var windows = WindowOperator()

    public init() {}

    public func perform(_ command: WindowCommand, targetPID: pid_t, screens: [ScreenGeometry]) throws(ActionError) -> String {
        try windows.perform(command, targetPID: targetPID, screens: screens)
    }
}

/// The Accessibility window logic, independent of where it runs.
///
/// - Important: AX requests aimed at *this* process are not sent over IPC.
///   AppKit services them in-process, synchronously on the calling thread, and
///   traps if that isn't the main thread. Use `WindowManager` for other apps
///   and a main-actor `WindowOperator` for MacGesture's own windows.
public struct WindowOperator {
    private struct RestoreEntry {
        let window: AXUIElement
        let frame: CGRect
    }

    /// Frames to return to when "Maximize" is repeated, newest last.
    private var restoreEntries: [RestoreEntry] = []

    public init() {}

    public mutating func perform(_ command: WindowCommand, targetPID: pid_t, screens: [ScreenGeometry]) throws(ActionError) -> String {
        guard AXIsProcessTrusted() else {
            throw .permissionRequired(.accessibility)
        }
        guard let primary = screens.first else {
            throw .unsupported("No displays found.")
        }
        let window = try focusedWindow(of: targetPID)

        switch command {
        case .minimize:
            try setAttribute(window, kAXMinimizedAttribute, kCFBooleanTrue, unsupported: "This window can't be minimized.")
            return "Minimized window"
        case .toggleFullScreen:
            let isFullScreen = (copyAttribute(window, "AXFullScreen") as? Bool) ?? false
            try setAttribute(window, "AXFullScreen", (!isFullScreen) as CFBoolean, unsupported: "This window doesn't support full screen.")
            return isFullScreen ? "Exited full screen" : "Entered full screen"
        default:
            break
        }

        let primaryHeight = primary.frame.height
        let currentAX = try frame(of: window)
        let current = WindowLayout.flip(currentAX, primaryHeight: primaryHeight)
        guard let screenIndex = WindowLayout.screenIndex(for: current, in: screens) else {
            throw .unsupported("Couldn't determine which display the window is on.")
        }
        let area = screens[screenIndex].visibleFrame

        let target: CGRect
        switch command {
        case .moveToNextDisplay:
            guard screens.count > 1 else {
                throw .unsupported("Only one display is connected.")
            }
            let next = screens[(screenIndex + 1) % screens.count].visibleFrame
            target = WindowLayout.transfer(current, from: area, to: next)
        case .maximize where WindowLayout.approximatelyEqual(current, area):
            guard let index = restoreEntries.lastIndex(where: { CFEqual($0.window, window) }) else {
                return "Window is already maximized"
            }
            target = restoreEntries.remove(at: index).frame
        default:
            guard let frame = WindowLayout.targetFrame(for: command, in: area, current: current) else {
                throw .unsupported("\(command.displayName) is not supported.")
            }
            target = frame
        }

        if command == .maximize, !WindowLayout.approximatelyEqual(current, area) {
            restoreEntries.removeAll { CFEqual($0.window, window) }
            restoreEntries.append(RestoreEntry(window: window, frame: current))
            if restoreEntries.count > 32 { restoreEntries.removeFirst() }
        }

        try apply(WindowLayout.flip(target, primaryHeight: primaryHeight), to: window, resize: target.size != current.size)
        let result = WindowLayout.flip(try frame(of: window), primaryHeight: primaryHeight)
        if !WindowLayout.approximatelyEqual(result, target, tolerance: 24) {
            return "\(command.displayName) (the app limited the window's size)"
        }
        return command.displayName
    }

    // MARK: - Accessibility helpers

    private func focusedWindow(of pid: pid_t) throws(ActionError) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        // Don't stall for the default 6s if the target app is hung.
        AXUIElementSetMessagingTimeout(app, 1.0)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let value = copyAttribute(app, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                return unsafeDowncast(value, to: AXUIElement.self)
            }
        }
        throw .noTargetWindow
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func setAttribute(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef, unsupported: String) throws(ActionError) {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success, settable.boolValue else {
            throw .unsupported(unsupported)
        }
        let status = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard status == .success else {
            throw .executionFailed("The window refused the change (AX error \(status.rawValue)).")
        }
    }

    private func frame(of window: AXUIElement) throws(ActionError) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = copyAttribute(window, kAXPositionAttribute),
              let sizeValue = copyAttribute(window, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else {
            throw .unsupported("This window doesn't report its position and size.")
        }
        return CGRect(origin: origin, size: size)
    }

    /// Size, then position, then size again: the first resize lets the window
    /// fit on the destination display, the second fixes any clamping.
    private func apply(_ frame: CGRect, to window: AXUIElement, resize: Bool) throws(ActionError) {
        var origin = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &origin), let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw .executionFailed("Couldn't encode the window frame.")
        }
        if resize {
            try setAttribute(window, kAXSizeAttribute, sizeValue, unsupported: "This window can't be resized.")
        }
        try setAttribute(window, kAXPositionAttribute, positionValue, unsupported: "This window can't be moved.")
        if resize {
            try setAttribute(window, kAXSizeAttribute, sizeValue, unsupported: "This window can't be resized.")
        }
    }
}
