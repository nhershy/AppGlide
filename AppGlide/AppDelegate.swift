//
//  AppDelegate.swift
//  AppGlide
//

import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appSwitcher: AppSwitcher?
    private var gestureMonitor: GestureMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessibility enables the accurate has-windows filter; without it the
        // switcher still works using the permissionless CGWindowList fallback.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        let switcher = AppSwitcher()
        let monitor = GestureMonitor(switcher: switcher)
        appSwitcher = switcher
        gestureMonitor = monitor
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        gestureMonitor?.stop()
    }
}
