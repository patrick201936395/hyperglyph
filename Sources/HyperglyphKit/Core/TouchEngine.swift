import Foundation
import OpenMultitouchSupport
import os

/// Bridges the private MultitouchSupport touch stream (via the OpenMultitouchSupport
/// package) into `TouchFrame` values delivered on the main actor.
///
/// Responsibilities:
/// - Starts/stops the `OMSManager` listener and consumes its async frame stream.
/// - Converts each raw `[OMSTouchData]` frame into a `TouchFrame` (normalized 0...1,
///   y-up coordinates), stamped with the local receipt time.
/// - Bridges over stream silences: MultitouchSupport pauses frame delivery both when
///   the pad goes idle and when resting fingers are perfectly still. After any frame
///   that contains touches, a short watchdog disambiguates the two cases. If the last
///   real frame's touches were all lifting (`.breaking`/`.leaving`), it synthesizes one
///   empty `TouchFrame` — a genuine end of touch, so downstream detectors (tap zones,
///   draw mode) always see the pad return to empty. Otherwise it emits synthetic
///   heartbeat frames — the last known touches re-delivered with a fresh timestamp,
///   repeating every `watchdogDelay` until a real frame arrives — meaning "unchanged,
///   fingers still down". Heartbeats keep dwell timers and touch sessions alive while
///   never fabricating "pad empty" under resting fingers.
public final class TouchEngine {
    /// Called on the main actor with every touch frame (including synthesized empty
    /// frames and heartbeats). Set before calling `start()`.
    public var onFrame: ((TouchFrame) -> Void)?

    /// Called on the main actor from `start()` if the MultitouchSupport listener could
    /// not be started (e.g. no accessible trackpad). Set before calling `start()`.
    public var onCaptureFailed: (() -> Void)?

    /// True between `start()` and `stop()`.
    public private(set) var isRunning = false

    /// Task consuming `OMSManager.shared.touchDataStream`.
    private var streamTask: Task<Void, Never>?

    /// Pending stream-silence watchdog; rescheduled on every real frame with touches
    /// and after every heartbeat it emits.
    private var watchdogTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.hyperglyph.Hyperglyph", category: "TouchEngine")

    /// Bumped on every `start()`/`stop()` so stale tasks from a previous run can
    /// never deliver frames into the current one.
    private var generation = 0

    /// How long the stream may stay silent after a touch-bearing frame before the
    /// watchdog synthesizes a frame (empty frame or heartbeat, see `scheduleWatchdog`).
    private static let watchdogDelay: Duration = .milliseconds(60)

    public init() {}

    /// Begins listening for trackpad touches. No-op if already running.
    ///
    /// If the MultitouchSupport listener cannot be started, logs the failure and
    /// invokes `onCaptureFailed`. `isRunning` is still set so a subsequent `stop()`
    /// stays balanced, but the stream-consuming task is not started — there is
    /// nothing to consume, and skipping it avoids parking a task on a stream that
    /// will never yield.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let gen = generation

        guard OMSManager.shared.startListening() else {
            Self.logger.error("OMSManager.startListening() failed; no accessible trackpad — touch capture unavailable")
            onCaptureFailed?()
            return
        }

        streamTask = Task { [weak self] in
            for await raw in OMSManager.shared.touchDataStream {
                guard let self, !Task.isCancelled, self.generation == gen else { return }
                self.deliver(Self.makeFrame(from: raw), generation: gen)
            }
        }
    }

    /// Stops listening, cancels in-flight tasks, and delivers one final empty frame
    /// so downstream state machines settle. No-op if not running.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1

        streamTask?.cancel()
        streamTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil

        OMSManager.shared.stopListening()

        onFrame?(TouchFrame(touches: [], timestamp: Date().timeIntervalSinceReferenceDate))
    }

    // MARK: - Delivery

    /// Hands a real frame to `onFrame` and manages the stream-silence watchdog.
    private func deliver(_ frame: TouchFrame, generation gen: Int) {
        guard generation == gen else { return }

        watchdogTask?.cancel()
        watchdogTask = nil

        onFrame?(frame)

        // Only frames that still contain touches need a watchdog; once the pad is
        // observed empty, downstream state is already settled.
        guard !frame.touches.isEmpty else { return }

        scheduleWatchdog(for: frame.touches, generation: gen)
    }

    /// Arms the watchdog for a stream silence following `touches`, the touches of the
    /// most recent real frame. When it fires:
    /// - If every touch was already lifting (`.breaking`/`.leaving`), the stream went
    ///   silent mid-lift: synthesize one empty frame so downstream state machines see
    ///   the pad clear.
    /// - Otherwise fingers may simply be resting perfectly still (MultitouchSupport
    ///   pauses delivery for stationary contacts): re-deliver the same touches with a
    ///   fresh timestamp as a heartbeat and re-arm, so heartbeats repeat every
    ///   `watchdogDelay` until a real frame arrives. The pad is never reported empty
    ///   while fingers may still be down.
    /// Both paths are guarded by the generation counter, so heartbeats stop after
    /// `stop()` or a restart.
    private func scheduleWatchdog(for touches: [TouchPoint], generation gen: Int) {
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: Self.watchdogDelay)
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            self.watchdogTask = nil

            let now = Date().timeIntervalSinceReferenceDate
            if touches.allSatisfy({ $0.phase == .breaking || $0.phase == .leaving }) {
                self.onFrame?(TouchFrame(touches: [], timestamp: now))
            } else {
                self.onFrame?(TouchFrame(touches: touches, timestamp: now))
                self.scheduleWatchdog(for: touches, generation: gen)
            }
        }
    }

    // MARK: - Conversion

    /// Converts one raw OMS frame into a `TouchFrame`, stamped at receipt time.
    /// Touches in the `notTouching` state are excluded.
    private nonisolated static func makeFrame(from raw: [OMSTouchData]) -> TouchFrame {
        let touches = raw.compactMap { data -> TouchPoint? in
            guard data.state != .notTouching else { return nil }
            return TouchPoint(
                id: data.id,
                x: Double(data.position.x),
                y: Double(data.position.y),
                pressure: Double(data.pressure),
                total: Double(data.total),
                majorAxis: Double(data.axis.major),
                minorAxis: Double(data.axis.minor),
                density: Double(data.density),
                phase: phase(for: data.state)
            )
        }
        return TouchFrame(touches: touches, timestamp: Date().timeIntervalSinceReferenceDate)
    }

    /// Maps the raw MultitouchSupport contact state onto the app's `TouchPhase`.
    private nonisolated static func phase(for state: OMSState) -> TouchPhase {
        switch state {
        case .starting: return .starting
        case .making, .touching: return .touching
        case .breaking: return .breaking
        case .leaving, .lingering: return .leaving
        case .hovering: return .hovering
        default: return .other
        }
    }
}
