import Foundation

/// Programmatic geometry for the built-in shape set.
///
/// Every template is generated from small `line`/`arc` primitives rather than
/// stored coordinate dumps. Points are in normalized trackpad space (0...1,
/// y-UP: y = 0 at the bottom edge) and each template is drawn in natural
/// human stroke order, since the $1 recognizer is direction-sensitive.
enum ShapeTemplates {

    // MARK: - Built-in shape catalog

    /// All built-in shapes in display order: letters, symbols, then flicks.
    /// Flick shapes carry no templates — the recognizer matches them with a
    /// straight-line fast path instead of $1.
    static let builtIn: [BuiltInShape] = [
        BuiltInShape(name: "C", symbol: "C", templates: letterC()),
        BuiltInShape(name: "S", symbol: "S", templates: letterS()),
        BuiltInShape(name: "Z", symbol: "Z", templates: letterZ()),
        BuiltInShape(name: "V", symbol: "V", templates: letterV()),
        BuiltInShape(name: "L", symbol: "L", templates: letterL()),
        BuiltInShape(name: "N", symbol: "N", templates: letterN()),
        BuiltInShape(name: "O", symbol: "O", templates: letterO()),
        BuiltInShape(name: "Check", symbol: "✓", templates: check()),
        BuiltInShape(name: "Cross", symbol: "✕", templates: cross()),
        BuiltInShape(name: "Question", symbol: "?", templates: question()),
        BuiltInShape(name: "Heart", symbol: "♡", templates: heart()),
        BuiltInShape(name: "Flick Up", symbol: "↑", templates: []),
        BuiltInShape(name: "Flick Down", symbol: "↓", templates: []),
        BuiltInShape(name: "Flick Left", symbol: "←", templates: []),
        BuiltInShape(name: "Flick Right", symbol: "→", templates: []),
    ]

    /// Preview stroke for a flick shape: a straight line in the flick
    /// direction (y-UP coordinates). Returns nil for non-flick names.
    static func flickPreview(for name: String) -> [StrokePoint]? {
        switch name {
        case "Flick Up":
            return line(from: StrokePoint(x: 0.5, y: 0.15), to: StrokePoint(x: 0.5, y: 0.85), steps: 32)
        case "Flick Down":
            return line(from: StrokePoint(x: 0.5, y: 0.85), to: StrokePoint(x: 0.5, y: 0.15), steps: 32)
        case "Flick Left":
            return line(from: StrokePoint(x: 0.85, y: 0.5), to: StrokePoint(x: 0.15, y: 0.5), steps: 32)
        case "Flick Right":
            return line(from: StrokePoint(x: 0.15, y: 0.5), to: StrokePoint(x: 0.85, y: 0.5), steps: 32)
        default:
            return nil
        }
    }

    // MARK: - Primitives

    /// Evenly spaced points along a straight segment, endpoints included.
    /// `steps` is the number of points produced (minimum 2).
    nonisolated static func line(from start: StrokePoint, to end: StrokePoint, steps: Int) -> [StrokePoint] {
        let count = max(steps, 2)
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return StrokePoint(
                x: start.x + t * (end.x - start.x),
                y: start.y + t * (end.y - start.y)
            )
        }
    }

    /// Evenly spaced points along a circular arc, endpoints included.
    /// Angles are in radians using math convention with y-UP: 0 = right,
    /// π/2 = top. Sweep direction follows the sign of `endAngle - startAngle`
    /// (increasing = counterclockwise). `steps` is the number of points (min 2).
    nonisolated static func arc(
        center: StrokePoint,
        radius: Double,
        startAngle: Double,
        endAngle: Double,
        steps: Int
    ) -> [StrokePoint] {
        let count = max(steps, 2)
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            let angle = startAngle + t * (endAngle - startAngle)
            return StrokePoint(
                x: center.x + radius * Foundation.cos(angle),
                y: center.y + radius * Foundation.sin(angle)
            )
        }
    }

    // MARK: - Composition helpers

    /// Degrees → radians, for readable shape definitions.
    private nonisolated static func deg(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }

    /// Point on a circle at an angle given in degrees (y-UP convention).
    private nonisolated static func onCircle(center: StrokePoint, radius: Double, degrees: Double) -> StrokePoint {
        let angle = deg(degrees)
        return StrokePoint(
            x: center.x + radius * Foundation.cos(angle),
            y: center.y + radius * Foundation.sin(angle)
        )
    }

    /// Concatenates stroke segments, dropping a duplicated joint point when
    /// one segment ends exactly where the next begins.
    private nonisolated static func joined(_ segments: [StrokePoint]...) -> [StrokePoint] {
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

    // MARK: - Letters

    /// C: open arc. Primary variant starts top-right and sweeps over the top,
    /// down the left, ending bottom-right (counterclockwise — the common way).
    /// Second variant starts bottom-right and sweeps clockwise (mirrored start).
    private static func letterC() -> [[StrokePoint]] {
        let center = StrokePoint(x: 0.5, y: 0.5)
        return [
            arc(center: center, radius: 0.4, startAngle: deg(60), endAngle: deg(300), steps: 56),
            arc(center: center, radius: 0.4, startAngle: deg(300), endAngle: deg(60), steps: 56),
        ]
    }

    /// S: top bow curving left (counterclockwise), then bottom bow curving
    /// right (clockwise), starting top-right and ending bottom-left.
    private static func letterS() -> [[StrokePoint]] {
        let topCenter = StrokePoint(x: 0.5, y: 0.72)
        let bottomCenter = StrokePoint(x: 0.5, y: 0.28)
        let radius = 0.22
        let stroke = joined(
            arc(center: topCenter, radius: radius, startAngle: deg(45), endAngle: deg(270), steps: 28),
            arc(center: bottomCenter, radius: radius, startAngle: deg(90), endAngle: deg(-135), steps: 28)
        )
        return [stroke]
    }

    /// Z: top bar left→right, diagonal down to bottom-left, bottom bar to the right.
    private static func letterZ() -> [[StrokePoint]] {
        let stroke = joined(
            line(from: StrokePoint(x: 0.1, y: 0.85), to: StrokePoint(x: 0.9, y: 0.85), steps: 20),
            line(from: StrokePoint(x: 0.9, y: 0.85), to: StrokePoint(x: 0.1, y: 0.15), steps: 26),
            line(from: StrokePoint(x: 0.1, y: 0.15), to: StrokePoint(x: 0.9, y: 0.15), steps: 20)
        )
        return [stroke]
    }

    /// V: down-right to the bottom vertex, then up-right.
    private static func letterV() -> [[StrokePoint]] {
        let stroke = joined(
            line(from: StrokePoint(x: 0.15, y: 0.85), to: StrokePoint(x: 0.5, y: 0.1), steps: 28),
            line(from: StrokePoint(x: 0.5, y: 0.1), to: StrokePoint(x: 0.85, y: 0.85), steps: 28)
        )
        return [stroke]
    }

    /// L: straight down the left side, then across the bottom to the right.
    private static func letterL() -> [[StrokePoint]] {
        let stroke = joined(
            line(from: StrokePoint(x: 0.2, y: 0.9), to: StrokePoint(x: 0.2, y: 0.1), steps: 30),
            line(from: StrokePoint(x: 0.2, y: 0.1), to: StrokePoint(x: 0.85, y: 0.1), steps: 26)
        )
        return [stroke]
    }

    /// N: up the left side, diagonal down to bottom-right, up the right side.
    private static func letterN() -> [[StrokePoint]] {
        let stroke = joined(
            line(from: StrokePoint(x: 0.15, y: 0.1), to: StrokePoint(x: 0.15, y: 0.9), steps: 20),
            line(from: StrokePoint(x: 0.15, y: 0.9), to: StrokePoint(x: 0.85, y: 0.1), steps: 26),
            line(from: StrokePoint(x: 0.85, y: 0.1), to: StrokePoint(x: 0.85, y: 0.9), steps: 20)
        )
        return [stroke]
    }

    /// O: full circle. Unlike every other shape, O is rotation-symmetric — the
    /// user can start anywhere on the rim — but the recognizer's indicative
    /// angle is set entirely by the start point and comparisons are gated to a
    /// 60° indicative delta. So each winding ships three variants with start
    /// angles 120° apart (90°, 210°, 330°), guaranteeing every possible start
    /// point lies within 60° of some variant. Counterclockwise first.
    private static func letterO() -> [[StrokePoint]] {
        let center = StrokePoint(x: 0.5, y: 0.5)
        let startAngles: [Double] = [90, 210, 330]
        let counterclockwise = startAngles.map { start in
            arc(center: center, radius: 0.4, startAngle: deg(start), endAngle: deg(start + 360), steps: 64)
        }
        let clockwise = startAngles.map { start in
            arc(center: center, radius: 0.4, startAngle: deg(start), endAngle: deg(start - 360), steps: 64)
        }
        return counterclockwise + clockwise
    }

    // MARK: - Symbols

    /// Check ✓: short stroke down-right, then a longer stroke up-right.
    private static func check() -> [[StrokePoint]] {
        let stroke = joined(
            line(from: StrokePoint(x: 0.2, y: 0.5), to: StrokePoint(x: 0.42, y: 0.2), steps: 18),
            line(from: StrokePoint(x: 0.42, y: 0.2), to: StrokePoint(x: 0.85, y: 0.85), steps: 34)
        )
        return [stroke]
    }

    /// Cross ✕ drawn as a single stroke, the classic $1 "X" unistroke:
    /// diagonal top-left → bottom-right, hook straight up the right side,
    /// then cross back down-left to the bottom-left corner.
    private static func cross() -> [[StrokePoint]] {
        let stroke = joined(
            line(from: StrokePoint(x: 0.15, y: 0.85), to: StrokePoint(x: 0.85, y: 0.15), steps: 26),
            line(from: StrokePoint(x: 0.85, y: 0.15), to: StrokePoint(x: 0.85, y: 0.85), steps: 14),
            line(from: StrokePoint(x: 0.85, y: 0.85), to: StrokePoint(x: 0.15, y: 0.15), steps: 26)
        )
        return [stroke]
    }

    /// Question ?: hook arc from upper-left over the top, down the right and
    /// curling in, then a straight tail down (no dot). Second variant curls
    /// less and finishes with a straighter, slanted tail.
    private static func question() -> [[StrokePoint]] {
        let hookCenter = StrokePoint(x: 0.5, y: 0.68)
        let radius = 0.24

        let curled = joined(
            arc(center: hookCenter, radius: radius, startAngle: deg(150), endAngle: deg(-90), steps: 44),
            line(from: onCircle(center: hookCenter, radius: radius, degrees: -90),
                 to: StrokePoint(x: 0.5, y: 0.12),
                 steps: 14)
        )

        let straightTail = joined(
            arc(center: hookCenter, radius: radius, startAngle: deg(150), endAngle: deg(-45), steps: 40),
            line(from: onCircle(center: hookCenter, radius: radius, degrees: -45),
                 to: StrokePoint(x: 0.58, y: 0.12),
                 steps: 16)
        )

        return [curled, straightTail]
    }

    /// Heart ♡: start at the top-center dip, arc over the left lobe, straight
    /// down to the bottom point, back up the right side, and arc over the
    /// right lobe to close at the dip. Second variant draws the right lobe first.
    private static func heart() -> [[StrokePoint]] {
        let leftCenter = StrokePoint(x: 0.3, y: 0.74)
        let rightCenter = StrokePoint(x: 0.7, y: 0.74)
        let lobeRadius = 0.21
        let bottomPoint = StrokePoint(x: 0.5, y: 0.06)

        let leftExit = onCircle(center: leftCenter, radius: lobeRadius, degrees: 210)
        let rightEntry = onCircle(center: rightCenter, radius: lobeRadius, degrees: -30)

        let leftFirst = joined(
            arc(center: leftCenter, radius: lobeRadius, startAngle: deg(-10), endAngle: deg(210), steps: 20),
            line(from: leftExit, to: bottomPoint, steps: 14),
            line(from: bottomPoint, to: rightEntry, steps: 14),
            arc(center: rightCenter, radius: lobeRadius, startAngle: deg(-30), endAngle: deg(190), steps: 20)
        )

        let rightFirst = joined(
            arc(center: rightCenter, radius: lobeRadius, startAngle: deg(190), endAngle: deg(-30), steps: 20),
            line(from: rightEntry, to: bottomPoint, steps: 14),
            line(from: bottomPoint, to: leftExit, steps: 14),
            arc(center: leftCenter, radius: lobeRadius, startAngle: deg(210), endAngle: deg(-10), steps: 20)
        )

        return [leftFirst, rightFirst]
    }
}
