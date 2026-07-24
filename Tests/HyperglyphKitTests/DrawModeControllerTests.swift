import Foundation
import Testing
@testable import HyperglyphKit

/// Headless draw-mode state machine tests. Arming is driven purely through
/// synthetic frame timestamps (the frame-timestamp dwell path), so no real
/// waiting is required to arm.
@Suite struct DrawModeControllerTests {

    private final class Capture {
        var armedCount = 0
        var updates: [[StrokePoint]] = []
        var ended: [[StrokePoint]] = []
        var cancelledCount = 0
    }

    private func makeController() -> (DrawModeController, Capture) {
        let controller = DrawModeController()
        let capture = Capture()
        controller.onArmed = { capture.armedCount += 1 }
        controller.onStrokeUpdate = { capture.updates.append($0) }
        controller.onStrokeEnded = { capture.ended.append($0) }
        controller.onCancelled = { capture.cancelledCount += 1 }
        return (controller, capture)
    }

    private func twoFingers(x1: Double, y1: Double, x2: Double, y2: Double,
                            phase: TouchPhase = .touching) -> [TouchPoint] {
        [makeTouch(id: 1, x: x1, y: y1, phase: phase),
         makeTouch(id: 2, x: x2, y: y2, phase: phase)]
    }

    /// Feeds a still two-finger dwell via frame timestamps: t = 0, 0.05, 0.1, 0.16
    /// (dwellSeconds defaults to 0.15, so the last frame arms synchronously).
    private func armViaFrames(_ controller: DrawModeController) {
        for t in [0.0, 0.05, 0.10, 0.16] {
            controller.process(makeFrame(twoFingers(x1: 0.40, y1: 0.50, x2: 0.50, y2: 0.50), t: t))
        }
    }

    // MARK: Arming

    @Test func twoStillFingersArmViaFrameTimestamps() {
        let (controller, capture) = makeController()
        armViaFrames(controller)
        #expect(capture.armedCount == 1)
        #expect(controller.isArmed)
        #expect(controller.isTracking)
        #expect(capture.ended.isEmpty)
        #expect(capture.cancelledCount == 0)
    }

    @Test func instantModeArmsImmediatelyAndCapturesMovingStroke() {
        let (controller, capture) = makeController()
        controller.requiresDwell = false
        // Fingers land and IMMEDIATELY move (a dwell-mode scroll) — instant mode
        // must arm on touch-down and record the whole motion as a stroke.
        controller.process(makeFrame(twoFingers(x1: 0.20, y1: 0.30, x2: 0.30, y2: 0.30, phase: .starting), t: 0))
        #expect(capture.armedCount == 1)
        #expect(controller.isArmed)
        var t = 0.0
        for step in 1...20 {
            t = Double(step) * 0.016
            let dx = Double(step) * 0.02
            controller.process(makeFrame(twoFingers(x1: 0.20 + dx, y1: 0.30, x2: 0.30 + dx, y2: 0.30), t: t))
        }
        controller.process(makeFrame([], t: t + 0.016))
        #expect(capture.ended.count == 1)
        #expect((capture.ended.first?.count ?? 0) >= 8)
        #expect(!controller.isTracking) // pad observed clear -> straight back to idle
    }

    // MARK: Stroke recording and delivery

    @Test func strokeGrowsWhileArmedAndEndsOnLift() {
        let (controller, capture) = makeController()
        armViaFrames(controller)
        #expect(capture.armedCount == 1)

        // Move the pair rightward 0.01 per frame for 14 frames (centroid path 0.14).
        var t = 0.18
        for i in 1...14 {
            let dx = Double(i) * 0.01
            controller.process(makeFrame(
                twoFingers(x1: 0.40 + dx, y1: 0.50, x2: 0.50 + dx, y2: 0.50), t: t
            ))
            t += 0.02
        }
        #expect(!capture.updates.isEmpty)
        #expect(capture.updates.count == 14, "each spaced centroid move should emit one update")
        // Updates must be monotonically growing snapshots of the stroke.
        for i in 1..<capture.updates.count {
            #expect(capture.updates[i].count > capture.updates[i - 1].count)
        }

        // Lift one finger: the stroke ends and qualifies as a draw.
        controller.process(makeFrame([
            makeTouch(id: 1, x: 0.54, y: 0.50, phase: .touching),
            makeTouch(id: 2, x: 0.64, y: 0.50, phase: .leaving),
        ], t: t))

        #expect(capture.ended.count == 1)
        #expect((capture.ended.first?.count ?? 0) >= 8)
        #expect(capture.cancelledCount == 0)
        #expect(!controller.isArmed)
    }

    @Test func shortArmedStrokeIsCancelledNotDelivered() {
        // Arm, then lift immediately: a long-press, not a draw.
        let (controller, capture) = makeController()
        armViaFrames(controller)
        controller.process(makeFrame([
            makeTouch(id: 1, x: 0.40, y: 0.50, phase: .leaving),
            makeTouch(id: 2, x: 0.50, y: 0.50, phase: .leaving),
        ], t: 0.2))
        #expect(capture.ended.isEmpty)
        #expect(capture.cancelledCount == 1)
    }

    // MARK: Scroll rejection

    @Test func immediatelyMovingFingersNeverArm() async throws {
        // A two-finger scroll: continuous movement from the very first frames,
        // spanning a full second of frame time. Must never arm.
        let (controller, capture) = makeController()
        var t = 0.0
        var y = 0.30
        while t <= 1.0 {
            controller.process(makeFrame(twoFingers(x1: 0.45, y1: y, x2: 0.55, y2: y), t: t))
            t += 0.03
            y += 0.02
        }
        #expect(capture.armedCount == 0)
        #expect(!controller.isArmed)
        #expect(controller.isTracking, "scroll holds the disqualified-until-clear state")

        // Also outlast the real-time dwell task (dwellSeconds = 0.15) to prove the
        // sleeping arm path was correctly invalidated.
        try await Task.sleep(for: .milliseconds(400))
        #expect(capture.armedCount == 0)

        // Pad clears -> back to idle, still without callbacks.
        controller.process(makeFrame([], t: t))
        #expect(!controller.isTracking)
        #expect(capture.armedCount == 0)
        #expect(capture.cancelledCount == 0)
        #expect(capture.ended.isEmpty)
    }

    @Test func scrollCannotReArmMidMotionEvenWhenItPauses() async throws {
        // Scroll, then hold perfectly still past the dwell: must stay disqualified
        // until the pad fully clears.
        let (controller, capture) = makeController()
        controller.process(makeFrame(twoFingers(x1: 0.45, y1: 0.30, x2: 0.55, y2: 0.30), t: 0))
        controller.process(makeFrame(twoFingers(x1: 0.45, y1: 0.40, x2: 0.55, y2: 0.40), t: 0.03))
        // Now hold still, with frame time well past dwellSeconds.
        for t in [0.1, 0.2, 0.3, 0.5] {
            controller.process(makeFrame(twoFingers(x1: 0.45, y1: 0.40, x2: 0.55, y2: 0.40), t: t))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(capture.armedCount == 0)
    }

    // MARK: Third finger

    @Test func thirdFingerWhileArmedCancels() {
        let (controller, capture) = makeController()
        armViaFrames(controller)
        #expect(capture.armedCount == 1)

        controller.process(makeFrame([
            makeTouch(id: 1, x: 0.40, y: 0.50),
            makeTouch(id: 2, x: 0.50, y: 0.50),
            makeTouch(id: 3, x: 0.60, y: 0.50, phase: .starting),
        ], t: 0.2))

        #expect(capture.cancelledCount == 1)
        #expect(capture.ended.isEmpty)
        #expect(!controller.isArmed)
    }

    // MARK: Reset

    @Test func resetFiresNoCallbacks() async throws {
        let (controller, capture) = makeController()
        // Mid-candidate reset.
        controller.process(makeFrame(twoFingers(x1: 0.40, y1: 0.50, x2: 0.50, y2: 0.50), t: 0))
        controller.reset()
        #expect(!controller.isTracking)
        #expect(!controller.isArmed)

        // Mid-armed reset.
        armViaFrames(controller)
        #expect(capture.armedCount == 1)
        controller.reset()
        #expect(!controller.isArmed)
        #expect(!controller.isTracking)

        // Outlast any real-time dwell tasks: nothing may fire late.
        try await Task.sleep(for: .milliseconds(400))
        #expect(capture.armedCount == 1)
        #expect(capture.ended.isEmpty)
        #expect(capture.cancelledCount == 0)
    }
}
