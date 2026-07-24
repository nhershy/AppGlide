//
//  MouseTouchMonitor.swift
//  AppGlide
//

import AppKit
import CoreGraphics

/// Modifier + a finger resting on the Magic Mouse peeks the HUD — the
/// clamshell counterpart of 3 fingers resting on the trackpad.
///
/// The OpenMultitouchSupport package only ever opens the DEFAULT multitouch
/// device (the built-in trackpad), so Magic Mouse touches never reach its
/// stream. This monitor talks to the same private MultitouchSupport.framework
/// directly — via dlopen/dlsym, so no build-setting or package changes — and
/// watches every EXTERNAL multitouch device. Touch data is never parsed;
/// only the per-frame touch count matters.

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTFrameCallback = @convention(c) (
    MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Void

private struct MTAPI {
    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias IsBuiltIn = @convention(c) (MTDeviceRef) -> Bool
    typealias RegisterFrame = @convention(c) (MTDeviceRef, MTFrameCallback) -> Void
    typealias DeviceStart = @convention(c) (MTDeviceRef, Int32) -> Int32
    typealias DeviceStop = @convention(c) (MTDeviceRef) -> Int32
    typealias GetInt32 = @convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>) -> Int32
    typealias GetUInt64 = @convention(c) (MTDeviceRef, UnsafeMutablePointer<UInt64>) -> Int32

    let createList: CreateList
    let isBuiltIn: IsBuiltIn
    let registerContactFrame: RegisterFrame
    let unregisterContactFrame: RegisterFrame
    let start: DeviceStart
    let stop: DeviceStop
    let getFamilyID: GetInt32
    let getDeviceID: GetUInt64

    static func load() -> MTAPI? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_NOW
        ) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let createList = sym("MTDeviceCreateList", CreateList.self),
              let isBuiltIn = sym("MTDeviceIsBuiltIn", IsBuiltIn.self),
              let register = sym("MTRegisterContactFrameCallback", RegisterFrame.self),
              let unregister = sym("MTUnregisterContactFrameCallback", RegisterFrame.self),
              let start = sym("MTDeviceStart", DeviceStart.self),
              let stop = sym("MTDeviceStop", DeviceStop.self),
              let getFamilyID = sym("MTDeviceGetFamilyID", GetInt32.self),
              let getDeviceID = sym("MTDeviceGetDeviceID", GetUInt64.self) else {
            return nil
        }
        return MTAPI(
            createList: createList,
            isBuiltIn: isBuiltIn,
            registerContactFrame: register,
            unregisterContactFrame: unregister,
            start: start,
            stop: stop,
            getFamilyID: getFamilyID,
            getDeviceID: getDeviceID
        )
    }
}

/// Runs on the framework's multitouch thread — gate as much as possible here
/// so main-thread hops only happen while the user is actually invoking the
/// feature (modifier held + touch resting).
private nonisolated func mouseTouchFrameCallback(
    device: MTDeviceRef?,
    touches: UnsafeMutableRawPointer?,
    numTouches: Int32,
    timestamp: Double,
    frame: Int32
) {
    guard numTouches > 0 else { return }
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: PrefKey.mouseScrollEnabled) as? Bool ?? true,
          !defaults.bool(forKey: PrefKey.isPaused) else { return }
    let flags = CGEventSource.flagsState(.combinedSessionState)
    let relevant = flags.intersection([.maskAlternate, .maskCommand, .maskControl])
    guard relevant == MouseScrollModifier.current(defaults).flag else { return }
    // A held button is a click/drag (⌥-drag duplicates in Finder, …),
    // not a lay-a-finger peek.
    guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            MouseTouchMonitor.current?.touchWithModifier()
        }
    }
}

final class MouseTouchMonitor {
    private enum Constants {
        /// Cadence of .peek while touches rest — mirrors the trackpad
        /// recognizer's peekRepeat.
        static let peekRepeat: Duration = .milliseconds(500)
        /// External devices come and go (Magic Mouse connects after launch,
        /// reconnects after sleep in the clamshell workflow), so re-enumerate
        /// on this interval; devices are rebuilt only when the set changes.
        static let rescanInterval: Duration = .seconds(15)
    }

    /// The MT frame callback carries no user-info pointer, so it reaches the
    /// instance the same way the OMS singleton does — via a static ref.
    private(set) nonisolated(unsafe) static weak var current: MouseTouchMonitor?

    private let gestureMonitor: GestureMonitor
    private let scrollMonitor: MouseScrollMonitor
    private var api: MTAPI?
    private var startedDevices: [MTDeviceRef] = []
    private var startedIDs: Set<UInt64> = []
    /// Owns the MTDeviceRefs in startedDevices (each list retains its devices).
    private var keptLists: [CFArray] = []
    private var rescanTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var lastPeekAt: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    init(gestureMonitor: GestureMonitor, scrollMonitor: MouseScrollMonitor) {
        self.gestureMonitor = gestureMonitor
        self.scrollMonitor = scrollMonitor
    }

    func start() {
        guard rescanTask == nil else { return }
        guard let api = api ?? MTAPI.load() else {
            AppLog.log("mouse touch: MultitouchSupport symbols unavailable, peek disabled")
            return
        }
        self.api = api
        MouseTouchMonitor.current = self
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            // Wake usually re-creates the Bluetooth device (new device ID),
            // but force a rebuild in case the ID survived with a dead ref.
            MainActor.assumeIsolated {
                MouseTouchMonitor.current?.rebuild()
            }
        }
        rescanTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.rescan()
                try? await Task.sleep(for: Constants.rescanInterval)
            }
        }
    }

    func stop() {
        rescanTask?.cancel()
        rescanTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        stopDevices()
        if MouseTouchMonitor.current === self {
            MouseTouchMonitor.current = nil
        }
    }

    /// HUD peek, rate-limited; hopped here from the multitouch thread with
    /// the modifier/enabled/no-click gates already passed.
    func touchWithModifier() {
        let now = clock.now
        if let last = lastPeekAt, now - last < Constants.peekRepeat { return }
        lastPeekAt = now
        scrollMonitor.noteModifierActivity()
        gestureMonitor.dispatch(.peek)
    }

    private func rebuild() {
        stopDevices()
        rescan()
    }

    private func rescan() {
        guard let api, let listRef = api.createList() else { return }
        let list = listRef.takeRetainedValue()
        var externals: [(device: MTDeviceRef, id: UInt64)] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            // The built-in trackpad already streams through OMS/GestureMonitor.
            if api.isBuiltIn(device) { continue }
            var id: UInt64 = 0
            _ = api.getDeviceID(device, &id)
            externals.append((device, id))
        }
        guard Set(externals.map(\.id)) != startedIDs else { return }
        stopDevices()
        for (device, id) in externals {
            api.registerContactFrame(device, mouseTouchFrameCallback)
            _ = api.start(device, 0)
            startedDevices.append(device)
            startedIDs.insert(id)
            var family: Int32 = -1
            _ = api.getFamilyID(device, &family)
            AppLog.log("mouse touch: watching external multitouch device id=\(id) family=\(family)")
        }
        if !externals.isEmpty {
            keptLists.append(list)
        }
    }

    private func stopDevices() {
        guard let api else { return }
        for device in startedDevices {
            api.unregisterContactFrame(device, mouseTouchFrameCallback)
            _ = api.stop(device)
        }
        startedDevices.removeAll()
        startedIDs.removeAll()
        keptLists.removeAll()
    }
}
