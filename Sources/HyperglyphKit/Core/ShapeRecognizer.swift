import Foundation

// MARK: - Public types

/// A shape shipped with the app that the recognizer can match out of the box.
public struct BuiltInShape: Identifiable, Hashable, Sendable {
    /// Stable identifier used by `ShapeBinding.shapeName`, e.g. "C", "Check", "Flick Up".
    public let name: String
    /// Short display glyph, e.g. "C", "✓", "↑".
    public let symbol: String
    /// Template strokes in normalized y-UP coordinates. EMPTY for flick shapes,
    /// which are matched by the straight-line fast path instead of $1.
    public let templates: [[StrokePoint]]

    public var id: String { name }
}

/// The outcome of a successful shape recognition.
public struct RecognitionResult: Hashable, Sendable {
    /// Matched shape name (`BuiltInShape.name` or `CustomTemplate.name`).
    public let name: String
    /// Display glyph for the matched shape.
    public let symbol: String
    /// Match confidence in 0...1 (flicks always score 1.0).
    public let score: Double
}

// MARK: - Recognizer

/// Two-finger stroke recognizer.
///
/// Combines a straight-line "flick" fast path with the
/// $1 Unistroke Recognizer (Wobbrock, Wilson, Li 2007) for drawn shapes:
/// candidate strokes are resampled to 64 points, rotated so the
/// centroid→first-point (indicative) angle is 0, scaled non-uniformly into a
/// 250×250 reference square, translated to the origin, and compared against
/// preprocessed templates using a golden-section search over ±45° of rotation.
/// The ±45° bound is deliberate — full rotation invariance would collapse
/// V/L/Check into each other.
///
/// All coordinates are normalized trackpad space: 0...1, y-UP (y = 0 at the
/// bottom edge, matching raw MultitouchSupport data).
public final class ShapeRecognizer {

    public init() {}

    /// The complete built-in shape catalog (letters, symbols, flicks).
    /// ConfigStore builds default shape bindings from this list.
    public static let builtInShapes: [BuiltInShape] = ShapeTemplates.builtIn

    /// Per-CustomTemplate cache of preprocessed samples, invalidated when the
    /// template's samples change.
    private var customCache: [UUID: (samplesHash: Int, processed: [Normalized])] = [:]

    /// Built-in templates preprocessed once (resampled/rotated/scaled/translated)
    /// so each `recognize` call is O(number of templates).
    private static let processedBuiltIns: [ProcessedTemplate] = builtInShapes.flatMap { shape in
        shape.templates.map { template in
            ProcessedTemplate(name: shape.name, symbol: shape.symbol, normalized: normalizeForMatching(template))
        }
    }

    /// A stroke after full $1 preprocessing, plus the raw indicative angle it
    /// was rotated away from (used to bound rotation invariance).
    private struct Normalized {
        let points: [StrokePoint]
        let indicativeAngle: Double
    }

    private struct ProcessedTemplate {
        let name: String
        let symbol: String
        let normalized: Normalized
    }

    // MARK: Recognition

    /// Recognizes a completed stroke against built-in shapes and the user's
    /// custom templates.
    ///
    /// Pipeline:
    /// 1. Nearly straight strokes (straightness > 0.9) are handled by the flick
    ///    fast path: long enough strokes whose direction lies within 25° of an
    ///    axis return the corresponding flick with score 1.0; other straight
    ///    strokes return nil (a diagonal line must not be mangled into an L or V).
    /// 2. Everything else runs through the $1 Unistroke Recognizer
    ///    (Wobbrock, Wilson, Li 2007) against every built-in template and every
    ///    sample of every custom template, with rotation invariance bounded so
    ///    rotated look-alikes (Z vs N) stay distinct.
    ///
    /// - Parameters:
    ///   - stroke: The drawn stroke in normalized y-UP coordinates.
    ///   - threshold: Minimum $1 score in 0...1 (e.g. `AppConfig.matchThreshold`).
    ///   - customTemplates: User-recorded shapes; each sample is matched as its own template.
    ///   - eligibleNames: When non-nil, only shapes in this set can win. Pass the
    ///     set of enabled+bound shape names so a disabled or unbound look-alike
    ///     can never shadow a shape the user actually wants to fire.
    /// - Returns: The best match at or above `threshold`, or nil if nothing qualifies.
    public func recognize(
        _ stroke: [StrokePoint],
        threshold: Double,
        customTemplates: [CustomTemplate],
        eligibleNames: Set<String>? = nil
    ) -> RecognitionResult? {
        guard stroke.count >= 2 else { return nil }
        pruneStaleCacheEntries(live: customTemplates)

        let length = Self.pathLength(stroke)
        guard length > 0 else { return nil }

        func eligible(_ name: String) -> Bool {
            eligibleNames?.contains(name) ?? true
        }

        let first = stroke[0]
        let last = stroke[stroke.count - 1]
        let straightness = Self.distance(first, last) / length

        // Flick fast path — and a hard stop for straight lines in general:
        // $1's scale normalization turns any near-line into garbage matches.
        // Straight strokes can still match STRAIGHT custom templates by direction.
        if straightness > 0.90 {
            if let flick = Self.matchFlick(from: first, to: last, pathLength: length),
               eligible(flick.name) {
                return flick
            }
            guard let straightCustom = Self.matchStraightCustom(
                from: first, to: last, pathLength: length,
                customTemplates: customTemplates, isEligible: eligible
            ), straightCustom.score >= threshold else { return nil }
            return straightCustom
        }

        let candidate = Self.normalizeForMatching(stroke)

        var bestDistance = Double.infinity
        var bestName: String?
        var bestSymbol = ""

        for template in Self.processedBuiltIns where eligible(template.name) {
            guard let d = Self.matchDistance(candidate, template.normalized) else { continue }
            if d < bestDistance {
                bestDistance = d
                bestName = template.name
                bestSymbol = template.symbol
            }
        }

        for custom in customTemplates where eligible(custom.name) {
            for sample in processedSamples(for: custom) {
                guard let d = Self.matchDistance(candidate, sample) else { continue }
                if d < bestDistance {
                    bestDistance = d
                    bestName = custom.name
                    bestSymbol = custom.symbol
                }
            }
        }

        guard let name = bestName else { return nil }
        let score = 1.0 - bestDistance / Self.halfDiagonal
        guard score >= threshold else { return nil }
        return RecognitionResult(name: name, symbol: bestSymbol, score: score)
    }

    /// A representative stroke for previewing a shape in the UI
    /// (y-UP normalized coordinates — flip y for screen display).
    ///
    /// Resolution order: built-in template → built-in flick arrow line →
    /// first sample of a matching custom template. Returns nil for unknown names.
    public static func previewPath(for name: String, customTemplates: [CustomTemplate]) -> [StrokePoint]? {
        if let shape = builtInShapes.first(where: { $0.name == name }) {
            if let template = shape.templates.first { return template }
            if let flick = ShapeTemplates.flickPreview(for: name) { return flick }
        }
        if let custom = customTemplates.first(where: { $0.name == name }),
           let sample = custom.samples.first(where: { $0.count >= 2 }) {
            return sample
        }
        return nil
    }

    // MARK: Flick fast path

    /// Axis directions in degrees (math convention, y-UP: +y displacement = up).
    private nonisolated static let flickAxes: [(name: String, symbol: String, degrees: Double)] = [
        ("Flick Right", "→", 0),
        ("Flick Up", "↑", 90),
        ("Flick Left", "←", 180),
        ("Flick Down", "↓", -90),
    ]

    private nonisolated static func matchFlick(
        from start: StrokePoint,
        to end: StrokePoint,
        pathLength: Double
    ) -> RecognitionResult? {
        guard pathLength > 0.12 else { return nil }
        let angle = atan2(end.y - start.y, end.x - start.x) * 180 / .pi
        for axis in flickAxes {
            var delta = abs(angle - axis.degrees)
            if delta > 180 { delta = 360 - delta }
            if delta <= 25 {
                return RecognitionResult(name: axis.name, symbol: axis.symbol, score: 1.0)
            }
        }
        // Straight but diagonal: reject outright rather than letting $1 mangle it.
        return nil
    }

    /// Direction-based matching for STRAIGHT custom templates ($1 cannot handle
    /// lines — its square normalization explodes them). A straight candidate
    /// matches a custom template when the template also has a nearly straight
    /// sample whose direction lies within 20° of the candidate's.
    private nonisolated static func matchStraightCustom(
        from start: StrokePoint,
        to end: StrokePoint,
        pathLength: Double,
        customTemplates: [CustomTemplate],
        isEligible: (String) -> Bool
    ) -> RecognitionResult? {
        // Same minimum as the flick fast path: a stroke too short to be a flick
        // must not be claimable by a straight custom template either, or a
        // short flick would fire the custom binding instead of the flick's.
        guard pathLength > 0.12 else { return nil }
        let candidateAngle = atan2(end.y - start.y, end.x - start.x) * 180 / .pi

        var best: (name: String, symbol: String, delta: Double)?
        for custom in customTemplates where isEligible(custom.name) {
            for sample in custom.samples where sample.count >= 2 {
                let sampleLength = Self.pathLength(sample)
                guard sampleLength > 0 else { continue }
                let sFirst = sample[0]
                let sLast = sample[sample.count - 1]
                guard Self.distance(sFirst, sLast) / sampleLength > 0.90 else { continue }
                let sampleAngle = atan2(sLast.y - sFirst.y, sLast.x - sFirst.x) * 180 / .pi
                var delta = abs(candidateAngle - sampleAngle)
                if delta > 180 { delta = 360 - delta }
                if delta <= 20, delta < (best?.delta ?? .infinity) {
                    best = (custom.name, custom.symbol, delta)
                }
            }
        }
        guard let best else { return nil }
        return RecognitionResult(name: best.name, symbol: best.symbol, score: 1.0 - best.delta / 90.0)
    }

    // MARK: Custom template cache

    /// Drops cache entries for templates the user has deleted, so the cache
    /// can't grow without bound over a long-running session.
    private func pruneStaleCacheEntries(live customTemplates: [CustomTemplate]) {
        guard customCache.count > customTemplates.count else { return }
        let liveIDs = Set(customTemplates.map(\.id))
        customCache = customCache.filter { liveIDs.contains($0.key) }
    }

    private func processedSamples(for template: CustomTemplate) -> [Normalized] {
        let hash = template.samples.hashValue
        if let cached = customCache[template.id], cached.samplesHash == hash {
            return cached.processed
        }
        let processed = template.samples
            .filter { $0.count >= 2 && Self.pathLength($0) > 0 }
            .map { Self.normalizeForMatching($0) }
        customCache[template.id] = (samplesHash: hash, processed: processed)
        return processed
    }

    // MARK: - $1 Unistroke Recognizer core (Wobbrock, Wilson, Li 2007)

    /// Resample target: templates and candidates are compared point-by-point at this count.
    private nonisolated static let resampleCount = 64
    /// Side of the reference square all strokes are scaled into.
    private nonisolated static let squareSize = 250.0
    /// Half the diagonal of the reference square; normalizes distance to a 0...1 score.
    private nonisolated static let halfDiagonal = 0.5 * (2.0 * 250.0 * 250.0).squareRoot()
    /// Golden-section rotation search bounds (±45°) and stop precision (2°), radians.
    private nonisolated static let angleRange = 45.0 * Double.pi / 180
    private nonisolated static let anglePrecision = 2.0 * Double.pi / 180
    /// Golden ratio conjugate.
    private nonisolated static let phi = 0.5 * ((5.0).squareRoot() - 1.0)
    /// Bounded rotation invariance: a template is only considered when its raw
    /// indicative angle is within this many radians of the candidate's (60°).
    /// Rotating fully to the indicative angle would otherwise conflate shapes
    /// that are pure rotations of each other (Z vs N are exactly 90° apart).
    private nonisolated static let maxIndicativeDelta = 60.0 * Double.pi / 180

    /// Full $1 preprocessing: resample → rotate indicative angle to 0 →
    /// scale to reference square → translate centroid to origin.
    /// The pre-rotation indicative angle rides along for the bounded-rotation gate.
    private nonisolated static func normalizeForMatching(_ points: [StrokePoint]) -> Normalized {
        var result = resample(points, to: resampleCount)
        let angle = indicativeAngle(of: result)
        result = rotate(result, by: -angle)
        result = scaleToSquare(result, size: squareSize)
        result = translateToOrigin(result)
        return Normalized(points: result, indicativeAngle: angle)
    }

    /// Distance between a normalized candidate and template, or nil when the
    /// pair is outside the bounded rotation window and must not be compared.
    private nonisolated static func matchDistance(_ candidate: Normalized, _ template: Normalized) -> Double? {
        var delta = abs(candidate.indicativeAngle - template.indicativeAngle)
        if delta > .pi { delta = 2 * .pi - delta }
        guard delta <= maxIndicativeDelta else { return nil }
        return distanceAtBestAngle(candidate.points, template.points)
    }

    /// Total arc length of a polyline.
    nonisolated static func pathLength(_ points: [StrokePoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            total += distance(points[i - 1], points[i])
        }
        return total
    }

    /// Resamples a polyline to exactly `count` evenly spaced points
    /// (first and last points preserved). Degenerate inputs are returned
    /// unchanged or padded.
    nonisolated static func resample(_ points: [StrokePoint], to count: Int) -> [StrokePoint] {
        guard count >= 2, points.count >= 2 else { return points }
        let total = pathLength(points)
        guard total > 0 else { return Array(repeating: points[0], count: count) }

        let interval = total / Double(count - 1)
        var result: [StrokePoint] = [points[0]]
        var accumulated = 0.0
        var previous = points[0]
        var index = 1

        while index < points.count && result.count < count {
            let current = points[index]
            let segment = distance(previous, current)
            if segment > 0, accumulated + segment >= interval {
                let t = (interval - accumulated) / segment
                let q = StrokePoint(
                    x: previous.x + t * (current.x - previous.x),
                    y: previous.y + t * (current.y - previous.y)
                )
                result.append(q)
                previous = q
                accumulated = 0
                // Stay on this segment; q is the new segment start.
            } else {
                accumulated += segment
                previous = current
                index += 1
            }
        }

        // Floating-point shortfall: pad with the final point.
        let lastPoint = points[points.count - 1]
        while result.count < count {
            result.append(lastPoint)
        }
        return result
    }

    nonisolated static func distance(_ a: StrokePoint, _ b: StrokePoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private nonisolated static func centroid(of points: [StrokePoint]) -> StrokePoint {
        guard !points.isEmpty else { return StrokePoint(x: 0, y: 0) }
        var sumX = 0.0
        var sumY = 0.0
        for p in points {
            sumX += p.x
            sumY += p.y
        }
        let n = Double(points.count)
        return StrokePoint(x: sumX / n, y: sumY / n)
    }

    /// Angle from the centroid to the first point ($1's "indicative angle").
    private nonisolated static func indicativeAngle(of points: [StrokePoint]) -> Double {
        guard let first = points.first else { return 0 }
        let c = centroid(of: points)
        return atan2(c.y - first.y, c.x - first.x)
    }

    /// Rotates all points around their centroid by `angle` radians.
    private nonisolated static func rotate(_ points: [StrokePoint], by angle: Double) -> [StrokePoint] {
        let c = centroid(of: points)
        let cosA = Foundation.cos(angle)
        let sinA = Foundation.sin(angle)
        return points.map { p in
            let dx = p.x - c.x
            let dy = p.y - c.y
            return StrokePoint(
                x: dx * cosA - dy * sinA + c.x,
                y: dx * sinA + dy * cosA + c.y
            )
        }
    }

    /// Non-uniform scale of the bounding box into a `size` × `size` square.
    private nonisolated static func scaleToSquare(_ points: [StrokePoint], size: Double) -> [StrokePoint] {
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        for p in points {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        let width = max(maxX - minX, 1e-9)
        let height = max(maxY - minY, 1e-9)
        return points.map { p in
            StrokePoint(x: p.x * (size / width), y: p.y * (size / height))
        }
    }

    /// Translates points so their centroid sits at the origin.
    private nonisolated static func translateToOrigin(_ points: [StrokePoint]) -> [StrokePoint] {
        let c = centroid(of: points)
        return points.map { StrokePoint(x: $0.x - c.x, y: $0.y - c.y) }
    }

    /// Golden-section search over ±45° for the rotation of `points` that
    /// minimizes path distance to `template`.
    private nonisolated static func distanceAtBestAngle(
        _ points: [StrokePoint],
        _ template: [StrokePoint]
    ) -> Double {
        var a = -angleRange
        var b = angleRange
        var x1 = phi * a + (1 - phi) * b
        var f1 = distanceAtAngle(points, template, angle: x1)
        var x2 = (1 - phi) * a + phi * b
        var f2 = distanceAtAngle(points, template, angle: x2)

        while abs(b - a) > anglePrecision {
            if f1 < f2 {
                b = x2
                x2 = x1
                f2 = f1
                x1 = phi * a + (1 - phi) * b
                f1 = distanceAtAngle(points, template, angle: x1)
            } else {
                a = x1
                x1 = x2
                f1 = f2
                x2 = (1 - phi) * a + phi * b
                f2 = distanceAtAngle(points, template, angle: x2)
            }
        }
        return min(f1, f2)
    }

    private nonisolated static func distanceAtAngle(
        _ points: [StrokePoint],
        _ template: [StrokePoint],
        angle: Double
    ) -> Double {
        pathDistance(rotate(points, by: angle), template)
    }

    /// Mean pairwise distance between two equal-length resampled paths.
    private nonisolated static func pathDistance(_ a: [StrokePoint], _ b: [StrokePoint]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return .infinity }
        var total = 0.0
        for i in 0..<count {
            total += distance(a[i], b[i])
        }
        return total / Double(count)
    }
}
