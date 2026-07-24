import Foundation

/// Persists AppConfig as JSON at ~/Library/Application Support/Hyperglyph/config.json.
/// Saves are debounced; call `save(_:)` freely on every mutation.
public final class ConfigStore {
    private let fileURL: URL
    private var pendingSave: Task<Void, Never>?
    private var latestConfig: AppConfig?

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Hyperglyph", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")
    }

    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else {
            return Self.defaultConfig()
        }
        return config
    }

    /// Cancels any pending debounced save and writes the most recent config synchronously.
    /// Call on termination so edits made in the final debounce window aren't lost.
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let config = latestConfig else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func save(_ config: AppConfig) {
        latestConfig = config
        pendingSave?.cancel()
        pendingSave = Task { [fileURL] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(config) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// First-run config: every built-in shape gets an (unbound) binding row so the gallery is populated.
    public static func defaultConfig() -> AppConfig {
        var config = AppConfig()
        config.shapeBindings = ShapeRecognizer.builtInShapes.map {
            ShapeBinding(shapeName: $0.name, action: nil, isEnabled: true)
        }
        config.zoneBindings = [
            ZoneBinding(zone: .leftHalf, tapCount: 2, action: nil),
            ZoneBinding(zone: .rightHalf, tapCount: 2, action: nil),
        ]
        return config
    }
}
