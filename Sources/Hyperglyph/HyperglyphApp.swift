import SwiftUI
import HyperglyphKit

@main
struct HyperglyphApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let coordinator = AppCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(coordinator: coordinator)
        } label: {
            MenuBarLabel(state: coordinator.state)
        }
        .menuBarExtraStyle(.window)

        Window("Hyperglyph", id: "main") {
            MainWindow(coordinator: coordinator)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 860, height: 600)
    }
}

/// Reactive menu bar label: trackpad glyph normally, flashes the recognized shape for ~1s,
/// dimmed when the master switch is off. Also the always-alive view that donates
/// `openWindow` to the coordinator so AppKit relaunch events can summon the window.
struct MenuBarLabel: View {
    var state: AppState

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let flash = state.menuBarFlash {
                Text(flash)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            } else {
                Image(systemName: "rectangle.and.hand.point.up.left")
            }
        }
        .opacity(state.isEnabled ? 1.0 : 0.4)
        .onAppear {
            AppCoordinator.shared.openMainWindow = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only even when run outside a bundled .app (e.g. `swift run`).
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.accessory)
        }
        AppCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppCoordinator.shared.stop()
    }

    /// Launching the already-running app (Spotlight, Raycast, Dock, `open`)
    /// summons the settings window instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppCoordinator.shared.openMainWindow?()
        return false
    }

    /// Closing the window never quits — the app keeps living in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
