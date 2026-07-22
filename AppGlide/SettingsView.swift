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
    @AppStorage(PrefKey.hudDuration) private var hudDuration = 2.0
    @AppStorage(PrefKey.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(PrefKey.musicHUDEnabled) private var musicHUDEnabled = true
    @AppStorage(PrefKey.mouseScrollEnabled) private var mouseScrollEnabled = true
    @AppStorage(PrefKey.mouseScrollModifier) private var mouseScrollModifier = MouseScrollModifier.option.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var status = SetupStatus.check()

    var body: some View {
        Form {
            Section("Status") {
                StatusRow(
                    ok: status.axTrusted,
                    okText: "Accessibility permission granted",
                    problemText: "Accessibility needed for accurate window detection",
                    buttonTitle: "Open Accessibility Settings",
                    url: SetupStatus.accessibilitySettingsURL
                )
                StatusRow(
                    ok: status.gestureFree,
                    okText: "3-finger swipe is free for AppGlide",
                    problemText: "macOS also uses 3-finger swipes — set app switching to four fingers",
                    buttonTitle: "Open Trackpad Settings",
                    url: SetupStatus.trackpadSettingsURL
                )
            }
            Section("Gesture") {
                Toggle("Invert swipe direction", isOn: $reverseDirection)
                Toggle("Haptic feedback on each step", isOn: $hapticsEnabled)
                Toggle("Hold modifier + scroll to glide (for Magic Mouse)", isOn: $mouseScrollEnabled)
                if mouseScrollEnabled {
                    Picker("Modifier", selection: $mouseScrollModifier) {
                        Text("⌥ Option").tag(MouseScrollModifier.option.rawValue)
                        Text("⌘ Command").tag(MouseScrollModifier.command.rawValue)
                        Text("⌃ Control").tag(MouseScrollModifier.control.rawValue)
                    }
                    .pickerStyle(.segmented)
                }
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
            Section("Excluded Apps") {
                ExcludedAppsList()
            }
            Section("HUD") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stays visible for \(hudDuration, format: .number.precision(.fractionLength(1))) s")
                    Slider(value: $hudDuration, in: 0.5...6.0)
                }
            }
            Section("Music") {
                Toggle("3-finger swipe down shows Music controls", isOn: $musicHUDEnabled)
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
        .frame(width: 440, height: 700)
        .onAppear { status = SetupStatus.check() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            status = SetupStatus.check()
        }
    }
}

private struct StatusRow: View {
    let ok: Bool
    let okText: String
    let problemText: String
    let buttonTitle: String
    let url: URL

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .yellow)
            Text(ok ? okText : problemText)
            Spacer()
            if !ok {
                Button(buttonTitle) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

private struct ExclusionRow: Identifiable {
    let id: String  // bundle ID
    let name: String
    let icon: NSImage?
    var isExcluded: Bool
}

private struct ExcludedAppsList: View {
    @State private var rows: [ExclusionRow] = []

    var body: some View {
        List(rows) { row in
            HStack {
                if let icon = row.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "app.dashed")
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.secondary)
                }
                Text(row.name)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { row.isExcluded },
                    set: { setExcluded(row.id, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
        }
        .frame(height: 140)
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            load()
        }
    }

    private func load() {
        let excluded = Set(UserDefaults.standard.stringArray(forKey: PrefKey.excludedBundleIDs) ?? [])
        var seen = Set<String>()
        var running: [ExclusionRow] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, seen.insert(bundleID).inserted else { continue }
            running.append(ExclusionRow(
                id: bundleID,
                name: app.localizedName ?? bundleID,
                icon: app.icon,
                isExcluded: excluded.contains(bundleID)
            ))
        }
        running.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Keep excluded-but-not-running apps visible so they can be un-excluded.
        let leftovers = excluded.subtracting(seen).sorted().map {
            ExclusionRow(id: $0, name: $0, icon: nil, isExcluded: true)
        }
        rows = running + leftovers
    }

    private func setExcluded(_ bundleID: String, _ excluded: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == bundleID }) else { return }
        rows[index].isExcluded = excluded
        UserDefaults.standard.set(
            rows.filter(\.isExcluded).map(\.id),
            forKey: PrefKey.excludedBundleIDs
        )
        NotificationCenter.default.post(name: .appGlideExclusionsChanged, object: nil)
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
