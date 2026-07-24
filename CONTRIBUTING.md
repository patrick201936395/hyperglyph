# Contributing to Hyperglyph

Thanks for your interest! Issues and pull requests are welcome.

## Getting started

```sh
git clone https://github.com/patrick201936395/hyperglyph.git
cd hyperglyph
swift build          # library + app
swift test           # 43 unit tests, all headless
./build.sh           # assemble + sign Hyperglyph.app
```

Requirements: macOS 15+, Xcode 26+ (Swift 6.2). A Force Touch trackpad is needed to exercise gestures end-to-end, but the whole recognition/detection pipeline is testable headlessly with synthetic frames — see `Tests/HyperglyphKitTests`.

## Project conventions

- **Two targets**: `HyperglyphKit` (engine library — no UI) and `Hyperglyph` (SwiftUI app). Engine logic goes in the Kit; anything that draws pixels stays in the app.
- **Swift 6.2, MainActor by default**: both targets use `defaultIsolation(MainActor.self)`. Mark things `nonisolated` deliberately, not reflexively.
- **Coordinates are y-up**: normalized `0...1`, `y = 0` at the trackpad's bottom edge (raw MultitouchSupport orientation). UI code flips y at the last moment. Never store flipped coordinates.
- **No new dependencies** without discussion — the only runtime dependency is OpenMultitouchSupport.
- **Tests for engine changes**: recognizer, detector, and state-machine changes need a synthetic-frame test in `Tests/HyperglyphKitTests`. UI-only changes don't.

## Pull requests

1. Fork, branch from `main`, keep PRs focused.
2. `swift test` must pass; `swift build` must be warning-free.
3. Describe the user-visible behavior change and how you verified it on real hardware (if applicable).

## Reporting bugs

Include: macOS version, Mac model, whether haptics report "native actuator" or "fallback" (Settings → Feedback), and — for recognition issues — a description or screen recording of the stroke that misbehaves.

## Private API caution

Touch capture and haptics use private frameworks. If a macOS update breaks them, the fix belongs in `TouchEngine` / `HapticEngine` behind the existing graceful-degradation paths — never let a private-API failure take the app down.
