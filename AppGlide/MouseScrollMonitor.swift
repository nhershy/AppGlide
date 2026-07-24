//
//  MouseScrollMonitor.swift
//  AppGlide
//

import CoreGraphics
import Foundation

/// nonisolated: pure value logic, also read on the multitouch thread by
/// MouseTouchMonitor's frame callback.
nonisolated enum MouseScrollModifier: String {
    case option
    case command
    case control

    var flag: CGEventFlags {
        switch self {
        case .option: .maskAlternate
        case .command: .maskCommand
        case .control: .maskControl
        }
    }

    static func current(_ defaults: UserDefaults = .standard) -> MouseScrollModifier {
        MouseScrollModifier(rawValue: defaults.string(forKey: PrefKey.mouseScrollModifier) ?? "") ?? .option
    }
}

/// C-convention callback — can't carry actor isolation. The tap's runloop
/// source lives on the main runloop, so assumeIsolated is a same-thread
/// assertion, not a hop.
private nonisolated func mouseScrollTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return MainActor.assumeIsolated {
        Unmanaged<MouseScrollMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            .handle(type: type, event: event)
    }
}

/// Modifier + scroll on a Magic Mouse (or any mouse wheel) drives the app
/// ring and music HUD — the clamshell-mode stand-in for the 3-finger trackpad
/// swipe. Matching events are consumed so the page behind never scrolls;
/// everything else passes through untouched.
final class MouseScrollMonitor {
    enum Constants {
        /// Points of accumulated travel per ring step (continuous devices).
        /// Fallback when PrefKey.mouseStepDistance is unset.
        static let stepDistance: Double = 120
        /// Downward points to toggle the music HUD (fires once, then latches).
        static let musicThreshold: Double = 60
        /// Same dominance rule as SwipeGestureRecognizer.
        static let dominanceRatio: Double = 1.5
        /// Gap without a matching event that ends the gesture.
        static let idleReset: Duration = .milliseconds(250)
        /// Points per fixed-point line unit for classic wheels
        /// (1 notch ≈ 1 line → ~2 notches per ring step at the default
        /// stepDistance; scaled with it so classic wheels keep that cadence).
        static let legacyLineMultiplier: Double = 60
        /// Natural scrolling ON: fingers-right → positive pointDeltaAxis2.
        /// Flip to -1 if the DEBUG sample log disproves this.
        static let scrollSignForOlder: Double = 1
        /// Natural scrolling ON: fingers-down → positive pointDeltaAxis1.
        static let downwardYSign: Double = 1
        /// Classic wheel (natural usually OFF): roll-toward-you → negative
        /// fixedPtDeltaAxis1; rolling "down the stack" walks to older apps.
        static let wheelSignForOlder: Double = -1
    }

    private let gestureMonitor: GestureMonitor
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accRing: Double = 0   // positive = toward older (.right)
    private var accMusic: Double = 0  // positive = toward music toggle
    private var musicLatched = false
    private var consumeMomentum = false
    private var lastMatchedAt: ContinuousClock.Instant?
    private var pinnedByModifier = false
    private let clock = ContinuousClock()

    /// User-tunable via Settings; falls back to the constant, like the
    /// trackpad recognizer's distance prefs.
    private var stepDistance: Double {
        let stored = UserDefaults.standard.double(forKey: PrefKey.mouseStepDistance)
        return stored > 0 ? stored : Constants.stepDistance
    }

    init(gestureMonitor: GestureMonitor) {
        self.gestureMonitor = gestureMonitor
    }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
            | CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mouseScrollTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Active taps need Accessibility; the Settings Status row is the
            // recovery path.
            AppLog.log("mouse scroll tap creation failed (Accessibility missing?)")
            return
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        clearModifierPin()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // WindowServer disables slow/user-interrupted taps; recover and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        // Handled before the enabled/paused guards so a pin can never leak
        // through a mid-hold settings change; never consumed.
        if type == .flagsChanged {
            handleFlagsChanged(event)
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PrefKey.mouseScrollEnabled) as? Bool ?? true,
              !defaults.bool(forKey: PrefKey.isPaused) else {
            resetGesture()
            consumeMomentum = false
            return Unmanaged.passUnretained(event)
        }

        // Momentum tail: swallow it if it belongs to a gesture we consumed
        // (even after the modifier is released) but never accumulate it —
        // that's what prevents runaway steps after finger lift.
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if momentum != 0 {
            guard consumeMomentum else { return Unmanaged.passUnretained(event) }
            if momentum == 3 {  // kCGMomentumScrollPhaseEnd
                consumeMomentum = false
            }
            return nil
        }

        // Exactly the chosen modifier among {option, command, control};
        // shift/fn don't disqualify.
        let relevant = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl])
        guard relevant == MouseScrollModifier.current(defaults).flag else {
            // Also clears the pin in case a flagsChanged was missed while the
            // tap was disabled.
            clearModifierPin()
            resetGesture()
            consumeMomentum = false
            return Unmanaged.passUnretained(event)
        }

        let now = clock.now
        if let last = lastMatchedAt, now - last > Constants.idleReset {
            resetGesture()
        }
        lastMatchedAt = now
        consumeMomentum = true

        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let ringDelta: Double
        let musicDelta: Double
        if continuous {
            ringDelta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
                * Constants.scrollSignForOlder
            musicDelta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                * Constants.downwardYSign
        } else {
            // Classic wheels are vertical-only: the wheel drives the ring.
            ringDelta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                * Constants.legacyLineMultiplier * Constants.wheelSignForOlder
            musicDelta = 0
        }

        accRing += ringDelta
        accMusic += musicDelta

        if abs(accRing) >= stepDistance,
           abs(accRing) > Constants.dominanceRatio * abs(accMusic) {
            let direction: SwipeDirection = accRing > 0 ? .right : .left
            // Carry the remainder so detents stay evenly spaced; verticality
            // is judged per detent, like the trackpad recognizer.
            accRing += accRing > 0 ? -stepDistance : stepDistance
            accMusic = 0
            setModifierPin()
            gestureMonitor.dispatch(direction)
        } else if !musicLatched,
                  accMusic >= Constants.musicThreshold,
                  abs(accMusic) > Constants.dominanceRatio * abs(accRing) {
            musicLatched = true
            accRing = 0
            setModifierPin()
            gestureMonitor.dispatch(.down)
        }

        return nil  // consume: the page behind must not scroll
    }

    /// Touch-peek (MouseTouchMonitor) routes its pin through here so the pin
    /// stays owned by the object that observes the release. Never pin without
    /// a live tap — no tap means no flagsChanged, so nothing could clear it.
    func noteModifierActivity() {
        guard tap != nil else { return }
        setModifierPin()
    }

    /// Modifier went up (or changed) while the HUD was pinned: unpin so the
    /// normal auto-hide countdown starts. consumeMomentum is deliberately
    /// left alone — the momentum tail must keep being swallowed after release.
    private func handleFlagsChanged(_ event: CGEvent) {
        guard pinnedByModifier else { return }
        let relevant = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl])
        if relevant != MouseScrollModifier.current(UserDefaults.standard).flag {
            clearModifierPin()
            resetGesture()
        }
    }

    /// While the modifier is held after a step fired, keep the HUD up —
    /// same pin registry the hover tracking uses.
    private func setModifierPin() {
        guard !pinnedByModifier else { return }
        pinnedByModifier = true
        HUDHoverState.shared.setHovering(true, for: "modifierHold")
    }

    private func clearModifierPin() {
        guard pinnedByModifier else { return }
        pinnedByModifier = false
        HUDHoverState.shared.setHovering(false, for: "modifierHold")
    }

    private func resetGesture() {
        accRing = 0
        accMusic = 0
        musicLatched = false
        lastMatchedAt = nil
    }
}
