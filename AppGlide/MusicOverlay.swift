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

/// Explicit menu-item target: SwiftUI Menu actions never dispatch from a
/// non-activating panel (the window can't become key), so the playlist menu
/// is a manually popped NSMenu with target/action wiring instead.
private final class PlaylistMenuTarget: NSObject {
    var onSelect: ((String) -> Void)?

    @objc func fire(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String {
            onSelect?(name)
        }
    }
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
    private var pollTask: Task<Void, Never>?
    private let playlistMenuTarget = PlaylistMenuTarget()

    init(controller: MusicController) {
        self.controller = controller
        HUDHoverState.shared.addObserver { [weak self] anyHovering in
            self?.sharedHoverChanged(anyHovering)
        }
        HUDAutoHide.shared.addExpireHandler { [weak self] in
            self?.hide()
        }
        playlistMenuTarget.onSelect = { [weak self] name in
            guard let self else { return }
            Task { await self.controller.addToPlaylist(name) }
        }
    }

    /// Pops the playlist menu natively. Blocks during menu tracking; the
    /// shared auto-hide is paused so the HUD can't vanish under an open menu.
    private func showPlaylistMenu() {
        HUDAutoHide.shared.cancel()
        let menu = NSMenu()
        menu.autoenablesItems = false
        if model.playlists.isEmpty {
            let item = NSMenuItem(title: "No playlists", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for name in model.playlists {
                let item = NSMenuItem(
                    title: name,
                    action: #selector(PlaylistMenuTarget.fire(_:)),
                    keyEquivalent: ""
                )
                item.target = playlistMenuTarget
                item.representedObject = name
                item.isEnabled = true
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        // popUp blocks until the menu closes; restart the clock afterwards.
        if isVisible, !HUDHoverState.shared.anyHovering {
            scheduleAutoHide()
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
        if !HUDHoverState.shared.anyHovering {
            scheduleAutoHide()
        }
    }

    func hide() {
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
        // Shared "stays visible" setting — one duration governs both HUDs.
        let stored = UserDefaults.standard.double(forKey: PrefKey.hudDuration)
        let delay: Duration = stored > 0 ? .seconds(stored) : Self.autoHideDelay
        HUDAutoHide.shared.requestAutoHide(after: delay)
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
            HUDAutoHide.shared.cancel()
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
            onInteract: { [weak self] in self?.userDidInteract() },
            onPlaylistMenu: { [weak self] in self?.showPlaylistMenu() }
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
    let onPlaylistMenu: () -> Void

    /// While set, the bar and elapsed label follow the drag instead of the
    /// poll; held briefly after seek so the bar doesn't snap back before the
    /// next poll reflects the new position.
    @State private var scrubFraction: Double?
    @State private var artworkHovering = false
    @State private var barHovering = false

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
                .brightness(artworkHovering ? 0.04 : 0)
                .scaleEffect(artworkHovering ? 1.02 : 1)
                .animation(.easeOut(duration: 0.12), value: artworkHovering)
                .onHover { hovering in
                    artworkHovering = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .onTapGesture {
                    if let now { navigate(.album, now) }
                }
            VStack(alignment: .leading, spacing: 4) {
                if let now {
                    ClickableText(
                        now.title,
                        font: .system(size: 16, weight: .semibold),
                        base: .white,
                        hover: .white
                    ) { navigate(.song, now) }
                } else {
                    Text("Nothing playing")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                bylineView(now: now)
                progressBar(now: now)
                controls(now: now)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Artist and album as separate tap targets: artist opens the artist page,
    /// album the album page.
    @ViewBuilder
    private func bylineView(now: NowPlaying?) -> some View {
        if let now {
            HStack(spacing: 0) {
                ClickableText(
                    now.artist,
                    font: .system(size: 14),
                    base: .white.opacity(0.65),
                    hover: .white
                ) { navigate(.artist, now) }
                Text(" — ")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.65))
                ClickableText(
                    now.album,
                    font: .system(size: 14),
                    base: .white.opacity(0.65),
                    hover: .white
                ) { navigate(.album, now) }
            }
        } else {
            Text(" ")
                .font(.system(size: 14))
        }
    }

    private func navigate(_ destination: MusicDestination, _ now: NowPlaying) {
        onInteract()
        Task { await controller.open(destination, for: now) }
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
        let barActive = barHovering || scrubFraction != nil
        return HStack(spacing: 8) {
            Text(timeString(shownPosition))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.15))
                        .frame(height: barActive ? 6 : 4)
                    Capsule()
                        .fill(.white.opacity(barActive ? 0.9 : 0.75))
                        .frame(width: max(geometry.size.width * fraction, 0), height: barActive ? 6 : 4)
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .offset(x: max(geometry.size.width * fraction - 5.5, 0))
                        .opacity(barActive ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .animation(.easeOut(duration: 0.12), value: barActive)
                .contentShape(Rectangle())
                .onHover { barHovering = $0 }
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
            controlButton("text.badge.plus", size: 15) { onPlaylistMenu() }
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
        ControlButton(symbol: symbol, size: size, hitSize: hitSize, tint: tint) {
            onInteract()
            Task { await action() }
        }
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

/// Icon button that lights up on hover: soft circular highlight, full-bright
/// icon, slight pop, pointing-hand cursor.
private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let hitSize: CGFloat
    let tint: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(tint ?? Color.white.opacity(hovering ? 1 : 0.85))
                .frame(width: hitSize, height: hitSize)
                .background(Circle().fill(.white.opacity(hovering ? 0.15 : 0)))
                .contentShape(Rectangle())
                .scaleEffect(hovering ? 1.08 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hovering = isHovering
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

/// Text that reads as a link on hover: brighter color, slight grow, and the
/// pointing-hand cursor.
private struct ClickableText: View {
    let string: String
    let font: Font
    let base: Color
    let hover: Color
    let action: () -> Void

    @State private var hovering = false

    init(_ string: String, font: Font, base: Color, hover: Color, action: @escaping () -> Void) {
        self.string = string
        self.font = font
        self.base = base
        self.hover = hover
        self.action = action
    }

    var body: some View {
        Text(string)
            .font(font)
            .foregroundStyle(hovering ? hover : base)
            .lineLimit(1)
            .scaleEffect(hovering ? 1.05 : 1, anchor: .leading)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { isHovering in
                hovering = isHovering
                if isHovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onTapGesture(perform: action)
    }
}
