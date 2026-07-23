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
    private var musicController: MusicController?
    private var musicOverlay: MusicOverlay?
    private var mouseScrollMonitor: MouseScrollMonitor?
    private var mouseTouchMonitor: MouseTouchMonitor?
    private var clickCommitMonitor: ClickCommitMonitor?

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
        let music = MusicController()
        let overlay = MusicOverlay(controller: music)
        appSwitcher = switcher
        gestureMonitor = monitor
        musicController = music
        musicOverlay = overlay
        monitor.onMusicGesture = { [weak overlay] in overlay?.toggle() }
        monitor.start()

        let mouse = MouseScrollMonitor(gestureMonitor: monitor)
        mouseScrollMonitor = mouse
        mouse.start()

        let touch = MouseTouchMonitor(gestureMonitor: monitor, scrollMonitor: mouse)
        mouseTouchMonitor = touch
        touch.start()

        let clickCommit = ClickCommitMonitor(switcher: switcher, gestureMonitor: monitor)
        clickCommitMonitor = clickCommit
        clickCommit.syncToMode()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Idempotent retries: recover the taps if Accessibility was granted
        // after launch.
        mouseScrollMonitor?.start()
        clickCommitMonitor?.syncToMode()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clickCommitMonitor?.stop()
        mouseTouchMonitor?.stop()
        mouseScrollMonitor?.stop()
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
