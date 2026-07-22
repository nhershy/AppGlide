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
    private let switcher: AppSwitcher
    private var recognizer = SwipeGestureRecognizer()
    private var task: Task<Void, Never>?
    #if DEBUG
    private var didLogSampleFrame = false
    #endif

    init(switcher: AppSwitcher) {
        self.switcher = switcher
    }

    func start() {
        guard task == nil else { return }
        if !OMSManager.shared.startListening() {
            NSLog("AppGlide: failed to start multitouch listener")
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
        #if DEBUG
        if !didLogSampleFrame, frame.count >= 3 {
            didLogSampleFrame = true
            NSLog("AppGlide sample frame: \(frame.map(\.description).joined(separator: " | "))")
        }
        #endif

        guard let direction = recognizer.consume(frame) else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: PrefKey.isPaused) else { return }

        // Swipe right → previous/older app (step +1), swipe left → newer (step -1).
        var step = direction == .right ? 1 : -1
        if defaults.bool(forKey: PrefKey.reverseDirection) {
            step = -step
        }
        #if DEBUG
        NSLog("AppGlide: swipe \(direction) -> step \(step)")
        #endif
        switcher.handleSwipe(step: step)
    }
}
