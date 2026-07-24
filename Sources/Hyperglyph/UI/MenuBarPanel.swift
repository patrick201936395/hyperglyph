import AppKit
import SwiftUI
import HyperglyphKit

/// Compact dropdown panel shown from the menu bar item (`MenuBarExtra(.window)`).
///
/// Layout: header (app glyph + title + master toggle), status line, recent
/// gesture events, and bottom actions (open main window / quit). Fixed at
/// 300pt wide with a native menu-panel look: hairline dividers, borderless
/// hover-highlighted rows, no heavy chrome.
struct MenuBarPanel: View {
    var coordinator: AppCoordinator

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusLine

            Divider()

            recentSection

            Divider()

            VStack(spacing: 2) {
                MenuActionRow(title: "Open Hyperglyph…", systemImage: "macwindow") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                MenuActionRow(title: "Quit", systemImage: "power") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.and.hand.point.up.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                )

            Text("Hyperglyph")
                .font(.headline)

            Spacer()

            Toggle("", isOn: enabledBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    /// Master switch binding routed through the coordinator so disabling also
    /// resets in-flight gesture state.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { coordinator.state.isEnabled },
            set: { coordinator.setEnabled($0) }
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        if coordinator.state.touchCaptureFailed {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .semibold))
                Text("Trackpad unavailable")
                    .font(.caption)
            }
            .foregroundStyle(.orange)
        } else {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        guard coordinator.state.isEnabled else { return "Paused" }
        let shapes = coordinator.config.shapeBindings
            .filter { $0.isEnabled && $0.action != nil }
            .count
        let zones = coordinator.config.zoneBindings
            .filter { $0.isEnabled && $0.action != nil }
            .count
        return "Listening · \(shapes) shapes · \(zones) zones active"
    }

    // MARK: - Recent events

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            let events = Array(coordinator.state.recentEvents.prefix(5))
            if events.isEmpty {
                Text("No gestures yet — draw a shape with two fingers")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(events) { event in
                        RecentEventRow(event: event)
                    }
                }
            }
        }
    }
}

// MARK: - Recent event row

/// One recent-gesture line: glyph badge, title, relative timestamp.
private struct RecentEventRow: View {
    let event: GestureEvent

    var body: some View {
        HStack(spacing: 8) {
            Text(event.symbol)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(event.success ? Color.primary : Color.secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.quaternary)
                )

            Text(event.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text(event.date, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Bottom action row

/// Full-width borderless button row with a native-menu hover highlight.
private struct MenuActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
