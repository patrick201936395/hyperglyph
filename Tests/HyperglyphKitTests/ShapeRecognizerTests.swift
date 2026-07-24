import Foundation
import Testing
@testable import HyperglyphKit

/// Headless recognition tests: synthetic strokes are generated geometrically
/// (slightly different radii/anchors than the shipped templates, plus
/// deterministic sin jitter) and must match the intended built-in shape.
/// All coordinates are normalized 0...1, y-UP.
@Suite struct ShapeRecognizerTests {

    private let threshold = 0.8

    private func recognize(_ stroke: [StrokePoint], custom: [CustomTemplate] = []) -> RecognitionResult? {
        ShapeRecognizer().recognize(stroke, threshold: threshold, customTemplates: custom)
    }

    private func expectShape(_ stroke: [StrokePoint], _ name: String,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let result = recognize(stroke)
        #expect(result != nil, "stroke for \(name) was not recognized at all", sourceLocation: sourceLocation)
        #expect(result?.name == name, "expected \(name), got \(result?.name ?? "nil") (score \(result?.score ?? 0))", sourceLocation: sourceLocation)
        #expect((result?.score ?? 0) >= threshold, sourceLocation: sourceLocation)
    }

    // MARK: Letters

    @Test func recognizesC() {
        // Open arc starting top-right, sweeping CCW over the top to bottom-right.
        let stroke = jittered(arcPoints(
            center: StrokePoint(x: 0.52, y: 0.48), radius: 0.37,
            fromDegrees: 63, toDegrees: 297, steps: 48
        ))
        expectShape(stroke, "C")
    }

    @Test func recognizesO() {
        // Full circle starting at the top, CCW, slightly off-center.
        let stroke = jittered(arcPoints(
            center: StrokePoint(x: 0.48, y: 0.52), radius: 0.36,
            fromDegrees: 90, toDegrees: 448, steps: 60
        ), amplitude: 0.003)
        expectShape(stroke, "O")
    }

    @Test func recognizesS() {
        let stroke = jittered(joinedStroke(
            arcPoints(center: StrokePoint(x: 0.5, y: 0.71), radius: 0.21,
                      fromDegrees: 45, toDegrees: 270, steps: 26),
            arcPoints(center: StrokePoint(x: 0.5, y: 0.29), radius: 0.21,
                      fromDegrees: 90, toDegrees: -135, steps: 26)
        ), amplitude: 0.003)
        expectShape(stroke, "S")
    }

    @Test func recognizesZ() {
        let stroke = jittered(joinedStroke(
            linePoints(from: StrokePoint(x: 0.12, y: 0.83), to: StrokePoint(x: 0.88, y: 0.83), steps: 18),
            linePoints(from: StrokePoint(x: 0.88, y: 0.83), to: StrokePoint(x: 0.12, y: 0.17), steps: 24),
            linePoints(from: StrokePoint(x: 0.12, y: 0.17), to: StrokePoint(x: 0.88, y: 0.17), steps: 18)
        ))
        expectShape(stroke, "Z")
    }

    @Test func recognizesV() {
        let stroke = jittered(joinedStroke(
            linePoints(from: StrokePoint(x: 0.17, y: 0.84), to: StrokePoint(x: 0.5, y: 0.12), steps: 26),
            linePoints(from: StrokePoint(x: 0.5, y: 0.12), to: StrokePoint(x: 0.83, y: 0.84), steps: 26)
        ))
        expectShape(stroke, "V")
    }

    @Test func recognizesL() {
        let stroke = jittered(joinedStroke(
            linePoints(from: StrokePoint(x: 0.22, y: 0.88), to: StrokePoint(x: 0.22, y: 0.12), steps: 28),
            linePoints(from: StrokePoint(x: 0.22, y: 0.12), to: StrokePoint(x: 0.83, y: 0.12), steps: 24)
        ))
        expectShape(stroke, "L")
    }

    @Test func recognizesN() {
        let stroke = jittered(joinedStroke(
            linePoints(from: StrokePoint(x: 0.17, y: 0.12), to: StrokePoint(x: 0.17, y: 0.88), steps: 18),
            linePoints(from: StrokePoint(x: 0.17, y: 0.88), to: StrokePoint(x: 0.83, y: 0.12), steps: 24),
            linePoints(from: StrokePoint(x: 0.83, y: 0.12), to: StrokePoint(x: 0.83, y: 0.88), steps: 18)
        ))
        expectShape(stroke, "N")
    }

    @Test func recognizesCheck() {
        let stroke = jittered(joinedStroke(
            linePoints(from: StrokePoint(x: 0.21, y: 0.49), to: StrokePoint(x: 0.43, y: 0.21), steps: 16),
            linePoints(from: StrokePoint(x: 0.43, y: 0.21), to: StrokePoint(x: 0.84, y: 0.83), steps: 30)
        ))
        expectShape(stroke, "Check")
    }

    @Test func recognizesHeart() {
        // Left-lobe-first heart, geometry near (but not identical to) the template.
        let leftCenter = StrokePoint(x: 0.31, y: 0.73)
        let rightCenter = StrokePoint(x: 0.69, y: 0.73)
        let lobeRadius = 0.2
        let bottom = StrokePoint(x: 0.5, y: 0.08)
        let leftExit = circlePoint(center: leftCenter, radius: lobeRadius, degrees: 210)
        let rightEntry = circlePoint(center: rightCenter, radius: lobeRadius, degrees: -30)

        let stroke = jittered(joinedStroke(
            arcPoints(center: leftCenter, radius: lobeRadius, fromDegrees: -10, toDegrees: 210, steps: 18),
            linePoints(from: leftExit, to: bottom, steps: 12),
            linePoints(from: bottom, to: rightEntry, steps: 12),
            arcPoints(center: rightCenter, radius: lobeRadius, fromDegrees: -30, toDegrees: 190, steps: 18)
        ), amplitude: 0.003)
        expectShape(stroke, "Heart")
    }

    // MARK: Flick fast path / adversarial straight strokes

    @Test func verticalUpStrokeIsFlickUpNeverALetter() {
        // Two-finger-scroll-like straight stroke going UP (y increases, y-UP coords).
        let stroke = jittered(
            linePoints(from: StrokePoint(x: 0.5, y: 0.2), to: StrokePoint(x: 0.5, y: 0.8), steps: 24),
            amplitude: 0.002
        )
        let result = recognize(stroke)
        #expect(result?.name == "Flick Up")
        #expect(result?.score == 1.0)
    }

    @Test func verticalDownStrokeIsFlickDown() {
        let stroke = jittered(
            linePoints(from: StrokePoint(x: 0.5, y: 0.8), to: StrokePoint(x: 0.5, y: 0.2), steps: 24),
            amplitude: 0.002
        )
        let result = recognize(stroke)
        #expect(result?.name == "Flick Down")
        #expect(result?.score == 1.0)
    }

    @Test func horizontalStrokesAreFlicksLeftAndRight() {
        let right = recognize(linePoints(from: StrokePoint(x: 0.2, y: 0.5), to: StrokePoint(x: 0.8, y: 0.5), steps: 24))
        #expect(right?.name == "Flick Right")
        let left = recognize(linePoints(from: StrokePoint(x: 0.8, y: 0.5), to: StrokePoint(x: 0.2, y: 0.5), steps: 24))
        #expect(left?.name == "Flick Left")
    }

    @Test func diagonalStraightLineReturnsNil() {
        // 45° off every axis: must be rejected outright, not mangled into L/V/Check.
        let stroke = linePoints(from: StrokePoint(x: 0.2, y: 0.2), to: StrokePoint(x: 0.8, y: 0.8), steps: 24)
        #expect(recognize(stroke) == nil)
    }

    // MARK: Degenerate inputs — must not crash

    @Test func emptyStrokeDoesNotCrash() {
        #expect(recognize([]) == nil)
    }

    @Test func singlePointStrokeDoesNotCrash() {
        #expect(recognize([StrokePoint(x: 0.3, y: 0.3)]) == nil)
    }

    @Test func tinyThreePointStrokeDoesNotCrash() {
        let stroke = [
            StrokePoint(x: 0.5, y: 0.5),
            StrokePoint(x: 0.501, y: 0.5),
            StrokePoint(x: 0.5, y: 0.501),
        ]
        let result = recognize(stroke)
        // Any non-crashing answer is acceptable; if something matched, the score must be sane.
        if let result { #expect(result.score.isFinite) }
    }

    @Test func zeroLengthMultiPointStrokeDoesNotCrash() {
        let stroke = Array(repeating: StrokePoint(x: 0.4, y: 0.4), count: 10)
        #expect(recognize(stroke) == nil)
    }

    @Test func perfectlyHorizontalWiggleDoesNotCrashScaleToSquare() {
        // Back-and-forth purely horizontal stroke: straightness is low so it reaches
        // the $1 pipeline with a zero-height bounding box (NaN guard territory).
        let stroke = joinedStroke(
            linePoints(from: StrokePoint(x: 0.2, y: 0.5), to: StrokePoint(x: 0.8, y: 0.5), steps: 20),
            linePoints(from: StrokePoint(x: 0.8, y: 0.5), to: StrokePoint(x: 0.4, y: 0.5), steps: 14)
        )
        let result = recognize(stroke)
        if let result { #expect(result.score.isFinite) }
    }

    // MARK: Custom template round-trip

    @Test func customTemplateRoundTrip() {
        // "Record" a triangle-ish sample...
        let sample = joinedStroke(
            linePoints(from: StrokePoint(x: 0.2, y: 0.2), to: StrokePoint(x: 0.5, y: 0.85), steps: 20),
            linePoints(from: StrokePoint(x: 0.5, y: 0.85), to: StrokePoint(x: 0.8, y: 0.2), steps: 20),
            linePoints(from: StrokePoint(x: 0.8, y: 0.2), to: StrokePoint(x: 0.23, y: 0.2), steps: 18)
        )
        let template = CustomTemplate(name: "Triangle", symbol: "△", samples: [sample])

        // ...then draw a similar (jittered, slightly shifted) stroke.
        let drawn = jittered(joinedStroke(
            linePoints(from: StrokePoint(x: 0.22, y: 0.22), to: StrokePoint(x: 0.51, y: 0.83), steps: 20),
            linePoints(from: StrokePoint(x: 0.51, y: 0.83), to: StrokePoint(x: 0.79, y: 0.22), steps: 20),
            linePoints(from: StrokePoint(x: 0.79, y: 0.22), to: StrokePoint(x: 0.25, y: 0.22), steps: 18)
        ))

        let result = recognize(drawn, custom: [template])
        #expect(result?.name == "Triangle")
        #expect(result?.symbol == "△")
        #expect((result?.score ?? 0) >= threshold)
    }
}
