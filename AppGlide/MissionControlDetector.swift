//
//  MissionControlDetector.swift
//  AppGlide
//

import AppKit
import CoreGraphics

/// Detects whether Mission Control is currently on screen, so gestures can be
/// suppressed while it's up (notably: the 3-finger swipe DOWN that dismisses
/// Mission Control must not open the music HUD).
///
/// Calibrated on macOS 26.5 (2026-07-22): while Mission Control is active the
/// Dock owns an on-screen full-screen window at layer 18 that does not exist
/// otherwise (baseline Dock windows sit at layer 20 and a deep negative layer).
@MainActor
enum MissionControlDetector {
    private static let missionControlLayer = 18
    private static let ttl: Duration = .milliseconds(150)
    private static let clock = ContinuousClock()
    private static var cached: (active: Bool, at: ContinuousClock.Instant)?

    static func isActive() -> Bool {
        let now = clock.now
        if let cached, now - cached.at < ttl {
            return cached.active
        }
        let active = queryDockWindows()
        cached = (active, now)
        return active
    }

    private static func queryDockWindows() -> Bool {
        guard let dockPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier else {
            return false
        }
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else {
            return false
        }
        let minWidth = (NSScreen.screens.map(\.frame.width).min() ?? 800) * 0.9
        for window in info {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == dockPID,
                  (window[kCGWindowLayer as String] as? Int) == missionControlLayer,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= minWidth else {
                continue
            }
            return true
        }
        return false
    }
}
