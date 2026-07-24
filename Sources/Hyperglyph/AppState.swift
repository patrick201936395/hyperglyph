import Foundation
import Observation
import HyperglyphKit

/// Observable UI state hub. All mutation happens on the main actor (package default isolation).
@Observable
final class AppState {
    /// Master enable switch (mirrored into AppConfig by the coordinator).
    var isEnabled: Bool = true

    /// Live touches for the visualizer, y-up normalized coords.
    var touches: [TouchPoint] = []

    /// Current in-progress shape stroke (empty when not drawing), y-up normalized coords.
    var currentStroke: [StrokePoint] = []

    /// True while two-finger draw mode is armed.
    var isDrawArmed: Bool = false

    /// Most recent gesture firings, newest first, capped at 10.
    var recentEvents: [GestureEvent] = []

    /// When non-nil, the menu bar icon shows this glyph instead of the trackpad symbol (~1s flash).
    var menuBarFlash: String? = nil

    var accessibilityGranted: Bool = false
    var hapticsUsingPrivateAPI: Bool = false

    /// True when the multitouch listener could not attach (e.g. no built-in trackpad).
    var touchCaptureFailed: Bool = false

    /// When non-nil, the shape recorder UI owns completed strokes: the coordinator routes
    /// finished strokes here instead of recognizing them.
    var recordingHandler: (([StrokePoint]) -> Void)? = nil

    func pushEvent(_ event: GestureEvent) {
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 10 { recentEvents.removeLast(recentEvents.count - 10) }
    }
}
