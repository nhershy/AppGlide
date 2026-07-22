//
//  SwitcherOverlay.swift
//  AppGlide
//

import AppKit
import SwiftUI

/// Bottom-of-screen HUD legend: one icon per app in the swipe session, with the
/// current selection highlighted. The panel is non-activating and click-through,
/// so it never steals focus from the app being switched to.
final class SwitcherOverlay {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<SwitcherHUDView>?
    private var hideTask: Task<Void, Never>?
    private let autoHideDelay: Duration

    init(autoHideDelay: Duration) {
        self.autoHideDelay = autoHideDelay
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
        let root = SwitcherHUDView(entries: entries, selectedIndex: clampedIndex)

        let panel = ensurePanel(rootView: root)
        if let hostingView {
            let size = hostingView.fittingSize
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            if let screen {
                let visible = screen.visibleFrame
                let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
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

        hideTask?.cancel()
        hideTask = Task { [weak self, autoHideDelay] in
            try? await Task.sleep(for: autoHideDelay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
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

    private func ensurePanel(rootView: SwitcherHUDView) -> NSPanel {
        if let panel, let hostingView {
            hostingView.rootView = rootView
            return panel
        }
        let hosting = NSHostingView(rootView: rootView)
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
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
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

    private static let baseIconSize: CGFloat = 48
    private static let frontSpacing: CGFloat = 60  // spacing between front neighbors
    private static let minRadius: CGFloat = 64
    private static let verticalDepth: CGFloat = 20

    private var slots: [(offset: Int, entry: HUDEntry)] {
        let n = entries.count
        let half = (n - 1) / 2
        return (-half...(n - 1 - half)).map { r in
            (r, entries[((selectedIndex - r) % n + n) % n])
        }
    }

    var body: some View {
        let n = entries.count
        let radius = max(Self.frontSpacing / (2 * sin(.pi / CGFloat(n))), Self.minRadius)
        let width = 2 * radius + Self.baseIconSize + 36
        let height = Self.baseIconSize * 1.2 + Self.verticalDepth + 10
        let centerX = width / 2
        let centerY = height / 2 + Self.verticalDepth / 2

        VStack(spacing: 2) {
            ZStack {
                ForEach(slots, id: \.entry.id) { slot in
                    let theta = 2 * CGFloat.pi * CGFloat(slot.offset) / CGFloat(n)
                    let depth = (cos(theta) + 1) / 2  // 1 = front, 0 = back
                    Image(nsImage: slot.entry.icon)
                        .resizable()
                        .frame(width: Self.baseIconSize, height: Self.baseIconSize)
                        .scaleEffect(0.66 + 0.49 * depth)
                        .shadow(color: .black.opacity(0.4 * depth), radius: 6, y: 3)
                        .opacity(0.68 + 0.32 * depth)
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
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct HUDBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
