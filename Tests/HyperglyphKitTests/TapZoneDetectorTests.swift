import Foundation
import Testing
@testable import HyperglyphKit

/// Headless tap-zone tests. Frame timestamps are synthetic; the multi-tap
/// window timer is a real main-actor Task, so tests that rely on window expiry
/// `await Task.sleep(...)` — the suite is main-actor isolated (package default
/// isolation), so sleeping suspends and lets the detector's timer task run.
/// Where possible we assert via the synchronous immediate-fire path instead.
@Suite struct TapZoneDetectorTests {

    /// Detector with a short multi-tap window (for fast timer tests) and a
    /// capture array recording every onTap firing.
    private func makeDetector(
        window: Double = 0.15,
        maxTaps: ((TapZone) -> Int)? = nil
    ) -> (TapZoneDetector, () -> [(TapZone, Int)]) {
        let detector = TapZoneDetector()
        detector.multiTapWindow = window
        detector.maxTapCountProvider = maxTaps
        var fired: [(TapZone, Int)] = []
        detector.onTap = { zone, count in fired.append((zone, count)) }
        return (detector, { fired })
    }

    // MARK: Basic taps

    @Test func singleTapLeftHalfFiresAfterWindow() async throws {
        // Provider allows up to 2 taps, so a single tap must wait out the window.
        let (detector, fired) = makeDetector(maxTaps: { _ in 2 })
        feedTap(into: detector, x: 0.35, y: 0.5, downAt: 0)
        #expect(fired().isEmpty, "must not fire before the multi-tap window expires")

        try await Task.sleep(for: .milliseconds(500))
        #expect(fired().count == 1)
        #expect(fired().first?.0 == .leftHalf)
        #expect(fired().first?.1 == 1)
    }

    @Test func singleTapFiresImmediatelyWhenMaxIsOne() {
        // Default provider (nil) treats every zone as single-tap: synchronous fire.
        let (detector, fired) = makeDetector(maxTaps: nil)
        feedTap(into: detector, x: 0.35, y: 0.5, downAt: 0)
        #expect(fired().count == 1)
        #expect(fired().first?.0 == .leftHalf)
        #expect(fired().first?.1 == 1)
    }

    @Test func doubleTapFiresImmediatelyAtMaxCount() {
        let (detector, fired) = makeDetector(maxTaps: { _ in 2 })
        feedTap(into: detector, x: 0.35, y: 0.5, downAt: 0)
        #expect(fired().isEmpty)
        // Second tap inside the window: count reaches the max bound -> immediate fire.
        feedTap(into: detector, x: 0.36, y: 0.51, downAt: 0.12)
        #expect(fired().count == 1)
        #expect(fired().first?.0 == .leftHalf)
        #expect(fired().first?.1 == 2)
    }

    // MARK: Disqualifiers

    @Test func movementAboveThresholdDoesNotFire() async throws {
        let (detector, fired) = makeDetector()
        detector.process(makeFrame([makeTouch(x: 0.3, y: 0.5, phase: .starting)], t: 0))
        detector.process(makeFrame([makeTouch(x: 0.36, y: 0.5, phase: .touching)], t: 0.03)) // moved 0.06 > 0.02
        detector.process(makeFrame([makeTouch(x: 0.36, y: 0.5, phase: .leaving)], t: 0.06))
        try await Task.sleep(for: .milliseconds(300))
        #expect(fired().isEmpty)
    }

    @Test func physicalClickDoesNotFire() async throws {
        let (detector, fired) = makeDetector()
        // Real mouse-down during the touch session marks it as a click, not a tap.
        detector.process(makeFrame([makeTouch(x: 0.3, y: 0.5, phase: .starting)], t: 0))
        detector.notePhysicalClick()
        detector.process(makeFrame([makeTouch(x: 0.3, y: 0.5, phase: .leaving)], t: 0.08))
        try await Task.sleep(for: .milliseconds(300))
        #expect(fired().isEmpty)
    }

    @Test func longPressDoesNotFire() async throws {
        let (detector, fired) = makeDetector()
        feedTap(into: detector, x: 0.3, y: 0.5, downAt: 0, duration: 0.4) // > tapMaxDuration 0.25
        try await Task.sleep(for: .milliseconds(300))
        #expect(fired().isEmpty)
    }

    @Test func twoSimultaneousFingersDoNotFire() async throws {
        let (detector, fired) = makeDetector()
        detector.process(makeFrame([
            makeTouch(id: 1, x: 0.3, y: 0.5, phase: .starting),
            makeTouch(id: 2, x: 0.4, y: 0.5, phase: .starting),
        ], t: 0))
        detector.process(makeFrame([
            makeTouch(id: 1, x: 0.3, y: 0.5, phase: .leaving),
            makeTouch(id: 2, x: 0.4, y: 0.5, phase: .leaving),
        ], t: 0.05))
        try await Task.sleep(for: .milliseconds(300))
        #expect(fired().isEmpty)
    }

    @Test func unboundZoneIsSilent() async throws {
        let (detector, fired) = makeDetector(maxTaps: { _ in 0 })
        feedTap(into: detector, x: 0.35, y: 0.5, downAt: 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fired().isEmpty)
    }

    // MARK: Zone geometry (y-UP: y = 0 is the bottom edge)

    @Test func cornerCoordinateMapsToTopLeftCorner() {
        let (detector, fired) = makeDetector(maxTaps: nil) // immediate fire
        feedTap(into: detector, x: 0.1, y: 0.9, downAt: 0)
        #expect(fired().first?.0 == .topLeftCorner)
    }

    @Test func allFourCornersMapCorrectly() {
        let cases: [(x: Double, y: Double, zone: TapZone)] = [
            (0.1, 0.9, .topLeftCorner),
            (0.9, 0.9, .topRightCorner),
            (0.1, 0.1, .bottomLeftCorner),
            (0.9, 0.1, .bottomRightCorner),
        ]
        for (i, c) in cases.enumerated() {
            let (detector, fired) = makeDetector(maxTaps: nil)
            feedTap(into: detector, x: c.x, y: c.y, downAt: Double(i))
            #expect(fired().first?.0 == c.zone, "(\(c.x), \(c.y)) should be \(c.zone)")
        }
    }

    @Test func centerBoundaryIsRightHalf() {
        // x < 0.5 is left, so exactly 0.5 lands in the right half.
        let (detector, fired) = makeDetector(maxTaps: nil)
        feedTap(into: detector, x: 0.5, y: 0.5, downAt: 0)
        #expect(fired().first?.0 == .rightHalf)
    }

    @Test func justLeftOfCenterIsLeftHalf() {
        let (detector, fired) = makeDetector(maxTaps: nil)
        feedTap(into: detector, x: 0.499, y: 0.5, downAt: 0)
        #expect(fired().first?.0 == .leftHalf)
    }

    // MARK: Reset

    @Test func resetClearsPendingSequenceWithoutFiring() async throws {
        let (detector, fired) = makeDetector(maxTaps: { _ in 3 })
        feedTap(into: detector, x: 0.35, y: 0.5, downAt: 0)
        detector.reset()
        try await Task.sleep(for: .milliseconds(400))
        #expect(fired().isEmpty)
    }
}
