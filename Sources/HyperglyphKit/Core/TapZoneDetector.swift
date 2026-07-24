import Foundation

/// Detects light, non-click taps in six trackpad zones and accumulates them into
/// multi-tap sequences (single / double / triple tap).
///
/// Feed every `TouchFrame` through `process(_:)`. The detector tracks each touch id
/// across frames as a *session* (start position, start time, peak movement, and the
/// maximum number of concurrent touches seen during its lifetime). When a touch
/// lifts, its session qualifies as a tap only if it was short, still, and the sole
/// touch on the pad the whole time — which filters out scrolls and multi-finger
/// gestures. Physical clicks are excluded via `notePhysicalClick()` (fed real
/// mouse-down events by the coordinator) rather than any raw pressure heuristic,
/// so light taps never need force to register.
///
/// Qualifying taps in the same zone within `multiTapWindow` accumulate; the final
/// count is delivered via `onTap`. If the count reaches the highest bound count for
/// the zone (from `maxTapCountProvider`) the tap fires immediately rather than
/// waiting out the window, keeping single-bound zones snappy.
///
/// All coordinates are normalized 0...1 with y-up (y = 0 at the bottom edge),
/// matching raw MultitouchSupport data.
public final class TapZoneDetector {

    // MARK: - Public API

    /// Fired with the zone and the final accumulated tap count once a sequence resolves.
    public var onTap: ((TapZone, Int) -> Void)?

    /// Returns the highest tap count bound for a zone (e.g. 2 if a double-tap binding
    /// exists). Returning 0 means the zone is unbound and taps there are ignored.
    /// When unset, every zone is treated as single-tap (max 1).
    public var maxTapCountProvider: ((TapZone) -> Int)?

    /// Maximum touch duration, in seconds, for a session to qualify as a tap.
    public var tapMaxDuration: Double = 0.25

    /// Maximum normalized movement from the start position for a session to qualify as a tap.
    public var tapMaxMovement: Double = 0.02

    /// Seconds to wait for another tap before finalizing a multi-tap sequence.
    public var multiTapWindow: Double = 0.35

    /// Corner zone width as a fraction of the trackpad.
    public var cornerWidth: Double = 0.30

    /// Corner zone height as a fraction of the trackpad.
    public var cornerHeight: Double = 0.40

    public init() {}

    /// Marks "a physical click just happened": any touch session overlapping this
    /// moment is disqualified, and any queued tap sequence is dropped. The
    /// coordinator calls this from real mouse-down event monitors — ground truth,
    /// unlike the undocumented raw pressure scale.
    public func notePhysicalClick() {
        lastClickTime = Date().timeIntervalSinceReferenceDate
        cancelPendingSequence()
    }

    /// Consumes one frame of touches: updates live sessions, finalizes lifted ones,
    /// and advances any pending multi-tap sequence.
    public func process(_ frame: TouchFrame) {
        // Hovering touches are invisible to tap detection.
        let contacting = frame.touches.filter { $0.phase != .hovering }
        let concurrentCount = contacting.count

        // A multi-finger frame is non-tap activity (scroll, pinch, draw): drop any
        // taps queued up before it so they can't fire mid-gesture.
        if concurrentCount >= 2 {
            cancelPendingSequence()
        }

        var ended: [Session] = []
        var liveIDs = Set<Int32>()

        for touch in contacting {
            if var session = sessions[touch.id] {
                session.maxMovement = max(
                    session.maxMovement,
                    hypot(touch.x - session.startX, touch.y - session.startY)
                )
                session.maxConcurrent = max(session.maxConcurrent, concurrentCount)
                if touch.phase == .leaving {
                    sessions[touch.id] = nil
                    ended.append(session)
                } else {
                    sessions[touch.id] = session
                    liveIDs.insert(touch.id)
                }
            } else if touch.phase != .leaving {
                sessions[touch.id] = Session(
                    startX: touch.x,
                    startY: touch.y,
                    startTime: frame.timestamp,
                    maxMovement: 0,
                    maxConcurrent: concurrentCount
                )
                liveIDs.insert(touch.id)
            }
        }

        // Sessions whose id vanished from the frame have also ended.
        for (id, session) in sessions where !liveIDs.contains(id) {
            sessions[id] = nil
            ended.append(session)
        }

        for session in ended {
            evaluate(session, endedAt: frame.timestamp)
        }
    }

    /// Clears all in-flight sessions and pending sequences and cancels timers.
    /// Nothing fires.
    public func reset() {
        sessions.removeAll()
        cancelPendingSequence()
    }

    // MARK: - Session tracking

    /// Lifetime record of a single touch id across frames.
    private struct Session {
        let startX: Double
        let startY: Double
        let startTime: TimeInterval
        var maxMovement: Double
        var maxConcurrent: Int
    }

    /// An in-progress multi-tap accumulation awaiting either more taps or window expiry.
    private struct PendingSequence {
        let zone: TapZone
        var count: Int
        var lastTapTime: TimeInterval
    }

    private var sessions: [Int32: Session] = [:]
    private var pending: PendingSequence?
    private var windowTask: Task<Void, Never>?
    /// Most recent physical mouse-down, from `notePhysicalClick()`.
    private var lastClickTime: TimeInterval = -.infinity

    private func evaluate(_ session: Session, endedAt endTime: TimeInterval) {
        let duration = endTime - session.startTime
        // A click that landed during (or a hair before) this session means the
        // touch was a physical click, not a light tap. Small leading margin
        // covers monitor-vs-frame timing skew.
        let clickedDuringSession = lastClickTime >= session.startTime - 0.05
        let isTap = duration < tapMaxDuration
            && session.maxMovement < tapMaxMovement
            && !clickedDuringSession
            && session.maxConcurrent == 1

        guard isTap else {
            // A drag, long press, click, or multi-finger participant just ended:
            // that's non-tap activity, so any queued sequence is stale.
            cancelPendingSequence()
            return
        }

        registerTap(in: zone(forX: session.startX, y: session.startY), at: endTime)
    }

    // MARK: - Multi-tap accumulation

    private func registerTap(in zone: TapZone, at time: TimeInterval) {
        let maxCount = maxTapCountProvider?(zone) ?? 1
        guard maxCount > 0 else { return } // Zone unbound: ignore entirely.

        if var sequence = pending {
            if sequence.zone == zone, time - sequence.lastTapTime <= multiTapWindow {
                sequence.count += 1
                sequence.lastTapTime = time
                pending = sequence
            } else {
                // Different zone (or stale window): resolve the old sequence now.
                finalizePendingSequence()
                pending = PendingSequence(zone: zone, count: 1, lastTapTime: time)
            }
        } else {
            pending = PendingSequence(zone: zone, count: 1, lastTapTime: time)
        }

        guard let sequence = pending else { return }

        if sequence.count >= maxCount {
            // No higher-count binding could match: fire immediately for snappiness.
            finalizePendingSequence()
        } else {
            restartWindowTimer()
        }
    }

    private func restartWindowTimer() {
        windowTask?.cancel()
        let window = multiTapWindow
        windowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled else { return }
            self?.finalizePendingSequence()
        }
    }

    /// Fires `onTap` for the pending sequence (if any) and clears it.
    private func finalizePendingSequence() {
        windowTask?.cancel()
        windowTask = nil
        guard let sequence = pending else { return }
        pending = nil
        onTap?(sequence.zone, sequence.count)
    }

    /// Discards the pending sequence without firing.
    private func cancelPendingSequence() {
        windowTask?.cancel()
        windowTask = nil
        pending = nil
    }

    // MARK: - Zone geometry

    /// Maps a start position (normalized, y-up) to its tap zone. Corners are
    /// `cornerWidth` × `cornerHeight` rectangles (defaults 30% × 40%) and take
    /// precedence over the halves.
    private func zone(forX x: Double, y: Double) -> TapZone {
        if x < cornerWidth && y > 1 - cornerHeight { return .topLeftCorner }
        if x > 1 - cornerWidth && y > 1 - cornerHeight { return .topRightCorner }
        if x < cornerWidth && y < cornerHeight { return .bottomLeftCorner }
        if x > 1 - cornerWidth && y < cornerHeight { return .bottomRightCorner }
        return x < 0.5 ? .leftHalf : .rightHalf
    }
}
