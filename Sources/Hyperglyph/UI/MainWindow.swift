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

/// The app's primary window. Deliberately avoids `NavigationSplitView`,
/// `NavigationStack`, and `.toolbar` — all three render broken chrome (blank
/// sidebar, detached toolbar items, dead scrolling) inside this LSUIElement
/// menu-bar app. Everything here is plain, hand-laid-out SwiftUI: an HStack
/// of [sidebar column | divider | header + content].
struct MainWindow: View {
    var coordinator: AppCoordinator

    @State private var selection: MainWindowSection = .shapes

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            contentColumn
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            coordinator.state.accessibilityGranted = ActionRunner.isAccessibilityTrusted
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            sidebarGroup("Gestures", [.shapes, .tapZones])
            sidebarGroup("Monitor", [.liveView])
            sidebarGroup(nil, [.settings])
            Spacer()
        }
        .padding(10)
        .padding(.top, 4)
        .frame(width: 200)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private func sidebarGroup(_ title: String?, _ sections: [MainWindowSection]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
            }
            ForEach(sections) { section in
                SidebarRowButton(section: section, isSelected: selection == section) {
                    selection = section
                }
            }
        }
    }

    // MARK: Content column

    private var contentColumn: some View {
        VStack(spacing: 0) {
            header
            if !coordinator.state.accessibilityGranted {
                AccessibilityBanner(coordinator: coordinator)
            }
            Group {
                switch selection {
                case .shapes:
                    ShapeGesturesView(coordinator: coordinator)
                case .tapZones:
                    TapZonesView(coordinator: coordinator)
                case .liveView:
                    LiveView(coordinator: coordinator)
                case .settings:
                    SettingsView(coordinator: coordinator)
                }
            }
            // Keep rows readable in maximized windows instead of stretching
            // controls to the screen edge. Live View manages its own width.
            .frame(maxWidth: selection == .liveView ? .infinity : 1000)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Hand-rolled header: page title on the left, master switch on the right.
    private var header: some View {
        HStack(spacing: 12) {
            Text(selection.title)
                .font(.title2.weight(.semibold))
            Spacer()
            Toggle("Hyperglyph", isOn: masterEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(
                    coordinator.state.isEnabled
                        ? "Hyperglyph is on. Turn off to pause all gestures."
                        : "Hyperglyph is off. Turn on to resume gestures."
                )
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
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

// MARK: - Sidebar row

/// A native-looking sidebar row drawn with plain SwiftUI primitives:
/// accent-tinted rounded highlight when selected, subtle fill on hover.
private struct SidebarRowButton: View {
    let section: MainWindowSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.systemImage)
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
                Text(section.title)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Spacer(minLength: 0)
            }
            .font(.body)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(Color.accentColor)
                            : isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
