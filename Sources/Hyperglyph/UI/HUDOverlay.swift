import AppKit
import Observation
import SwiftUI
import HyperglyphKit

// MARK: - Controller

/// Presents a click-through, system-HUD-style overlay panel used for two things:
///
/// 1. A live "ghost trackpad" trail card while the user draws a two-finger shape
///    (`showTrail(points:)` streams stroke updates, `endTrail()` hides it).
/// 2. A transient result pill after a gesture resolves (`showResult(symbol:title:success:)`),
///    which springs in, holds briefly, and fades away on its own.
///
/// A single borderless, non-activating `NSPanel` is created lazily and reused for every
/// presentation. It never becomes key, never steals focus, ignores all mouse events, and
/// joins every Space (including full-screen apps). Position and screen are recomputed each
/// time the panel comes on screen, so display changes are handled naturally.
final class HUDOverlayController {

    /// Fixed panel size — generous enough for the trail card plus its glow,
    /// and for the widest reasonable result pill. Content centers itself inside.
    private static let panelSize = NSSize(width: 520, height: 340)

    /// How long the result pill holds fully visible before fading.
    private static let resultHold: Duration = .milliseconds(900)
    /// Duration of the result fade-out.
    private static let resultFade: Duration = .milliseconds(300)
    /// Grace period after `endTrail()` during which an incoming result reuses
    /// the still-visible panel, so trail → result feels continuous.
    private static let trailLinger: Duration = .milliseconds(350)

    /// Screen anchor for the pop-up; set from AppConfig by the coordinator.
    var position: HUDPosition = .bottomCenter
    /// Visual design of the pop-up; set from AppConfig by the coordinator.
    var template: HUDTemplate = .glass {
        didSet { model.template = template }
    }

    private let model = HUDViewModel()
    private var panel: HUDPanel?
    /// Pending hide/dismiss work; cancelled whenever a new presentation begins.
    private var dismissTask: Task<Void, Never>?

    /// Fires a sample pill so Settings can live-preview position/template edits.
    func showPreview() {
        showResult(symbol: "C", title: "Preview", systemImage: "sparkles", success: true)
    }

    /// Streams the in-progress stroke to the trail card, presenting the panel on the
    /// first call. Points are normalized 0...1 trackpad coordinates with y-up.
    func showTrail(points: [StrokePoint]) {
        dismissTask?.cancel()
        dismissTask = nil

        model.trailPoints = points

        if model.phase != .trail {
            model.result = nil
            presentPanelIfNeeded()
            withAnimation(.easeOut(duration: 0.18)) {
                model.phase = .trail
            }
        }
    }

    /// Fades the trail card out. The panel lingers briefly off-content so that a
    /// `showResult` arriving within a beat replaces the trail in place.
    func endTrail() {
        guard model.phase == .trail else { return }

        withAnimation(.easeOut(duration: 0.2)) {
            model.phase = .hidden
        }
        model.trailPoints = []

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.trailLinger)
            guard !Task.isCancelled else { return }
            self?.orderOutIfIdle()
        }
    }

    /// Shows the transient result pill: springs in, holds ~0.9 s, fades ~0.3 s, then the
    /// panel orders out. Calling again while a pill is pending replaces it and restarts
    /// the timeline.
    /// `icon` (an app icon) or `systemImage` (an action-type glyph), when given,
    /// replace the title text — the pill reads "shape → target icon".
    func showResult(
        symbol: String,
        title: String,
        icon: NSImage? = nil,
        systemImage: String? = nil,
        success: Bool
    ) {
        dismissTask?.cancel()
        dismissTask = nil

        presentPanelIfNeeded()

        model.trailPoints = []
        model.result = HUDResult(
            symbol: symbol, title: title, icon: icon, systemImage: systemImage, success: success
        )
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            model.phase = .result
        }

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resultHold)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.model.phase = .hidden
            }
            try? await Task.sleep(for: Self.resultFade + .milliseconds(50))
            guard !Task.isCancelled else { return }
            self.model.result = nil
            self.orderOutIfIdle()
        }
    }

    // MARK: Panel lifecycle

    /// Creates the panel on first use, repositions it on the screen under the pointer,
    /// and orders it front without activating — but only when it isn't already visible.
    private func presentPanelIfNeeded() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard !panel.isVisible else { return }
        position(panel)
        panel.orderFrontRegardless()
    }

    private func orderOutIfIdle() {
        guard model.phase == .hidden else { return }
        panel?.orderOut(nil)
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let hosting = NSHostingView(rootView: HUDRootView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    /// Anchors the panel at the configured `position` on the screen containing the
    /// mouse pointer (falling back to the main screen), clamped to stay on screen.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let size = Self.panelSize
        let frame = screen.visibleFrame
        let anchor = position.anchor
        let center = NSPoint(
            x: frame.minX + frame.width * anchor.x,
            y: frame.minY + frame.height * anchor.y
        )
        let x = min(max(center.x - size.width / 2, frame.minX), frame.maxX - size.width)
        let y = min(max(center.y - size.height / 2, frame.minY), frame.maxY - size.height)
        panel.setFrame(
            NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height),
            display: false
        )
    }
}

// MARK: - Panel

/// Borderless utility panel that can never become key or main, so the HUD
/// never steals focus from the frontmost app.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View model

/// What the HUD is currently presenting.
private enum HUDPhase {
    case hidden
    case trail
    case result
}

/// A resolved gesture outcome to display in the pill. Fresh identity per call so
/// back-to-back results re-run the entrance animation.
private struct HUDResult: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    /// App icon shown in place of the title when present.
    let icon: NSImage?
    /// SF Symbol shown in place of the title when present (non-app actions).
    let systemImage: String?
    let success: Bool
}

/// Small observable state bridge between the controller and the SwiftUI content.
@Observable
private final class HUDViewModel {
    var phase: HUDPhase = .hidden
    /// Normalized 0...1 stroke points, y-up (trackpad orientation).
    var trailPoints: [StrokePoint] = []
    var result: HUDResult?
    var template: HUDTemplate = .glass
}

// MARK: - Root view

/// Root of the panel's hosting view: crossfades between the trail card and the
/// result pill, both centered in the (transparent, click-through) panel.
private struct HUDRootView: View {
    var model: HUDViewModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .hidden:
                EmptyView()
            case .trail:
                TrailCard(points: model.trailPoints)
                    .transition(.opacity)
            case .result:
                if let result = model.result {
                    ResultPill(result: result, template: model.template)
                        .id(result.id)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.9).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Trail card

/// The "ghost trackpad": a dark, blurred rounded rect mirroring the physical pad,
/// with the in-progress stroke rendered as a glowing gradient path.
private struct TrailCard: View {
    var points: [StrokePoint]

    private static let cardSize = CGSize(width: 340, height: 220)
    /// Keeps the stroke and its glow away from the card edges.
    private static let inset: CGFloat = 22
    private static let strokeWidth: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            let mapped = Self.mapToCanvas(points, in: size)
            guard let first = mapped.first, let last = mapped.last else { return }

            let path = Self.smoothedPath(through: mapped)
            let style = StrokeStyle(
                lineWidth: Self.strokeWidth,
                lineCap: .round,
                lineJoin: .round
            )

            // Soft glow underneath the stroke.
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 7))
                layer.stroke(
                    path,
                    with: .color(.accentColor.opacity(0.75)),
                    style: StrokeStyle(lineWidth: Self.strokeWidth + 5, lineCap: .round, lineJoin: .round)
                )
            }

            // Main stroke: white at the start fading into the accent at the head.
            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [.white, Color.accentColor]),
                    startPoint: first,
                    endPoint: last
                ),
                style: style
            )

            // Bright dot at the head of the stroke.
            let headGlow = CGRect(x: last.x - 9, y: last.y - 9, width: 18, height: 18)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 5))
                layer.fill(Path(ellipseIn: headGlow), with: .color(.accentColor.opacity(0.9)))
            }
            let head = CGRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: head), with: .color(.white))
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 26, y: 10)
    }

    /// Maps normalized trackpad points (0...1, y-UP) into canvas coordinates
    /// (y-down), inset from the edges.
    private static func mapToCanvas(_ points: [StrokePoint], in size: CGSize) -> [CGPoint] {
        let width = size.width - inset * 2
        let height = size.height - inset * 2
        return points.map { point in
            CGPoint(
                x: inset + CGFloat(point.x) * width,
                y: inset + CGFloat(1.0 - point.y) * height
            )
        }
    }

    /// Builds a smooth path by drawing quadratic curves through segment midpoints,
    /// using the raw samples as control points.
    private static func smoothedPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)

        guard points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }

        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: current)
        }
        if let last = points.last {
            path.addLine(to: last)
        }
        return path
    }
}

// MARK: - Result pill

/// The gesture result pop-up, rendered in the user's chosen `HUDTemplate` —
/// green-tinted on success, muted orange on failure.
private struct ResultPill: View {
    var result: HUDResult
    var template: HUDTemplate

    private var tint: Color { result.success ? .green : .orange }

    var body: some View {
        switch template {
        case .glass: glass
        case .midnight: midnight
        case .minimal: minimal
        case .jumbo: jumbo
        }
    }

    // MARK: Shared pieces

    /// The recognized-shape glyph in a tinted status ring.
    private func glyphCircle(diameter: CGFloat, fontSize: CGFloat, ring: Bool = true) -> some View {
        ZStack {
            Circle().fill(tint.opacity(0.14))
            if ring {
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [tint.opacity(0.75), tint.opacity(0.35)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
            }
            Text(result.symbol)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(result.success ? Color.primary : tint)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(diameter * 0.12)
        }
        .frame(width: diameter, height: diameter)
    }

    /// The target: app icon, action-type symbol, or (fallback/failure) title text.
    @ViewBuilder
    private func target(iconSide: CGFloat, textSize: CGFloat) -> some View {
        if let icon = result.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSide, height: iconSide)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        } else if let systemImage = result.systemImage {
            Image(systemName: systemImage)
                .font(.system(size: iconSide * 0.55, weight: .semibold))
                .foregroundStyle(result.success ? Color.primary : Color.secondary)
                .frame(width: iconSide, height: iconSide)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: iconSide * 0.23, style: .continuous))
        } else {
            Text(result.title)
                .font(.system(size: textSize, weight: .medium, design: .rounded))
                .foregroundStyle(result.success ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var hasTargetGlyph: Bool { result.icon != nil || result.systemImage != nil }

    // MARK: Templates

    /// System-material capsule with a status ring (default).
    private var glass: some View {
        HStack(spacing: 14) {
            glyphCircle(diameter: 52, fontSize: 28)
            if hasTargetGlyph { arrow }
            target(iconSide: 44, textSize: 15)
        }
        .padding(.leading, 12)
        .padding(.trailing, 22)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.2)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 22, y: 8)
    }

    /// Opaque near-black card with glowing accents.
    private var midnight: some View {
        HStack(spacing: 14) {
            glyphCircle(diameter: 52, fontSize: 28)
                .shadow(color: tint.opacity(0.55), radius: 12)
            if hasTargetGlyph { arrow }
            target(iconSide: 44, textSize: 15)
        }
        .padding(.leading, 14)
        .padding(.trailing, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: tint.opacity(0.25), radius: 26, y: 6)
    }

    /// Small, quiet, compact pill.
    private var minimal: some View {
        HStack(spacing: 8) {
            Text(result.symbol)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(result.success ? Color.primary : tint)
            if hasTargetGlyph {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            target(iconSide: 22, textSize: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: 300)
        .background(.thinMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.20), radius: 10, y: 4)
    }

    /// Large square card, classic macOS volume-HUD style.
    private var jumbo: some View {
        VStack(spacing: 16) {
            glyphCircle(diameter: 76, fontSize: 40)
            target(iconSide: 64, textSize: 17)
        }
        .padding(28)
        .frame(width: 190, height: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black.opacity(0.2)))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.30), radius: 24, y: 8)
    }
}
