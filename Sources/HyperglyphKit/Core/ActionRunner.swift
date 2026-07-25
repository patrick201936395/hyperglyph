import AppKit
import ApplicationServices
import Foundation
import Synchronization
import os

/// Executes a `GestureAction` in response to a recognized gesture.
///
/// All entry points are fire-and-forget: `run(_:)` returns immediately and never throws.
/// Failures (missing app, malformed URL, un-launchable process, missing Accessibility
/// permission) are logged via `os.Logger` and otherwise swallowed — a gesture misfire
/// must never crash or stall the app.
///
/// The class is main-actor isolated (package default isolation); detached subprocesses
/// are retained in a lock-guarded static table so they are not deallocated (and thus
/// force-terminated) before they exit on their own.
public final class ActionRunner {

    // MARK: - Logging

    private nonisolated static let logger = Logger(subsystem: "com.hyperglyph.app", category: "ActionRunner")

    // MARK: - Detached process bookkeeping

    /// Processes we launched fire-and-forget, keyed by a launch token. Retaining them here
    /// keeps Foundation from reaping the `Process` object while the child is still running;
    /// each entry removes itself from its termination handler. Guarded by the `Mutex`, so it
    /// is safe to touch from any thread (termination handlers fire on arbitrary queues).
    private nonisolated static let liveProcesses = Mutex<[UUID: Process]>([:])

    /// Creates the runner. Stateless apart from the shared process table.
    public init() {}

    // MARK: - Accessibility

    /// Whether the process is currently trusted for Accessibility (required to synthesize
    /// keyboard events). Mirrors `AXIsProcessTrusted()`.
    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks the system to trust this process for Accessibility, showing the standard
    /// System Settings prompt if permission has not been granted yet.
    public static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Running actions

    /// Performs `action` asynchronously and returns immediately.
    ///
    /// Failures are logged, never thrown; long-running work (subprocesses, the key-up
    /// delay of a synthesized hotkey) happens off the current call stack.
    public func run(_ action: GestureAction) {
        switch action {
        case .launchApp(let bundleID, let name):
            launchApp(bundleID: bundleID, name: name)
        case .keyboardShortcut(let hotkey):
            postKeyboardShortcut(hotkey)
        case .shellCommand(let command):
            Self.launchDetached(
                executablePath: "/bin/zsh",
                arguments: ["-lc", command],
                label: "shell command"
            )
        case .openURL(let urlString):
            openURL(urlString)
        case .runShortcut(let name):
            Self.launchDetached(
                executablePath: "/usr/bin/shortcuts",
                arguments: ["run", name],
                label: "shortcut \u{201C}\(name)\u{201D}"
            )
        }
    }

    // MARK: - Apple Shortcuts discovery

    /// Returns the names of the user's Apple Shortcuts, sorted alphabetically, by invoking
    /// `/usr/bin/shortcuts list` off the main actor. Returns `[]` if the binary is missing,
    /// exits non-zero, or produces no parsable output; the subprocess is force-terminated
    /// if it has not finished within 10 seconds.
    public static func availableShortcuts() async -> [String] {
        await Task.detached(priority: .utility) { () -> [String] in
            let toolPath = "/usr/bin/shortcuts"
            guard FileManager.default.isExecutableFile(atPath: toolPath) else {
                logger.error("shortcuts binary not found at \(toolPath, privacy: .public)")
                return []
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: toolPath)
            process.arguments = ["list"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                logger.error("Failed to run shortcuts list: \(error.localizedDescription, privacy: .public)")
                return []
            }

            // Watchdog: if `shortcuts list` hangs, kill it so the read below unblocks
            // and we fall through to returning whatever (likely nothing) we got.
            let watchdog = UncheckedSendableBox(process)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                if watchdog.value.isRunning {
                    logger.error("shortcuts list timed out; terminating")
                    watchdog.value.terminate()
                }
            }

            // Blocking reads are fine here: we are on a detached task, not the main actor.
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
                logger.error("shortcuts list exited with status \(process.terminationStatus)")
                return []
            }

            return text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }.value
    }

    // MARK: - Launch app

    private func launchApp(bundleID: String, name: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Self.logger.error("No application for bundle id \(bundleID, privacy: .public) (\(name, privacy: .public))")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Launches the app, or brings it to the front if it is already running.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Self.logger.error("Failed to open \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Keyboard shortcut

    private func postKeyboardShortcut(_ hotkey: Hotkey) {
        guard Self.isAccessibilityTrusted else {
            Self.logger.error("Skipping hotkey \(hotkey.display, privacy: .public): Accessibility permission not granted")
            return
        }
        if let chord = hotkey.chordKeyCodes, !chord.isEmpty {
            postModifierChord(chord, display: hotkey.display)
            return
        }
        // Inherits main-actor isolation; the sleep suspends rather than blocks.
        Task {
            let source = CGEventSource(stateID: .hidSystemState)
            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: hotkey.keyCode, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: hotkey.keyCode, keyDown: false)
            else {
                Self.logger.error("Failed to create CGEvents for hotkey \(hotkey.display, privacy: .public)")
                return
            }
            let flags = CGEventFlags(rawValue: hotkey.modifiers)
            keyDown.flags = flags
            keyUp.flags = flags
            keyDown.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(20))
            keyUp.post(tap: .cghidEventTap)
        }
    }

    /// Per-modifier-keycode flag contribution: device-independent CGEventFlags mask
    /// plus the NX device-dependent bit that distinguishes left/right keys.
    private nonisolated static let modifierKeyFlags: [UInt16: UInt64] = [
        54: CGEventFlags.maskCommand.rawValue | 0x0010,   // right command
        55: CGEventFlags.maskCommand.rawValue | 0x0008,   // left command
        56: CGEventFlags.maskShift.rawValue | 0x0002,     // left shift
        60: CGEventFlags.maskShift.rawValue | 0x0004,     // right shift
        58: CGEventFlags.maskAlternate.rawValue | 0x0020, // left option
        61: CGEventFlags.maskAlternate.rawValue | 0x0040, // right option
        59: CGEventFlags.maskControl.rawValue | 0x0001,   // left control
        62: CGEventFlags.maskControl.rawValue | 0x2000,   // right control
        63: CGEventFlags.maskSecondaryFn.rawValue,        // fn / globe
    ]

    /// Simulates a modifier-only chord (e.g. Option + Right Shift): presses each
    /// modifier in recorded order and releases in reverse, as `flagsChanged`
    /// events with cumulative flags — the shape real modifier presses have, which
    /// is what apps listening for modifier-chord hotkeys observe.
    private func postModifierChord(_ chord: [UInt16], display: String) {
        Task {
            let source = CGEventSource(stateID: .hidSystemState)

            func post(keyCode: UInt16, down: Bool, flags: UInt64) {
                guard let event = CGEvent(
                    keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down
                ) else {
                    Self.logger.error("Failed to create chord event for \(display, privacy: .public)")
                    return
                }
                event.type = .flagsChanged
                event.flags = CGEventFlags(rawValue: flags)
                event.post(tap: .cghidEventTap)
            }

            var accumulated: UInt64 = 0
            for keyCode in chord {
                accumulated |= Self.modifierKeyFlags[keyCode] ?? 0
                post(keyCode: keyCode, down: true, flags: accumulated)
                try? await Task.sleep(for: .milliseconds(15))
            }
            try? await Task.sleep(for: .milliseconds(40))
            for keyCode in chord.reversed() {
                accumulated &= ~(Self.modifierKeyFlags[keyCode] ?? 0)
                post(keyCode: keyCode, down: false, flags: accumulated)
                try? await Task.sleep(for: .milliseconds(15))
            }
        }
    }

    // MARK: - Open URL

    private func openURL(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Self.logger.error("Ignoring empty URL action")
            return
        }
        // "example.com" and friends get a scheme so NSWorkspace treats them as web URLs.
        let candidate: String
        if let parsed = URL(string: trimmed), parsed.scheme != nil {
            candidate = trimmed
        } else {
            candidate = "https://" + trimmed
        }
        guard let url = URL(string: candidate) else {
            Self.logger.error("Malformed URL: \(urlString, privacy: .public)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Detached subprocess launcher

    /// Launches `executablePath` with `arguments`, detached: stdio is discarded, nothing
    /// waits on the child, and the `Process` object is parked in `liveProcesses` until its
    /// termination handler removes it. Synchronous and non-blocking (`Process.run()` is a
    /// spawn, not a wait), so it is safe to call from the main actor.
    private nonisolated static func launchDetached(
        executablePath: String,
        arguments: [String],
        label: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let token = UUID()
        process.terminationHandler = { finished in
            if finished.terminationStatus != 0 {
                logger.error("Detached \(label, privacy: .public) exited with status \(finished.terminationStatus)")
            }
            _ = liveProcesses.withLock { $0.removeValue(forKey: token) }
        }

        // Insert before run() so a child that exits instantly still finds its entry
        // to remove (the handler can fire on another thread immediately after spawn).
        liveProcesses.withLock { $0[token] = process }
        do {
            try process.run()
        } catch {
            _ = liveProcesses.withLock { $0.removeValue(forKey: token) }
            logger.error("Failed to launch \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Helpers

/// Minimal box for threading a known-thread-safe reference (here: a `Process`, whose
/// `isRunning`/`terminate()` are safe to call from any thread) through a `@Sendable` closure.
private nonisolated final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
