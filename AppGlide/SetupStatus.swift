//
//  SetupStatus.swift
//  AppGlide
//

import ApplicationServices
import Foundation

/// The two invisible prerequisites AppGlide depends on, surfaced in Settings.
struct SetupStatus {
    /// Accessibility permission — needed for accurate window detection.
    var axTrusted: Bool
    /// True when macOS itself has no 3-finger horizontal gesture bound
    /// (app switching set to four fingers or off, three-finger drag off).
    var gestureFree: Bool

    static func check() -> SetupStatus {
        let domain = "com.apple.AppleMultitouchTrackpad" as CFString
        let horizontal = CFPreferencesCopyAppValue(
            "TrackpadThreeFingerHorizSwipeGesture" as CFString, domain
        ) as? Int
        let drag = CFPreferencesCopyAppValue(
            "TrackpadThreeFingerDrag" as CFString, domain
        ) as? Int
        return SetupStatus(
            axTrusted: AXIsProcessTrusted(),
            // nil = macOS default, which binds three fingers → conflict.
            gestureFree: (horizontal ?? 2) == 0 && (drag ?? 0) == 0
        )
    }

    static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let trackpadSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!
}
