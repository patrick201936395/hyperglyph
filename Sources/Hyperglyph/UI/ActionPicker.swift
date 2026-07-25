import AppKit
import SwiftUI
import UniformTypeIdentifiers
import HyperglyphKit

// MARK: - ActionPickerButton

/// The single reusable control for assigning any `GestureAction` to a binding row.
///
/// Collapsed states:
/// - `action == nil`: a secondary "Choose Action…" bordered button.
/// - otherwise: a compact chip showing the action's icon + display name, with a small
///   clear (×) button on its trailing edge that resets the binding to `nil`.
///
/// Clicking the button/chip opens a popover editor with a segmented picker over the five
/// action types (App, Hotkey, Shell, URL, Shortcut) and a type-specific pane.
struct ActionPickerButton: View {
    @Binding private var action: GestureAction?
    @State private var isEditorPresented = false

    /// Creates the picker button bound to an optional gesture action.
    /// - Parameter action: The action slot this control edits. Set to `nil` by the clear button.
    init(action: Binding<GestureAction?>) {
        self._action = action
    }

    var body: some View {
        Group {
            if let action {
                chip(for: action)
            } else {
                Button("Choose Action…") {
                    isEditorPresented = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }
        }
        .popover(isPresented: $isEditorPresented, arrowEdge: .bottom) {
            ActionEditorView(action: $action) {
                isEditorPresented = false
            }
        }
    }

    /// Compact bordered chip for an assigned action, capped at ~220pt and truncating.
    private func chip(for action: GestureAction) -> some View {
        HStack(spacing: 2) {
            Button {
                isEditorPresented = true
            } label: {
                Label {
                    Text(action.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Image(systemName: action.systemImage)
                        .imageScale(.small)
                }
                .font(.callout)
                .padding(.leading, 8)
                .padding(.trailing, 2)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit action")

            Button {
                self.action = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .help("Remove action")
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .frame(maxWidth: 220, alignment: .leading)
    }
}

// MARK: - Action kinds

/// The five configurable action types, in editor display order.
private enum ActionKind: String, CaseIterable, Identifiable {
    case app, hotkey, shell, url, shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return "App"
        case .hotkey: return "Hotkey"
        case .shell: return "Shell"
        case .url: return "URL"
        case .shortcut: return "Shortcut"
        }
    }

    var systemImage: String {
        switch self {
        case .app: return "app.badge"
        case .hotkey: return "keyboard"
        case .shell: return "terminal"
        case .url: return "link"
        case .shortcut: return "sparkles.rectangle.stack"
        }
    }

    init(matching action: GestureAction?) {
        switch action {
        case .launchApp: self = .app
        case .keyboardShortcut: self = .hotkey
        case .shellCommand: self = .shell
        case .openURL: self = .url
        case .runShortcut: self = .shortcut
        case nil: self = .app
        }
    }
}

// MARK: - Editor

/// Popover content: type selector + type-specific pane + Done bar.
private struct ActionEditorView: View {
    @Binding var action: GestureAction?
    let onDone: () -> Void

    @State private var kind: ActionKind
    @State private var shellText: String
    @State private var urlText: String

    init(action: Binding<GestureAction?>, onDone: @escaping () -> Void) {
        self._action = action
        self.onDone = onDone
        self._kind = State(initialValue: ActionKind(matching: action.wrappedValue))

        if case .shellCommand(let command) = action.wrappedValue {
            self._shellText = State(initialValue: command)
        } else {
            self._shellText = State(initialValue: "")
        }
        if case .openURL(let urlString) = action.wrappedValue {
            self._urlText = State(initialValue: urlString)
        } else {
            self._urlText = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("Action Type", selection: $kind) {
                ForEach(ActionKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.systemImage)
                        .tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            pane

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    commitTextIfNeeded()
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    @ViewBuilder
    private var pane: some View {
        switch kind {
        case .app:
            AppPickerPane { apply($0) }
        case .hotkey:
            HotkeyPane(current: currentHotkey) { apply(.keyboardShortcut($0)) }
        case .shell:
            ShellPane(text: $shellText) {
                commitTextIfNeeded()
                onDone()
            }
        case .url:
            URLPane(text: $urlText) {
                commitTextIfNeeded()
                onDone()
            }
        case .shortcut:
            ShortcutPane(current: currentShortcutName) { apply($0) }
        }
    }

    private var currentHotkey: Hotkey? {
        if case .keyboardShortcut(let hotkey) = action { return hotkey }
        return nil
    }

    private var currentShortcutName: String? {
        if case .runShortcut(let name) = action { return name }
        return nil
    }

    /// Immediate-apply path (app row, hotkey capture, shortcut pick): set and close.
    private func apply(_ newAction: GestureAction) {
        action = newAction
        onDone()
    }

    /// Text-field panes commit on Done / return; empty text leaves the action untouched.
    private func commitTextIfNeeded() {
        switch kind {
        case .shell:
            let command = shellText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty { action = .shellCommand(command: command) }
        case .url:
            let urlString = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !urlString.isEmpty { action = .openURL(urlString: urlString) }
        case .app, .hotkey, .shortcut:
            break
        }
    }
}

// MARK: - App pane

/// A top-level .app bundle discovered on disk. Value type so enumeration can run off the main actor.
private struct InstalledApp: Identifiable, Hashable, Sendable {
    var id: String { bundleID }
    let name: String
    let bundleID: String
    let url: URL
}

/// Searchable list of installed applications, enumerated off the main actor at open.
private struct AppPickerPane: View {
    let onSelect: (GestureAction) -> Void

    @State private var apps: [InstalledApp]?
    @State private var searchText = ""

    private var filteredApps: [InstalledApp] {
        guard let apps else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search apps", text: $searchText)
                .textFieldStyle(.roundedBorder)

            Group {
                if apps != nil {
                    List(filteredApps) { app in
                        Button {
                            onSelect(.launchApp(bundleID: app.bundleID, name: app.name))
                        } label: {
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 24, height: 24)
                                Text(app.name)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                } else {
                    ProgressView("Loading apps…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 240)

            Button("Other…") {
                presentOpenPanel()
            }
            .controlSize(.small)
        }
        .task {
            guard apps == nil else { return }
            apps = await Task.detached(priority: .userInitiated) {
                AppPickerPane.enumerateInstalledApps()
            }.value
        }
    }

    /// Enumerates top-level .app bundles in the standard application folders.
    /// Runs off the main actor; skips bundles without a bundle identifier and dedupes by it.
    nonisolated private static func enumerateInstalledApps() -> [InstalledApp] {
        let fileManager = FileManager.default
        let directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]

        var seenBundleIDs = Set<String>()
        var found: [InstalledApp] = []
        for directory in directories {
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in contents where url.pathExtension == "app" {
                guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                      seenBundleIDs.insert(bundleID).inserted else { continue }
                let name = fileManager.displayName(atPath: url.path)
                found.append(InstalledApp(name: name, bundleID: bundleID, url: url))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Fallback for apps outside the standard folders.
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.message = "Choose an application"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            NSSound.beep()
            return
        }
        let name = FileManager.default.displayName(atPath: url.path)
        onSelect(.launchApp(bundleID: bundleID, name: name))
    }
}

// MARK: - Hotkey pane

private struct HotkeyPane: View {
    let current: Hotkey?
    let onCapture: (Hotkey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HotkeyRecorderField(hotkey: current, onCapture: onCapture)
            Text("Press a combination with ⌘, ⌥, or ⌃ — or a function key. Esc cancels recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// A focusable rounded field that records a keyboard shortcut.
///
/// Click to start recording; the field installs a local NSEvent monitor for
/// `.keyDown` + `.flagsChanged`, swallows keystrokes while recording, and captures
/// either (a) the first key pressed together with ⌘/⌥/⌃ (or any function key), or
/// (b) a MODIFIER-ONLY chord — hold two or more modifiers (e.g. Option + Right Shift)
/// and release them all. Esc without modifiers cancels. The monitor is always
/// removed on capture, cancel, or disappearance.
struct HotkeyRecorderField: View {
    var hotkey: Hotkey?
    var onCapture: (Hotkey) -> Void

    @State private var isRecording = false
    @State private var eventMonitor: Any?
    /// Modifier key codes pressed (in order) during the current chord attempt.
    @State private var chordKeys: [UInt16] = []

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(labelText)
                .foregroundStyle(labelIsPlaceholder ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isRecording {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                    .imageScale(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isRecording ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(nsColor: .separatorColor)),
                    lineWidth: isRecording ? 2 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .focusable()
        .onTapGesture {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        }
        .onDisappear {
            stopRecording()
        }
        .accessibilityLabel("Keyboard shortcut recorder")
        .accessibilityValue(hotkey?.display ?? "None")
    }

    private var labelText: String {
        if isRecording { return "Press keys…" }
        return hotkey?.display ?? "Click, then press keys"
    }

    private var labelIsPlaceholder: Bool {
        !isRecording && hotkey == nil
    }

    // MARK: Recording

    private func startRecording() {
        guard eventMonitor == nil else { return }
        isRecording = true
        chordKeys = []
        // Local monitors deliver on the main thread; the closure inherits main-actor isolation.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            event.type == .flagsChanged ? handleFlagsChanged(event) : handleKeyDown(event)
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        isRecording = false
        chordKeys = []
    }

    /// Modifier keys emit `flagsChanged`, never `keyDown` — this path captures
    /// modifier-only chords like Option + Right Shift. Presses accumulate; when
    /// every modifier is released with ≥2 keys collected (and no regular key was
    /// hit, which would have won via `handleKeyDown`), the chord is committed.
    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        let keyCode = event.keyCode
        let active = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])

        if Self.modifierDisplayNames[keyCode] != nil, !chordKeys.contains(keyCode),
           !active.isEmpty {
            chordKeys.append(keyCode) // A modifier went down.
        }

        if active.isEmpty { // Everything released: commit or discard.
            let chord = chordKeys
            if chord.count >= 2 {
                let display = chord
                    .compactMap { Self.modifierDisplayNames[$0] }
                    .joined(separator: " ")
                let captured = Hotkey(keyCode: 0, modifiers: 0, display: display, chordKeyCodes: chord)
                stopRecording()
                onCapture(captured)
            } else {
                chordKeys = [] // Single modifier tap: too accident-prone, ignore.
            }
        }
        return nil
    }

    /// Modifier key codes → display names, with left/right distinguished.
    static let modifierDisplayNames: [UInt16: String] = [
        55: "⌘", 54: "R⌘",
        56: "⇧", 60: "R⇧",
        58: "⌥", 61: "R⌥",
        59: "⌃", 62: "R⌃",
        63: "🌐",
    ]

    /// Returns `nil` to swallow every keystroke while recording.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode
        chordKeys = [] // A real key ends any modifier-chord attempt.

        // Esc without modifiers cancels.
        if keyCode == 53, flags.intersection([.command, .option, .control, .shift]).isEmpty {
            stopRecording()
            return nil
        }

        let hasQualifyingModifier = !flags.intersection([.command, .option, .control]).isEmpty
        let isFunctionKey = HotkeyRecorderField.functionKeyCodes.contains(keyCode)
        guard hasQualifyingModifier || isFunctionKey else {
            // Ignore (and swallow) plain keys so recording can't type into the app.
            return nil
        }

        let captured = Hotkey(
            keyCode: keyCode,
            modifiers: HotkeyRecorderField.cgEventFlags(from: flags).rawValue,
            display: HotkeyRecorderField.displayString(flags: flags, keyCode: keyCode, event: event)
        )
        stopRecording()
        onCapture(captured)
        return nil
    }

    // MARK: Key mapping

    /// Explicit NSEvent → CGEventFlags translation. The bit layouts of
    /// `NSEvent.ModifierFlags` and `CGEventFlags` differ, so raw values must never pass through.
    static func cgEventFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.command) { out.insert(.maskCommand) }
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.shift) { out.insert(.maskShift) }
        if flags.contains(.function) { out.insert(.maskSecondaryFn) }
        return out
    }

    /// Builds the human-readable combo in canonical symbol order ⌃⌥⇧⌘ + key name.
    static func displayString(flags: NSEvent.ModifierFlags, keyCode: UInt16, event: NSEvent) -> String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols + keyName(for: keyCode, event: event)
    }

    /// Human-readable name for a virtual key code, falling back to the event's characters.
    static func keyName(for keyCode: UInt16, event: NSEvent) -> String {
        if let name = HotkeyRecorderField.keyCodeNames[keyCode] {
            return name
        }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return characters.uppercased()
        }
        return "Key \(keyCode)"
    }

    /// kVK_F1…kVK_F20.
    static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// Virtual key code (kVK_*) → display name for letters, digits, F-keys, and special keys.
    static let keyCodeNames: [UInt16: String] = [
        // Letters
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        // Digits (top row)
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",
        // Punctuation
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 50: "`",
        // Special keys
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20",
    ]
}

// MARK: - Shell pane

private struct ShellPane: View {
    @Binding var text: String
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("open -a Terminal ~/Projects", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit(onCommit)
            Text("Runs in zsh. Fire-and-forget.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - URL pane

private struct URLPane: View {
    @Binding var text: String
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("https://example.com", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onCommit)
            Text("Any URL or scheme (https:, mailto:, raycast:, …). Opens with the default handler.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Shortcut pane

/// Async-loaded picker of the user's Apple Shortcuts. Selecting applies immediately.
private struct ShortcutPane: View {
    let current: String?
    let onSelect: (GestureAction) -> Void

    @State private var shortcuts: [String]?
    @State private var selection: String?

    init(current: String?, onSelect: @escaping (GestureAction) -> Void) {
        self.current = current
        self.onSelect = onSelect
        self._selection = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let shortcuts {
                if shortcuts.isEmpty {
                    Label("No shortcuts found", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text("Create shortcuts in the Shortcuts app, then reopen this editor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Shortcut", selection: $selection) {
                        Text("Choose a shortcut…").tag(String?.none)
                        ForEach(shortcuts, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selection) { _, newValue in
                        guard let newValue, newValue != current else { return }
                        onSelect(.runShortcut(name: newValue))
                    }
                    Text("Runs via Shortcuts.app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading shortcuts…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.vertical, 4)
        .task {
            guard shortcuts == nil else { return }
            shortcuts = await ActionRunner.availableShortcuts()
        }
    }
}
