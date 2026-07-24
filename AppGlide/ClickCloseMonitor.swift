//
//  ClickCloseMonitor.swift
//  AppGlide
//

import AppKit
import CoreGraphics

/// C-convention callback — can't carry actor isolation. The tap's runloop
/// source lives on the main runloop, so assumeIsolated is a same-thread
/// assertion, not a hop.
private nonisolated func clickCloseTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return MainActor.assumeIsolated {
        Unmanaged<ClickCloseMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            .handle(type: type, event: event)
    }
}

/// A physical trackpad click while 3 fingers rest on the pad quits the app
/// currently selected in the carousel. The click (down, up, and any drag
/// between) is consumed so it never lands on whatever is under the pointer.
/// Outside a browsing session the callback is one cheap check per click.
final class ClickCloseMonitor {
    private let switcher: AppSwitcher
    private let gestureMonitor: GestureMonitor
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// A down was swallowed; swallow the matching up (and drags) too.
    private var swallowUntilUp = false

    init(switcher: AppSwitcher, gestureMonitor: GestureMonitor) {
        self.switcher = switcher
        self.gestureMonitor = gestureMonitor
    }

    /// Idempotent: called at launch and on app activation so the tap
    /// recovers once Accessibility is granted.
    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventType.leftMouseDown.rawValue
            | CGEventMask(1) << CGEventType.leftMouseUp.rawValue
            | CGEventMask(1) << CGEventType.leftMouseDragged.rawValue
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: clickCloseTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Active taps need Accessibility; the Settings Status row is the
            // recovery path.
            AppLog.log("click close tap creation failed (Accessibility missing?)")
            return
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        swallowUntilUp = false
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
        if type == .leftMouseUp || type == .leftMouseDragged {
            guard swallowUntilUp else { return Unmanaged.passUnretained(event) }
            if type == .leftMouseUp {
                swallowUntilUp = false
            }
            return nil
        }
        guard type == .leftMouseDown else { return Unmanaged.passUnretained(event) }
        // >= rather than ==: with the browsing gate already required, a stray
        // 4th contact during the press should still quit — passing the click
        // through to the app underneath is the worse failure.
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: PrefKey.isPaused),
              gestureMonitor.trackpadFingersDown >= SwipeGestureRecognizer.Constants.requiredFingers,
              switcher.isBrowsing,
              !MissionControlDetector.isActive() else {
            return Unmanaged.passUnretained(event)
        }
        swallowUntilUp = true
        switcher.closeSelected()
        return nil  // consume: the click must not land under the pointer
    }
}
