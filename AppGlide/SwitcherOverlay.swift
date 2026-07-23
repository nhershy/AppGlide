//
//  SwitcherOverlay.swift
//  AppGlide
//

import AppKit
import SwiftUI

/// Bottom-of-screen HUD showing the app ring, with the current selection front
/// and center. The panel is non-activating, so it never steals focus from the
/// app being switched to. Hovering the mouse over it pins it open; a gear
/// button in its corner opens the settings window.
final class SwitcherOverlay {
    /// Called with the pid of an icon the user clicks in the HUD.
    var onSelectApp: ((pid_t) -> Void)?

    private var panel: NSPanel?
    private var hostingView: NSHostingView<SwitcherHUDView>?
    private let autoHideDelay: Duration
    /// Extra bottom clearance while the music HUD occupies the bottom slot.
    private var bottomInset: CGFloat = 0
    private var musicObserver: NSObjectProtocol?

    init(autoHideDelay: Duration) {
        self.autoHideDelay = autoHideDelay
        HUDHoverState.shared.addObserver { [weak self] anyHovering in
            self?.sharedHoverChanged(anyHovering)
        }
        HUDAutoHide.shared.addExpireHandler { [weak self] in
            self?.hide()
        }
        musicObserver = NotificationCenter.default.addObserver(
            forName: .musicHUDVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let height = note.userInfo?["height"] as? CGFloat ?? 0
            MainActor.assumeIsolated {
                self?.musicHUDHeightChanged(height)
            }
        }
    }

    deinit {
        if let musicObserver {
            NotificationCenter.default.removeObserver(musicObserver)
        }
    }

    private func musicHUDHeightChanged(_ height: CGFloat) {
        bottomInset = height > 0 ? height + 12 : 0
        guard let panel, panel.isVisible, panel.alphaValue > 0 else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        var frame = panel.frame
        frame.origin.y = screen.visibleFrame.minY + 24 + bottomInset
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// `apps` is the frozen session order ([0] = most recent); `selectedIndex`
    /// is the cursor within it.
    func show(apps: [NSRunningApplication], selectedIndex: Int) {
        let entries = apps.map { app in
            HUDEntry(
                id: app.processIdentifier,
                icon: app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(),
                name: app.localizedName ?? ""
            )
        }
        guard !entries.isEmpty else { return }
        let clampedIndex = min(max(selectedIndex, 0), entries.count - 1)
        let root = SwitcherHUDView(
            entries: entries,
            selectedIndex: clampedIndex,
            onHover: { [weak self] hovering in self?.hoverChanged(hovering) },
            onSettings: { [weak self] in self?.openSettings() },
            onSelect: { [weak self] pid in self?.onSelectApp?(pid) }
        )

        let panel = ensurePanel(rootView: root)
        if let hostingView {
            let size = hostingView.fittingSize
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            if let screen {
                let visible = screen.visibleFrame
                let origin = NSPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.minY + 24 + bottomInset
                )
                panel.setFrame(NSRect(origin: origin, size: size), display: true)
            }
        }

        if panel.isVisible, panel.alphaValue > 0 {
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

        if !HUDHoverState.shared.anyHovering {
            scheduleAutoHide()
        }
    }

    func hide() {
        HUDHoverState.shared.setHovering(false, for: "carousel")
        guard let panel, panel.isVisible, panel.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            panel.animator().alphaValue = 0
        } completionHandler: {
            // A show() during the fade restores alpha to 1; only dismiss if
            // the fade actually ran to completion.
            if panel.alphaValue == 0 {
                panel.orderOut(nil)
            }
        }
    }

    private func scheduleAutoHide() {
        let stored = UserDefaults.standard.double(forKey: PrefKey.hudDuration)
        var delay: Duration = stored > 0 ? .seconds(stored) : autoHideDelay
        // Never fade out before a pending settle commit fires — the app would
        // activate "out of nowhere" after the HUD is gone.
        let focus = FocusDelayPref.seconds()
        if focus > 0 {
            delay = max(delay, .seconds(focus + 0.3))
        }
        HUDAutoHide.shared.requestAutoHide(after: delay)
    }

    private func hoverChanged(_ hovering: Bool) {
        HUDHoverState.shared.setHovering(hovering, for: "carousel")
    }

    private func sharedHoverChanged(_ anyHovering: Bool) {
        if anyHovering {
            HUDAutoHide.shared.cancel()
            // Interrupt an in-flight fade-out so the HUD revives under the cursor.
            if let panel, panel.isVisible {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.1
                    panel.animator().alphaValue = 1
                }
            }
        } else if let panel, panel.isVisible, panel.alphaValue > 0 {
            scheduleAutoHide()
        }
    }

    private func openSettings() {
        hide()
        SettingsWindowController.shared.show()
    }

    private func ensurePanel(rootView: SwitcherHUDView) -> NSPanel {
        if let panel, let hostingView {
            hostingView.rootView = rootView
            return panel
        }
        let hosting = FirstMouseHostingView(rootView: rootView)
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        // Always-dark HUD regardless of system appearance — the white
        // text/icons depend on it.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        self.panel = panel
        self.hostingView = hosting
        return panel
    }
}

private struct HUDEntry: Identifiable {
    let id: pid_t
    let icon: NSImage
    let name: String
}

/// 3D ring carousel: apps sit on a circle viewed from the front. The focused
/// app is at the front of the ring — full size, full opacity — and the others
/// recede around it, shrinking, dimming, rising slightly, and layering behind
/// as they approach the back. Slot -1 (left) is the next-older app, slot +1
/// (right) the next-newer; a swipe rotates the ring so the new selection comes
/// around to the front, moving with the fingers (swipe right = older app
/// arrives from the left). The ring's seam is at the back, where icons are
/// smallest, so wrap-around is visually seamless.
private struct SwitcherHUDView: View {
    let entries: [HUDEntry]  // frozen session order, [0] = most recent
    let selectedIndex: Int   // always a valid index into entries
    let onHover: (Bool) -> Void
    let onSettings: () -> Void
    let onSelect: (pid_t) -> Void

    @State private var gearHovering = false

    private static let baseIconSize: CGFloat = 48
    private static let frontSpacing: CGFloat = 60  // ring-chord spacing between adjacent slots
    private static let frontNeighborGap: CGFloat = 52  // min horizontal gap, front icon to its neighbors
    private static let minRadius: CGFloat = 64
    private static let verticalDepth: CGFloat = 36

    private var slots: [(offset: Int, entry: HUDEntry)] {
        let n = entries.count
        let half = (n - 1) / 2
        return (-half...(n - 1 - half)).map { r in
            (r, entries[((selectedIndex - r) % n + n) % n])
        }
    }

    var body: some View {
        let n = entries.count
        // With few apps the adjacent-chord formula collapses the ring until
        // front icons overlap; also require the front neighbors' horizontal
        // projection to clear the focused icon.
        let adjacentRadius = Self.frontSpacing / (2 * sin(.pi / CGFloat(n)))
        let neighborProjection = sin(2 * .pi / CGFloat(n))
        let neighborRadius = neighborProjection > 0.1 ? Self.frontNeighborGap / neighborProjection : 0
        let radius = max(adjacentRadius, neighborRadius, Self.minRadius)
        let width = 2 * radius + Self.baseIconSize + 36
        let height = Self.baseIconSize * 1.2 + Self.verticalDepth + 10
        let centerX = width / 2
        let centerY = height / 2 + Self.verticalDepth / 2

        VStack(spacing: 2) {
            ZStack {
                ForEach(slots, id: \.entry.id) { slot in
                    let theta = 2 * CGFloat.pi * CGFloat(slot.offset) / CGFloat(n)
                    let depth = (cos(theta) + 1) / 2  // 1 = front, 0 = back
                    // The high exponent concentrates size on the front slot so
                    // the focused app clearly outranks its neighbors, while
                    // the floor keeps the back row legible.
                    let emphasis = pow(depth, 2.5)
                    CarouselIcon(
                        icon: slot.entry.icon,
                        showGlow: slot.offset == 0,
                        iconSize: Self.baseIconSize,
                        scale: 0.66 + 0.64 * emphasis,
                        shadowOpacity: 0.4 * depth,
                        iconOpacity: 0.68 + 0.32 * depth,
                        onTap: { onSelect(slot.entry.id) }
                    )
                    .position(
                        x: centerX + sin(theta) * radius,
                        y: centerY - (1 - depth) * Self.verticalDepth
                    )
                    .zIndex(Double(depth))
                }
            }
            .frame(width: width, height: height)
            .animation(.snappy(duration: 0.28), value: entries[selectedIndex].id)

            Text(entries[selectedIndex].name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: width - 16)
        }
        .padding(.horizontal, 16)
        .padding(.top, 3)
        .padding(.bottom, 10)
        .background(HUDBackground())
        .clipShape(RoundedRectangle(cornerRadius: 36))
        .overlay {
            RoundedRectangle(cornerRadius: 36)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(gearHovering ? 0.95 : 0.5))
                    .scaleEffect(gearHovering ? 1.12 : 1)
                    .animation(.easeOut(duration: 0.12), value: gearHovering)
            }
            .buttonStyle(.plain)
            .padding(16)
            .onHover { isHovering in
                gearHovering = isHovering
                if isHovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .onHover(perform: onHover)
    }
}

/// One app icon on the ring; brightens, pops, and shows the pointing-hand
/// cursor on hover so it reads as clickable.
private struct CarouselIcon: View {
    let icon: NSImage
    let showGlow: Bool
    let iconSize: CGFloat
    let scale: CGFloat
    let shadowOpacity: Double
    let iconOpacity: Double
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: iconSize, height: iconSize)
            .background {
                if showGlow {
                    Circle()
                        .fill(.white.opacity(0.28))
                        .frame(width: iconSize * 1.5, height: iconSize * 1.5)
                        .blur(radius: 14)
                }
            }
            .scaleEffect(scale * (hovering ? 1.08 : 1))
            .shadow(color: .black.opacity(shadowOpacity), radius: 6, y: 3)
            .opacity(hovering ? 1 : iconOpacity)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
            .onHover { isHovering in
                hovering = isHovering
                if isHovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onTapGesture(perform: onTap)
    }
}
