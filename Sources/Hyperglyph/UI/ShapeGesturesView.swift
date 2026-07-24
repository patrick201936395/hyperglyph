import SwiftUI
import HyperglyphKit

/// Settings page listing every shape gesture binding (built-in letters/symbols/flicks and
/// user-recorded custom shapes), each with a live path preview, an action assignment control,
/// and an enable switch. Hosts the custom-shape recorder sheet.
struct ShapeGesturesView: View {
    var coordinator: AppCoordinator

    @State private var isRecorderPresented = false

    /// Built-in shape names that group under "Letters".
    private static let letterNames: Set<String> = ["C", "S", "Z", "V", "L", "N", "O"]
    /// Built-in shape names that group under "Symbols".
    private static let symbolNames: Set<String> = ["Check", "Cross", "Question", "Heart"]
    /// Built-in shape names that group under "Flicks" (exact names — a custom shape
    /// like "Flicker" must not land here).
    private static let flickNames: Set<String> = ["Flick Up", "Flick Down", "Flick Left", "Flick Right"]

    var body: some View {
        Group {
            if coordinator.config.shapeBindings.isEmpty {
                ContentUnavailableView(
                    "No Shape Gestures",
                    systemImage: "scribble.variable",
                    description: Text("Record a custom shape to get started.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(groupedSections, id: \.title) { section in
                            sectionView(title: section.title, bindings: section.bindings)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Shape Gestures")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isRecorderPresented = true
                } label: {
                    Label("Record Custom Shape…", systemImage: "plus.viewfinder")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .sheet(isPresented: $isRecorderPresented) {
            ShapeRecorderSheet(coordinator: coordinator)
        }
    }

    // MARK: - Sections

    private var groupedSections: [(title: String, bindings: [ShapeBinding])] {
        var letters: [ShapeBinding] = []
        var symbols: [ShapeBinding] = []
        var flicks: [ShapeBinding] = []
        var custom: [ShapeBinding] = []

        let customNames = Set(coordinator.config.customTemplates.map(\.name))

        for binding in coordinator.config.shapeBindings {
            // A user-recorded template always wins: a custom shape named e.g. "Flicker"
            // or even "Check" must file under Custom, not a built-in section.
            if customNames.contains(binding.shapeName) {
                custom.append(binding)
            } else if Self.letterNames.contains(binding.shapeName) {
                letters.append(binding)
            } else if Self.symbolNames.contains(binding.shapeName) {
                symbols.append(binding)
            } else if Self.flickNames.contains(binding.shapeName) {
                flicks.append(binding)
            } else {
                custom.append(binding)
            }
        }

        let all: [(String, [ShapeBinding])] = [
            ("Letters", letters),
            ("Symbols", symbols),
            ("Flicks", flicks),
            ("Custom", custom),
        ]
        return all.filter { !$0.1.isEmpty }.map { (title: $0.0, bindings: $0.1) }
    }

    @ViewBuilder
    private func sectionView(title: String, bindings: [ShapeBinding]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(bindings.enumerated()), id: \.element.id) { index, binding in
                    row(for: binding)
                    if index < bindings.count - 1 {
                        Divider().padding(.leading, 84)
                    }
                }
            }
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for binding: ShapeBinding) -> some View {
        let isCustom = coordinator.config.customTemplates.contains { $0.name == binding.shapeName }
        let preview = ShapeRecognizer.previewPath(
            for: binding.shapeName,
            customTemplates: coordinator.config.customTemplates
        )

        HStack(spacing: 14) {
            ShapePreview(points: preview, fallbackSymbol: symbol(for: binding.shapeName))
                .opacity(binding.isEnabled ? 1.0 : 0.4)

            VStack(alignment: .leading, spacing: 3) {
                Text(binding.shapeName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(binding.isEnabled ? .primary : .secondary)
                if let action = binding.action {
                    Label(action.displayName, systemImage: action.systemImage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No action")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            ActionPickerButton(action: actionBinding(forID: binding.id))

            Toggle("Enabled", isOn: enabledBinding(forID: binding.id))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)

            if isCustom {
                Button {
                    deleteCustomShape(named: binding.shapeName)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete this custom shape")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu {
            if isCustom {
                Button("Delete \"\(binding.shapeName)\"", systemImage: "trash", role: .destructive) {
                    deleteCustomShape(named: binding.shapeName)
                }
            }
        }
    }

    private func symbol(for shapeName: String) -> String {
        if let builtIn = ShapeRecognizer.builtInShapes.first(where: { $0.name == shapeName }) {
            return builtIn.symbol
        }
        if let template = coordinator.config.customTemplates.first(where: { $0.name == shapeName }) {
            return template.symbol
        }
        return "?"
    }

    // MARK: - Stable bindings into config (looked up by id at access time)

    private func actionBinding(forID id: UUID) -> Binding<GestureAction?> {
        Binding(
            get: {
                coordinator.config.shapeBindings.first(where: { $0.id == id })?.action
            },
            set: { newValue in
                guard let index = coordinator.config.shapeBindings.firstIndex(where: { $0.id == id })
                else { return }
                coordinator.config.shapeBindings[index].action = newValue
            }
        )
    }

    private func enabledBinding(forID id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                coordinator.config.shapeBindings.first(where: { $0.id == id })?.isEnabled ?? false
            },
            set: { newValue in
                guard let index = coordinator.config.shapeBindings.firstIndex(where: { $0.id == id })
                else { return }
                coordinator.config.shapeBindings[index].isEnabled = newValue
            }
        )
    }

    private func deleteCustomShape(named name: String) {
        coordinator.config.customTemplates.removeAll { $0.name == name }
        coordinator.config.shapeBindings.removeAll { $0.shapeName == name }
    }
}

// MARK: - Shape preview tile

/// A 56×56 rounded tile that draws a shape's template path (fitted to the tile, y flipped
/// from trackpad y-up to screen y-down), or the shape's glyph when no path is available.
private struct ShapePreview: View {
    var points: [StrokePoint]?
    var fallbackSymbol: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.6))

            if let points, points.count > 1 {
                Canvas { context, size in
                    let path = ShapeDrawing.fittedPath(points, in: size, inset: 10)
                    context.stroke(
                        path,
                        with: .color(.secondary),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
                }
            } else {
                Text(fallbackSymbol)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
    }
}

// MARK: - Path helpers

/// Shared stroke-to-`Path` conversion. All inputs are normalized trackpad points (y-up);
/// outputs are screen-space paths (y-down), so y is flipped here.
private enum ShapeDrawing {
    /// Maps normalized 0...1 points directly into `size` (trackpad-proportional), flipping y.
    static func absolutePath(_ points: [StrokePoint], in size: CGSize, inset: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        let width = max(size.width - inset * 2, 1)
        let height = max(size.height - inset * 2, 1)
        func convert(_ point: StrokePoint) -> CGPoint {
            CGPoint(x: inset + point.x * width, y: inset + (1 - point.y) * height)
        }
        path.move(to: convert(first))
        for point in points.dropFirst() {
            path.addLine(to: convert(point))
        }
        return path
    }

    /// Fits the stroke's bounding box into `size` (aspect preserved, centered), flipping y.
    /// Suits small previews where the raw trackpad position is irrelevant.
    static func fittedPath(_ points: [StrokePoint], in size: CGSize, inset: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }

        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let boxWidth = max(maxX - minX, 0.0001)
        let boxHeight = max(maxY - minY, 0.0001)
        let available = CGSize(width: max(size.width - inset * 2, 1), height: max(size.height - inset * 2, 1))
        let scale = min(available.width / boxWidth, available.height / boxHeight)
        let drawnWidth = boxWidth * scale
        let drawnHeight = boxHeight * scale
        let originX = (size.width - drawnWidth) / 2
        let originY = (size.height - drawnHeight) / 2

        func convert(_ point: StrokePoint) -> CGPoint {
            CGPoint(
                x: originX + (point.x - minX) * scale,
                y: originY + (maxY - point.y) * scale  // flip y
            )
        }
        path.move(to: convert(first))
        for point in points.dropFirst() {
            path.addLine(to: convert(point))
        }
        return path
    }
}

// MARK: - Custom shape recorder sheet

/// Sheet that teaches Hyperglyph a new shape: captures up to three drawn samples via
/// `AppState.recordingHandler`, collects a name and glyph, then saves a `CustomTemplate`
/// plus a fresh `ShapeBinding` into the config.
private struct ShapeRecorderSheet: View {
    var coordinator: AppCoordinator

    @Environment(\.dismiss) private var dismiss

    @State private var samples: [[StrokePoint]] = []
    @State private var name: String = ""
    @State private var symbol: String = ""

    private static let maxSamples = 3
    /// Overlay opacities for captured samples 1...3.
    private static let sampleOpacities: [Double] = [0.45, 0.32, 0.22]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Custom Shape")
                .font(.title2.weight(.bold))

            ghostTrackpad

            VStack(alignment: .leading, spacing: 10) {
                Text(instructionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !samples.isEmpty {
                    sampleChips
                }

                if let warning = straightSampleWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            fields

            Spacer(minLength: 0)

            HStack {
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Shape") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
        .onAppear { installRecordingHandler() }
        .onDisappear { coordinator.state.recordingHandler = nil }
        .onChange(of: name) { oldValue, newValue in
            // Keep the glyph auto-derived from the name until the user customizes it.
            if symbol.isEmpty || symbol == autoSymbol(for: oldValue) {
                symbol = autoSymbol(for: newValue)
            }
        }
        .onChange(of: symbol) { _, newValue in
            if newValue.count > 2 { symbol = String(newValue.prefix(2)) }
        }
    }

    // MARK: Ghost trackpad

    private var ghostTrackpad: some View {
        let liveStroke = coordinator.state.currentStroke
        let isArmed = coordinator.state.isDrawArmed

        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.quaternary.opacity(0.5))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    isArmed ? AnyShapeStyle(Color.accentColor.opacity(0.8)) : AnyShapeStyle(.quaternary),
                    lineWidth: isArmed ? 2 : 1
                )

            Canvas { context, size in
                let style = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                for (index, sample) in samples.enumerated() {
                    let opacity = Self.sampleOpacities[min(index, Self.sampleOpacities.count - 1)]
                    context.stroke(
                        ShapeDrawing.absolutePath(sample, in: size, inset: 14),
                        with: .color(.secondary.opacity(opacity)),
                        style: style
                    )
                }
                if liveStroke.count > 1 {
                    context.stroke(
                        ShapeDrawing.absolutePath(liveStroke, in: size, inset: 14),
                        with: .color(Color.accentColor.opacity(0.55)),
                        style: style
                    )
                }
            }

            if samples.isEmpty && liveStroke.isEmpty {
                Image(systemName: "hand.draw")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.quaternary)
            }
        }
        .aspectRatio(1.6, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: isArmed)
    }

    // MARK: Sample chips

    private var sampleChips: some View {
        HStack(spacing: 8) {
            ForEach(samples.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    Text("Sample \(index + 1)")
                        .font(.caption.weight(.medium))
                    Button {
                        if samples.indices.contains(index) {
                            samples.remove(at: index)
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Discard this sample")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.quinary, in: Capsule())
            }
        }
    }

    // MARK: Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField("Name", text: $name, prompt: Text("Shape name"))
                    .textFieldStyle(.roundedBorder)
                TextField("Symbol", text: $symbol, prompt: Text("Aa"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .multilineTextAlignment(.center)
            }
            if nameCollides {
                Label("A shape named “\(trimmedName)” already exists.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Straight-sample advisory

    /// Advisory (never blocks saving) shown when a captured sample is nearly straight.
    /// The recognizer matches straight strokes by direction only, and axis-aligned
    /// straight strokes are claimed first by built-in Flicks whenever those flicks
    /// are enabled and bound — so warn the user up front.
    private var straightSampleWarning: String? {
        for sample in samples {
            guard sample.count > 1, let first = sample.first, let last = sample.last else { continue }

            var pathLength = 0.0
            for index in 1..<sample.count {
                let dx = sample[index].x - sample[index - 1].x
                let dy = sample[index].y - sample[index - 1].y
                pathLength += (dx * dx + dy * dy).squareRoot()
            }
            guard pathLength > 0 else { continue }

            let dx = last.x - first.x
            let dy = last.y - first.y
            let straightness = (dx * dx + dy * dy).squareRoot() / pathLength
            guard straightness > 0.90 else { continue }

            // Angle in degrees, (-180, 180]; near-axis = within 25° of horizontal/vertical.
            let angle = atan2(dy, dx) * 180 / .pi
            let isNearAxis = [0.0, 90.0, -90.0, 180.0, -180.0]
                .contains { abs(angle - $0) <= 25 }
            if isNearAxis {
                return "Straight lines work best as Flicks — this shape only fires when the matching Flick is unbound."
            }
            return "Straight diagonal — matched by direction only, keep it distinctly angled."
        }
        return nil
    }

    // MARK: State machine

    private var instructionText: String {
        switch samples.count {
        case 0:
            return coordinator.config.instantDraw
                ? "Draw your shape on the trackpad with two fingers."
                : "Hold two fingers still on the trackpad, then draw your shape."
        case 1:
            return "Draw it again for accuracy (2 of 3) — or Save."
        case 2:
            return "One more for good measure (3 of 3) — or Save."
        default:
            return "All \(Self.maxSamples) samples captured — Save when ready."
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameCollides: Bool {
        guard !trimmedName.isEmpty else { return false }
        let candidate = trimmedName.lowercased()
        if ShapeRecognizer.builtInShapes.contains(where: { $0.name.lowercased() == candidate }) {
            return true
        }
        return coordinator.config.customTemplates.contains { $0.name.lowercased() == candidate }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !nameCollides && !samples.isEmpty
    }

    private func autoSymbol(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "" }
        return String(first).uppercased()
    }

    // MARK: Recording plumbing

    private func installRecordingHandler() {
        coordinator.state.recordingHandler = { stroke in
            guard samples.count < Self.maxSamples, stroke.count > 1 else { return }
            samples.append(stroke)
        }
    }

    private func cancel() {
        coordinator.state.recordingHandler = nil
        dismiss()
    }

    private func save() {
        guard canSave else { return }
        let finalSymbol: String = {
            let trimmed = symbol.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(2)) }
            return autoSymbol(for: trimmedName).isEmpty ? "◇" : autoSymbol(for: trimmedName)
        }()

        coordinator.config.customTemplates.append(
            CustomTemplate(name: trimmedName, symbol: finalSymbol, samples: samples)
        )
        coordinator.config.shapeBindings.append(
            ShapeBinding(shapeName: trimmedName)
        )
        coordinator.state.recordingHandler = nil
        dismiss()
    }
}
