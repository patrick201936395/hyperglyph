import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Swallows trackpad scroll-wheel events while two-finger draw mode is armed, so
/// drawing a shape (e.g. a "C") doesn't scroll the content underneath.
///
/// Implementation: a session-level `CGEventTap` (`.cgSessionEventTap`,
/// `.headInsertEventTap`, `.defaultTap`) matching `.scrollWheel` events — momentum
/// scroll events arrive as `.scrollWheel` too, so one mask covers both. The tap is
/// created lazily on the first `begin()` and its run-loop source is added to the
/// main run loop, so the C callback always executes on the main thread and may
/// safely hop onto the main actor via `MainActor.assumeIsolated`.
///
/// Requires Accessibility trust (`AXIsProcessTrusted`). Without it, `begin()` logs
/// once and degrades gracefully to a no-op — gestures still work, pages just scroll.
public final class ScrollSuppressor {
    /// True while scroll events are being swallowed (including the short grace
    /// period after `end()` that eats residual momentum-scroll events).
    public private(set) var isActive = false

    /// The event tap; kept alive for the lifetime of this object.
    private nonisolated(unsafe) var tap: CFMachPort?
    /// The tap's run-loop source, installed on the main run loop.
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    /// Pending deferred disable scheduled by `end()`; cancelled if `begin()` reoccurs.
    private var pendingDisable: Task<Void, Never>?
    /// Ensures the missing-permission warning is logged only once.
    private var didLogMissingPermission = false

    private let logger = Logger(subsystem: "com.hyperglyph.Hyperglyph", category: "ScrollSuppressor")

    /// How long after `end()` scroll events keep being swallowed, to absorb
    /// residual momentum events from the just-finished draw gesture.
    private static let graceDuration: Duration = .milliseconds(300)

    public init() {}

    /// Starts swallowing scroll events. Lazily creates and enables the event tap.
    /// No-ops (with a one-time log) if Accessibility permission is missing.
    public func begin() {
        pendingDisable?.cancel()
        pendingDisable = nil

        guard AXIsProcessTrusted() else {
            if !didLogMissingPermission {
                didLogMissingPermission = true
                logger.warning("Accessibility permission not granted — scroll suppression disabled; drawing may scroll underlying content.")
            }
            return
        }

        if tap == nil {
            createTap()
        }
        guard let tap else { return }

        isActive = true
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Stops swallowing scroll events after a 300 ms grace period that eats residual
    /// momentum-scroll events, then disables the tap to save CPU. No-op when not
    /// active. A `begin()` during the grace period cancels the pending disable.
    public func end() {
        guard isActive else { return }
        pendingDisable?.cancel()
        pendingDisable = Task { [weak self] in
            try? await Task.sleep(for: ScrollSuppressor.graceDuration)
            guard !Task.isCancelled, let self else { return }
            self.isActive = false
            if let tap = self.tap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            self.pendingDisable = nil
        }
    }

    deinit {
        // Tear the tap down so the C callback can never fire against a dangling
        // refcon (the refcon holds `self` unretained).
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }

    // MARK: - Tap plumbing

    /// Creates the scroll-wheel event tap and installs its source on the main run loop.
    private func createTap() {
        let mask = CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hyperglyphScrollTapCallback,
            userInfo: refcon
        ) else {
            logger.error("Failed to create scroll-wheel event tap.")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            logger.error("Failed to create run-loop source for scroll-wheel event tap.")
            CFMachPortInvalidate(port)
            return
        }

        tap = port
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// Decides what to do with an incoming tap event. Called from the C callback,
    /// which runs on the main thread (the tap's source lives on the main run loop).
    fileprivate func decide(for type: CGEventType) -> ScrollTapDecision {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disabled our tap (we were too slow, or the user
            // interrupted); re-enable so suppression keeps working.
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return .pass
        default:
            return isActive ? .swallow : .pass
        }
    }
}

/// Outcome of a tap-callback decision. `Sendable` so it can cross out of
/// `MainActor.assumeIsolated` inside the nonisolated C callback.
private enum ScrollTapDecision: Sendable {
    case pass
    case swallow
}

/// C-convention `CGEventTapCallBack`. Cannot capture context and is not
/// MainActor-isolated, so it recovers the suppressor from `refcon` and hops onto
/// the main actor with `assumeIsolated` — safe because the tap's run-loop source
/// is installed on the main run loop, so this always executes on the main thread.
private nonisolated func hyperglyphScrollTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let suppressor = Unmanaged<ScrollSuppressor>.fromOpaque(refcon).takeUnretainedValue()

    let decision = MainActor.assumeIsolated {
        suppressor.decide(for: type)
    }

    switch decision {
    case .swallow:
        return nil
    case .pass:
        return Unmanaged.passUnretained(event)
    }
}
