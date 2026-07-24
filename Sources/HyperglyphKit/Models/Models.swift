import Foundation

// MARK: - Touch primitives

/// Normalized trackpad coordinates: x in 0...1 (left → right), y in 0...1 (BOTTOM → top, matching raw MultitouchSupport orientation). UI layers flip y for display.
public nonisolated struct StrokePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public nonisolated enum TouchPhase: Sendable, Hashable {
    case starting
    case touching
    case breaking
    case leaving
    case hovering
    case other
}

public nonisolated struct TouchPoint: Identifiable, Hashable, Sendable {
    public let id: Int32
    /// Normalized 0...1, y-up (bottom = 0).
    public let x: Double
    public let y: Double
    public let pressure: Double
    public let total: Double
    public let majorAxis: Double
    public let minorAxis: Double
    public let density: Double
    public let phase: TouchPhase

    public init(
        id: Int32,
        x: Double,
        y: Double,
        pressure: Double,
        total: Double,
        majorAxis: Double,
        minorAxis: Double,
        density: Double,
        phase: TouchPhase
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.pressure = pressure
        self.total = total
        self.majorAxis = majorAxis
        self.minorAxis = minorAxis
        self.density = density
        self.phase = phase
    }
}

/// One frame of all touches currently on the pad, stamped with a local monotonic-ish receipt time.
public nonisolated struct TouchFrame: Sendable {
    public let touches: [TouchPoint]
    /// Seconds, from Date().timeIntervalSinceReferenceDate at receipt.
    public let timestamp: TimeInterval

    public init(touches: [TouchPoint], timestamp: TimeInterval) {
        self.touches = touches
        self.timestamp = timestamp
    }
}

// MARK: - Actions

public nonisolated struct Hotkey: Codable, Hashable, Sendable {
    /// Virtual key code (kVK_*).
    public var keyCode: UInt16
    /// CGEventFlags raw value.
    public var modifiers: UInt64
    /// Human-readable, e.g. "⌘⇧D".
    public var display: String

    public init(keyCode: UInt16, modifiers: UInt64, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }
}

public nonisolated enum GestureAction: Codable, Hashable, Sendable {
    case launchApp(bundleID: String, name: String)
    case keyboardShortcut(Hotkey)
    case shellCommand(command: String)
    case openURL(urlString: String)
    case runShortcut(name: String)

    public var displayName: String {
        switch self {
        case .launchApp(_, let name): return name
        case .keyboardShortcut(let hotkey): return hotkey.display
        case .shellCommand(let command): return String(command.prefix(30))
        case .openURL(let urlString): return String(urlString.prefix(30))
        case .runShortcut(let name): return name
        }
    }

    public var systemImage: String {
        switch self {
        case .launchApp: return "app.badge"
        case .keyboardShortcut: return "keyboard"
        case .shellCommand: return "terminal"
        case .openURL: return "link"
        case .runShortcut: return "sparkles.rectangle.stack"
        }
    }
}

// MARK: - Tap zones

public nonisolated enum TapZone: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftHalf, rightHalf
    case topLeftCorner, topRightCorner, bottomLeftCorner, bottomRightCorner

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topLeftCorner: return "Top Left Corner"
        case .topRightCorner: return "Top Right Corner"
        case .bottomLeftCorner: return "Bottom Left Corner"
        case .bottomRightCorner: return "Bottom Right Corner"
        }
    }
}

public nonisolated struct ZoneBinding: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var zone: TapZone
    /// 1–3 taps.
    public var tapCount: Int
    public var action: GestureAction?
    public var isEnabled: Bool = true

    public init(
        id: UUID = UUID(),
        zone: TapZone,
        tapCount: Int,
        action: GestureAction? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.zone = zone
        self.tapCount = tapCount
        self.action = action
        self.isEnabled = isEnabled
    }
}

// MARK: - Shapes

public nonisolated struct ShapeBinding: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    /// Matches BuiltInShape.name or CustomTemplate.name.
    public var shapeName: String
    public var action: GestureAction?
    public var isEnabled: Bool = true

    public init(
        id: UUID = UUID(),
        shapeName: String,
        action: GestureAction? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.shapeName = shapeName
        self.action = action
        self.isEnabled = isEnabled
    }
}

public nonisolated struct CustomTemplate: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    /// Short display glyph, e.g. "µ" or an emoji.
    public var symbol: String
    /// One or more recorded strokes; the recognizer matches against each.
    public var samples: [[StrokePoint]]

    public init(id: UUID = UUID(), name: String, symbol: String, samples: [[StrokePoint]]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.samples = samples
    }
}

// MARK: - HUD appearance

/// Where the gesture pop-up (trail card + result pill) appears on screen.
public nonisolated enum HUDPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft, topCenter, topRight
    case center
    case bottomLeft, bottomCenter, bottomRight

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top Center"
        case .topRight: return "Top Right"
        case .center: return "Center"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight: return "Bottom Right"
        }
    }

    /// Normalized screen anchor (0...1, y-up) for this position.
    public var anchor: (x: Double, y: Double) {
        switch self {
        case .topLeft: return (0.08, 0.85)
        case .topCenter: return (0.50, 0.85)
        case .topRight: return (0.92, 0.85)
        case .center: return (0.50, 0.50)
        case .bottomLeft: return (0.08, 0.16)
        case .bottomCenter: return (0.50, 0.16)
        case .bottomRight: return (0.92, 0.16)
        }
    }
}

/// Visual design of the gesture pop-up.
public nonisolated enum HUDTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    /// System-material capsule with a colored status ring (default).
    case glass
    /// Opaque near-black card with glowing accents.
    case midnight
    /// Small, quiet, compact pill.
    case minimal
    /// Large square center card, classic macOS volume-HUD style.
    case jumbo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .glass: return "Glass"
        case .midnight: return "Midnight"
        case .minimal: return "Minimal"
        case .jumbo: return "Jumbo"
        }
    }
}

// MARK: - Config

public nonisolated struct AppConfig: Codable, Sendable {
    public var isEnabled: Bool = true
    public var zoneBindings: [ZoneBinding] = []
    public var shapeBindings: [ShapeBinding] = []
    public var customTemplates: [CustomTemplate] = []

    // Tunables (Settings sliders)
    /// Instant draw: two fingers arm immediately — just draw, no hold. Failures
    /// (i.e. ordinary scrolls) are silent; only recognized shapes fire feedback.
    /// When false, the dwell-to-arm flow applies (hold still `dwellSeconds` first).
    public var instantDraw: Bool = true
    /// Seconds two fingers must stay still to arm draw mode.
    public var dwellSeconds: Double = 0.15
    /// Max normalized movement allowed during dwell.
    public var stillnessThreshold: Double = 0.015
    /// Max seconds for a touch to count as a tap.
    public var tapMaxDuration: Double = 0.25
    /// Max normalized movement for a tap.
    public var tapMaxMovement: Double = 0.02
    /// Seconds to wait for another tap in a multi-tap sequence.
    public var multiTapWindow: Double = 0.35
    /// Pressure above which a touch counts as a physical click (disqualifies taps).
    public var clickPressureThreshold: Double = 0.5
    /// Corner zone width as a fraction of the trackpad (0.15...0.5).
    public var cornerWidth: Double = 0.30
    /// Corner zone height as a fraction of the trackpad (0.2...0.5).
    public var cornerHeight: Double = 0.40
    /// $1 recognizer minimum score (0...1).
    public var matchThreshold: Double = 0.80

    public var hapticsEnabled: Bool = true
    public var hudEnabled: Bool = true
    public var hudPosition: HUDPosition = .bottomCenter
    public var hudTemplate: HUDTemplate = .glass
    public var launchAtLogin: Bool = false

    public init() {}

    /// Tolerant decoding: every missing key falls back to its default, so configs
    /// written by older builds keep loading (instead of resetting to defaults)
    /// whenever a new setting is added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        zoneBindings = try c.decodeIfPresent([ZoneBinding].self, forKey: .zoneBindings) ?? defaults.zoneBindings
        shapeBindings = try c.decodeIfPresent([ShapeBinding].self, forKey: .shapeBindings) ?? defaults.shapeBindings
        customTemplates = try c.decodeIfPresent([CustomTemplate].self, forKey: .customTemplates) ?? defaults.customTemplates
        instantDraw = try c.decodeIfPresent(Bool.self, forKey: .instantDraw) ?? defaults.instantDraw
        dwellSeconds = try c.decodeIfPresent(Double.self, forKey: .dwellSeconds) ?? defaults.dwellSeconds
        stillnessThreshold = try c.decodeIfPresent(Double.self, forKey: .stillnessThreshold) ?? defaults.stillnessThreshold
        tapMaxDuration = try c.decodeIfPresent(Double.self, forKey: .tapMaxDuration) ?? defaults.tapMaxDuration
        tapMaxMovement = try c.decodeIfPresent(Double.self, forKey: .tapMaxMovement) ?? defaults.tapMaxMovement
        multiTapWindow = try c.decodeIfPresent(Double.self, forKey: .multiTapWindow) ?? defaults.multiTapWindow
        clickPressureThreshold = try c.decodeIfPresent(Double.self, forKey: .clickPressureThreshold) ?? defaults.clickPressureThreshold
        cornerWidth = try c.decodeIfPresent(Double.self, forKey: .cornerWidth) ?? defaults.cornerWidth
        cornerHeight = try c.decodeIfPresent(Double.self, forKey: .cornerHeight) ?? defaults.cornerHeight
        matchThreshold = try c.decodeIfPresent(Double.self, forKey: .matchThreshold) ?? defaults.matchThreshold
        hapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? defaults.hapticsEnabled
        hudEnabled = try c.decodeIfPresent(Bool.self, forKey: .hudEnabled) ?? defaults.hudEnabled
        hudPosition = try c.decodeIfPresent(HUDPosition.self, forKey: .hudPosition) ?? defaults.hudPosition
        hudTemplate = try c.decodeIfPresent(HUDTemplate.self, forKey: .hudTemplate) ?? defaults.hudTemplate
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
    }
}

// MARK: - Events (for menu bar "recent" list)

public nonisolated struct GestureEvent: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let date: Date
    /// Shape glyph or zone icon, e.g. "C" or "◱".
    public let symbol: String
    /// e.g. "C → Codex" or "Double-tap Left → Wispr".
    public let title: String
    public let success: Bool

    public init(date: Date, symbol: String, title: String, success: Bool) {
        self.id = UUID()
        self.date = date
        self.symbol = symbol
        self.title = title
        self.success = success
    }
}
