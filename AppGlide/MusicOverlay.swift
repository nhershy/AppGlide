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
    /// Music-app volume 0–100; nil until the first refresh reports it.
    @Published var volume: Int?
    /// Lives here rather than view @State: the hosting view is never torn
    /// down on hide, so only MusicOverlay can reliably reset the expansion.
    @Published var volumeExpanded = false
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
    static let hudWidth: CGFloat = 500
    /// Fixed height for all states: keeps the stacking offset known before
    /// layout and avoids frame churn when the state flips mid-display.
    static let hudHeight: CGFloat = 128
    private static let autoHideDelay: Duration = .seconds(1.5)

    private let controller: MusicController
    private let model = MusicHUDModel()
    private var panel: NSPanel?
    private var hostingView: FirstMouseHostingView<MusicHUDView>?
    private var pollTask: Task<Void, Never>?
    /// Slow poll that keeps the controller's station latch honest while the
    /// HUD is hidden — without it, a takeover in Music.app between HUD
    /// showings would go unnoticed and the button would reopen green.
    private var stationMonitorTask: Task<Void, Never>?
    private let playlistMenuTarget = PlaylistMenuTarget()

    init(controller: MusicController) {
        self.controller = controller
        HUDHoverState.shared.addObserver { [weak self] anyHovering in
            self?.sharedHoverChanged(anyHovering)
        }
        HUDAutoHide.shared.addExpireHandler { [weak self] in
            self?.hide()
        }
    }

    /// Pops the playlist menu natively. Blocks during menu tracking; the
    /// shared auto-hide is paused so the HUD can't vanish under an open menu.
    /// The selection handler comes from the view so it can drive its own
    /// feedback state (green button + toast).
    private func showPlaylistMenu(onSelect: @escaping (String) -> Void) {
        playlistMenuTarget.onSelect = onSelect
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
        model.volumeExpanded = false
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
        stationMonitorTask?.cancel()
        stationMonitorTask = nil
        startPolling()
        if !HUDHoverState.shared.anyHovering {
            scheduleAutoHide()
        }
    }

    func hide() {
        pollTask?.cancel()
        pollTask = nil
        startStationMonitorIfNeeded()
        model.volumeExpanded = false
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
                let (state, volume) = await self.controller.refresh()
                self.model.state = state
                if let volume { self.model.volume = volume }
                if case .playing(let now) = state {
                    self.model.artwork = await self.controller.artwork(for: now.persistentID)
                } else {
                    self.model.artwork = nil
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// While a HUD-created station plays, keep refreshing at a relaxed
    /// cadence even though the HUD is hidden: the latch needs to see track
    /// transitions to tell natural station advances from the user taking
    /// over in Music.app. Exits as soon as the latch clears.
    private func startStationMonitorIfNeeded() {
        stationMonitorTask?.cancel()
        guard controller.isStationLatched else {
            stationMonitorTask = nil
            return
        }
        stationMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                guard self.controller.isStationLatched else { return }
                let (state, volume) = await self.controller.refresh()
                self.model.state = state
                if let volume { self.model.volume = volume }
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
            onPlaylistMenu: { [weak self] onSelect in self?.showPlaylistMenu(onSelect: onSelect) }
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
    let onPlaylistMenu: (@escaping (String) -> Void) -> Void

    /// While set, the bar and elapsed label follow the drag instead of the
    /// poll; held briefly after seek so the bar doesn't snap back before the
    /// next poll reflects the new position.
    @State private var scrubFraction: Double?
    @State private var artworkHovering = false
    @State private var barHovering = false

    /// Volume twin of scrubFraction: while set, the slider follows the drag
    /// instead of the poll, held briefly after release.
    @State private var volumeFraction: Double?
    @State private var volumeHovering = false
    @State private var volumeCollapseTask: Task<Void, Never>?
    /// Transient action outcome (Create Station, Add to Library, Add to
    /// Playlist), shown as a capsule toast over the HUD.
    @State private var toast: (message: String, icon: String, success: Bool)?
    @State private var toastTask: Task<Void, Never>?

    /// Optimistic toggle states: shown immediately on click, held until the
    /// poll reads the same value back (catalog tracks may never read back
    /// favorited = true, so the heart trusts the click for the life of the
    /// current track) or the track changes.
    @State private var shuffleOverride: Bool?
    @State private var favoritedOverride: Bool?
    /// Optimistic Create Station: green immediately on click, bridging the
    /// few seconds until Music opens the deep link and the poll's isStation
    /// confirms. Unlike shuffle, confirmation may never arrive (createStation
    /// only proves the URL opened), so a failsafe timeout also clears it.
    @State private var stationOverride: Bool?
    /// Last polled persistent ID, to reset per-song state on track change.
    @State private var trackID: String?
    /// Per-song "added" confirmations: green until the track changes.
    @State private var libraryAdded = false
    @State private var playlistAdded = false

    var body: some View {
        Group {
            switch model.state {
            case .notRunning:
                placeholder(
                    icon: "music.note.slash",
                    title: "Music isn't running",
                    caption: "Open it to control playback"
                ) {
                    PillButton("Open Music") { controller.openMusic() }
                }
            case .permissionDenied:
                placeholder(
                    icon: "exclamationmark.triangle.fill",
                    title: "Allow AppGlide to control Music",
                    actionsBelow: true
                ) {
                    HStack(spacing: 8) {
                        PillButton("Try Again") {
                            _ = controller.ensureAutomationPermission()
                        }
                        PillButton("Settings") {
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
        .overlay {
            if let toast {
                toastView(toast)
            }
        }
        .onHover(perform: onHover)
        .onChange(of: model.state) { _, newState in
            guard case .playing(let now) = newState else {
                favoritedOverride = nil
                shuffleOverride = nil
                stationOverride = nil
                libraryAdded = false
                playlistAdded = false
                return
            }
            if now.persistentID != trackID {
                trackID = now.persistentID
                favoritedOverride = nil   // never paint a stale heart on the next song
                libraryAdded = false
                playlistAdded = false
            }
            // Shuffle and station are player-global, not per-track: cleared
            // only once the poll confirms — never on track change, since a
            // just-created station's first track IS a track change and the
            // override exists exactly to cover that window.
            if let f = favoritedOverride, now.favorited == f { favoritedOverride = nil }
            if let s = shuffleOverride, now.shuffle == s { shuffleOverride = nil }
            if stationOverride == true, now.isStation { stationOverride = nil }
        }
    }

    /// Empty-state banner: icon medallion, title/caption, and actions either
    /// trailing (single button) or stacked under the title (button pairs,
    /// which would otherwise crowd the title out of the fixed width).
    private func placeholder(
        icon: String,
        title: String,
        caption: String? = nil,
        actionsBelow: Bool = false,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(.white.opacity(0.08))
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: actionsBelow ? 8 : 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if actionsBelow {
                    action()
                        .fixedSize()
                }
            }
            Spacer(minLength: 12)
            if !actionsBelow {
                action()
                    .fixedSize()
            }
        }
        .padding(.horizontal, 24)
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
        let shuffleOn = shuffleOverride ?? (now?.shuffle == true)
        let favorited = favoritedOverride ?? (now?.favorited == true)
        let stationActive = stationOverride ?? (now?.isStation == true)
        return HStack(spacing: 16) {
            controlButton("backward.fill") { await controller.previous() }
                .help("Previous")
            controlButton(
                now?.isPlaying == true ? "pause.fill" : "play.fill",
                size: 22,
                hitSize: 34
            ) { await controller.playPause() }
                .help(now?.isPlaying == true ? "Pause" : "Play")
            controlButton("forward.fill") { await controller.next() }
                .help("Next")
            Spacer(minLength: 8)
            // Right cluster: the speaker stays put as the collapse toggle; the
            // buttons to its right crossfade into the volume slider.
            HStack(spacing: 12) {
                // ControlButton directly, not the helper: the toggle needs a
                // synchronous withAnimation, not a Task-wrapped action.
                ControlButton(
                    symbol: speakerSymbol,
                    size: 14,
                    hitSize: 26,
                    tint: model.volumeExpanded ? .accentColor : nil
                ) {
                    onInteract()
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.volumeExpanded.toggle()
                    }
                    if model.volumeExpanded {
                        scheduleVolumeCollapse()
                    } else {
                        volumeCollapseTask?.cancel()
                    }
                }
                .help("Volume")
                // Fixed swap width (exactly the five buttons' footprint) so
                // the cluster — and the speaker beside it — never shifts when
                // the slider swaps in; the shorter slider centers inside it.
                Group {
                    if model.volumeExpanded {
                        volumeSlider()
                            .frame(width: 150)
                            .transition(.opacity)
                    } else {
                        HStack(spacing: 12) {
                            controlButton(
                                favorited ? "heart.fill" : "heart",
                                tint: favorited ? .red : nil
                            ) {
                                let target = !favorited
                                favoritedOverride = target
                                await controller.setFavorited(target)
                            }
                            .help(favorited ? "Unfavorite" : "Favorite")
                            controlButton(
                                libraryAdded ? "checkmark.circle.fill" : "plus.circle",
                                tint: libraryAdded ? .green : nil
                            ) {
                                if await controller.addToLibrary() {
                                    withAnimation(.easeOut(duration: 0.15)) { libraryAdded = true }
                                    showToast("Added to Library", icon: "checkmark.circle", success: true)
                                } else {
                                    showToast("Couldn't add to Library", icon: "", success: false)
                                }
                            }
                            .help("Add to Library")
                            // Stays clickable while green: re-seeding a
                            // station from the station's current track is
                            // a valid move.
                            controlButton(
                                "dot.radiowaves.left.and.right",
                                size: 15,
                                tint: stationActive ? .green : nil
                            ) { await createStation(now) }
                                .help(stationActive ? "Station playing — create a new one" : "Create Station")
                            controlButton(
                                playlistAdded ? "text.badge.checkmark" : "text.badge.plus",
                                size: 15,
                                tint: playlistAdded ? .green : nil
                            ) {
                                onPlaylistMenu { name in
                                    // Optimistic: the streaming-track path can
                                    // take ~30s; a late failure reverts below.
                                    withAnimation(.easeOut(duration: 0.15)) { playlistAdded = true }
                                    showToast("Added to \u{201C}\(name)\u{201D}", icon: "checkmark.circle", success: true)
                                    Task {
                                        if await !controller.addToPlaylist(name) {
                                            withAnimation(.easeOut(duration: 0.3)) { playlistAdded = false }
                                            showToast("Couldn't add to \u{201C}\(name)\u{201D}", icon: "", success: false)
                                        }
                                    }
                                }
                            }
                            .help("Add to Playlist")
                            // Stations sequence themselves; Music ignores
                            // shuffle for them, so don't pretend otherwise.
                            controlButton(
                                "shuffle",
                                tint: shuffleOn ? .accentColor : nil,
                                enabled: !stationActive
                            ) {
                                let target = !shuffleOn
                                shuffleOverride = target
                                await controller.setShuffle(target)
                            }
                            .help(stationActive ? "Shuffle unavailable for stations" : "Shuffle")
                        }
                        .transition(.opacity)
                    }
                }
                .frame(width: 178)
            }
        }
    }

    private func controlButton(
        _ symbol: String,
        size: CGFloat = 16,
        hitSize: CGFloat = 26,
        tint: Color? = nil,
        enabled: Bool = true,
        action: @escaping () async -> Void
    ) -> some View {
        ControlButton(symbol: symbol, size: size, hitSize: hitSize, tint: tint, enabled: enabled) {
            onInteract()
            Task { await action() }
        }
    }

    /// Steps with the live level so the icon doubles as a readout. Glyph-width
    /// differences are absorbed by ControlButton's fixed hitSize frame.
    private var speakerSymbol: String {
        let level = volumeFraction.map { Int(($0 * 100).rounded()) } ?? model.volume ?? 50
        switch level {
        case 0: return "speaker.slash.fill"
        case ..<34: return "speaker.wave.1.fill"
        case ..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    /// The scrubber's layout and interaction model, minus the time labels,
    /// bookended by min/max speaker icons. Sets the Music-app volume live
    /// during the drag (safe — the controller coalesces the burst).
    private func volumeSlider() -> some View {
        let active = volumeHovering || volumeFraction != nil
        return HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            GeometryReader { geometry in
                let fraction = volumeFraction ?? Double(model.volume ?? 50) / 100
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.15))
                        .frame(height: active ? 6 : 4)
                    Capsule()
                        .fill(.white.opacity(active ? 0.9 : 0.75))
                        .frame(width: max(geometry.size.width * fraction, 0), height: active ? 6 : 4)
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .offset(x: max(geometry.size.width * fraction - 5.5, 0))
                        .opacity(active ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .animation(.easeOut(duration: 0.12), value: active)
                .contentShape(Rectangle())
                .onHover { volumeHovering = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            onInteract()
                            scheduleVolumeCollapse()
                            let fraction = min(max(value.location.x / geometry.size.width, 0), 1)
                            volumeFraction = fraction
                            Task { await controller.setVolume(Int((fraction * 100).rounded())) }
                        }
                        .onEnded { value in
                            let fraction = min(max(value.location.x / geometry.size.width, 0), 1)
                            volumeFraction = fraction
                            Task {
                                await controller.setVolume(Int((fraction * 100).rounded()))
                                // Hold the dragged level until the next poll
                                // reflects it, so the slider doesn't snap back.
                                try? await Task.sleep(for: .milliseconds(1200))
                                volumeFraction = nil
                            }
                        }
                )
            }
            .frame(height: 16)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// Collapses the slider back to the action cluster after a few idle
    /// seconds; rescheduled by every drag change.
    private func scheduleVolumeCollapse() {
        volumeCollapseTask?.cancel()
        volumeCollapseTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                model.volumeExpanded = false
            }
        }
    }

    private func createStation(_ now: NowPlaying?) async {
        guard let now else { return }
        let created = await controller.createStation(for: now)
        showToast(
            created ? "Station created" : "Couldn't create station",
            icon: "dot.radiowaves.left.and.right",
            success: created
        )
        if created {
            stationOverride = true
            // Failsafe: `created` only proves the URL opened, so the poll may
            // never confirm. Once it has, the polled value drives the tint
            // anyway, making the unconditional clear harmless.
            Task {
                try? await Task.sleep(for: .seconds(10))
                stationOverride = nil
            }
        }
    }

    /// Presents the capsule toast, replacing any toast already showing —
    /// cancelling its pending dismissal so back-to-back outcomes each get
    /// their full display time.
    private func showToast(_ message: String, icon: String, success: Bool) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
            toast = (message, icon, success)
        }
        toastTask = Task {
            try? await Task.sleep(for: .milliseconds(1800))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { toast = nil }
        }
    }

    /// Springs in over the HUD with a blur-materialize, the caller's icon,
    /// and a colored glow; blurs back out when dismissed.
    private func toastView(_ toast: (message: String, icon: String, success: Bool)) -> some View {
        let glow: Color = toast.success ? .green : .orange
        return HStack(spacing: 8) {
            Image(systemName: toast.success ? toast.icon : "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(glow)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: toast.success)
            Text(toast.message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Capsule().fill(.black.opacity(0.5)))
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [glow.opacity(0.6), .white.opacity(0.25), glow.opacity(0.15)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        )
        .shadow(color: glow.opacity(0.45), radius: 16)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .transition(.blurReplace.combined(with: ScaleTransition(0.8)))
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

/// Capsule action button for the placeholder states: translucent fill that
/// brightens on hover, matching the HUD's styling.
private struct PillButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.9))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(hovering ? 0.22 : 0.13)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .contentShape(Capsule())
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

/// Icon button that lights up on hover: soft circular highlight, full-bright
/// icon, slight pop, pointing-hand cursor.
private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let hitSize: CGFloat
    let tint: Color?
    // `var` with a default so the memberwise init keeps existing call sites.
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                // Disabled suppresses the tint too: a player-global flag like
                // "shuffle enabled" can stay true while the button is inert,
                // and accent-plus-dimmed would read as contradictory.
                .foregroundStyle(enabled
                    ? (tint ?? Color.white.opacity(hovering ? 1 : 0.85))
                    : Color.white.opacity(0.3))
                .frame(width: hitSize, height: hitSize)
                .background(Circle().fill(.white.opacity(enabled && hovering ? 0.15 : 0)))
                .contentShape(Rectangle())
                .scaleEffect(enabled && hovering ? 1.08 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovering in
            guard enabled else {
                hovering = false
                return
            }
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
