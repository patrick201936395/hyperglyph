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
/// dimmed when the master switch is off.
struct MenuBarLabel: View {
    var state: AppState

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
}
