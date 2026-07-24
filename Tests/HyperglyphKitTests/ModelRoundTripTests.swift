import Foundation
import Testing
@testable import HyperglyphKit

@Suite struct ModelRoundTripTests {

    /// One of every GestureAction case.
    private var allActionCases: [GestureAction] {
        [
            .launchApp(bundleID: "com.apple.Safari", name: "Safari"),
            .keyboardShortcut(Hotkey(keyCode: 2, modifiers: 1_179_648, display: "⌘⇧D")),
            .shellCommand(command: "echo 'hello world' | pbcopy"),
            .openURL(urlString: "https://example.com/path?q=1"),
            .runShortcut(name: "My Shortcut"),
        ]
    }

    @Test func appConfigWithEveryActionCaseRoundTrips() throws {
        var config = AppConfig()
        config.isEnabled = false
        config.dwellSeconds = 0.2
        config.stillnessThreshold = 0.02
        config.tapMaxDuration = 0.3
        config.tapMaxMovement = 0.05
        config.multiTapWindow = 0.4
        config.clickPressureThreshold = 0.6
        config.matchThreshold = 0.85
        config.hapticsEnabled = false
        config.hudEnabled = false
        config.launchAtLogin = true

        // Spread every action case across zone bindings and shape bindings.
        let zones = TapZone.allCases
        config.zoneBindings = allActionCases.enumerated().map { i, action in
            ZoneBinding(zone: zones[i % zones.count], tapCount: (i % 3) + 1, action: action, isEnabled: i % 2 == 0)
        }
        config.shapeBindings = allActionCases.enumerated().map { i, action in
            ShapeBinding(shapeName: ShapeRecognizer.builtInShapes[i].name, action: action, isEnabled: true)
        }
        config.customTemplates = [
            CustomTemplate(
                name: "Triangle",
                symbol: "△",
                samples: [[StrokePoint(x: 0.1, y: 0.2), StrokePoint(x: 0.5, y: 0.9), StrokePoint(x: 0.9, y: 0.2)]]
            )
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        // AppConfig is not Equatable; compare every stored property...
        #expect(decoded.isEnabled == config.isEnabled)
        #expect(decoded.zoneBindings == config.zoneBindings)
        #expect(decoded.shapeBindings == config.shapeBindings)
        #expect(decoded.customTemplates == config.customTemplates)
        #expect(decoded.dwellSeconds == config.dwellSeconds)
        #expect(decoded.stillnessThreshold == config.stillnessThreshold)
        #expect(decoded.tapMaxDuration == config.tapMaxDuration)
        #expect(decoded.tapMaxMovement == config.tapMaxMovement)
        #expect(decoded.multiTapWindow == config.multiTapWindow)
        #expect(decoded.clickPressureThreshold == config.clickPressureThreshold)
        #expect(decoded.matchThreshold == config.matchThreshold)
        #expect(decoded.hapticsEnabled == config.hapticsEnabled)
        #expect(decoded.hudEnabled == config.hudEnabled)
        #expect(decoded.launchAtLogin == config.launchAtLogin)

        // ...and prove byte-for-byte stability across a second encode pass.
        let reencoded = try encoder.encode(decoded)
        #expect(reencoded == data)
    }

    @Test func everyGestureActionCaseRoundTripsIndividually() throws {
        for action in allActionCases {
            let data = try JSONEncoder().encode(action)
            let decoded = try JSONDecoder().decode(GestureAction.self, from: data)
            #expect(decoded == action)
        }
    }

    @Test func defaultConfigCoversEveryBuiltInShape() {
        let config = ConfigStore.defaultConfig()
        let boundNames = Set(config.shapeBindings.map(\.shapeName))
        for shape in ShapeRecognizer.builtInShapes {
            #expect(boundNames.contains(shape.name), "no default binding for built-in shape \(shape.name)")
        }
    }
}
