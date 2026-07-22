//
//  MusicOverlay.swift
//  AppGlide
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted by MusicOverlay with userInfo ["height": CGFloat] (0 = hidden);
    /// SwitcherOverlay lifts the carousel above the music HUD accordingly.
    static let musicHUDVisibilityChanged = Notification.Name("musicHUDVisibilityChanged")
}

@MainActor
final class MusicHUDModel: ObservableObject {
    @Published var state: MusicState = .notRunning
    @Published var artwork: NSImage?
    @Published var playlists: [String] = []
}

/// Floating Apple Music controls in the carousel's bottom-center slot,
/// toggled by a 3-finger swipe down. Non-activating; hovering either HUD
/// pins both open.
final class MusicOverlay {
    static let hudWidth: CGFloat = 460
    /// Fixed height for all states: keeps the stacking offset known before
    /// layout and avoids frame churn when the state flips mid-display.
    static let hudHeight: CGFloat = 128
    private static let autoHideDelay: Duration = .seconds(2)

    private let controller: MusicController
    private let model = MusicHUDModel()
    private var panel: NSPanel?
    private var hostingView: FirstMouseHostingView<MusicHUDView>?
    private var hideTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init(controller: MusicController) {
        self.controller = controller
        HUDHoverState.shared.addObserver { [weak self] anyHovering in
            self?.sharedHoverChanged(anyHovering)
        }
    }

    var isVisible: Bool {
        (panel?.isVisible ?? false) && (panel?.alphaValue ?? 0) > 0
    }

    func toggle() {
        if UserDefaults.standard.object(forKey: PrefKey.hapticsEnabled) as? Bool ?? true {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = ensurePanel()
        let size = NSSize(width: Self.hudWidth, height: Self.hudHeight)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let screen {
            let visible = screen.visibleFrame
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        NotificationCenter.default.post(
            name: .musicHUDVisibilityChanged,
            object: nil,
            userInfo: ["height": Self.hudHeight]
        )

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

        if !controller.ensureAutomationPermission() {
            model.state = .permissionDenied
        }
        startPolling()
        if HUDHoverState.shared.anyHovering {
            hideTask?.cancel()
            hideTask = nil
        } else {
            scheduleAutoHide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        pollTask?.cancel()
        pollTask = nil
        HUDHoverState.shared.setHovering(false, for: "music")
        // Post at hide start so the carousel descends alongside the fade.
        NotificationCenter.default.post(
            name: .musicHUDVisibilityChanged,
            object: nil,
            userInfo: ["height": CGFloat(0)]
        )
        guard let panel, panel.isVisible, panel.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            panel.animator().alphaValue = 0
        } completionHandler: {
            if panel.alphaValue == 0 {
                panel.orderOut(nil)
            }
        }
    }

    // MARK: - Internals

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // First tick also loads the playlists for the add-to menu.
            if let self {
                self.model.playlists = await self.controller.userPlaylists()
            }
            while !Task.isCancelled {
                guard let self else { return }
                let state = await self.controller.refresh()
                self.model.state = state
                if case .playing(let now) = state {
                    self.model.artwork = await self.controller.artwork(for: now.persistentID)
                } else {
                    self.model.artwork = nil
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        let stored = UserDefaults.standard.double(forKey: PrefKey.musicHudDuration)
        let delay: Duration = stored > 0 ? .seconds(stored) : Self.autoHideDelay
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Any interaction keeps the HUD alive.
    private func userDidInteract() {
        if !HUDHoverState.shared.anyHovering {
            scheduleAutoHide()
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        HUDHoverState.shared.setHovering(hovering, for: "music")
    }

    private func sharedHoverChanged(_ anyHovering: Bool) {
        if anyHovering {
            hideTask?.cancel()
            hideTask = nil
            if let panel, panel.isVisible {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.1
                    panel.animator().alphaValue = 1
                }
            }
        } else if isVisible {
            scheduleAutoHide()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }
        let root = MusicHUDView(
            model: model,
            controller: controller,
            onHover: { [weak self] hovering in self?.hoverChanged(hovering) },
            onInteract: { [weak self] in self?.userDidInteract() }
        )
        let hosting = FirstMouseHostingView(rootView: root)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.hudWidth, height: Self.hudHeight),
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

// MARK: - Views

private struct MusicHUDView: View {
    @ObservedObject var model: MusicHUDModel
    let controller: MusicController
    let onHover: (Bool) -> Void
    let onInteract: () -> Void

    /// While set, the bar and elapsed label follow the drag instead of the
    /// poll; held briefly after seek so the bar doesn't snap back before the
    /// next poll reflects the new position.
    @State private var scrubFraction: Double?

    var body: some View {
        Group {
            switch model.state {
            case .notRunning:
                placeholder(icon: "music.note.slash", text: "Music isn't running") {
                    Button("Open Music") { controller.openMusic() }
                }
            case .permissionDenied:
                placeholder(icon: "exclamationmark.triangle.fill", text: "Allow AppGlide to control Music") {
                    HStack(spacing: 8) {
                        Button("Try Again") {
                            _ = controller.ensureAutomationPermission()
                        }
                        Button("Settings") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
                            )
                        }
                    }
                }
            case .nothingPlaying:
                player(now: nil)
            case .playing(let now):
                player(now: now)
            }
        }
        .frame(width: MusicOverlay.hudWidth, height: MusicOverlay.hudHeight)
        .background(HUDBackground())
        .clipShape(RoundedRectangle(cornerRadius: 36))
        .overlay {
            RoundedRectangle(cornerRadius: 36)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .onHover(perform: onHover)
    }

    private func placeholder(icon: String, text: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                action()
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    private func player(now: NowPlaying?) -> some View {
        HStack(spacing: 14) {
            artworkView
            VStack(alignment: .leading, spacing: 4) {
                Text(now?.title ?? "Nothing playing")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(now.map { "\($0.artist) — \($0.album)" } ?? " ")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                progressBar(now: now)
                controls(now: now)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var artworkView: some View {
        Group {
            if let artwork = model.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.1))
                    Image(systemName: "music.note")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func progressBar(now: NowPlaying?) -> some View {
        let duration = now?.duration ?? 0
        let fraction = scrubFraction ?? progressFraction(now)
        let shownPosition = scrubFraction.map { $0 * duration } ?? (now?.position ?? 0)
        return HStack(spacing: 8) {
            Text(timeString(shownPosition))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.15))
                        .frame(height: 4)
                    Capsule()
                        .fill(.white.opacity(0.75))
                        .frame(width: max(geometry.size.width * fraction, 0), height: 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            onInteract()
                            scrubFraction = min(max(value.location.x / geometry.size.width, 0), 1)
                        }
                        .onEnded { value in
                            guard duration > 0 else {
                                scrubFraction = nil
                                return
                            }
                            let target = min(max(value.location.x / geometry.size.width, 0), 1)
                            scrubFraction = target
                            Task {
                                await controller.seek(to: target * duration)
                                // Hold the scrubbed position until the next
                                // poll reflects it, so the bar doesn't snap back.
                                try? await Task.sleep(for: .milliseconds(1200))
                                scrubFraction = nil
                            }
                        }
                )
            }
            .frame(height: 16)
            Text(timeString(duration))
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
    }

    private func controls(now: NowPlaying?) -> some View {
        HStack(spacing: 16) {
            controlButton("backward.fill") { await controller.previous() }
            controlButton(
                now?.isPlaying == true ? "pause.fill" : "play.fill",
                size: 22,
                hitSize: 34
            ) { await controller.playPause() }
            controlButton("forward.fill") { await controller.next() }
            Spacer()
            controlButton(
                now?.favorited == true ? "heart.fill" : "heart",
                tint: now?.favorited == true ? .red : nil
            ) { await controller.toggleFavorite() }
            controlButton("plus.circle") { await controller.addToLibrary() }
            Menu {
                if model.playlists.isEmpty {
                    Text("No playlists")
                } else {
                    ForEach(model.playlists, id: \.self) { playlist in
                        Button(playlist) {
                            onInteract()
                            Task { await controller.addToPlaylist(playlist) }
                        }
                    }
                }
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            controlButton("shuffle", tint: now?.shuffle == true ? .accentColor : nil) {
                await controller.toggleShuffle()
            }
        }
    }

    private func controlButton(
        _ symbol: String,
        size: CGFloat = 16,
        hitSize: CGFloat = 26,
        tint: Color? = nil,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            onInteract()
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(tint ?? Color.white.opacity(0.85))
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func progressFraction(_ now: NowPlaying?) -> CGFloat {
        guard let now, now.duration > 0 else { return 0 }
        return CGFloat(min(max(now.position / now.duration, 0), 1))
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
