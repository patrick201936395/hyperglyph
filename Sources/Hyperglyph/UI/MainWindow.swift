import SwiftUI
import HyperglyphKit

// MARK: - Sidebar sections

/// The top-level pages of the main window, listed in the sidebar.
enum MainWindowSection: String, CaseIterable, Identifiable, Hashable {
    case shapes
    case tapZones
    case liveView
    case settings

    var id: String { rawValue }

    /// Sidebar / navigation title for the section.
    var title: String {
        switch self {
        case .shapes: return "Shapes"
        case .tapZones: return "Tap Zones"
        case .liveView: return "Live View"
        case .settings: return "Settings"
        }
    }

    /// SF Symbol shown next to the sidebar label.
    var systemImage: String {
        switch self {
        case .shapes: return "scribble.variable"
        case .tapZones: return "rectangle.split.2x2"
        case .liveView: return "dot.radiowaves.left.and.right"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Main window

/// The app's primary window: a `NavigationSplitView` with a sidebar of pages
/// (Shapes, Tap Zones, Live View, Settings), a master enable switch in the
/// toolbar, and a permission banner when Accessibility access is missing.
struct MainWindow: View {
    var coordinator: AppCoordinator

    @State private var selection: MainWindowSection? = .shapes
    /// Explicitly pinned so window restoration (e.g. after a force-quit) can
    /// never bring the window back with the sidebar collapsed.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .onAppear {
            columnVisibility = .all
            coordinator.state.accessibilityGranted = ActionRunner.isAccessibilityTrusted
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Gestures") {
                sidebarRow(.shapes)
                sidebarRow(.tapZones)
            }
            Section("Monitor") {
                sidebarRow(.liveView)
            }
            Section {
                sidebarRow(.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    }

    private func sidebarRow(_ section: MainWindowSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
    }

    // MARK: Detail

    private var detail: some View {
        NavigationStack {
            // The banner participates in layout (VStack), never overlaying content.
            VStack(spacing: 0) {
                if !coordinator.state.accessibilityGranted {
                    AccessibilityBanner(coordinator: coordinator)
                }
                switch selection ?? .shapes {
                case .shapes:
                    ShapeGesturesView(coordinator: coordinator)
                        .navigationTitle("Shapes")
                case .tapZones:
                    TapZonesView(coordinator: coordinator)
                        .navigationTitle("Tap Zones")
                case .liveView:
                    LiveView(coordinator: coordinator)
                        .navigationTitle("Live View")
                case .settings:
                    SettingsView(coordinator: coordinator)
                        .navigationTitle("Settings")
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Hyperglyph", isOn: masterEnabledBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(
                            coordinator.state.isEnabled
                                ? "Hyperglyph is on. Turn off to pause all gestures."
                                : "Hyperglyph is off. Turn on to resume gestures."
                        )
                }
            }
        }
    }

    /// Master switch: reads live state, writes through the coordinator so
    /// engines are reset and the change is persisted.
    private var masterEnabledBinding: Binding<Bool> {
        Binding(
            get: { coordinator.state.isEnabled },
            set: { coordinator.setEnabled($0) }
        )
    }
}

// MARK: - Accessibility banner

/// Yellow-tinted banner shown while Accessibility permission is missing.
/// Re-checks trust every two seconds so it dismisses itself once the user
/// grants access in System Settings.
private struct AccessibilityBanner: View {
    var coordinator: AppCoordinator

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 3) {
                Text("Accessibility permission needed for keyboard shortcuts and scroll blocking")
                    .font(.callout)
                Text("Already granted but still seeing this? Rebuilds change the app's signature — in the Accessibility list, remove Hyperglyph (−), re-add it (+), and relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button("Open Settings…") {
                ActionRunner.requestAccessibility()
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.yellow.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.yellow.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .task {
            // Poll while the banner is visible; the task is cancelled when the
            // banner leaves the hierarchy (i.e. once permission is granted).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                coordinator.state.accessibilityGranted = ActionRunner.isAccessibilityTrusted
            }
        }
    }
}
