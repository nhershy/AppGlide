//
//  GestureMonitor.swift
//  AppGlide
//

import Foundation
import OpenMultitouchSupport

enum PrefKey {
    static let isPaused = "isPaused"
    static let reverseDirection = "reverseDirection"
    static let minimizedAppBehavior = "minimizedAppBehavior"
    static let swipeDistance = "swipeDistance"
    static let glideStepDistance = "glideStepDistance"
    static let hudDuration = "hudDuration"
    static let hapticsEnabled = "hapticsEnabled"
    static let excludedBundleIDs = "excludedBundleIDs"
    static let musicHUDEnabled = "musicHUDEnabled"
    static let mouseScrollEnabled = "mouseScrollEnabled"
    static let mouseScrollModifier = "mouseScrollModifier"
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

/// Consumes the global multitouch stream and forwards recognized swipes to the switcher.
final class GestureMonitor {
    /// Fired on a 3-finger swipe down (music HUD toggle); wired by AppDelegate.
    var onMusicGesture: (() -> Void)?

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
        OMSManager.shared.stopListening()
    }

    private func handle(_ frame: [OMSTouchData]) {
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
