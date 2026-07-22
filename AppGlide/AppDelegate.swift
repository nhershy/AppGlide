//
//  AppDelegate.swift
//  AppGlide
//

import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appSwitcher: AppSwitcher?
    private var gestureMonitor: GestureMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: PrefKey.hasShownSetup) {
            defaults.set(true, forKey: PrefKey.hasShownSetup)
            // The system prompt also pre-adds AppGlide to the Accessibility
            // list; afterwards the Settings Status section is the recovery path.
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            SettingsWindowController.shared.show()
        }
        reconcileLoginItem()

        let switcher = AppSwitcher()
        let monitor = GestureMonitor(switcher: switcher)
        appSwitcher = switcher
        gestureMonitor = monitor
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        gestureMonitor?.stop()
    }

    /// A login item registered from a build directory keeps pointing there.
    /// When running from /Applications with the login item enabled, re-register
    /// once so it resolves to the installed copy.
    private func reconcileLoginItem() {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasPrefix("/Applications/"),
              SMAppService.mainApp.status == .enabled,
              UserDefaults.standard.string(forKey: PrefKey.loginItemPath) != bundlePath else {
            return
        }
        try? SMAppService.mainApp.unregister()
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(bundlePath, forKey: PrefKey.loginItemPath)
    }
}
