import Foundation
@testable import HyperglyphKit

// MARK: - Stroke synthesis (all deterministic — no randomness anywhere)

/// Evenly spaced points along a straight segment (endpoints included).
func linePoints(from start: StrokePoint, to end: StrokePoint, steps: Int) -> [StrokePoint] {
    ShapeTemplates.line(from: start, to: end, steps: steps)
}

/// Evenly spaced points along a circular arc. Angles in DEGREES, math
/// convention with y-UP (0 = right, 90 = top). Increasing sweep = CCW.
func arcPoints(center: StrokePoint, radius: Double, fromDegrees: Double, toDegrees: Double, steps: Int) -> [StrokePoint] {
    ShapeTemplates.arc(
        center: center,
        radius: radius,
        startAngle: fromDegrees * .pi / 180,
        endAngle: toDegrees * .pi / 180,
        steps: steps
    )
}

/// Point on a circle at `degrees` (y-UP convention).
func circlePoint(center: StrokePoint, radius: Double, degrees: Double) -> StrokePoint {
    let a = degrees * .pi / 180
    return StrokePoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
}

/// Concatenates stroke segments into one polyline.
func joinedStroke(_ segments: [StrokePoint]...) -> [StrokePoint] {
    var result: [StrokePoint] = []
    for segment in segments {
        if let last = result.last, let first = segment.first, last == first {
            result.append(contentsOf: segment.dropFirst())
        } else {
            result.append(contentsOf: segment)
        }
    }
    return result
}

/// Deterministic sin-based jitter — simulates human wobble without randomness.
func jittered(_ points: [StrokePoint], amplitude: Double = 0.004) -> [StrokePoint] {
    points.enumerated().map { i, p in
        StrokePoint(
            x: p.x + amplitude * sin(Double(i) * 7.31 + 0.5),
            y: p.y + amplitude * cos(Double(i) * 5.17 + 1.1)
        )
    }
}

// MARK: - Touch / frame synthesis

func makeTouch(
    id: Int32 = 1,
    x: Double,
    y: Double,
    pressure: Double = 0.1,
    phase: TouchPhase = .touching
) -> TouchPoint {
    TouchPoint(
        id: id,
        x: x,
        y: y,
        pressure: pressure,
        total: 1.0,
        majorAxis: 5,
        minorAxis: 5,
        density: 1.0,
        phase: phase
    )
}

func makeFrame(_ touches: [TouchPoint], t: TimeInterval) -> TouchFrame {
    TouchFrame(touches: touches, timestamp: t)
}

/// Feeds a complete light-tap sequence (touch down, then lift) for one finger.
/// The lift is delivered as a `.leaving` phase frame.
func feedTap(
    into detector: TapZoneDetector,
    x: Double,
    y: Double,
    downAt t0: TimeInterval,
    duration: Double = 0.05,
    pressure: Double = 0.1,
    id: Int32 = 1
) {
    detector.process(makeFrame([makeTouch(id: id, x: x, y: y, pressure: pressure, phase: .starting)], t: t0))
    detector.process(makeFrame([makeTouch(id: id, x: x, y: y, pressure: pressure, phase: .leaving)], t: t0 + duration))
}
