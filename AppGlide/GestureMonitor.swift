//
//  GestureMonitor.swift
//  AppGlide
//

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
    static let activationMode = "activationMode"
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
    /// Posted by SettingsView when the activation mode changes;
    /// ClickCommitMonitor installs or removes its click tap immediately.
    static let appGlideActivationModeChanged = Notification.Name("appGlideActivationModeChanged")
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

/// How the carousel selection becomes the frontmost app.
nonisolated enum ActivationMode: String {
    /// The selection activates after resting for the focus-delay pref.
    case timed
    /// Trackpad only: nothing auto-activates — a physical 3-finger click
    /// commits (ClickCommitMonitor). Mouse steps stay timed.
    case manualClick

    static func current(_ defaults: UserDefaults = .standard) -> ActivationMode {
        ActivationMode(rawValue: defaults.string(forKey: PrefKey.activationMode) ?? "") ?? .timed
    }
}

/// Which input device produced a swipe step — manual activation mode applies
/// only to the trackpad, so AppSwitcher needs to know.
nonisolated enum SwipeSource {
    case trackpad
    case mouse
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
    /// Fired on a 3-finger swipe down (music HUD toggle); wired by AppDelegate.
    var onMusicGesture: (() -> Void)?

    /// Live count of fingers on the built-in trackpad, updated every frame.
    /// ClickCommitMonitor reads it to tell a 3-finger commit click from a
    /// normal click (both arrive as plain leftMouseDown events).
    private(set) var trackpadFingersDown = 0

    private let switcher: AppSwitcher
    private var recognizer = SwipeGestureRecognizer()
    private var task: Task<Void, Never>?

    init(switcher: AppSwitcher) {
        self.switcher = switcher
    }

    func start() {
        guard task == nil else { return }
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
        OMSManager.shared.stopListening()
    }

    private func handle(_ frame: [OMSTouchData]) {
        trackpadFingersDown = frame.filter { $0.state == .touching || $0.state == .making }.count
        guard let direction = recognizer.consume(frame) else { return }
        dispatch(direction, source: .trackpad)
    }

    /// Shared routing for every input source (trackpad recognizer, mouse
    /// scroll): applies the pause/music/invert prefs in exactly one place.
    func dispatch(_ direction: SwipeDirection, source: SwipeSource) {
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
        switcher.handleSwipe(step: step, source: source)
    }
}
