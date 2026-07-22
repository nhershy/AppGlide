//
//  HUDSupport.swift
//  AppGlide
//

import AppKit
import SwiftUI

/// Accepts the first click even though a HUD panel never becomes key, so
/// buttons inside respond to a single tap.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shared hover tracking across the app-switcher and music HUDs: hovering
/// either panel pins BOTH open; auto-hide resumes when the mouse leaves both.
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

/// Cross-HUD layout facts.
@MainActor
enum HUDLayout {
    /// Last width the carousel laid out at; the music HUD matches it.
    static var carouselWidth: CGFloat?
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
