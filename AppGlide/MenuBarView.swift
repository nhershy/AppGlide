//
//  MenuBarView.swift
//  AppGlide
//

import ServiceManagement
import SwiftUI

struct MenuBarView: View {
    @AppStorage(PrefKey.isPaused) private var isPaused = false
    @AppStorage(PrefKey.reverseDirection) private var reverseDirection = false
    @AppStorage(PrefKey.minimizedAppBehavior) private var minimizedBehavior = MinimizedAppBehavior.restore.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Pause Switching", isOn: $isPaused)
        Toggle("Reverse Swipe Direction", isOn: $reverseDirection)
        Divider()
        Picker("Minimized Apps", selection: $minimizedBehavior) {
            Text("Unminimize on Switch").tag(MinimizedAppBehavior.restore.rawValue)
            Text("Skip in Switcher").tag(MinimizedAppBehavior.skip.rawValue)
        }
        .pickerStyle(.inline)
        Divider()
        Toggle("Launch at Login", isOn: $launchAtLogin)
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
        Divider()
        Button("Quit AppGlide") {
            NSApp.terminate(nil)
        }
    }
}
