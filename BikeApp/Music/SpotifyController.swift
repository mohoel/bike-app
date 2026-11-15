import AppKit
import Foundation
import Observation

/// Shows and controls what Spotify is playing.
///
/// Commands go to Spotify directly via AppleScript (not via the media keys), so a series
/// playing in the browser is never paused by accident. Spotify is never launched unless
/// the user asks for it. The first command makes macOS ask for permission to control Spotify.
@Observable @MainActor
final class SpotifyController {
    struct Track: Equatable {
        var id: String
        var name: String
        var artist: String
        var artworkURL: URL?
    }

    struct State: Equatable {
        var isRunning: Bool
        var isPlaying: Bool
        var track: Track?
    }

    nonisolated static let bundleId = "com.spotify.client"

    private(set) var isInstalled = false
    private(set) var isRunning = false
    private(set) var isPlaying = false
    private(set) var track: Track?
    private(set) var artwork: NSImage?
    private(set) var permissionDenied = false

    @ObservationIgnored private var artworkFor: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastNotification = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false

    init() {}

    /// Starts watching Spotify (called when a ride starts, so nothing is asked at app launch).
    func start() {
        // Never talk to Spotify from unit tests.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !started else {
            refresh()
            return
        }
        started = true
        isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) != nil
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).isEmpty

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == SpotifyController.bundleId else { return }
            MainActor.assumeIsolated {
                self?.isRunning = true
                self?.refresh(after: 1.5)
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == SpotifyController.bundleId else { return }
            MainActor.assumeIsolated {
                self?.isRunning = false
                self?.isPlaying = false
                self?.track = nil
                self?.artwork = nil
            }
        })
        // Spotify announces every change of track or play state.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.apply(notification: info) }
        })
        refresh()
        startPolling()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Commands

    func playPause() {
        guard isRunning else { return }
        isPlaying.toggle()
        send("playpause")
    }

    func next() {
        guard isRunning else { return }
        send("next track")
    }

    func previous() {
        guard isRunning else { return }
        send("previous track")
    }

    /// Opens Spotify in the background and starts playback.
    func launchAndPlay() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self?.send("play")
            }
        }
    }

    /// Fixed state for previews and snapshot tests.
    func applyPreview(name: String, artist: String, playing: Bool) {
        isInstalled = true
        isRunning = true
        isPlaying = playing
        track = Track(id: "preview", name: name, artist: artist, artworkURL: nil)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: State

    private func apply(notification info: [AnyHashable: Any]) {
        lastNotification = Date()
        let state = (info["Player State"] as? String)?.lowercased() ?? ""
        isRunning = true
        isPlaying = state == "playing"
        if state == "stopped" {
            track = nil
            return
        }
        let id = info["Track ID"] as? String ?? ""
        let name = info["Name"] as? String ?? track?.name ?? ""
        let artist = info["Artist"] as? String ?? track?.artist ?? ""
        let changed = id != track?.id
        track = Track(id: id, name: name, artist: artist, artworkURL: changed ? nil : track?.artworkURL)
        if changed { refresh(after: 0.3) }
    }

    func refresh(after delay: TimeInterval = 0) {
        guard isRunning else { return }
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let result = await Self.runScript(Self.stateScript)
            switch result {
            case let .success(output):
                permissionDenied = false
                guard let state = Self.parse(output) else { return }
                isRunning = state.isRunning
                isPlaying = state.isPlaying
                track = state.track
                await loadArtwork()
            case let .failure(error):
                if error.notAuthorized { permissionDenied = true }
            }
        }
    }

    /// Fallback if Spotify does not send notifications: ask every 5 s.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.isRunning, !self.permissionDenied else { continue }
                if Date().timeIntervalSince(self.lastNotification) > 10 { self.refresh() }
            }
        }
    }

    private func loadArtwork() async {
        guard let track, let url = track.artworkURL else {
            if track == nil { artwork = nil }
            return
        }
        guard artworkFor != track.id else { return }
        artworkFor = track.id
        guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
        if self.track?.id == track.id { artwork = image }
    }

    private func send(_ command: String) {
        Task {
            let script = "if application id \"\(Self.bundleId)\" is running then tell application id \"\(Self.bundleId)\" to \(command)"
            let result = await Self.runScript(script)
            if case let .failure(error) = result, error.notAuthorized { permissionDenied = true }
            refresh(after: 0.4)
        }
    }

    // MARK: AppleScript

    nonisolated static let stateScript = """
    if application id "com.spotify.client" is running then
        tell application id "com.spotify.client"
            set s to player state as string
            if s is "stopped" then return "stopped"
            set t to current track
            return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (id of t) & linefeed & (artwork url of t)
        end tell
    end if
    return "notrunning"
    """

    /// Parses the output of `stateScript`.
    nonisolated static func parse(_ output: String) -> State? {
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let first = lines.first?.lowercased() else { return nil }
        switch first {
        case "notrunning": return State(isRunning: false, isPlaying: false, track: nil)
        case "stopped": return State(isRunning: true, isPlaying: false, track: nil)
        case "playing", "paused":
            guard lines.count >= 4 else { return State(isRunning: true, isPlaying: first == "playing", track: nil) }
            let artwork = lines.count >= 5 ? URL(string: lines[4].trimmingCharacters(in: .whitespaces)) : nil
            let track = Track(id: lines[3], name: lines[1], artist: lines[2], artworkURL: artwork)
            return State(isRunning: true, isPlaying: first == "playing", track: track)
        default:
            return nil
        }
    }

    struct ScriptError: Error {
        var message: String
        /// -1743: the user did not allow controlling Spotify.
        var notAuthorized: Bool { message.contains("-1743") || message.contains("Not authorized") || message.contains("nicht berechtigt") }
    }

    /// Runs AppleScript in a separate osascript process, off the main thread.
    nonisolated static func runScript(_ source: String) async -> Result<String, ScriptError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(ScriptError(message: error.localizedDescription)))
                    return
                }
                let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errors = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(output))
                } else {
                    continuation.resume(returning: .failure(ScriptError(message: errors)))
                }
            }
        }
    }
}
