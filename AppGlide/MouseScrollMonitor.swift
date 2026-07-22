//
//  MouseScrollMonitor.swift
//  AppGlide
//

import CoreGraphics
import Foundation

enum MouseScrollModifier: String {
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
        static let stepDistance: Double = 50
        /// Downward points to toggle the music HUD (fires once, then latches).
        static let musicThreshold: Double = 60
        /// Same dominance rule as SwipeGestureRecognizer.
        static let dominanceRatio: Double = 1.5
        /// Gap without a matching event that ends the gesture.
        static let idleReset: Duration = .milliseconds(250)
        /// Points per fixed-point line unit for classic wheels
        /// (1 notch ≈ 1 line → ~2 notches per ring step).
        static let legacyLineMultiplier: Double = 25
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
    private let clock = ContinuousClock()
    #if DEBUG
    private var didLogSampleEvent = false
    #endif

    init(gestureMonitor: GestureMonitor) {
        self.gestureMonitor = gestureMonitor
    }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
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
            NSLog("AppGlide: mouse scroll tap creation failed (Accessibility missing?)")
            return
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
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
        #if DEBUG
        if !didLogSampleEvent {
            didLogSampleEvent = true
            NSLog(
                "AppGlide scroll sample: continuous=%d rawY=%.1f rawX=%.1f (expect +X fingers-right, +Y fingers-down with natural scrolling ON)",
                continuous ? 1 : 0,
                event.getDoubleValueField(continuous ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis1),
                event.getDoubleValueField(continuous ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventFixedPtDeltaAxis2)
            )
        }
        #endif

        accRing += ringDelta
        accMusic += musicDelta

        if abs(accRing) >= Constants.stepDistance,
           abs(accRing) > Constants.dominanceRatio * abs(accMusic) {
            let direction: SwipeDirection = accRing > 0 ? .right : .left
            // Carry the remainder so detents stay evenly spaced; verticality
            // is judged per detent, like the trackpad recognizer.
            accRing += accRing > 0 ? -Constants.stepDistance : Constants.stepDistance
            accMusic = 0
            gestureMonitor.dispatch(direction)
        } else if !musicLatched,
                  accMusic >= Constants.musicThreshold,
                  abs(accMusic) > Constants.dominanceRatio * abs(accRing) {
            musicLatched = true
            accRing = 0
            gestureMonitor.dispatch(.down)
        }

        return nil  // consume: the page behind must not scroll
    }

    private func resetGesture() {
        accRing = 0
        accMusic = 0
        musicLatched = false
        lastMatchedAt = nil
    }
}
