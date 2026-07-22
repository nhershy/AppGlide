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
    var persistentID: String
}

enum MusicState: Equatable {
    case notRunning
    case permissionDenied
    case nothingPlaying
    case playing(NowPlaying)
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

    func refresh() async -> MusicState {
        guard Self.isMusicRunning else { return .notRunning }
        // Deliberately NO try/on error in the script: a TCC denial raises a
        // catchable AppleScript error, and swallowing it would masquerade as
        // "nothing playing". Errors must surface here.
        let source = """
        tell application "Music"
            if player state is stopped then return {"stopped"}
            set t to current track
            return {"ok", name of t, artist of t, album of t, ¬
                (player state is playing), player position, duration of t, ¬
                favorited of t, shuffle enabled, persistent ID of t}
        end tell
        """
        switch await Self.executeAsync(source) {
        case .failure(let error):
            if error.code == Self.errAEEventNotPermitted { return .permissionDenied }
            NSLog("AppGlide: Music refresh failed (\(error.code)) \(error.message)")
            return .nothingPlaying
        case .success(let descriptor):
            guard descriptor.numberOfItems >= 1,
                  descriptor.atIndex(1)?.stringValue == "ok",
                  descriptor.numberOfItems >= 10 else {
                return .nothingPlaying
            }
            return .playing(NowPlaying(
                title: descriptor.atIndex(2)?.stringValue ?? "",
                artist: descriptor.atIndex(3)?.stringValue ?? "",
                album: descriptor.atIndex(4)?.stringValue ?? "",
                isPlaying: descriptor.atIndex(5)?.booleanValue ?? false,
                position: descriptor.atIndex(6)?.doubleValue ?? 0,
                duration: descriptor.atIndex(7)?.doubleValue ?? 0,
                favorited: descriptor.atIndex(8)?.booleanValue ?? false,
                shuffle: descriptor.atIndex(9)?.booleanValue ?? false,
                persistentID: descriptor.atIndex(10)?.stringValue ?? ""
            ))
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
            NSLog("AppGlide: Music command failed (\(error.code)) \(error.message): \(source)")
        }
    }

    func playPause() async { await run("tell application \"Music\" to playpause") }
    func next() async { await run("tell application \"Music\" to next track") }
    /// Media-key behavior: restart the track, or go to the previous one when
    /// already near the start.
    func previous() async { await run("tell application \"Music\" to back track") }

    func toggleFavorite() async {
        await run("tell application \"Music\" to set favorited of current track to not favorited of current track")
    }

    func toggleShuffle() async {
        await run("tell application \"Music\" to set shuffle enabled to not shuffle enabled")
    }

    func seek(to seconds: Double) async {
        await run("tell application \"Music\" to set player position to \(max(seconds, 0))")
    }

    func addToLibrary() async {
        guard Self.isMusicRunning else { return }
        let primary = "tell application \"Music\" to duplicate current track to source \"Library\""
        if case .failure(let error) = await Self.executeAsync(primary) {
            if error.code == Self.errAENoSuchObject {
                await run("tell application \"Music\" to duplicate current track to library playlist 1")
            } else if error.code != 0 {
                NSLog("AppGlide: add to library failed (\(error.code)) \(error.message)")
            }
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

    func addToPlaylist(_ name: String) async {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        await run("tell application \"Music\" to duplicate current track to playlist \"\(escaped)\"")
    }

    /// Explicit user action only (Open Music button).
    func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.musicBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
