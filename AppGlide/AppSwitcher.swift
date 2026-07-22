//
//  AppSwitcher.swift
//  AppGlide
//

import AppKit
import ApplicationServices

/// Maintains the MRU app order and cycles a persistent spatial strip: the
/// frozen MRU snapshot and cursor survive pauses of any length, so left/right
/// stay stable directions (swipe left to an app, swipe right later to return).
/// The strip only rebuilds — in then-current MRU order — when the user switches
/// apps by other means (Dock, Cmd-Tab, click) or an app launches or quits.
final class AppSwitcher: NSObject {
    private enum Constants {
        /// Fallback when the shared "stays visible" pref is unset — matches
        /// MusicOverlay.autoHideDelay so both HUDs default identically.
        static let overlayHideDelay: Duration = .seconds(2)
        /// A swipe this soon after the previous one is part of a glide, so its
        /// activation is deferred until the user settles.
        static let rapidSwipeWindow: Duration = .milliseconds(350)
        static let settleDelay: Duration = .milliseconds(250)
    }

    private struct Session {
        /// Frozen MRU snapshot, [0] = most recent. Never re-reads mruPIDs;
        /// only a HUD click reorders it (jumpToApp).
        var apps: [NSRunningApplication]
        var index: Int
    }

    private var mruPIDs: [pid_t] = []
    private var session: Session?
    private let overlay = SwitcherOverlay(autoHideDelay: Constants.overlayHideDelay)
    /// Set before we activate an app ourselves so the resulting didActivate
    /// notification doesn't kill the live session; any other activation
    /// (Dock, Cmd-Tab, click) must end it.
    private var pendingActivationPID: pid_t?
    private var lastSwipeAt: ContinuousClock.Instant?
    private var commitTask: Task<Void, Never>?
    private let clock = ContinuousClock()

    override init() {
        super.init()
        overlay.onSelectApp = { [weak self] pid in self?.jumpToApp(pid) }
        seedMRU()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(workspaceDidActivateApp(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceDidTerminateApp(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(exclusionsDidChange),
            name: .appGlideExclusionsChanged,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func exclusionsDidChange() {
        // Rebuild the ring on the next swipe so exclusions apply immediately.
        session = nil
        commitTask?.cancel()
        commitTask = nil
        overlay.hide()
    }

    /// Show the ring at its current state without stepping — fired when
    /// 3 fingers rest on the trackpad. Repeated peeks while the fingers stay
    /// down keep extending the HUD's auto-hide.
    func peek() {
        if session == nil {
            session = makeSession()
        }
        guard let s = session else { return }
        overlay.show(apps: s.apps, selectedIndex: s.index)
    }

    /// step: +1 = older in MRU, -1 = newer. Wraps around at the ends.
    ///
    /// Commit-on-settle: an isolated swipe activates its target immediately,
    /// but further swipes in quick succession only move the cursor and HUD —
    /// the selection activates once the user pauses, so a multi-step glide
    /// raises one app instead of every app passed along the way.
    func handleSwipe(step: Int) {
        pendingActivationPID = nil
        if session == nil {
            session = makeSession()
        }
        guard var s = session else { return }
        let count = s.apps.count
        let target: Int
        if s.index < 0 {
            // Frontmost app wasn't eligible: enter the strip from the matching end.
            target = step > 0 ? 0 : count - 1
        } else {
            target = ((s.index + step) % count + count) % count
        }
        guard !s.apps[target].isTerminated else {
            session = s
            return
        }
        s.index = target
        session = s
        overlay.show(apps: s.apps, selectedIndex: s.index)
        if UserDefaults.standard.object(forKey: PrefKey.hapticsEnabled) as? Bool ?? true {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }

        let now = clock.now
        let isRapidGlide = lastSwipeAt.map { now - $0 < Constants.rapidSwipeWindow } ?? false
        lastSwipeAt = now
        commitTask?.cancel()
        if isRapidGlide {
            commitTask = Task { [weak self] in
                try? await Task.sleep(for: Constants.settleDelay)
                guard !Task.isCancelled else { return }
                self?.commitSelection()
            }
        } else {
            commitSelection()
        }
    }

    /// HUD icon clicked: instead of rotating the whole ring to the clicked
    /// app, pull it out of its slot and insert it beside the currently focused
    /// app, then focus it — so the rest of the ring barely moves.
    private func jumpToApp(_ pid: pid_t) {
        guard var s = session,
              let clicked = s.apps.firstIndex(where: { $0.processIdentifier == pid }) else { return }
        commitTask?.cancel()
        commitTask = nil
        if clicked != s.index {
            let app = s.apps.remove(at: clicked)
            let insertAt = clicked > s.index ? s.index : s.index - 1
            s.apps.insert(app, at: insertAt)
            s.index = insertAt
        }
        session = s
        overlay.show(apps: s.apps, selectedIndex: s.index)
        if UserDefaults.standard.object(forKey: PrefKey.hapticsEnabled) as? Bool ?? true {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        let app = s.apps[s.index]
        guard !app.isTerminated else { return }
        activate(app)
    }

    private func commitSelection() {
        commitTask = nil
        guard let s = session, s.apps.indices.contains(s.index) else { return }
        let app = s.apps[s.index]
        guard !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else {
            return
        }
        activate(app)
    }

    // MARK: - Workspace notifications

    @objc private func workspaceDidActivateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        mruPIDs.removeAll { $0 == pid }
        mruPIDs.insert(pid, at: 0)
        if pid == pendingActivationPID {
            pendingActivationPID = nil
        } else {
            // User switched apps some other way (Dock, Cmd-Tab, click); a
            // pending glide commit must not override their choice.
            session = nil
            commitTask?.cancel()
            commitTask = nil
            overlay.hide()
        }
    }

    @objc private func workspaceDidTerminateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        mruPIDs.removeAll { $0 == app.processIdentifier }
        // The strip contains a dead app now; rebuild it on the next swipe.
        session = nil
        commitTask?.cancel()
        commitTask = nil
        overlay.hide()
    }

    // MARK: - Session construction

    private func seedMRU() {
        var pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map(\.processIdentifier)
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let i = pids.firstIndex(of: front) {
            pids.remove(at: i)
            pids.insert(front, at: 0)
        }
        mruPIDs = pids
    }

    private func makeSession() -> Session? {
        // AX gives the accurate answer (phantom retained windows are excluded,
        // minimized and Cmd-H-hidden ones included) but needs the Accessibility
        // permission; without it, fall back to the over-inclusive CG filter.
        let axTrusted = AXIsProcessTrusted()
        let skipMinimized = MinimizedAppBehavior.current() == .skip
        let excluded = Set(UserDefaults.standard.stringArray(forKey: PrefKey.excludedBundleIDs) ?? [])
        let windowPIDs = axTrusted ? [] : Self.pidsOwningWindows()
        let byPID = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = mruPIDs.compactMap { byPID[$0] }.filter {
            $0.activationPolicy == .regular
                && !$0.isTerminated
                && $0.processIdentifier != ownPID
                && !excluded.contains($0.bundleIdentifier ?? "")
                && (axTrusted
                        ? Self.axHasWindows($0.processIdentifier, skippingMinimizedOnly: skipMinimized)
                        : windowPIDs.contains($0.processIdentifier))
        }
        guard apps.count > 1 else { return nil }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // index -1 when the frontmost app has no eligible windows: a swipe
        // toward older then lands on apps[0], a swipe toward newer no-ops.
        let index = apps.firstIndex { $0.processIdentifier == frontPID } ?? -1
        return Session(apps: apps, index: index)
    }

    /// The app's Accessibility window list. Visible, minimized, and
    /// Cmd-H-hidden windows all appear there; ordered-out "phantom" windows
    /// apps retain after closing do not — a distinction CGWindowList cannot
    /// make (identical alpha/bounds/store type).
    private static func axWindows(_ pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        // Don't let one hung app stall the swipe (default timeout is seconds).
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return []
        }
        return windows
    }

    private static func axIsMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
              let number = value as? NSNumber else {
            return false
        }
        return number.boolValue
    }

    private static func axHasWindows(_ pid: pid_t, skippingMinimizedOnly skip: Bool) -> Bool {
        let windows = axWindows(pid)
        guard !windows.isEmpty else { return false }
        guard skip else { return true }
        return windows.contains { !axIsMinimized($0) }
    }

    /// If every window of the app is minimized, restore the frontmost one so
    /// switching actually brings content on screen.
    private static func restoreMinimizedWindowIfNeeded(_ pid: pid_t) {
        let windows = axWindows(pid)
        guard let first = windows.first, windows.allSatisfy({ axIsMinimized($0) }) else { return }
        AXUIElementSetAttributeValue(first, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    /// Fallback when Accessibility isn't granted: PIDs owning at least one
    /// normal-layer window. Over-inclusive (counts phantom retained windows)
    /// but needs no TCC permission.
    private static func pidsOwningWindows() -> Set<pid_t> {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var pids = Set<pid_t>()
        for window in info where (window[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t {
                pids.insert(pid)
            }
        }
        return pids
    }

    // MARK: - Activation

    private func activate(_ app: NSRunningApplication) {
        pendingActivationPID = app.processIdentifier
        if app.isHidden {
            app.unhide()
        }
        if MinimizedAppBehavior.current() == .restore, AXIsProcessTrusted() {
            Self.restoreMinimizedWindowIfNeeded(app.processIdentifier)
        }
        var activated = app.activate(from: .current, options: [.activateAllWindows])
        if !activated {
            // Cooperative activation can refuse requests from a never-active
            // accessory app; the legacy call still works from the background.
            activated = app.activate(options: [.activateAllWindows])
        }
        if !activated {
            pendingActivationPID = nil
        }
    }
}
