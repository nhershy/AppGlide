//
//  MusicController.swift
//  AppGlide
//

import AppKit
import ApplicationServices
import Foundation

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var favorited: Bool
    var shuffle: Bool
    var repeatMode: RepeatMode
    var persistentID: String
    /// True while the station started from the HUD is still driving playback.
    /// Maintained by the controller's station latch — Music's scripting
    /// interface cannot report this itself (see the latch comment).
    var isStation: Bool
}

enum RepeatMode: String, Equatable {
    case off
    case all
    case one

    /// Music's `song repeat` comes back as a typeEnumerated descriptor whose
    /// enumCodeValue is a four-char OSType: 'kRpO' off, 'kRpA' all, 'kRp1' one.
    init?(enumCode: OSType) {
        switch enumCode {
        case 0x6B52704F: self = .off   // 'kRpO'
        case 0x6B527041: self = .all   // 'kRpA'
        case 0x6B527031: self = .one   // 'kRp1'
        default: return nil
        }
    }

    /// Music.app's own button cycle: off → all → one → off.
    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

enum MusicState: Equatable {
    case notRunning
    case permissionDenied
    case nothingPlaying
    case playing(NowPlaying)
}

enum MusicDestination {
    case song
    case album
    case artist
}

/// Talks to the Music app over Apple Events. Requires the hardened-runtime
/// entitlement com.apple.security.automation.apple-events — without it macOS
/// auto-denies every event silently, with no consent prompt.
///
/// Every call is guarded by an is-running check because `tell application
/// "Music"` silently launches it. Scripts run on a dedicated serial queue
/// (NSAppleScript isn't thread-safe, but one fresh instance per call confined
/// to one queue is) so the trackpad stream on the main actor never blocks on
/// a 10–100ms Apple Event.
final class MusicController {
    private nonisolated static let musicBundleID = "com.apple.Music"
    private nonisolated static let scriptQueue = DispatchQueue(label: "AppGlide.MusicController.script")

    /// TCC denial for Apple Events.
    private static let errAEEventNotPermitted = -1743
    /// "Object not found" — used to detect the add-to-library fallback case.
    private static let errAENoSuchObject = -1731

    private struct ScriptError: Error {
        let code: Int
        let message: String
    }

    private var cachedArtwork: (persistentID: String, image: NSImage?)?

    /// setVolume coalescing state — only touched on the main actor.
    private var volumeSendActive = false
    private var pendingVolume: Int?

    // MARK: - Station latch
    //
    // AppleScript cannot tell station playback from an on-demand catalog
    // song: both report a `URL track` with identical properties, no current
    // playlist, and no stream title (verified against Music on macOS 26 —
    // playerInfo notifications and the Controls menu are equally blind). So
    // "a station is playing" is tracked as a latch instead: set when the HUD
    // starts a station, cleared when evidence shows the user took over —
    // a non-stream track, a stop, or a jump to a different track mid-song.
    // Natural station advances only happen at end-of-track, which is what
    // the position baseline distinguishes.

    /// All latch state — only touched on the main actor, like the volume
    /// coalescing above.
    private var stationLatched = false
    /// Deadline for a just-requested station to actually start: any playback
    /// discontinuity inside the window confirms it; none by the deadline
    /// means the deep link fizzled and the latch clears.
    private var stationStartDeadline: Date?
    /// HUD-initiated next/previous must not read as takeovers.
    private var expectedSkipUntil: Date?
    /// Last observed playback sample — the baseline discontinuities are
    /// judged against.
    private var lastSample: (trackID: String, position: Double, duration: Double, at: Date)?

    var isStationLatched: Bool { stationLatched }

    /// Called when the HUD successfully opens a station deep link.
    private func noteStationRequested() {
        stationLatched = true
        stationStartDeadline = Date().addingTimeInterval(15)
    }

    private func noteExpectedSkip() {
        guard stationLatched else { return }
        expectedSkipUntil = Date().addingTimeInterval(5)
    }

    private func clearStationLatch(_ reason: String) {
        guard stationLatched else { return }
        stationLatched = false
        stationStartDeadline = nil
        expectedSkipUntil = nil
        AppLog.log("station latch: cleared (\(reason))")
    }

    /// Runs once per refresh with the freshly polled playback sample.
    private func updateStationLatch(
        trackID: String, position: Double, duration: Double, streamed: Bool
    ) {
        let sampledAt = Date()
        defer { lastSample = (trackID, position, duration, sampledAt) }
        guard stationLatched, let last = lastSample else { return }
        let changedTrack = trackID != last.trackID

        if let deadline = stationStartDeadline {
            // Waiting for the created station to start. The station's first
            // track can be the seed song itself, so a rewind counts as a
            // discontinuity too.
            if changedTrack || position < last.position - 5 {
                stationStartDeadline = nil
            } else if sampledAt > deadline {
                clearStationLatch("station never started")
            }
            return
        }

        if !streamed {
            clearStationLatch("non-stream playback")
            return
        }
        guard changedTrack else { return }
        if let skip = expectedSkipUntil, sampledAt <= skip {
            expectedSkipUntil = nil
            return
        }
        // Natural end-of-track advance: the previous sample was within reach
        // of the track's end given how long ago it was taken. The margin
        // adapts to the poll cadence (1s visible, slower when hidden).
        let margin = sampledAt.timeIntervalSince(last.at) + 2.0
        if last.duration > 0, last.position >= last.duration - margin {
            return
        }
        clearStationLatch("manual playback change")
    }

    nonisolated static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).isEmpty
    }

    /// Presents the Automation consent prompt from the main thread if needed.
    /// Returns false only on a known denial.
    func ensureAutomationPermission() -> Bool {
        guard Self.isMusicRunning else { return true }
        var addressDesc = AEAddressDesc()
        let created = Self.musicBundleID.utf8CString.withUnsafeBufferPointer { buffer in
            AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count - 1, &addressDesc)
        }
        guard created == noErr else { return true }
        defer { AEDisposeDesc(&addressDesc) }
        let status = AEDeterminePermissionToAutomateTarget(
            &addressDesc, typeWildCard, typeWildCard, true
        )
        return status != OSStatus(Self.errAEEventNotPermitted)
    }

    // MARK: - Script plumbing

    private nonisolated static func executeAsync(_ source: String) async -> Result<NSAppleEventDescriptor, ScriptError> {
        await withCheckedContinuation { continuation in
            scriptQueue.async {
                var errorInfo: NSDictionary?
                let script = NSAppleScript(source: source)
                if let descriptor = script?.executeAndReturnError(&errorInfo) {
                    continuation.resume(returning: .success(descriptor))
                } else {
                    let code = (errorInfo?[NSAppleScript.errorNumber] as? Int) ?? 0
                    let message = (errorInfo?[NSAppleScript.errorMessage] as? String) ?? ""
                    continuation.resume(returning: .failure(ScriptError(code: code, message: message)))
                }
            }
        }
    }

    // MARK: - State

    /// Volume is the Music app's own `sound volume` (0–100), returned in both
    /// script branches so it's known even when nothing is playing; nil on the
    /// error paths so callers can keep the last known value.
    func refresh() async -> (state: MusicState, volume: Int?) {
        guard Self.isMusicRunning else {
            clearStationLatch("Music not running")
            return (.notRunning, nil)
        }
        // Deliberately NO try/on error around the script as a whole: a TCC
        // denial raises a catchable AppleScript error, and swallowing it would
        // masquerade as "nothing playing". Errors must surface here. The two
        // narrow trys below sit after `current track` has already executed, so
        // a TCC denial still errors out of the script before reaching them —
        // they only shield the stream probe, which must degrade to "not
        // streamed" rather than sink the whole refresh.
        //
        // `streamed` (URL track class, or a live-radio stream title) can NOT
        // positively identify a station — on-demand catalog songs are also
        // URL tracks. It's a negative signal only: a non-stream track proves
        // the user left the station, feeding the latch (see MARK above).
        let source = """
        tell application "Music"
            if player state is stopped then return {"stopped", sound volume}
            set t to current track
            set streamed to false
            try
                if class of t is URL track then set streamed to true
            end try
            if not streamed then
                try
                    set streamTitle to current stream title
                    if streamTitle is not missing value and streamTitle is not "" then set streamed to true
                end try
            end if
            return {"ok", name of t, artist of t, album of t, ¬
                (player state is playing), player position, duration of t, ¬
                favorited of t, shuffle enabled, persistent ID of t, sound volume, streamed, ¬
                song repeat}
        end tell
        """
        switch await Self.executeAsync(source) {
        case .failure(let error):
            if error.code == Self.errAEEventNotPermitted {
                clearStationLatch("automation permission denied")
                return (.permissionDenied, nil)
            }
            AppLog.log("Music refresh failed (\(error.code)) \(error.message)")
            return (.nothingPlaying, nil)
        case .success(let descriptor):
            guard descriptor.atIndex(1)?.stringValue == "ok",
                  descriptor.numberOfItems >= 13 else {
                clearStationLatch("playback stopped")
                let volume: Int? = descriptor.atIndex(1)?.stringValue == "stopped"
                    ? descriptor.atIndex(2).map { Int($0.int32Value) }
                    : nil
                return (.nothingPlaying, volume)
            }
            let trackID = descriptor.atIndex(10)?.stringValue ?? ""
            let position = descriptor.atIndex(6)?.doubleValue ?? 0
            let duration = descriptor.atIndex(7)?.doubleValue ?? 0
            updateStationLatch(
                trackID: trackID,
                position: position,
                duration: duration,
                streamed: descriptor.atIndex(12)?.booleanValue ?? false
            )
            let now = NowPlaying(
                title: descriptor.atIndex(2)?.stringValue ?? "",
                artist: descriptor.atIndex(3)?.stringValue ?? "",
                album: descriptor.atIndex(4)?.stringValue ?? "",
                isPlaying: descriptor.atIndex(5)?.booleanValue ?? false,
                position: position,
                duration: duration,
                favorited: descriptor.atIndex(8)?.booleanValue ?? false,
                shuffle: descriptor.atIndex(9)?.booleanValue ?? false,
                repeatMode: descriptor.atIndex(13).flatMap { RepeatMode(enumCode: $0.enumCodeValue) } ?? .off,
                persistentID: trackID,
                isStation: stationLatched
            )
            return (.playing(now), descriptor.atIndex(11).map { Int($0.int32Value) })
        }
    }

    /// The slow call — fetched only when the track changes, cached per track.
    func artwork(for persistentID: String) async -> NSImage? {
        if let cached = cachedArtwork, cached.persistentID == persistentID {
            return cached.image
        }
        guard Self.isMusicRunning else { return nil }
        let source = "tell application \"Music\" to return raw data of artwork 1 of current track"
        var image: NSImage?
        if case .success(let descriptor) = await Self.executeAsync(source) {
            image = NSImage(data: descriptor.data)
        }
        cachedArtwork = (persistentID, image)
        return image
    }

    // MARK: - Controls (fire and forget; the poll picks up resulting state)

    private func run(_ source: String) async {
        guard Self.isMusicRunning else { return }
        if case .failure(let error) = await Self.executeAsync(source), error.code != 0 {
            AppLog.log("Music command failed (\(error.code)) \(error.message): \(source)")
        }
    }

    func playPause() async { await run("tell application \"Music\" to playpause") }
    func next() async {
        noteExpectedSkip()
        await run("tell application \"Music\" to next track")
    }
    /// Media-key behavior: restart the track, or go to the previous one when
    /// already near the start.
    func previous() async {
        noteExpectedSkip()
        await run("tell application \"Music\" to back track")
    }

    /// Explicit target rather than a toggle: catalog tracks can report
    /// favorited as false even after a successful favorite, so toggling off
    /// the reported value would re-favorite on a click meant to unfavorite.
    func setFavorited(_ favorited: Bool) async {
        await run("tell application \"Music\" to set favorited of current track to \(favorited)")
    }

    func setShuffle(_ enabled: Bool) async {
        await run("tell application \"Music\" to set shuffle enabled to \(enabled)")
    }

    func setRepeat(_ mode: RepeatMode) async {
        await run("tell application \"Music\" to set song repeat to \(mode.rawValue)")
    }

    func seek(to seconds: Double) async {
        await run("tell application \"Music\" to set player position to \(max(seconds, 0))")
    }

    /// Music-app volume, 0–100 (NOT system volume). The slider drag fires at
    /// 60–120 Hz; one Apple Event per tick would backlog the serial queue for
    /// seconds, so bursts coalesce last-write-wins: at most one event in
    /// flight, always converging on the most recent value.
    func setVolume(_ level: Int) async {
        pendingVolume = min(max(level, 0), 100)
        guard !volumeSendActive else { return }
        volumeSendActive = true
        while let level = pendingVolume {
            pendingVolume = nil
            await run("tell application \"Music\" to set sound volume to \(level)")
        }
        volumeSendActive = false
    }

    func addToLibrary() async -> Bool {
        guard Self.isMusicRunning else { return false }
        let primary = "tell application \"Music\" to duplicate current track to source \"Library\""
        switch await Self.executeAsync(primary) {
        case .success:
            return true
        case .failure(let error):
            guard error.code == Self.errAENoSuchObject else {
                AppLog.log("add to library failed (\(error.code)) \(error.message)")
                return false
            }
            let fallback = "tell application \"Music\" to duplicate current track to library playlist 1"
            if case .failure(let error) = await Self.executeAsync(fallback) {
                AppLog.log("add to library fallback failed (\(error.code)) \(error.message)")
                return false
            }
            return true
        }
    }

    func userPlaylists() async -> [String] {
        guard Self.isMusicRunning else { return [] }
        let source = """
        tell application "Music" to get name of every user playlist ¬
            whose special kind is none and smart is false and genius is false
        """
        guard case .success(let descriptor) = await Self.executeAsync(source),
              descriptor.numberOfItems >= 1 else { return [] }
        return (1...descriptor.numberOfItems).compactMap {
            descriptor.atIndex($0)?.stringValue
        }
    }

    /// Streaming tracks can't be duplicated straight into a playlist
    /// (error -10006): they must be added to the Library, and the LIBRARY
    /// COPY placed into the playlist. The library copy of a fresh add appears
    /// asynchronously (iCloud Music Library sync — can take many seconds), so
    /// the wait is a Swift-side retry of small quick scripts rather than one
    /// long blocking script: refresh polls interleave and the UI stays live.
    func addToPlaylist(_ name: String) async -> Bool {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let playlist = esc(name)
        AppLog.log("add to playlist \"\(name)\" requested")

        let direct = "tell application \"Music\" to duplicate current track to playlist \"\(playlist)\""
        switch await Self.executeAsync(direct) {
        case .success:
            AppLog.log("add to playlist \"\(name)\": direct")
            return true
        case .failure(let error):
            guard error.code == -10006 else {
                AppLog.log("add to playlist \"\(name)\" failed (\(error.code)) \(error.message)")
                return false
            }
        }

        // Capture the track's identity and kick off the library add.
        let prep = """
        tell application "Music"
            set t to current track
            try
                duplicate t to source "Library"
            end try
            return (name of t) & linefeed & (artist of t)
        end tell
        """
        guard Self.isMusicRunning,
              case .success(let descriptor) = await Self.executeAsync(prep),
              let combined = descriptor.stringValue,
              case let parts = combined.components(separatedBy: "\n"),
              parts.count >= 2 else {
            AppLog.log("add to playlist \"\(name)\": library add prep failed")
            return false
        }
        let find = """
        tell application "Music"
            set matches to (every track of library playlist 1 whose ¬
                name is "\(esc(parts[0]))" and artist is "\(esc(parts[1]))")
            if (count of matches) is 0 then return "pending"
            duplicate (item 1 of matches) to playlist "\(playlist)"
            return "done"
        end tell
        """
        for attempt in 1...30 {
            guard Self.isMusicRunning else { return false }
            if case .success(let result) = await Self.executeAsync(find),
               result.stringValue == "done" {
                AppLog.log("add to playlist \"\(name)\": two-step done (attempt \(attempt))")
                return true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        AppLog.log("add to playlist \"\(name)\": library copy never appeared within 30s")
        return false
    }

    /// Explicit user action only (Open Music button).
    func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.musicBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Navigation (click-through from the HUD)

    /// Opens Apple Music at the current song / its album / its artist,
    /// resolved through the iTunes Search API. Falls back to revealing the
    /// current track inside the Music app when the lookup can't resolve
    /// (local files, no network).
    func open(_ destination: MusicDestination, for now: NowPlaying) async {
        if let url = await Self.catalogURL(for: destination, now: now) {
            NSWorkspace.shared.open(url)
            return
        }
        await run("tell application \"Music\" to reveal current track")
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleID).first?
            .activate()
    }

    private nonisolated struct SearchResponse: Decodable {
        struct Item: Decodable {
            let trackId: Int?
            let trackViewUrl: String?
            let collectionViewUrl: String?
            let artistViewUrl: String?
        }
        let results: [Item]
    }

    /// One iTunes Search API hit for the current track — shared by the
    /// navigation deep links and Create Station.
    private nonisolated static func searchItem(for now: NowPlaying) async -> SearchResponse.Item? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(now.artist) \(now.title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            return nil
        }
        return response.results.first
    }

    private nonisolated static func catalogURL(
        for destination: MusicDestination,
        now: NowPlaying
    ) async -> URL? {
        guard let item = await searchItem(for: now) else { return nil }
        let target: String?
        switch destination {
        case .song: target = item.trackViewUrl
        case .album: target = item.collectionViewUrl
        case .artist: target = item.artistViewUrl
        }
        guard var urlString = target else { return nil }
        // The music:// scheme opens the Music app instead of a browser.
        if urlString.hasPrefix("https://") {
            urlString = "music://" + urlString.dropFirst("https://".count)
        }
        return URL(string: urlString)
    }

    /// Starts a radio station seeded from the current track, like Music's own
    /// "Create Station". The scripting dictionary has no station verb, and the
    /// iTunes-Radio-era itsradio://…/idsa.<id> scheme is silently swallowed by
    /// modern Music — but every catalog song's station lives at
    /// station/ra.<trackId>. Opening that link starts the station playing;
    /// delivered without activating Music so the HUD keeps focus.
    /// Returns false when the track has no catalog match (local files,
    /// no network) so the UI can show feedback.
    func createStation(for now: NowPlaying) async -> Bool {
        guard Self.isMusicRunning else { return false }
        guard let trackID = await Self.searchItem(for: now)?.trackId else {
            AppLog.log("create station: no catalog match for \(now.artist) — \(now.title)")
            return false
        }
        let country = (Locale.current.region?.identifier ?? "US").lowercased()
        guard let url = URL(string: "music://music.apple.com/\(country)/station/ra.\(trackID)") else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
        } catch {
            AppLog.log("create station: open failed \(error.localizedDescription)")
            return false
        }
        AppLog.log("create station: ra.\(trackID) for \(now.artist) — \(now.title)")
        noteStationRequested()
        return true
    }
}
