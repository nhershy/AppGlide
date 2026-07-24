//
//  HUDSupport.swift
//  AppGlide
//

import AppKit
import SwiftUI

/// Accepts the first click even though a HUD panel never becomes key, so
/// buttons inside respond to a single tap.
/// Non-generic over AnyView: a generic subclass of NSHostingView crashes the
/// Swift 6.3 optimizer (SIL inliner) when targeting macOS < 26.
final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shared pin tracking across the app-switcher and music HUDs — hover or a
/// held scroll-modifier key: any pin holds BOTH panels open; auto-hide
/// resumes when the last pin clears.
@MainActor
final class HUDHoverState {
    static let shared = HUDHoverState()

    private var flags: [String: Bool] = [:]
    private var observers: [(Bool) -> Void] = []
    private(set) var anyHovering = false

    func addObserver(_ observer: @escaping (Bool) -> Void) {
        observers.append(observer)
    }

    func setHovering(_ hovering: Bool, for key: String) {
        flags[key] = hovering
        let any = flags.values.contains(true)
        guard any != anyHovering else { return }
        anyHovering = any
        for observer in observers {
            observer(any)
        }
    }
}

/// Single shared auto-hide clock for both HUDs: activity on either extends
/// one common deadline (never shortens it), and expiry dismisses both at the
/// same moment — so stacked HUDs always fade together.
@MainActor
final class HUDAutoHide {
    static let shared = HUDAutoHide()

    private var expireHandlers: [() -> Void] = []
    private var task: Task<Void, Never>?
    private var deadline: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    func addExpireHandler(_ handler: @escaping () -> Void) {
        expireHandlers.append(handler)
    }

    /// Extends (never shortens) the shared deadline.
    func requestAutoHide(after duration: Duration) {
        let candidate = clock.now + duration
        if let deadline, deadline >= candidate { return }
        deadline = candidate
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(until: candidate, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        deadline = nil
    }

    private func fire() {
        task = nil
        deadline = nil
        for handler in expireHandlers {
            handler()
        }
    }
}

/// The shared HUD chrome backdrop: system HUD material blurring what's behind
/// the panel, plus a dark scrim so the hardcoded white text stays readable
/// even when very bright content sits underneath.
struct HUDBackground: View {
    var body: some View {
        ZStack {
            HUDBlur()
            Color.black.opacity(0.22)
        }
    }
}

private struct HUDBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
