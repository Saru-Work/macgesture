import AppKit
import MacGestureCore
import SwiftUI

@main
struct MacGestureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: appDelegate.model)
        } label: {
            Image(systemName: appDelegate.model.isEnabled ? "hand.point.up.left.fill" : "hand.raised.slash")
                .accessibilityLabel(appDelegate.model.isEnabled ? "MacGesture, active" : "MacGesture, paused")
        }
        .menuBarExtraStyle(.menu)

        Window("MacGesture", id: WindowID.main) {
            MainWindow(model: appDelegate.model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 980, height: 680)
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentMinSize)

        Window("Welcome to MacGesture", id: WindowID.onboarding) {
            OnboardingView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(appDelegate.model.configuration.general.hasCompletedOnboarding ? .suppressed : .presented)
    }
}

enum WindowID {
    static let main = "main"
    static let onboarding = "onboarding"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Opens a window and brings this menu-bar-only app forward.
@MainActor
func bringForward(_ openWindow: OpenWindowAction, id: String) {
    openWindow(id: id)
    NSApp.activate()
}
