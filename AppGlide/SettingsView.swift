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

/// Allowed values per slider: ascending, odd count, with the app default at the
/// center index so untouched settings render with the knob centered. Center
/// elements must match the engine defaults (SwipeGestureRecognizer.Constants,
/// MouseScrollMonitor.Constants.stepDistance, FocusDelayPref.defaultSeconds,
/// AppSwitcher.Constants.overlayHideDelay).
private enum SliderCatalog {
    static let swipeDistance: [Double] = [0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.10, 0.11, 0.12]
    static let glideStep: [Double] = [0.06, 0.07, 0.08, 0.09, 0.10, 0.11, 0.12, 0.13, 0.14]
    static let mouseStep: [Double] = [60, 75, 90, 105, 120, 135, 150, 165, 180]
    static let focusDelay: [Double] = [0, 0.2, 0.35, 0.5, 0.75, 1.0, 1.5]
    static let hudDuration: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 6.0]
}

struct SettingsView: View {
    @AppStorage(PrefKey.isPaused) private var isPaused = false
    @AppStorage(PrefKey.reverseDirection) private var reverseDirection = false
    @AppStorage(PrefKey.minimizedAppBehavior) private var minimizedBehavior = MinimizedAppBehavior.restore.rawValue
    @AppStorage(PrefKey.swipeDistance) private var swipeDistance = 0.08
    @AppStorage(PrefKey.glideStepDistance) private var glideStepDistance = 0.10
    @AppStorage(PrefKey.focusDelay) private var focusDelay = FocusDelayPref.defaultSeconds
    @AppStorage(PrefKey.hudDuration) private var hudDuration = 1.5
    @AppStorage(PrefKey.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(PrefKey.musicHUDEnabled) private var musicHUDEnabled = true
    @AppStorage(PrefKey.playlistSortOrder) private var playlistSortOrder = PlaylistSortOrder.recentlyPicked.rawValue
    @AppStorage(PrefKey.mouseScrollEnabled) private var mouseScrollEnabled = true
    @AppStorage(PrefKey.mouseScrollModifier) private var mouseScrollModifier = MouseScrollModifier.option.rawValue
    @AppStorage(PrefKey.mouseStepDistance) private var mouseStepDistance = MouseScrollMonitor.Constants.stepDistance
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var status = SetupStatus.check()
    @State private var exclusionRows: [ExclusionRow] = []
    @State private var exclusionsExpanded = false

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
            }
            Section("Trackpad") {
                Toggle("Invert swipe direction", isOn: $reverseDirection)
                Toggle("Haptic feedback on each step", isOn: $hapticsEnabled)
                NotchedSlider(
                    title: "Swipe distance",
                    subtitle: "Travel needed for the first switch — shorter is more sensitive",
                    values: SliderCatalog.swipeDistance,
                    value: $swipeDistance,
                    format: { "\(Int(($0 * 100).rounded()))% of trackpad" }
                )
                NotchedSlider(
                    title: "Glide step",
                    subtitle: "Extra travel per app while gliding without lifting",
                    values: SliderCatalog.glideStep,
                    value: $glideStepDistance,
                    format: { "\(Int(($0 * 100).rounded()))% of trackpad" }
                )
                Text("While the switcher is up: click with 3 fingers to quit the selected app, or right-click any icon to quit it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Magic Mouse") {
                Toggle("Hold modifier + scroll to glide", isOn: $mouseScrollEnabled)
                if mouseScrollEnabled {
                    Picker("Modifier", selection: $mouseScrollModifier) {
                        Text("⌥ Option").tag(MouseScrollModifier.option.rawValue)
                        Text("⌘ Command").tag(MouseScrollModifier.command.rawValue)
                        Text("⌃ Control").tag(MouseScrollModifier.control.rawValue)
                    }
                    .pickerStyle(.segmented)
                    NotchedSlider(
                        title: "Scroll distance per switch",
                        subtitle: "Scroll travel needed per app — shorter is more sensitive",
                        values: SliderCatalog.mouseStep,
                        value: $mouseStepDistance,
                        format: { "\(Int($0)) pt" }
                    )
                }
            }
            Section("Switching") {
                NotchedSlider(
                    title: "Focus delay",
                    subtitle: "Apps you browse past won't be raised or un-minimized until the selection holds still this long.",
                    values: SliderCatalog.focusDelay,
                    value: $focusDelay,
                    format: { $0 < 0.05 ? "Instant" : String(format: "%.2f s", $0) },
                    minLabel: "Instant",
                    maxLabel: "Slow"
                )
                Picker("When all of an app's windows are minimized", selection: $minimizedBehavior) {
                    Text("Unminimize on switch").tag(MinimizedAppBehavior.restore.rawValue)
                    Text("Skip in switcher").tag(MinimizedAppBehavior.skip.rawValue)
                }
                .pickerStyle(.radioGroup)
            }
            Section("Heads-Up Display") {
                NotchedSlider(
                    title: "Visible duration",
                    values: SliderCatalog.hudDuration,
                    value: $hudDuration,
                    format: { "\($0.formatted(.number.precision(.fractionLength(1...2)))) s" },
                    minLabel: "Brief",
                    maxLabel: "Long"
                )
                Toggle("3-finger swipe down shows Music controls", isOn: $musicHUDEnabled)
                if musicHUDEnabled {
                    Picker("Order of the \u{201C}Add to Playlist\u{201D} menu", selection: $playlistSortOrder) {
                        Text("Recently picked first").tag(PlaylistSortOrder.recentlyPicked.rawValue)
                        Text("Alphabetical").tag(PlaylistSortOrder.alphabetical.rawValue)
                    }
                    .pickerStyle(.radioGroup)
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
            Section("Excluded Apps") {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        exclusionsExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(excludedCount == 0 ? "No apps excluded" : "^[\(excludedCount) app](inflect: true) excluded")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(exclusionsExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if exclusionsExpanded {
                    ForEach(exclusionRows) { row in
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
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 660)
        .onAppear {
            status = SetupStatus.check()
            loadExclusions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            status = SetupStatus.check()
            loadExclusions()
        }
    }

    private var excludedCount: Int {
        exclusionRows.filter(\.isExcluded).count
    }

    private func loadExclusions() {
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
        exclusionRows = running + leftovers
    }

    private func setExcluded(_ bundleID: String, _ excluded: Bool) {
        guard let index = exclusionRows.firstIndex(where: { $0.id == bundleID }) else { return }
        exclusionRows[index].isExcluded = excluded
        UserDefaults.standard.set(
            exclusionRows.filter(\.isExcluded).map(\.id),
            forKey: PrefKey.excludedBundleIDs
        )
        NotificationCenter.default.post(name: .appGlideExclusionsChanged, object: nil)
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

/// Discrete slider over an explicit catalog of allowed values. The stored
/// value is matched to the catalog by nearest distance, never equality, so
/// legacy continuous values and float drift both resolve to a valid notch.
private struct NotchedSlider: View {
    let title: String
    var subtitle: String? = nil
    let values: [Double]
    @Binding var value: Double
    let format: (Double) -> String
    var minLabel = "Short"
    var maxLabel = "Long"

    private var nearestIndex: Int {
        values.indices.min {
            abs(values[$0] - value) < abs(values[$1] - value)
        } ?? values.count / 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(nearestIndex) },
                    set: { newIndex in
                        let snapped = values[Int(newIndex.rounded())]
                        if snapped != value {
                            value = snapped
                            NSHapticFeedbackManager.defaultPerformer
                                .perform(.alignment, performanceTime: .now)
                        }
                    }
                ),
                in: 0...Double(values.count - 1),
                step: 1
            ) {
                EmptyView()
            } minimumValueLabel: {
                Text(minLabel).font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(maxLabel).font(.caption).foregroundStyle(.secondary)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            // Snap legacy out-of-catalog values into the catalog once.
            let snapped = values[nearestIndex]
            if snapped != value { value = snapped }
        }
    }
}
