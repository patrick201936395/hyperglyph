import Foundation

/// Detects the two-finger "dwell to arm" drawing gesture and tracks the resulting stroke.
///
/// State machine:
/// ```
/// idle ──(exactly 2 active touches)──▶ candidate
/// candidate ──(both still for dwellSeconds)──▶ armed
/// candidate ──(movement / extra finger)──▶ disqualified
/// armed ──(finger lifted → stroke ends, or extra finger → cancel)──▶ disqualified
/// disqualified ──(pad fully clears)──▶ idle
/// ```
/// The `disqualified` holding state guarantees that a scroll or an aborted draw can
/// never re-arm mid-motion: nothing new starts until every finger leaves the pad.
///
/// Dwell completion is detected both from incoming frame timestamps and from an
/// independent sleeping task, because MultitouchSupport stops delivering frames when
/// fingers are perfectly still — exactly the moment we need to arm.
///
/// All coordinates are normalized 0...1, y-up (matching raw MultitouchSupport data).
public final class DrawModeController {

    // MARK: - Callbacks

    /// Fired once when the two-finger dwell completes and draw mode arms.
    public var onArmed: (() -> Void)?

    /// Fired on each frame while armed, with the full stroke so far (centroid path).
    public var onStrokeUpdate: (([StrokePoint]) -> Void)?

    /// Fired when an armed stroke ends and qualifies as an intentional draw
    /// (at least 8 points and total path length > 0.06 normalized).
    public var onStrokeEnded: (([StrokePoint]) -> Void)?

    /// Fired when an armed session is abandoned: an extra finger landed, or the
    /// stroke ended too short to count as a draw (i.e. it was just a long-press).
    public var onCancelled: (() -> Void)?

    // MARK: - Public state

    /// True from the moment the dwell completes until the stroke ends or is cancelled.
    public private(set) var isArmed: Bool = false

    /// True from the first two-finger candidate frame until the pad fully clears.
    /// The coordinator uses this to suppress tap-zone detection during draws/scrolls.
    public private(set) var isTracking: Bool = false

    // MARK: - Tunables

    /// When false ("instant draw"), two fingers landing arms IMMEDIATELY — no
    /// dwell, no stillness check. Every two-finger motion becomes a candidate
    /// stroke; the recognizer decides on lift whether it was a shape. The
    /// coordinator keeps arm haptics/scroll-suppression off in this mode so
    /// normal scrolling is unaffected.
    public var requiresDwell: Bool = true

    /// Seconds two fingers must stay still before draw mode arms.
    public var dwellSeconds: Double = 0.15

    /// Maximum normalized movement either finger may make during the dwell;
    /// exceeding it classifies the gesture as a scroll and disqualifies it.
    public var stillnessThreshold: Double = 0.015

    // MARK: - Private state

    private enum State {
        case idle
        /// Two fingers down; waiting out the dwell to decide draw vs. scroll.
        case candidate
        /// Dwell completed; recording the centroid stroke.
        case armed
        /// Gesture rejected or finished; ignore everything until the pad clears.
        case disqualifiedUntilClear
    }

    private var state: State = .idle {
        didSet { isTracking = state != .idle }
    }

    /// Start position of each candidate finger, keyed by touch identifier.
    private var startPositions: [Int32: StrokePoint] = [:]
    /// Most recent position of each candidate finger, for arming between frames.
    private var lastPositions: [Int32: StrokePoint] = [:]
    /// `TouchFrame.timestamp` of the frame that started the candidate.
    private var candidateStartTime: TimeInterval = 0
    /// The stroke recorded while armed (centroid of the two fingers).
    private var stroke: [StrokePoint] = []

    /// Invalidates in-flight dwell tasks whenever the state machine moves.
    private var generation: UInt64 = 0
    private var dwellTask: Task<Void, Never>?

    /// Minimum centroid movement (normalized) before a new stroke point is appended.
    private let minPointSpacing: Double = 0.004
    /// Minimum stroke point count for a valid draw.
    private let minStrokePoints = 8
    /// Minimum total path length (normalized) for a valid draw.
    private let minStrokeLength: Double = 0.06

    // MARK: - Public API

    public init() {}

    /// Feeds one touch frame through the state machine. Call for every frame,
    /// regardless of state; the controller ignores what it doesn't need.
    public func process(_ frame: TouchFrame) {
        let active = frame.touches.filter { isActive($0.phase) }

        switch state {
        case .idle:
            guard active.count == 2 else { return }
            beginCandidate(with: active, at: frame.timestamp)

        case .candidate:
            processCandidate(active: active, at: frame.timestamp)

        case .armed:
            processArmed(active: active)

        case .disqualifiedUntilClear:
            if active.isEmpty {
                transition(to: .idle)
            }
        }
    }

    /// Returns the controller to `idle` immediately. Cancels any pending dwell task
    /// and fires no callbacks — the caller is expected to clean up its own UI state.
    public func reset() {
        cancelDwellTask()
        bumpGeneration()
        isArmed = false
        startPositions = [:]
        lastPositions = [:]
        stroke = []
        state = .idle
    }

    // MARK: - Candidate

    private func beginCandidate(with touches: [TouchPoint], at timestamp: TimeInterval) {
        startPositions = [:]
        lastPositions = [:]
        for touch in touches {
            let point = StrokePoint(x: touch.x, y: touch.y)
            startPositions[touch.id] = point
            lastPositions[touch.id] = point
        }
        candidateStartTime = timestamp
        stroke = []
        if requiresDwell {
            transition(to: .candidate)
            scheduleDwellTask()
        } else {
            // Instant draw: arm on touch-down and start the stroke right away
            // (lastPositions was just seeded above).
            arm()
        }
    }

    private func processCandidate(active: [TouchPoint], at timestamp: TimeInterval) {
        // Finger count changed: silently drop the candidate.
        guard active.count == 2 else {
            cancelDwellTask()
            bumpGeneration()
            transition(to: active.isEmpty ? .idle : .disqualifiedUntilClear)
            return
        }

        // Any movement past the stillness threshold means this is a scroll.
        // Stay disqualified until the pad clears so a scroll never arms mid-motion.
        for touch in active {
            guard let start = startPositions[touch.id] else {
                // A finger was swapped within a single frame — not a stable candidate.
                disqualifyCandidate()
                return
            }
            let current = StrokePoint(x: touch.x, y: touch.y)
            lastPositions[touch.id] = current
            if distance(start, current) > stillnessThreshold {
                disqualifyCandidate()
                return
            }
        }

        // Both fingers still and the dwell has elapsed: arm.
        if timestamp - candidateStartTime >= dwellSeconds {
            arm()
        }
    }

    private func disqualifyCandidate() {
        cancelDwellTask()
        bumpGeneration()
        transition(to: .disqualifiedUntilClear)
    }

    // MARK: - Dwell task

    /// Frames pause when fingers are perfectly still, so the frame-timestamp check in
    /// `processCandidate` alone can miss the dwell. This task sleeps out the dwell and
    /// arms if the candidate is still valid, guarded by the generation counter.
    private func scheduleDwellTask() {
        cancelDwellTask()
        let expected = generation
        let delay = dwellSeconds
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard self.generation == expected, self.state == .candidate else { return }
            self.arm()
        }
    }

    private func cancelDwellTask() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    // MARK: - Armed

    private func arm() {
        cancelDwellTask()
        bumpGeneration()
        isArmed = true
        stroke = [centroid(of: Array(lastPositions.values))]
        transition(to: .armed)
        onArmed?()
    }

    private func processArmed(active: [TouchPoint]) {
        if active.count == 2 {
            let center = centroid(of: active.map { StrokePoint(x: $0.x, y: $0.y) })
            if let last = stroke.last, distance(last, center) <= minPointSpacing {
                return
            }
            stroke.append(center)
            onStrokeUpdate?(stroke)
            return
        }

        if active.count > 2 {
            // A third finger landed mid-draw: abandon the stroke.
            endArmedSession(delivering: nil)
            return
        }

        // A finger lifted: the stroke ends. Deliver it only if it was a real draw.
        // If THIS frame already shows the pad empty (e.g. TouchEngine's one-shot
        // synthetic end-of-touch frame), go straight to idle — no further empty
        // frame will arrive to clear a disqualified state.
        let finished = stroke
        let padCleared = active.isEmpty
        if finished.count >= minStrokePoints, pathLength(of: finished) > minStrokeLength {
            endArmedSession(delivering: finished, padCleared: padCleared)
        } else {
            endArmedSession(delivering: nil, padCleared: padCleared)
        }
    }

    /// Leaves the armed state — into idle when the pad is already observed clear,
    /// otherwise into disqualified-until-clear — firing exactly one of
    /// `onStrokeEnded` (when `finishedStroke` is non-nil) or `onCancelled`.
    private func endArmedSession(delivering finishedStroke: [StrokePoint]?, padCleared: Bool = false) {
        bumpGeneration()
        isArmed = false
        stroke = []
        transition(to: padCleared ? .idle : .disqualifiedUntilClear)
        if let finishedStroke {
            onStrokeEnded?(finishedStroke)
        } else {
            onCancelled?()
        }
    }

    // MARK: - Helpers

    private func transition(to newState: State) {
        state = newState
        if newState == .idle {
            startPositions = [:]
            lastPositions = [:]
            stroke = []
        }
    }

    private func bumpGeneration() {
        generation &+= 1
    }

    private nonisolated func isActive(_ phase: TouchPhase) -> Bool {
        switch phase {
        case .starting, .touching, .breaking: return true
        case .hovering, .leaving, .other: return false
        }
    }

    private nonisolated func distance(_ a: StrokePoint, _ b: StrokePoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private nonisolated func centroid(of points: [StrokePoint]) -> StrokePoint {
        guard !points.isEmpty else { return StrokePoint(x: 0.5, y: 0.5) }
        let count = Double(points.count)
        let sumX = points.reduce(0.0) { $0 + $1.x }
        let sumY = points.reduce(0.0) { $0 + $1.y }
        return StrokePoint(x: sumX / count, y: sumY / count)
    }

    private nonisolated func pathLength(of points: [StrokePoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            total += distance(points[i - 1], points[i])
        }
        return total
    }
}
