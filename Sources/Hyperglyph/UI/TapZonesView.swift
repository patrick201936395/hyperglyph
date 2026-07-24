import SwiftUI
import HyperglyphKit

/// Settings page for tap-zone bindings: an interactive trackpad diagram mirroring the
/// detector's halves + corners geometry, plus a per-zone bindings editor.
///
/// All edits flow through `coordinator.config` (an `@Observable` property whose `didSet`
/// persists automatically), and rows are addressed by `ZoneBinding.id` — never by index —
/// so bindings stay valid across inserts and deletes.
struct TapZonesView: View {
    var coordinator: AppCoordinator

    /// The zone whose bindings are shown in the editor below the diagram.
    @State private var selectedZone: TapZone = .leftHalf

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                diagram
                    .frame(maxWidth: .infinity)

                boundarySliders
                    .frame(maxWidth: .infinity)

                bindingsSection

                Text("Light taps only — physical clicks and multi-finger touches never trigger zones.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(24)
        }
    }

    // MARK: - Trackpad diagram

    private var cornerWidth: CGFloat { coordinator.config.cornerWidth }
    private var cornerHeight: CGFloat { coordinator.config.cornerHeight }

    private var diagram: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.quaternary.opacity(0.5))

            ForEach(TapZone.allCases) { zone in
                let shape = TrackpadZoneShape(zone: zone, cornerWidth: cornerWidth, cornerHeight: cornerHeight)
                shape
                    .fill(zone == selectedZone ? Color.accentColor.opacity(0.22) : Color.clear)
                shape
                    .stroke(.separator, lineWidth: 1)
            }

            GeometryReader { proxy in
                ForEach(TapZone.allCases) { zone in
                    let center = TrackpadZoneShape.labelCenter(
                        for: zone, cornerWidth: cornerWidth, cornerHeight: cornerHeight
                    )
                    zoneLabel(zone)
                        .position(x: center.x * proxy.size.width, y: center.y * proxy.size.height)
                }
            }
            .allowsHitTesting(false)

            // Tap targets on top so labels never swallow clicks.
            ForEach(TapZone.allCases) { zone in
                let shape = TrackpadZoneShape(zone: zone, cornerWidth: cornerWidth, cornerHeight: cornerHeight)
                shape
                    .fill(Color.clear)
                    .contentShape(shape)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedZone = zone
                        }
                    }
                    .accessibilityLabel(zone.displayName)
                    .accessibilityAddTraits(zone == selectedZone ? [.isSelected] : [])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        )
        .aspectRatio(1.6, contentMode: .fit)
        .frame(maxWidth: 460)
    }

    /// Live boundary controls — the diagram and the detector share these values.
    private var boundarySliders: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Corner Width")
                Slider(value: boundaryBinding(\.cornerWidth), in: 0.15...0.50)
                    .frame(maxWidth: 260)
                Text("\(Int((coordinator.config.cornerWidth * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            HStack {
                Text("Corner Height")
                Slider(value: boundaryBinding(\.cornerHeight), in: 0.20...0.50)
                    .frame(maxWidth: 260)
                Text("\(Int((coordinator.config.cornerHeight * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Text("Drag to move the zone boundaries — the diagram above shows exactly what the trackpad will use.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460)
    }

    private func boundaryBinding(_ keyPath: WritableKeyPath<AppConfig, Double>) -> Binding<Double> {
        Binding(
            get: { coordinator.config[keyPath: keyPath] },
            set: { coordinator.config[keyPath: keyPath] = $0 }
        )
    }

    private func zoneLabel(_ zone: TapZone) -> some View {
        VStack(spacing: 3) {
            Text(Self.shortLabel(for: zone))
                .font(.caption2)
                .foregroundStyle(zone == selectedZone ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
                .opacity(zoneHasBinding(zone) ? 1 : 0)
        }
    }

    private static func shortLabel(for zone: TapZone) -> String {
        switch zone {
        case .topLeftCorner: return "TL"
        case .topRightCorner: return "TR"
        case .bottomLeftCorner: return "BL"
        case .bottomRightCorner: return "BR"
        case .leftHalf: return "Left"
        case .rightHalf: return "Right"
        }
    }

    /// True when the zone has at least one enabled binding with an action assigned.
    private func zoneHasBinding(_ zone: TapZone) -> Bool {
        coordinator.config.zoneBindings.contains {
            $0.zone == zone && $0.isEnabled && $0.action != nil
        }
    }

    // MARK: - Bindings editor

    private var selectedBindings: [ZoneBinding] {
        coordinator.config.zoneBindings.filter { $0.zone == selectedZone }
    }

    private var bindingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bindings for \(selectedZone.displayName)")
                .font(.headline)

            VStack(spacing: 0) {
                let bindings = selectedBindings
                if bindings.isEmpty {
                    Text("No bindings yet. Add one to make taps in this zone do something.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ForEach(bindings) { binding in
                        bindingRow(binding)
                        if binding.id != bindings.last?.id {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.separator, lineWidth: 1)
            )

            Button {
                addBinding()
            } label: {
                Label("Add Binding", systemImage: "plus")
            }
        }
    }

    private func bindingRow(_ binding: ZoneBinding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("Tap count", selection: tapCountBinding(id: binding.id)) {
                    Text("1 tap").tag(1)
                    Text("2 taps").tag(2)
                    Text("3 taps").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                ActionPickerButton(action: actionBinding(id: binding.id))

                Spacer(minLength: 8)

                Toggle("Enabled", isOn: enabledBinding(id: binding.id))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)

                Button {
                    deleteBinding(id: binding.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Delete binding")
                .accessibilityLabel("Delete binding")
            }

            if isDuplicate(binding) {
                Label(
                    "Another binding already uses \(tapCountPhrase(binding.tapCount)) here",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// A binding duplicates an earlier one when a prior array entry shares its (zone, tapCount).
    /// The earlier entry wins at runtime (the coordinator fires the first match), so only the
    /// shadowed row gets the warning.
    private func isDuplicate(_ binding: ZoneBinding) -> Bool {
        guard let index = coordinator.config.zoneBindings.firstIndex(where: { $0.id == binding.id }) else {
            return false
        }
        return coordinator.config.zoneBindings[..<index].contains {
            $0.zone == binding.zone && $0.tapCount == binding.tapCount
        }
    }

    private func tapCountPhrase(_ count: Int) -> String {
        count == 1 ? "1 tap" : "\(count) taps"
    }

    // MARK: - Mutations

    private func addBinding() {
        let used = Set(selectedBindings.map(\.tapCount))
        let tapCount = (1...3).first { !used.contains($0) } ?? 1
        coordinator.config.zoneBindings.append(
            ZoneBinding(zone: selectedZone, tapCount: tapCount, action: nil)
        )
    }

    private func deleteBinding(id: UUID) {
        coordinator.config.zoneBindings.removeAll { $0.id == id }
    }

    // MARK: - Bindings by id (never stale indices)

    private func tapCountBinding(id: UUID) -> Binding<Int> {
        Binding(
            get: {
                coordinator.config.zoneBindings.first { $0.id == id }?.tapCount ?? 1
            },
            set: { newValue in
                guard let index = coordinator.config.zoneBindings.firstIndex(where: { $0.id == id }) else { return }
                coordinator.config.zoneBindings[index].tapCount = newValue
            }
        )
    }

    private func actionBinding(id: UUID) -> Binding<GestureAction?> {
        Binding(
            get: {
                coordinator.config.zoneBindings.first { $0.id == id }?.action
            },
            set: { newValue in
                guard let index = coordinator.config.zoneBindings.firstIndex(where: { $0.id == id }) else { return }
                coordinator.config.zoneBindings[index].action = newValue
            }
        )
    }

    private func enabledBinding(id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                coordinator.config.zoneBindings.first { $0.id == id }?.isEnabled ?? false
            },
            set: { newValue in
                guard let index = coordinator.config.zoneBindings.firstIndex(where: { $0.id == id }) else { return }
                coordinator.config.zoneBindings[index].isEnabled = newValue
            }
        )
    }
}

// MARK: - Zone geometry

/// Draws one tap zone as a polygon inside a unit-normalized trackpad rect.
///
/// Mirrors the detector's y-up geometry exactly for the configured corner size —
/// corners are `x < cornerWidth` / `x > 1-cornerWidth` crossed with the top/bottom
/// `cornerHeight` bands — translated to SwiftUI's y-down space, so `topLeftCorner`
/// renders visually top-left. The two halves are the leftover T-shaped strips,
/// split at `x = 0.5`.
nonisolated struct TrackpadZoneShape: Shape {
    let zone: TapZone
    var cornerWidth: CGFloat = 0.30
    var cornerHeight: CGFloat = 0.40

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = normalizedPolygon(for: zone)
        guard let first = points.first else { return path }
        path.move(to: Self.scaled(first, in: rect))
        for point in points.dropFirst() {
            path.addLine(to: Self.scaled(point, in: rect))
        }
        path.closeSubpath()
        return path
    }

    private static func scaled(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + point.x * rect.width,
            y: rect.minY + point.y * rect.height
        )
    }

    /// Polygon vertices in normalized SwiftUI coordinates (y-down; visual top is y = 0).
    private func normalizedPolygon(for zone: TapZone) -> [CGPoint] {
        let cw = cornerWidth
        let ch = cornerHeight
        switch zone {
        case .topLeftCorner:
            return [
                CGPoint(x: 0, y: 0), CGPoint(x: cw, y: 0),
                CGPoint(x: cw, y: ch), CGPoint(x: 0, y: ch),
            ]
        case .topRightCorner:
            return [
                CGPoint(x: 1 - cw, y: 0), CGPoint(x: 1, y: 0),
                CGPoint(x: 1, y: ch), CGPoint(x: 1 - cw, y: ch),
            ]
        case .bottomLeftCorner:
            return [
                CGPoint(x: 0, y: 1 - ch), CGPoint(x: cw, y: 1 - ch),
                CGPoint(x: cw, y: 1), CGPoint(x: 0, y: 1),
            ]
        case .bottomRightCorner:
            return [
                CGPoint(x: 1 - cw, y: 1 - ch), CGPoint(x: 1, y: 1 - ch),
                CGPoint(x: 1, y: 1), CGPoint(x: 1 - cw, y: 1),
            ]
        case .leftHalf:
            // T-shape rotated left: the middle band on the far left plus the
            // full-height strip between the left corners and the centerline.
            return [
                CGPoint(x: cw, y: 0), CGPoint(x: 0.5, y: 0),
                CGPoint(x: 0.5, y: 1), CGPoint(x: cw, y: 1),
                CGPoint(x: cw, y: 1 - ch), CGPoint(x: 0, y: 1 - ch),
                CGPoint(x: 0, y: ch), CGPoint(x: cw, y: ch),
            ]
        case .rightHalf:
            return [
                CGPoint(x: 0.5, y: 0), CGPoint(x: 1 - cw, y: 0),
                CGPoint(x: 1 - cw, y: ch), CGPoint(x: 1, y: ch),
                CGPoint(x: 1, y: 1 - ch), CGPoint(x: 1 - cw, y: 1 - ch),
                CGPoint(x: 1 - cw, y: 1), CGPoint(x: 0.5, y: 1),
            ]
        }
    }

    /// Normalized (y-down) anchor for the zone's label at the given corner geometry.
    static func labelCenter(for zone: TapZone, cornerWidth: CGFloat, cornerHeight: CGFloat) -> CGPoint {
        switch zone {
        case .topLeftCorner: return CGPoint(x: cornerWidth / 2, y: cornerHeight / 2)
        case .topRightCorner: return CGPoint(x: 1 - cornerWidth / 2, y: cornerHeight / 2)
        case .bottomLeftCorner: return CGPoint(x: cornerWidth / 2, y: 1 - cornerHeight / 2)
        case .bottomRightCorner: return CGPoint(x: 1 - cornerWidth / 2, y: 1 - cornerHeight / 2)
        case .leftHalf: return CGPoint(x: (cornerWidth + 0.5) / 2, y: 0.50)
        case .rightHalf: return CGPoint(x: (1.5 - cornerWidth) / 2, y: 0.50)
        }
    }
}
