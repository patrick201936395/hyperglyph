import AppKit
import Foundation
import Observation
import HyperglyphKit

/// Central wiring hub. Owns every engine and routes touch frames through:
///   TouchEngine → DrawModeController (shape strokes) + TapZoneDetector (zone taps)
/// and fans recognized gestures out to ActionRunner, HapticEngine, HUD, and AppState.
/// @Observable so SwiftUI views tracking `config` refresh on edits.
@Observable
final class AppCoordinator {
    static let shared = AppCoordinator()

    let state = AppState()
    let configStore = ConfigStore()

    var config: AppConfig {
        didSet {
            configStore.save(config)
            applyConfig()
        }
    }

    let touchEngine = TouchEngine()
    let zoneDetector = TapZoneDetector()
    let drawController = DrawModeController()
    let scrollSuppressor = ScrollSuppressor()
    let recognizer = ShapeRecognizer()
    let haptics = HapticEngine()
    let actionRunner = ActionRunner()
    let hud = HUDOverlayController()

    private var flashTask: Task<Void, Never>?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    /// When the current draw stroke started (armed); used to reject slow
    /// scroll-like "flicks" in instant mode.
    private var drawStartedAt: Date?
    /// True once the current instant-mode stroke has revealed the HUD trail;
    /// keeps the trail sticky for the rest of the stroke.
    private var trailVisibleForCurrentStroke = false

    /// A stroke "looks like a drawing" once it has covered some ground AND is
    /// clearly bending — scrolls track nearly straight (straightness ≈ 1), while
    /// shapes like C or O curve well below it.
    private static func looksLikeDrawing(_ stroke: [StrokePoint]) -> Bool {
        guard stroke.count >= 6, let first = stroke.first, let last = stroke.last else { return false }
        var length = 0.0
        for i in 1..<stroke.count {
            length += hypot(stroke[i].x - stroke[i - 1].x, stroke[i].y - stroke[i - 1].y)
        }
        guard length > 0.08 else { return false }
        let straightness = hypot(last.x - first.x, last.y - first.y) / length
        return straightness < 0.88
    }

    private init() {
        config = configStore.load()
        state.isEnabled = config.isEnabled
        wire()
        applyConfig()
    }

    func start() {
        state.accessibilityGranted = ActionRunner.isAccessibilityTrusted
        touchEngine.start()
        state.hapticsUsingPrivateAPI = haptics.usingPrivateAPI
        installClickMonitors()
    }

    /// Physical clicks are detected from real mouse-down events (no Accessibility
    /// needed for mouse monitors) so the tap detector never has to guess from raw
    /// pressure — light taps trigger zones without any click force.
    private func installClickMonitors() {
        let clickTypes: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clickTypes) { [weak self] _ in
            self?.zoneDetector.notePhysicalClick()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clickTypes) { [weak self] event in
            self?.zoneDetector.notePhysicalClick()
            return event
        }
    }

    func stop() {
        touchEngine.stop()
        scrollSuppressor.end()
        hud.endTrail()
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
        configStore.flush()
    }

    func setEnabled(_ enabled: Bool) {
        state.isEnabled = enabled
        config.isEnabled = enabled
        if !enabled {
            zoneDetector.reset()
            drawController.reset()
            scrollSuppressor.end()
            hud.endTrail()
            state.currentStroke = []
            state.isDrawArmed = false
            trailVisibleForCurrentStroke = false
        }
    }

    // MARK: - Wiring

    private func wire() {
        touchEngine.onFrame = { [weak self] frame in
            self?.handleFrame(frame)
        }
        touchEngine.onCaptureFailed = { [weak self] in
            self?.state.touchCaptureFailed = true
        }

        zoneDetector.onTap = { [weak self] zone, count in
            self?.handleZoneTap(zone: zone, count: count)
        }
        zoneDetector.maxTapCountProvider = { [weak self] zone in
            guard let self else { return 1 }
            return self.config.zoneBindings
                .filter { $0.zone == zone && $0.isEnabled && $0.action != nil }
                .map(\.tapCount)
                .max() ?? 0
        }

        drawController.onArmed = { [weak self] in
            guard let self else { return }
            drawStartedAt = Date()
            // Instant mode arms on EVERY two-finger touch (scrolls included), so
            // the arm tick, scroll blocking, and armed badge stay dwell-mode-only.
            guard !config.instantDraw else { return }
            state.isDrawArmed = true
            scrollSuppressor.begin()
            if config.hapticsEnabled { haptics.play(.arm) }
        }
        drawController.onStrokeUpdate = { [weak self] stroke in
            guard let self else { return }
            state.currentStroke = stroke
            guard config.hudEnabled else { return }
            if !config.instantDraw {
                // Dwell mode: the user deliberately armed, always show the trail.
                hud.showTrail(points: stroke)
            } else if trailVisibleForCurrentStroke || Self.looksLikeDrawing(stroke) {
                // Instant mode: reveal the trail the moment the motion curves like
                // a shape rather than tracking straight like a scroll — then keep
                // it up (sticky) for the rest of the stroke.
                trailVisibleForCurrentStroke = true
                hud.showTrail(points: stroke)
            }
        }
        drawController.onStrokeEnded = { [weak self] stroke in
            self?.finishStroke(stroke)
        }
        drawController.onCancelled = { [weak self] in
            guard let self else { return }
            state.isDrawArmed = false
            state.currentStroke = []
            trailVisibleForCurrentStroke = false
            scrollSuppressor.end()
            hud.endTrail()
        }
    }

    private func applyConfig() {
        drawController.requiresDwell = !config.instantDraw
        drawController.dwellSeconds = config.dwellSeconds
        drawController.stillnessThreshold = config.stillnessThreshold
        zoneDetector.tapMaxDuration = config.tapMaxDuration
        zoneDetector.tapMaxMovement = config.tapMaxMovement
        zoneDetector.multiTapWindow = config.multiTapWindow
    }

    // MARK: - Frame routing

    private func handleFrame(_ frame: TouchFrame) {
        state.touches = frame.touches
        guard state.isEnabled else { return }
        drawController.process(frame)
        // Suppress zone taps while drawing so lifting fingers doesn't misfire a zone.
        if drawController.isArmed || drawController.isTracking {
            zoneDetector.reset()
        } else {
            zoneDetector.process(frame)
        }
    }

    // MARK: - Shape flow

    private func finishStroke(_ stroke: [StrokePoint]) {
        state.isDrawArmed = false
        state.currentStroke = []
        trailVisibleForCurrentStroke = false
        scrollSuppressor.end()
        hud.endTrail()
        let drawDuration = drawStartedAt.map { Date().timeIntervalSince($0) }
        drawStartedAt = nil

        // Recorder UI takes priority over recognition.
        if let handler = state.recordingHandler {
            handler(stroke)
            if config.hapticsEnabled { haptics.play(.success) }
            return
        }

        // Pass 1: only shapes that can actually fire (enabled + action bound) may win,
        // so a disabled or unbound look-alike can never shadow a configured gesture.
        let eligibleNames = Set(
            config.shapeBindings
                .filter { $0.isEnabled && $0.action != nil }
                .map(\.shapeName)
        )
        let result = recognizer.recognize(
            stroke,
            threshold: config.matchThreshold,
            customTemplates: config.customTemplates,
            eligibleNames: eligibleNames
        )

        // Instant mode: a "flick" that took as long as a scroll IS a scroll.
        if config.instantDraw,
           let matched = result, matched.name.hasPrefix("Flick"),
           let duration = drawDuration, duration > 0.4 {
            return
        }

        guard let result else {
            // Instant mode captures every two-finger motion, so misses are almost
            // always ordinary scrolls — stay completely silent.
            guard !config.instantDraw else { return }
            // Pass 2 (informational only): would this have matched an unbound or
            // disabled shape? Tell the user precisely why nothing fired.
            if config.hapticsEnabled { haptics.play(.fail) }
            if config.hudEnabled {
                if let shadow = recognizer.recognize(
                    stroke,
                    threshold: config.matchThreshold,
                    customTemplates: config.customTemplates
                ) {
                    let binding = config.shapeBindings.first { $0.shapeName == shadow.name }
                    let reason = (binding?.isEnabled == false) ? "disabled" : "no action set"
                    hud.showResult(symbol: shadow.symbol, title: "\(shadow.name) — \(reason)", success: false)
                } else {
                    hud.showResult(symbol: "?", title: "Not recognized", success: false)
                }
            }
            return
        }

        guard let action = config.shapeBindings.first(where: {
            $0.shapeName == result.name && $0.isEnabled && $0.action != nil
        })?.action else {
            return // Unreachable: eligibility filtering guarantees a bound action.
        }

        if config.hapticsEnabled { haptics.play(.success) }
        let title = "\(result.symbol) → \(action.displayName)"
        if config.hudEnabled { hud.showResult(symbol: result.symbol, title: action.displayName, success: true) }
        state.pushEvent(GestureEvent(date: Date(), symbol: result.symbol, title: title, success: true))
        flashMenuBar(result.symbol)
        actionRunner.run(action)
    }

    // MARK: - Zone flow

    private func handleZoneTap(zone: TapZone, count: Int) {
        guard state.isEnabled, state.recordingHandler == nil else { return }
        guard let binding = config.zoneBindings.first(where: {
            $0.zone == zone && $0.tapCount == count && $0.isEnabled && $0.action != nil
        }), let action = binding.action else { return }

        if config.hapticsEnabled { haptics.play(.zone) }
        let symbol = "▣"
        let title = "\(count)× \(zone.displayName) → \(action.displayName)"
        if config.hudEnabled { hud.showResult(symbol: symbol, title: action.displayName, success: true) }
        state.pushEvent(GestureEvent(date: Date(), symbol: symbol, title: title, success: true))
        flashMenuBar(symbol)
        actionRunner.run(action)
    }

    // MARK: - Menu bar flash

    private func flashMenuBar(_ symbol: String) {
        flashTask?.cancel()
        state.menuBarFlash = symbol
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.state.menuBarFlash = nil
        }
    }
}
