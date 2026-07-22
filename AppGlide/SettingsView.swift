//
//  SettingsView.swift
//  AppGlide
//

import AppKit
import ServiceManagement
import SwiftUI

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "AppGlide Settings"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @AppStorage(PrefKey.isPaused) private var isPaused = false
    @AppStorage(PrefKey.reverseDirection) private var reverseDirection = false
    @AppStorage(PrefKey.minimizedAppBehavior) private var minimizedBehavior = MinimizedAppBehavior.restore.rawValue
    @AppStorage(PrefKey.swipeDistance) private var swipeDistance = 0.08
    @AppStorage(PrefKey.glideStepDistance) private var glideStepDistance = 0.10
    @AppStorage(PrefKey.hudDuration) private var hudDuration = 1.5
    @AppStorage(PrefKey.hapticsEnabled) private var hapticsEnabled = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Gesture") {
                Toggle("Invert swipe direction", isOn: $reverseDirection)
                Toggle("Haptic feedback on each step", isOn: $hapticsEnabled)
                DistanceSlider(
                    title: "Swipe distance",
                    subtitle: "Travel needed for the first switch — shorter is more sensitive",
                    value: $swipeDistance,
                    range: 0.05...0.15
                )
                DistanceSlider(
                    title: "Glide step",
                    subtitle: "Extra travel per app while gliding without lifting",
                    value: $glideStepDistance,
                    range: 0.06...0.16
                )
            }
            Section("Minimized Apps") {
                Picker("When all of an app's windows are minimized", selection: $minimizedBehavior) {
                    Text("Unminimize on switch").tag(MinimizedAppBehavior.restore.rawValue)
                    Text("Skip in switcher").tag(MinimizedAppBehavior.skip.rawValue)
                }
                .pickerStyle(.radioGroup)
            }
            Section("HUD") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stays visible for \(hudDuration, format: .number.precision(.fractionLength(1))) s")
                    Slider(value: $hudDuration, in: 0.5...3.0)
                }
            }
            Section("General") {
                Toggle("Pause switching", isOn: $isPaused)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 470)
    }
}

private struct DistanceSlider: View {
    let title: String
    let subtitle: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Slider(value: $value, in: range) {
                EmptyView()
            } minimumValueLabel: {
                Text("Short").font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("Long").font(.caption).foregroundStyle(.secondary)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
