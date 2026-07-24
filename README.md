# Hyperglyph

**Turn your Mac's trackpad into a programmable gesture surface.**

Draw a `C` with two fingers → launch your editor. Double-tap the left edge → toggle your dictation app. Hyperglyph reads raw multitouch data from the Force Touch trackpad and fires configurable actions from drawn shapes and light taps — with real trackpad haptic feedback, a native SwiftUI UI, and a live touch visualizer.

> Like a macro pad, but it's the trackpad you already have.

## Features

- **Shape gestures** — draw letters and symbols with two fingers, Android-gesture style: `C S Z V L N O ✓ ✕ ? ♡` plus directional flicks, all ready to bind. Record your own custom shapes in-app.
- **Instant draw** — just draw; no mode switch. Ordinary scrolls stay silent, recognized shapes fire. (An optional hold-to-arm mode adds a haptic tick and scroll-blocking for deliberate drawing.)
- **Tap zones** — light taps (no click needed) on six regions: left/right halves and four corners, with single/double/triple-tap bindings. Physical clicks are detected via real mouse events and never misfire a zone.
- **Actions** — launch/focus apps, simulate keyboard shortcuts, run shell commands, open URLs, run Apple Shortcuts.
- **Trackpad haptics** — distinct patterns (arm tick, success double-pulse, fail thud, zone click) via the private `MTActuator` API, with automatic `NSHapticFeedbackManager` fallback.
- **Native UI** — menu-bar app with a reactive icon, a volume-HUD-style result overlay, a dark "Live View" showing your touches in real time, and a System-Settings-grade configuration window.
- **$1 Unistroke Recognizer** — a clean Swift implementation of Wobbrock, Wilson & Li (2007) with bounded rotation invariance, a flick fast-path, and direction matching for straight custom strokes.

## Requirements

- macOS 15+ (Sequoia or later), Apple Silicon or Intel with a Force Touch trackpad
- Xcode 26+ / Swift 6.2 toolchain to build

## Build & Run

```sh
git clone https://github.com/patrick201936395/hyperglyph.git
cd hyperglyph
./build.sh
open Hyperglyph.app
```

Hyperglyph lives in your menu bar (look for the trackpad glyph). Grant **Accessibility** permission when prompted — it's needed for simulated keyboard shortcuts and for blocking scrolling during hold-to-arm drawing. Everything else works without it.

Run the test suite:

```sh
swift test
```

### A note on code signing

`build.sh` signs with your Apple Development identity if one exists in your keychain, otherwise it falls back to ad-hoc signing. Ad-hoc signatures change on every build, which resets the macOS Accessibility grant — sign into Xcode → Settings → Accounts once to get a stable identity.

## Architecture

The package is split into a reusable engine library and the app:

```
HyperglyphKit  (library — use it to build your own trackpad tools)
├── TouchEngine          raw multitouch frames via OpenMultitouchSupport,
│                        with heartbeat synthesis for still-finger stream pauses
├── TapZoneDetector      tap sessions, zone hit-testing, multi-tap accumulation
├── DrawModeController   two-finger draw state machine (instant & dwell modes)
├── ShapeRecognizer      $1 unistroke + flick fast-path + straight-custom matching
├── ScrollSuppressor     CGEventTap that swallows scrolls while drawing (dwell mode)
├── HapticEngine         private MTActuator haptics with public-API fallback
├── ActionRunner         app launch / CGEvent hotkeys / shell / URLs / Shortcuts
└── Models + ConfigStore Codable config, tolerant decoding, debounced persistence

Hyperglyph  (executable — the menu-bar app)
├── AppCoordinator       wiring hub: frames → detectors → recognizer → actions
├── UI/                  SwiftUI: main window, Live View, zone editor,
│                        shape gallery + recorder, HUD overlay, menu bar panel
└── HyperglyphApp        @main MenuBarExtra scene
```

Coordinates everywhere are normalized `0...1` with **y-up** (matching raw MultitouchSupport data); UI layers flip y for display.

### Using HyperglyphKit in your own project

```swift
import HyperglyphKit

let engine = TouchEngine()
let recognizer = ShapeRecognizer()

engine.onFrame = { frame in
    // frame.touches: per-finger position, pressure, axes, phase
}
engine.start()
```

## How it works

- **Raw touches**: [OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport) wraps the private `MultitouchSupport.framework` to stream per-finger touch data. This requires the app to run **unsandboxed** (which is why Hyperglyph can't ship on the Mac App Store).
- **Haptics**: the private `MTActuatorCreateFromDeviceID` API drives the trackpad's Taptic Engine directly (the same approach used by [HapticKey](https://github.com/niw/HapticKey)), with recovery after sleep/wake and a public-API fallback.
- **Recognition**: strokes are resampled to 64 points, rotation-normalized, scaled, and compared against templates with a golden-section search — the classic [$1 Unistroke Recognizer](https://depts.washington.edu/acelab/proj/dollar/index.html). Rotation invariance is deliberately bounded to ±45° so `Z`/`N` and `V`/`✓` stay distinct.

> **Private API disclaimer**: Hyperglyph uses private macOS frameworks (`MultitouchSupport`) for touch capture and haptics. These APIs are undocumented and may change in any macOS release. The engine degrades gracefully where it can, but breakage on future macOS versions is possible.

## Contributing

PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Good first areas: new built-in shape templates, action types, recognizer accuracy, and multi-display HUD polish.

## Credits

- [OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport) by Kyome22 (MIT) — multitouch data access
- Wobbrock, J.O., Wilson, A.D., Li, Y. (2007) — [the $1 Unistroke Recognizer](https://depts.washington.edu/acelab/proj/dollar/index.html) (independent Swift implementation)
- [HapticKey](https://github.com/niw/HapticKey) by niw — prior art for the MTActuator haptics approach

## License

[MIT](LICENSE) © 2026 Patrick Ruan
