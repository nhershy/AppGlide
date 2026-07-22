//
//  SetupStatus.swift
//  AppGlide
//

import ApplicationServices
import Foundation

/// The setup prerequisite AppGlide surfaces in Settings.
struct SetupStatus {
    /// Accessibility permission — needed for accurate window detection.
    var axTrusted: Bool

    static func check() -> SetupStatus {
        SetupStatus(axTrusted: AXIsProcessTrusted())
    }

    static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
