import AppKit
import Foundation
import IOKit
import os

/// Plays haptic feedback patterns on the built-in Force Touch trackpad.
///
/// On initialization the engine attempts to bind the private MultitouchSupport
/// actuator API (`MTActuatorCreateFromDeviceID` & co.), which produces real
/// trackpad "taptic" pulses with controllable strength. If any step of that
/// binding fails, the engine silently degrades to
/// `NSHapticFeedbackManager.defaultPerformer` and reports the mode via
/// ``usingPrivateAPI``.
///
/// Note: trackpad haptics only physically fire while a finger is resting on
/// the pad. Gesture patterns fire while (or immediately as) fingers lift, so
/// the first pulse of every pattern is issued synchronously from ``play(_:)``
/// to catch the finger before it fully leaves the surface.
public final class HapticEngine {
    /// The feedback vocabulary the coordinator uses.
    public enum Pattern {
        /// Draw mode armed: single weak tick.
        case arm
        /// Shape recognized and action fired: medium pulse, then a strong pulse 70 ms later.
        case success
        /// Shape not recognized / no action bound: two weak ticks 50 ms apart.
        case fail
        /// Zone tap fired: single strong pulse.
        case zone
    }

    /// `true` when the private MultitouchSupport actuator was successfully
    /// opened and pulses go straight to the trackpad hardware; `false` when
    /// the engine is falling back to `NSHapticFeedbackManager`.
    public private(set) var usingPrivateAPI: Bool

    private let actuator: TrackpadActuator?
    /// Pending delayed second pulse of a multi-pulse pattern.
    private var pulseTask: Task<Void, Never>?
    /// Wake observer token; stored so `deinit` can unregister it.
    /// `nonisolated(unsafe)`: written once in init, read once in deinit —
    /// no concurrent access is possible across that lifecycle.
    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?
    /// Captured at init so `deinit` (nonisolated) never touches `NSWorkspace.shared`.
    private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter

    private static let logger = Logger(subsystem: "com.hyperglyph.Hyperglyph", category: "HapticEngine")

    public init() {
        if let actuator = TrackpadActuator() {
            self.actuator = actuator
            self.usingPrivateAPI = true
        } else {
            self.actuator = nil
            self.usingPrivateAPI = false
            Self.logger.info("Private MultitouchSupport actuator unavailable; using NSHapticFeedbackManager fallback.")
        }

        // After system sleep the actuator connection can go stale even though
        // MTActuatorIsOpen still reports true. Proactively recycle it on wake
        // so the first post-wake gesture already produces hardware haptics.
        if let actuator = self.actuator {
            wakeObserver = workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                actuator.recycle()
            }
        }
    }

    deinit {
        if let wakeObserver {
            workspaceNotificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Plays the given pattern. Fire-and-forget: never blocks the caller.
    /// The first pulse is emitted synchronously; any follow-up pulses are
    /// scheduled on a task and cancel a previously pending follow-up.
    public func play(_ pattern: Pattern) {
        guard actuator != nil, usingPrivateAPI else {
            playFallback(pattern)
            return
        }

        pulseTask?.cancel()
        pulseTask = nil

        switch pattern {
        case .arm:
            emit(.weak)
        case .zone:
            emit(.strong)
        case .success:
            emit(.medium)
            scheduleFollowUp(.strong, after: .milliseconds(70))
        case .fail:
            emit(.weak)
            scheduleFollowUp(.weak, after: .milliseconds(50))
        }
    }

    // MARK: - Private

    /// Fires one hardware pulse, degrading to the equivalent
    /// `NSHapticFeedbackManager` pattern for this pulse only when the
    /// actuator (including its recycle-and-retry path) fails, so the user
    /// still feels something even with a broken private-API connection.
    private func emit(_ strength: TrackpadActuator.Strength) {
        guard let actuator else { return }
        if !actuator.pulse(strength) {
            NSHapticFeedbackManager.defaultPerformer.perform(
                Self.fallbackFeedback(for: strength),
                performanceTime: .now
            )
        }
    }

    private static func fallbackFeedback(for strength: TrackpadActuator.Strength) -> NSHapticFeedbackManager.FeedbackPattern {
        switch strength {
        case .weak: .alignment
        case .medium: .levelChange
        case .strong: .generic
        }
    }

    private func scheduleFollowUp(_ strength: TrackpadActuator.Strength, after delay: Duration) {
        pulseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.emit(strength)
        }
    }

    private func playFallback(_ pattern: Pattern) {
        let feedback: NSHapticFeedbackManager.FeedbackPattern
        switch pattern {
        case .arm: feedback = .alignment
        case .success: feedback = .levelChange
        case .fail: feedback = .generic
        case .zone: feedback = .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(feedback, performanceTime: .now)
    }
}

// MARK: - Private MultitouchSupport actuator

/// Thin RAII wrapper around the private `MTActuator*` C API.
///
/// Lifetime: `init?` binds the symbols, creates the actuator for the built-in
/// trackpad, and opens it; `deinit` closes it (the CF reference itself is
/// released by ARC). All calls happen on the main actor in practice; the class
/// is `@unchecked Sendable` only so it can be captured by the engine's
/// follow-up pulse tasks and its wake observer, both of which also run on the
/// main actor / main queue.
private nonisolated final class TrackpadActuator: @unchecked Sendable {
    /// Known-good actuation IDs (1...6 exist on current hardware).
    enum Strength: Int32 {
        case weak = 3
        case medium = 4
        case strong = 6
    }

    private typealias CreateFn = @convention(c) (UInt64) -> Unmanaged<AnyObject>?
    private typealias OpenFn = @convention(c) (AnyObject) -> IOReturn
    private typealias CloseFn = @convention(c) (AnyObject) -> IOReturn
    private typealias ActuateFn = @convention(c) (AnyObject, Int32, UInt32, Float32, Float32) -> IOReturn
    private typealias IsOpenFn = @convention(c) (AnyObject) -> Bool

    /// The multitouch device ID of the built-in trackpad actuator.
    private static let builtInTrackpadDeviceID: UInt64 = 0x200000001

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private static let logger = Logger(subsystem: "com.hyperglyph.Hyperglyph", category: "TrackpadActuator")

    /// Retained actuator object (`MTActuatorCreateFromDeviceID` follows the
    /// CF Create rule; ARC releases this on deinit).
    private let actuatorRef: AnyObject
    private let openFn: OpenFn
    private let closeFn: CloseFn
    private let actuateFn: ActuateFn
    private let isOpenFn: IsOpenFn

    /// Set after the first runtime failure so the log isn't spammed on every pulse.
    private var didLogRuntimeFailure = false

    init?() {
        // The framework stays resident for the process lifetime; we never
        // dlclose so the bound function pointers remain valid.
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else {
            Self.logger.error("dlopen(MultitouchSupport) failed.")
            return nil
        }

        guard
            let createSym = dlsym(handle, "MTActuatorCreateFromDeviceID"),
            let openSym = dlsym(handle, "MTActuatorOpen"),
            let closeSym = dlsym(handle, "MTActuatorClose"),
            let actuateSym = dlsym(handle, "MTActuatorActuate"),
            let isOpenSym = dlsym(handle, "MTActuatorIsOpen")
        else {
            Self.logger.error("dlsym failed for one or more MTActuator symbols.")
            return nil
        }

        let create = unsafeBitCast(createSym, to: CreateFn.self)
        let open = unsafeBitCast(openSym, to: OpenFn.self)
        let close = unsafeBitCast(closeSym, to: CloseFn.self)
        let actuate = unsafeBitCast(actuateSym, to: ActuateFn.self)
        let isOpen = unsafeBitCast(isOpenSym, to: IsOpenFn.self)

        guard let created = create(Self.builtInTrackpadDeviceID) else {
            Self.logger.error("MTActuatorCreateFromDeviceID returned nil (no built-in trackpad actuator?).")
            return nil
        }
        let ref = created.takeRetainedValue()

        let openResult = open(ref)
        guard openResult == kIOReturnSuccess else {
            Self.logger.error("MTActuatorOpen failed: \(openResult).")
            return nil
        }

        self.actuatorRef = ref
        self.openFn = open
        self.closeFn = close
        self.actuateFn = actuate
        self.isOpenFn = isOpen
    }

    deinit {
        if isOpenFn(actuatorRef) {
            _ = closeFn(actuatorRef)
        }
    }

    /// Fires a single haptic pulse, reopening the actuator first if the
    /// system closed it (e.g. after sleep). Never throws or blocks.
    ///
    /// After sleep/wake the connection can go stale: `MTActuatorIsOpen`
    /// still reports true while `MTActuatorActuate` fails. When actuation
    /// fails, the connection is recycled (close + reopen) and the pulse
    /// retried once before giving up.
    ///
    /// - Returns: `true` if a hardware pulse was actually issued, so the
    ///   caller can substitute its own fallback feedback on failure.
    @discardableResult
    func pulse(_ strength: Strength) -> Bool {
        if !isOpenFn(actuatorRef) {
            let reopenResult = openFn(actuatorRef)
            guard reopenResult == kIOReturnSuccess else {
                logRuntimeFailureOnce("MTActuatorOpen (reopen) failed: \(String(reopenResult, radix: 16))")
                return false
            }
        }
        if actuateFn(actuatorRef, strength.rawValue, 0, 0, 2.0) == kIOReturnSuccess {
            return true
        }

        // Stale connection: recycle it and retry the actuation once.
        _ = closeFn(actuatorRef)
        let reopenResult = openFn(actuatorRef)
        guard reopenResult == kIOReturnSuccess else {
            logRuntimeFailureOnce("MTActuatorOpen (recycle after failed actuate) failed: \(String(reopenResult, radix: 16))")
            return false
        }
        let retryResult = actuateFn(actuatorRef, strength.rawValue, 0, 0, 2.0)
        guard retryResult == kIOReturnSuccess else {
            logRuntimeFailureOnce("MTActuatorActuate failed after recycle: \(String(retryResult, radix: 16))")
            return false
        }
        return true
    }

    /// Closes and reopens the actuator connection. Called on system wake so
    /// the first post-wake pulse doesn't pay the recycle-and-retry cost. If
    /// the reopen fails, the actuator is left closed and ``pulse(_:)`` will
    /// attempt the open again on its next call.
    func recycle() {
        if isOpenFn(actuatorRef) {
            _ = closeFn(actuatorRef)
        }
        let reopenResult = openFn(actuatorRef)
        if reopenResult != kIOReturnSuccess {
            logRuntimeFailureOnce("MTActuatorOpen (post-wake recycle) failed: \(String(reopenResult, radix: 16))")
        }
    }

    private func logRuntimeFailureOnce(_ message: String) {
        guard !didLogRuntimeFailure else { return }
        didLogRuntimeFailure = true
        Self.logger.error("\(message, privacy: .public)")
    }
}
