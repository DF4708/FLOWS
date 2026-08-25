// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Pure request/response shapes for Spotify's Web API player endpoints —
/// split from the controller so FLOWSTests can pin them without a network.
enum SpotifyWebAPI {
    struct Call: Equatable {
        let method: String
        let path: String
    }

    static let apiBase = "https://api.spotify.com"

    static let playerState = Call(method: "GET", path: "/v1/me/player")
    static let next = Call(method: "POST", path: "/v1/me/player/next")
    static let previous = Call(method: "POST", path: "/v1/me/player/previous")

    /// The transport toggle: pause while playing, play while paused.
    static func playPauseCall(isPlaying: Bool) -> Call {
        Call(method: "PUT",
             path: isPlaying ? "/v1/me/player/pause" : "/v1/me/player/play")
    }

    static func shuffleCall(on: Bool) -> Call {
        Call(method: "PUT", path: "/v1/me/player/shuffle?state=\(on)")
    }

    /// Loop-all maps to Spotify's "context" repeat; anything else turns
    /// repeat off (FLOWS's play-order cycle has no single-track loop).
    static func repeatCall(all: Bool) -> Call {
        Call(method: "PUT", path: "/v1/me/player/repeat?state=\(all ? "context" : "off")")
    }

    static func urlRequest(for call: Call, token: String) -> URLRequest? {
        guard let url = URL(string: apiBase + call.path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = call.method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    struct PlayerState: Equatable {
        let isPlaying: Bool
        let track: String
        let shuffle: Bool
        let repeatOn: Bool
    }

    /// GET /v1/me/player payload → the four fields the mini player shows.
    static func parsePlayerState(_ data: Data) -> PlayerState? {
        guard let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let isPlaying = json["is_playing"] as? Bool else { return nil }
        let item = json["item"] as? [String: Any]
        return PlayerState(
            isPlaying: isPlaying,
            track: item?["name"] as? String ?? "",
            shuffle: json["shuffle_state"] as? Bool ?? false,
            repeatOn: (json["repeat_state"] as? String).map { $0 != "off" } ?? false)
    }

    /// Spotify's shuffle/repeat pair → the mini player's play-order cycle.
    static func order(shuffle: Bool, repeatOn: Bool) -> MusicController.PlayOrder {
        if shuffle { return .shuffle }
        return repeatOn ? .loop : .ordered
    }

    /// HTTP status → what the driver should DO, in plain words (nil = fine).
    /// Raw API errors are jargon; each case here names the one fix.
    static func plainWords(status: Int) -> String? {
        switch status {
        case 200...299: return nil
        case 401: return "Spotify token expired or wrong. Paste a fresh one in Settings."
        case 403: return "Spotify says no — remote control needs Spotify Premium."
        case 404: return "No Spotify player is on. Open Spotify and play one song first."
        case 429: return "Spotify is busy. Wait a moment and try again."
        default: return "Spotify didn't answer. Try again."
        }
    }
}

/// OPTIONAL in-app Spotify transport — the Yelp/TomTom pattern: a key the
/// user supplies in Settings lights the feature up; without it the mini
/// player keeps the honest "Open Spotify" button.
///
/// True in-app Spotify control on iOS needs Spotify's own iOS SDK plus a
/// registered client key — a dependency this repo doesn't take. The Web API
/// covers play/pause/skip/shuffle against the user's ACTIVE Spotify device
/// (phone, car, speaker) using the user's own access token. The token is a
/// credential, so it lives in the Keychain (SecureStore), never UserDefaults.
/// macOS doesn't need any of this — Spotify.app is scripted directly over
/// Apple Events (MusicController's macOS branch, unchanged).
@MainActor
final class SpotifyRemote: ObservableObject {
    static let shared = SpotifyRemote()

    /// True when a token is present — gates the transport buttons.
    @Published private(set) var linked: Bool
    @Published private(set) var isPlaying = false
    @Published private(set) var trackName = ""
    @Published private(set) var playOrder: MusicController.PlayOrder = .ordered
    /// Plain-words line for the music menu ("open Spotify first", "token
    /// expired") — nil when everything works.
    @Published private(set) var status: String?

    private var token: String

    static let keychainKey = "spotify.token"

    private init() {
        token = SecureStore.get(Self.keychainKey) ?? ""
        linked = !token.isEmpty
    }

    /// From Settings (AppModel persists via SecureStore on its side too —
    /// this keeps the in-memory copy and the linked flag current).
    func setToken(_ newToken: String) {
        token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        SecureStore.set(token, for: Self.keychainKey)
        linked = !token.isEmpty
        status = nil
        if linked { refresh(afterSeconds: 0) }
    }

    // MARK: - Transport (called by MusicController when Spotify is active)

    func playPause() {
        // Optimistic flip so the button answers instantly; the follow-up
        // state read corrects it if the command didn't land.
        let call = SpotifyWebAPI.playPauseCall(isPlaying: isPlaying)
        isPlaying.toggle()
        send(call)
        refresh(afterSeconds: 0.8)
    }

    /// Resume whatever Spotify last had queued (the music menu's row).
    func resume() {
        isPlaying = true
        send(SpotifyWebAPI.playPauseCall(isPlaying: false))
        refresh(afterSeconds: 0.8)
    }

    func skip() {
        send(SpotifyWebAPI.next)
        refresh(afterSeconds: 0.8)
    }

    func back() {
        send(SpotifyWebAPI.previous)
        refresh(afterSeconds: 0.8)
    }

    func setOrder(_ order: MusicController.PlayOrder) {
        playOrder = order
        send(SpotifyWebAPI.shuffleCall(on: order == .shuffle))
        send(SpotifyWebAPI.repeatCall(all: order == .loop))
    }

    // MARK: - Wire

    private func send(_ call: SpotifyWebAPI.Call) {
        guard linked,
              let request = SpotifyWebAPI.urlRequest(for: call, token: token)
        else { return }
        Task { [weak self] in
            guard let (_, resp) = try? await ThrottledNet.fetch(request),
                  let code = (resp as? HTTPURLResponse)?.statusCode else {
                await MainActor.run { self?.status = "Spotify didn't answer. Try again." }
                return
            }
            await MainActor.run { self?.status = SpotifyWebAPI.plainWords(status: code) }
        }
    }

    /// Read the real player state a beat after a command (Spotify's player
    /// state settles server-side after the command returns — the same
    /// lesson as the macOS refreshSoon).
    private func refresh(afterSeconds delay: Double) {
        guard linked,
              let request = SpotifyWebAPI.urlRequest(for: SpotifyWebAPI.playerState,
                                                     token: token)
        else { return }
        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let (data, resp) = try? await ThrottledNet.fetch(request),
                  let code = (resp as? HTTPURLResponse)?.statusCode else { return }
            await MainActor.run {
                guard let self else { return }
                if code == 200, let state = SpotifyWebAPI.parsePlayerState(data) {
                    self.isPlaying = state.isPlaying
                    self.trackName = state.track
                    self.playOrder = SpotifyWebAPI.order(shuffle: state.shuffle,
                                                         repeatOn: state.repeatOn)
                    self.status = nil
                } else if code == 204 {
                    // 204 = token fine, but no Spotify device is active.
                    self.isPlaying = false
                    self.status = "Open Spotify and play one song first — "
                        + "then the buttons here take over."
                } else {
                    self.status = SpotifyWebAPI.plainWords(status: code)
                }
            }
        }
    }
}
