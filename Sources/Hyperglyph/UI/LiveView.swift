import SwiftUI
import HyperglyphKit

/// The showpiece "Live" page: a dark, glassy real-time trackpad visualizer.
///
/// Renders every finger on the pad as a glowing orb (radius scaled by pressure),
/// leaves fading comet trails behind moving touches, and draws the in-progress
/// shape stroke as a bright gradient path with glow. When draw mode is armed the
/// trackpad border pulses and a "DRAW" badge appears. A glassy stats strip below
/// the canvas shows live touch count, armed state, haptic engine, and the master
/// enable switch.
///
/// Incoming coordinates from `AppState` are normalized 0...1 with y-UP
/// (MultitouchSupport orientation); this view flips y for screen display.
struct LiveView: View {
    /// The app's wiring hub; this view reads `coordinator.state` for live data.
    var coordinator: AppCoordinator

    /// Ring buffer of recent touch positions for comet trails.
    @State private var trails: [TrailSample] = []
    /// Deferred sweep that clears the trail buffer once the last comet has faded,
    /// letting the animation timeline pause when the pad goes quiet.
    @State private var trailSweep: Task<Void, Never>?

    // MARK: - Tuning

    private static let trailLifetime: TimeInterval = 0.8
    private static let trailCapacity = 480
    private static let cornerRadius: CGFloat = 24
    private static let padAspect: CGFloat = 1.6
    private static let padMaxWidth: CGFloat = 640

    /// Electric cyan — the page's primary accent.
    private static let accent = Color(red: 0.36, green: 0.87, blue: 1.0)
    /// Violet — secondary accent for gradients and the background glow.
    private static let accentAlt = Color(red: 0.62, green: 0.44, blue: 1.0)

    private struct TrailSample {
        let touchID: Int32
        let x: Double
        let y: Double
        let time: TimeInterval
    }

    // MARK: - Derived state

    /// True while anything on the canvas is moving; gates the animation timeline.
    private var isLive: Bool {
        !coordinator.state.touches.isEmpty
            || !trails.isEmpty
            || !coordinator.state.currentStroke.isEmpty
            || coordinator.state.isDrawArmed
    }

    private var showHint: Bool {
        coordinator.state.touches.isEmpty
            && trails.isEmpty
            && coordinator.state.currentStroke.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 26) {
            header
            trackpadCanvas
            statsStrip
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pageBackground)
        .environment(\.colorScheme, .dark)
        .onChange(of: coordinator.state.touches) { _, newTouches in
            recordTrail(for: newTouches)
        }
        .onDisappear {
            trailSweep?.cancel()
            trailSweep = nil
            trails.removeAll()
        }
    }

    // MARK: - Background

    private var pageBackground: some View {
        ZStack {
            Color(red: 0.043, green: 0.043, blue: 0.062)
            RadialGradient(
                colors: [Self.accentAlt.opacity(0.14), .clear],
                center: UnitPoint(x: 0.5, y: 0.06),
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [Self.accent.opacity(0.06), .clear],
                center: UnitPoint(x: 0.86, y: 0.94),
                startRadius: 0,
                endRadius: 440
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 5) {
            Text("LIVE INPUT")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(3.5)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Self.accent, Self.accentAlt],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            Text("Every touch on the pad, rendered in real time")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
        }
    }

    // MARK: - Trackpad canvas

    private var trackpadCanvas: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let armed = coordinator.state.isDrawArmed

        return ZStack {
            // Surface.
            shape.fill(
                LinearGradient(
                    colors: [Color(white: 0.105), Color(white: 0.052)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            gridDots
                .clipShape(shape)

            // Dynamic layer: trails, stroke, touch orbs, armed pulse.
            TimelineView(.animation(paused: !isLive)) { timeline in
                Canvas { context, size in
                    drawDynamicLayer(
                        in: &context,
                        size: size,
                        now: timeline.date.timeIntervalSinceReferenceDate
                    )
                }
            }
            .clipShape(shape)

            // Inner-shadow feel: a soft dark line hugging the inside edge.
            shape
                .inset(by: 1)
                .stroke(Color.black.opacity(0.55), lineWidth: 2.5)
                .blur(radius: 2)
                .clipShape(shape)

            // Thin gradient border: bright sheen at top, accent whisper at bottom.
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(0.26),
                        .white.opacity(0.06),
                        Self.accent.opacity(armed ? 0.5 : 0.18),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )

            if showHint {
                Text("Rest your fingers on the trackpad")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.22))
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if armed { drawBadge }
        }
        .aspectRatio(Self.padAspect, contentMode: .fit)
        .frame(maxWidth: Self.padMaxWidth)
        .shadow(color: .black.opacity(0.5), radius: 28, y: 14)
        .animation(.easeInOut(duration: 0.3), value: showHint)
        .animation(.spring(duration: 0.35, bounce: 0.4), value: armed)
    }

    private var drawBadge: some View {
        Text("DRAW")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(2)
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Self.accent))
            .shadow(color: Self.accent.opacity(0.65), radius: 10)
            .padding(12)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
    }

    /// Static dot grid — drawn once; never part of the animation timeline.
    private var gridDots: some View {
        Canvas { context, size in
            let cols = 25
            let rows = 16
            let inset: CGFloat = 20
            let stepX = (size.width - inset * 2) / CGFloat(cols - 1)
            let stepY = (size.height - inset * 2) / CGFloat(rows - 1)
            let dot = GraphicsContext.Shading.color(.white.opacity(0.055))
            for row in 0..<rows {
                let y = inset + CGFloat(row) * stepY
                for col in 0..<cols {
                    let x = inset + CGFloat(col) * stepX
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                        with: dot
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Dynamic drawing

    private func drawDynamicLayer(in context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        if coordinator.state.isDrawArmed {
            drawArmedPulse(in: &context, size: size, now: now)
        }
        drawTrails(in: &context, size: size, now: now)
        drawShapeStroke(in: &context, size: size)
        drawTouchOrbs(in: &context, size: size)
    }

    /// Pulsing accent glow around the border while draw mode is armed.
    private func drawArmedPulse(in context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
        let path = Path(roundedRect: rect, cornerRadius: Self.cornerRadius - 2, style: .continuous)
        let phase = 0.5 + 0.5 * sin(now * (2 * .pi / 1.3))
        let strength = 0.3 + 0.45 * phase

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 7))
            layer.stroke(path, with: .color(Self.accent.opacity(strength)), lineWidth: 6)
        }
        context.stroke(path, with: .color(Self.accent.opacity(strength * 0.85)), lineWidth: 1.5)
    }

    /// Fading comet trails behind recently moving touches.
    private func drawTrails(in context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        guard !trails.isEmpty else { return }
        // Last drawn point per finger, so segments only connect samples of the same touch.
        var previous: [Int32: (point: CGPoint, time: TimeInterval)] = [:]
        previous.reserveCapacity(8)

        for sample in trails {
            let age = max(0, now - sample.time)
            let point = CGPoint(x: sample.x * size.width, y: (1 - sample.y) * size.height)
            defer { previous[sample.touchID] = (point, sample.time) }

            guard age < Self.trailLifetime else { continue }
            guard let prev = previous[sample.touchID], sample.time - prev.time < 0.1 else { continue }

            let fade = 1 - age / Self.trailLifetime // 1 fresh → 0 dead
            var segment = Path()
            segment.move(to: prev.point)
            segment.addLine(to: point)
            context.stroke(
                segment,
                with: .color(Self.accent.opacity(0.45 * fade * fade)),
                style: StrokeStyle(lineWidth: 1 + 3.5 * fade, lineCap: .round)
            )
        }
    }

    /// The active shape stroke: bright gradient path with a soft glow underneath —
    /// visually distinct from the passive comet trails.
    private func drawShapeStroke(in context: inout GraphicsContext, size: CGSize) {
        let points = coordinator.state.currentStroke
        guard let first = points.first else { return }

        let start = CGPoint(x: first.x * size.width, y: (1 - first.y) * size.height)
        guard points.count > 1 else {
            context.fill(
                Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)),
                with: .color(Self.accent)
            )
            return
        }

        var path = Path()
        path.move(to: start)
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height))
        }
        let end = path.currentPoint ?? start

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 7))
            layer.stroke(
                path,
                with: .color(Self.accent.opacity(0.55)),
                style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
            )
        }
        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: [Self.accentAlt, Self.accent, .white]),
                startPoint: start,
                endPoint: end
            ),
            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        )
    }

    /// Glowing orbs for every finger currently on the pad.
    private func drawTouchOrbs(in context: inout GraphicsContext, size: CGSize) {
        for touch in coordinator.state.touches {
            guard touch.phase != .leaving else { continue }
            let center = CGPoint(x: touch.x * size.width, y: (1 - touch.y) * size.height)
            let pressure = min(max(touch.pressure, 0), 1)
            let radius = 14 + 20 * pressure

            // Soft glow scaled by pressure.
            context.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [Self.accent.opacity(0.85), Self.accent.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
            // Faint ring.
            let ring = radius * 0.62
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: center.x - ring, y: center.y - ring,
                    width: ring * 2, height: ring * 2
                )),
                with: .color(.white.opacity(0.16)),
                lineWidth: 1
            )
            // Crisp core.
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 3.2, y: center.y - 3.2, width: 6.4, height: 6.4)),
                with: .color(.white)
            )
        }
    }

    // MARK: - Trail bookkeeping

    private func recordTrail(for touches: [TouchPoint]) {
        let now = Date().timeIntervalSinceReferenceDate

        for touch in touches where touch.phase == .starting || touch.phase == .touching {
            trails.append(TrailSample(touchID: touch.id, x: touch.x, y: touch.y, time: now))
        }
        // Prune the ring buffer: drop dead samples, then cap capacity.
        trails.removeAll { now - $0.time > Self.trailLifetime }
        if trails.count > Self.trailCapacity {
            trails.removeFirst(trails.count - Self.trailCapacity)
        }

        // Once frames stop arriving nothing prunes the buffer, so schedule a final
        // sweep just after the last comet fades — this lets `isLive` go false and
        // the animation timeline pause.
        trailSweep?.cancel()
        guard !trails.isEmpty else { return }
        trailSweep = Task {
            try? await Task.sleep(for: .seconds(Self.trailLifetime + 0.1))
            guard !Task.isCancelled else { return }
            trails.removeAll()
        }
    }

    // MARK: - Stats strip

    private var statsStrip: some View {
        let state = coordinator.state
        let touchCount = state.touches.count

        return HStack(spacing: 0) {
            statCell(
                icon: "hand.point.up.left.fill",
                iconTint: touchCount > 0 ? Self.accent : .white.opacity(0.3),
                value: "\(touchCount)",
                label: "Touches"
            )
            cellDivider
            armedCell(isArmed: state.isDrawArmed)
            cellDivider
            statCell(
                icon: "waveform",
                iconTint: state.hapticsUsingPrivateAPI ? Self.accent : .white.opacity(0.3),
                value: state.hapticsUsingPrivateAPI ? "Actuator" : "Fallback",
                label: "Haptics"
            )
            cellDivider
            statCell(
                icon: "power",
                iconTint: state.isEnabled ? .green : .red.opacity(0.8),
                value: state.isEnabled ? "On" : "Off",
                label: "Engine"
            )
        }
        .padding(.vertical, 14)
        .frame(maxWidth: Self.padMaxWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: state.isDrawArmed)
    }

    private func statCell(icon: String, iconTint: Color, value: String, label: String) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconTint)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.92))
            }
            cellLabel(label)
        }
        .frame(maxWidth: .infinity)
    }

    private func armedCell(isArmed: Bool) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isArmed ? Self.accent : Color.white.opacity(0.2))
                    .frame(width: 7, height: 7)
                    .shadow(color: isArmed ? Self.accent.opacity(0.9) : .clear, radius: 4)
                Text(isArmed ? "Armed" : "Idle")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isArmed ? Self.accent : .white.opacity(0.92))
            }
            cellLabel("Draw Mode")
        }
        .frame(maxWidth: .infinity)
    }

    private func cellLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.35))
    }

    private var cellDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1, height: 26)
    }
}
