//
//  GestureMonitor.swift
//  AppGlide
//

import AppKit
import Foundation
import OpenMultitouchSupport

/// nonisolated: pure constants, also read on the multitouch thread by
/// MouseTouchMonitor's frame callback.
nonisolated enum PrefKey {
    static let isPaused = "isPaused"
    static let reverseDirection = "reverseDirection"
    static let minimizedAppBehavior = "minimizedAppBehavior"
    static let swipeDistance = "swipeDistance"
    static let glideStepDistance = "glideStepDistance"
    static let focusDelay = "focusDelay"
    static let hudDuration = "hudDuration"
    static let hapticsEnabled = "hapticsEnabled"
    static let excludedBundleIDs = "excludedBundleIDs"
    static let musicHUDEnabled = "musicHUDEnabled"
    static let mouseScrollEnabled = "mouseScrollEnabled"
    static let mouseScrollModifier = "mouseScrollModifier"
    static let mouseStepDistance = "mouseStepDistance"
    static let hasShownSetup = "hasShownSetup"
    static let loginItemPath = "loginItemRegisteredPath"
}

extension Notification.Name {
    /// Posted by SettingsView when the excluded-apps set changes; AppSwitcher
    /// invalidates the live session so the ring drops the app immediately.
    static let appGlideExclusionsChanged = Notification.Name("appGlideExclusionsChanged")
}

/// What to do with apps whose windows are all minimized.
enum MinimizedAppBehavior: String {
    /// Keep them in the rotation; switching restores their frontmost window.
    case restore
    /// Leave them out of the rotation and legend, like window-less apps.
    case skip

    static func current(_ defaults: UserDefaults = .standard) -> MinimizedAppBehavior {
        MinimizedAppBehavior(rawValue: defaults.string(forKey: PrefKey.minimizedAppBehavior) ?? "") ?? .restore
    }
}

/// Stabilization delay: how long the selection must rest on an app before it
/// activates. 0 = instant (legacy commit-on-settle behavior). Shared by
/// AppSwitcher (commit timer), SwitcherOverlay (auto-hide clamp), and
/// SettingsView (slider default).
nonisolated enum FocusDelayPref {
    static let defaultSeconds: Double = 0.5

    static func seconds(_ defaults: UserDefaults = .standard) -> Double {
        // object(forKey:), not double(forKey:) — a stored 0 is a legitimate
        // value ("instant"), not "unset".
        max(0, (defaults.object(forKey: PrefKey.focusDelay) as? Double) ?? defaultSeconds)
    }
}

/// Consumes the global multitouch stream and forwards recognized swipes to the switcher.
final class GestureMonitor {
    private enum Constants {
        /// NSWorkspace.didWake fires before the built-in trackpad re-enumerates;
        /// OpenMultitouchSupport rebinds its MTDevice exactly then and can latch
        /// a dead handle, killing the touch stream until the listener is torn
        /// down and rebuilt. Successive delays: restart at ~3s (pad usually
        /// back) and ~10s (backstop — MTDeviceIsAvailable can still be false at
        /// 3s, which makes a restart silently no-op).
        static let wakeRestartDelays: [Duration] = [.seconds(3), .seconds(7)]
    }

    /// Fired on a 3-finger swipe down (music HUD toggle); wired by AppDelegate.
    var onMusicGesture: (() -> Void)?

    /// Live count of fingers on the built-in trackpad, updated every frame.
    /// ClickCloseMonitor reads it to tell a 3-finger close click from a
    /// normal click (both arrive as plain leftMouseDown events).
    private(set) var trackpadFingersDown = 0

    private let switcher: AppSwitcher
    private var recognizer = SwipeGestureRecognizer()
    private var task: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var wakeRecoveryTask: Task<Void, Never>?

    init(switcher: AppSwitcher) {
        self.switcher = switcher
    }

    func start() {
        guard task == nil else { return }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleWakeRecovery() }
            }
        }
        if !OMSManager.shared.startListening() {
            AppLog.log("failed to start multitouch listener")
        }
        task = Task { [weak self] in
            for await frame in OMSManager.shared.touchDataStream {
                guard let self else { break }
                self.handle(frame)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        trackpadFingersDown = 0
        // Fingers down at lid close never see their lift frame; drop any
        // latched tracking/failed state so the rebuilt stream starts clean.
        recognizer = SwipeGestureRecognizer()
        OMSManager.shared.stopListening()
        // wakeObserver stays registered: stop() is also the first half of
        // restart(), and the only unconditional stop is at app termination.
    }

    /// Each wake replaces any pending recovery so rapid sleep/wake cycles
    /// never stack restarts and delays count from the latest wake.
    private func scheduleWakeRecovery() {
        AppLog.log("trackpad: system woke, scheduling multitouch stream restarts")
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = Task { [weak self] in
            var elapsed = Duration.zero
            for delay in Constants.wakeRestartDelays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                elapsed += delay
                self.restart(reason: "post-wake T+\(elapsed)")
            }
        }
    }

    /// Full teardown/rebuild of the OMS listener: dropping the last listener
    /// makes the vendored manager MTDeviceStop/Release its device, re-adding
    /// runs a fresh MTDeviceCreateDefault — the in-process equivalent of
    /// relaunching the app. Never cancels wakeRecoveryTask (that task is the
    /// caller).
    private func restart(reason: String) {
        AppLog.log("trackpad: restarting multitouch stream (\(reason))")
        stop()
        start()
        AppLog.log("trackpad: restart done, listening=\(OMSManager.shared.isListening)")
    }

    private func handle(_ frame: [OMSTouchData]) {
        trackpadFingersDown = frame.filter { $0.state == .touching || $0.state == .making }.count
        guard let direction = recognizer.consume(frame) else { return }
        dispatch(direction)
    }

    /// Shared routing for every input source (trackpad recognizer, mouse
    /// scroll): applies the pause/music/invert prefs in exactly one place.
    func dispatch(_ direction: SwipeDirection) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: PrefKey.isPaused) else { return }
        // While Mission Control is up, every gesture belongs to it — most
        // importantly the swipe-down that dismisses it must not open the
        // music HUD.
        guard !MissionControlDetector.isActive() else { return }

        if direction == .peek {
            switcher.peek()
            return
        }
        if direction == .down {
            guard defaults.object(forKey: PrefKey.musicHUDEnabled) as? Bool ?? true else { return }
            onMusicGesture?()
            return
        }

        // Swipe right → previous/older app (step +1), swipe left → newer (step -1).
        var step = direction == .right ? 1 : -1
        if defaults.bool(forKey: PrefKey.reverseDirection) {
            step = -step
        }
        switcher.handleSwipe(step: step)
    }
}
