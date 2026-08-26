// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Music services the mini player can hand playback to. All keyless: each
/// entry launches its app through the service's public URL scheme, with the
/// public web player as the fallback when the app isn't installed.
///
/// Apple Music is the only service FLOWS can drive IN PLACE
/// (MPMusicPlayerController on iOS/CarPlay; Music.app Apple Events on
/// macOS). Every other service requires its own SDK for in-app control, so
/// FLOWS opens that service's app instead and says so.
///
/// Standing project rule: no services operated from Russia, China, Iran, or
/// North Korea (e.g. Tencent Music, NetEase, Yandex Music) — do not add them.
enum MusicProvider: String, CaseIterable, Identifiable, Codable {
    /// No streaming subscription needed: FLOWS's own AM/FM internet radio
    /// AS the music service. A genre ask tunes a matching station, next
    /// moves to the next station of that genre, pause silences it — the
    /// shape of a streaming app, served by free public radio.
    case radio
    case appleMusic
    case spotify
    case youtubeMusic
    case amazonMusic
    case pandora
    case siriusXM
    case jioSaavn
    case gaana
    case soundCloud
    case deezer
    case qobuz
    case tidal
    case applePodcasts
    case iHeartRadio
    case audible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .radio: return "Radio (no subscription)"
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .youtubeMusic: return "YouTube Music"
        case .amazonMusic: return "Amazon Music"
        case .pandora: return "Pandora"
        case .siriusXM: return "SiriusXM"
        case .jioSaavn: return "JioSaavn"
        case .gaana: return "Gaana"
        case .soundCloud: return "SoundCloud"
        case .deezer: return "Deezer"
        case .qobuz: return "Qobuz"
        case .tidal: return "Tidal"
        case .applePodcasts: return "Apple Podcasts"
        case .iHeartRadio: return "iHeartRadio"
        case .audible: return "Audible"
        }
    }

    var symbol: String {
        switch self {
        case .radio: return "radio.fill"
        case .appleMusic: return "music.note"
        case .spotify: return "music.note.list"
        case .youtubeMusic: return "play.rectangle.fill"
        case .amazonMusic: return "music.quarternote.3"
        case .pandora: return "dot.radiowaves.left.and.right"
        case .siriusXM: return "antenna.radiowaves.left.and.right"
        case .jioSaavn: return "waveform"
        case .gaana: return "waveform.path"
        case .soundCloud: return "cloud.fill"
        case .deezer: return "waveform.circle.fill"
        case .qobuz: return "hifispeaker.fill"
        case .tidal: return "water.waves"
        case .applePodcasts: return "mic.fill"
        case .iHeartRadio: return "heart.fill"
        case .audible: return "headphones"
        }
    }

    /// The in-place-control truth table, pure so tests pin every case.
    /// Surveyed per service 2026-08 (docs/DATA_FEEDS.md §13), not assumed:
    /// Spotify is the ONLY third-party service with a public remote-control
    /// API (Web API player endpoints, user token). Amazon's API is a closed
    /// partner beta (in-app DRM playback, no remote), Deezer's is frozen
    /// with its SDKs deprecated, SoundCloud registration has been closed
    /// since 2022, Tidal's public API is catalog-only (playback = their SDK
    /// + client key), and YouTube Music / Qobuz / iHeartRadio / JioSaavn /
    /// Gaana / Apple Podcasts / Audible publish no control API at all. So:
    /// Apple Music always; Spotify via Apple Events on macOS or a user
    /// token on iOS; everything else only its own app can control.
    func controllable(onMac: Bool, spotifyLinked: Bool) -> Bool {
        switch self {
        // Radio IS FLOWS's own player — always drivable in place, with no
        // account, subscription, key, or other app involved.
        case .radio: return true
        case .appleMusic: return true
        case .spotify: return onMac || spotifyLinked
        default: return false
        }
    }

    /// The KEYLESS floor of the table above — what works with no token.
    /// The token-aware answer every surface should gate on lives in
    /// `MusicController.controlsInPlace` / `AppModel.musicControllable`.
    var controllable: Bool {
        #if os(macOS)
        return controllable(onMac: true, spotifyLinked: false)
        #else
        return controllable(onMac: false, spotifyLinked: false)
        #endif
    }

    /// One-letter badge so the mini player shows WHICH service is active
    /// (brand logos need each service's asset license; a colored monogram
    /// identifies without imitating). SiriusXM gets "XM" — a plain "s"
    /// would collide with Spotify's badge.
    var monogram: String {
        self == .siriusXM ? "XM" : String(rawValue.prefix(1))
    }

    /// The service's signature color, approximated for the badge.
    var badgeColor: Color {
        switch self {
        case .radio: return Color(red: 0.45, green: 0.32, blue: 0.20)   // radio brown
        case .appleMusic: return Color(red: 0.98, green: 0.18, blue: 0.32)
        case .spotify: return Color(red: 0.11, green: 0.73, blue: 0.33)
        case .youtubeMusic: return Color(red: 0.93, green: 0.11, blue: 0.14)
        case .amazonMusic: return Color(red: 0.05, green: 0.65, blue: 0.85)
        case .pandora: return Color(red: 0.21, green: 0.41, blue: 1.00)
        case .siriusXM: return Color(red: 0.00, green: 0.20, blue: 0.63)
        case .jioSaavn: return Color(red: 0.17, green: 0.62, blue: 0.56)
        case .gaana: return Color(red: 0.91, green: 0.26, blue: 0.21)
        case .soundCloud: return Color(red: 1.00, green: 0.33, blue: 0.00)
        case .deezer: return Color(red: 0.64, green: 0.00, blue: 1.00)
        case .qobuz: return Color(red: 0.00, green: 0.35, blue: 0.65)
        case .tidal: return .black
        case .applePodcasts: return Color(red: 0.57, green: 0.25, blue: 0.86)
        case .iHeartRadio: return Color(red: 0.78, green: 0.06, blue: 0.19)
        case .audible: return Color(red: 0.96, green: 0.60, blue: 0.05)
        }
    }

    /// The service's public app URL scheme (launches the installed app).
    var appURL: URL? {
        let scheme: String
        switch self {
        // Radio plays inside FLOWS — there is no app to launch.
        case .radio: return nil
        case .appleMusic: scheme = "music://"
        case .spotify: scheme = "spotify://"
        case .youtubeMusic: scheme = "youtubemusic://"
        case .amazonMusic: scheme = "amznmp3://"
        case .pandora: scheme = "pandora://"
        case .siriusXM: scheme = "sxm://"
        case .jioSaavn: scheme = "jiosaavn://"
        case .gaana: scheme = "gaana://"
        case .soundCloud: scheme = "soundcloud://"
        case .deezer: scheme = "deezer://"
        case .qobuz: scheme = "qobuz://"
        case .tidal: scheme = "tidal://"
        case .applePodcasts: scheme = "podcasts://"
        case .iHeartRadio: scheme = "iheartradio://"
        case .audible: scheme = "audible://"
        }
        return URL(string: scheme)
    }

    /// Web player fallback when the app isn't installed.
    var webURL: URL {
        let address: String
        switch self {
        // Never opened (radio is controllable in place); the directory
        // FLOWS's stations come from is the honest stand-in.
        case .radio: address = "https://www.radio-browser.info"
        case .appleMusic: address = "https://music.apple.com"
        case .spotify: address = "https://open.spotify.com"
        case .youtubeMusic: address = "https://music.youtube.com"
        case .amazonMusic: address = "https://music.amazon.com"
        case .pandora: address = "https://www.pandora.com"
        case .siriusXM: address = "https://www.siriusxm.com/player"
        case .jioSaavn: address = "https://www.jiosaavn.com"
        case .gaana: address = "https://gaana.com"
        case .soundCloud: address = "https://soundcloud.com"
        case .deezer: address = "https://www.deezer.com"
        case .qobuz: address = "https://play.qobuz.com"
        case .tidal: address = "https://listen.tidal.com"
        case .applePodcasts: address = "https://podcasts.apple.com"
        case .iHeartRadio: address = "https://www.iheart.com"
        case .audible: address = "https://www.audible.com"
        }
        return URL(string: address)!
    }

    /// Native Siri playback tip — services that ship SiriKit media
    /// intents answer "Hey Siri, play country on <service>" DIRECTLY, no
    /// FLOWS in the loop (verified per service, 2026-08 survey, sources
    /// in DATA_FEEDS §13). nil = no evidence the service supports it, so
    /// no tip is shown rather than a guess.
    var siriPlaybackTip: String? {
        switch self {
        // FLOWS plays radio itself, so its phrase routes through FLOWS.
        case .radio: return "Play something in FLOWS"
        case .appleMusic: return "Hey Siri, play country music"
        case .spotify: return "Hey Siri, play country on Spotify"
        case .youtubeMusic: return "Hey Siri, play country on YouTube Music"
        case .amazonMusic: return "Hey Siri, play country on Amazon Music"
        case .pandora: return "Hey Siri, play country on Pandora"
        case .deezer: return "Hey Siri, play country on Deezer"
        case .tidal: return "Hey Siri, play country on Tidal"
        case .iHeartRadio: return "Hey Siri, play country on iHeartRadio"
        default: return nil
        }
    }

    /// The service's own search page for a term — the deep-integration
    /// layer that needs NO key and NO SDK: these are https universal
    /// links, so on a phone with the service's app installed the link
    /// opens IN that app at its search results; otherwise the web player
    /// serves the same page. Every pattern probed live (2026-08); Tidal
    /// answers 403 to curl (bot gate) but the path is its web player's
    /// own search route.
    func searchURL(query: String) -> URL {
        // Strict encoding — & = + ? in a genre/search term must not split
        // the query (the Yelp lesson).
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let address: String
        switch self {
        // Radio searches happen in FLOWS (RadioBrowser), never on the web.
        case .radio: return webURL
        case .appleMusic: address = "https://music.apple.com/us/search?term=\(q)"
        case .spotify: address = "https://open.spotify.com/search/\(q)"
        case .youtubeMusic: address = "https://music.youtube.com/search?q=\(q)"
        case .amazonMusic: address = "https://music.amazon.com/search/\(q)"
        case .pandora: address = "https://www.pandora.com/search/\(q)"
        case .siriusXM: address = "https://www.siriusxm.com/search?activeTab=all&q=\(q)"
        case .jioSaavn: address = "https://www.jiosaavn.com/search/song/\(q)"
        case .gaana: address = "https://gaana.com/search/\(q)"
        case .soundCloud: address = "https://soundcloud.com/search?q=\(q)"
        case .deezer: address = "https://www.deezer.com/search/\(q)"
        case .qobuz: address = "https://play.qobuz.com/search?q=\(q)"
        case .tidal: address = "https://listen.tidal.com/search?q=\(q)"
        case .applePodcasts: address = "https://podcasts.apple.com/us/search?term=\(q)"
        case .iHeartRadio: address = "https://www.iheart.com/search/?q=\(q)"
        case .audible: address = "https://www.audible.com/search?keywords=\(q)"
        }
        return URL(string: address) ?? webURL
    }

    /// Open the service AT a search — its app when installed (iOS routes
    /// the universal link), its web player otherwise. No scheme needed.
    @MainActor
    func openSearch(query: String) {
        let url = searchURL(query: query)
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Open the service: its app when installed, its web player otherwise.
    @MainActor
    func openApp() {
        #if os(iOS)
        guard let app = appURL else {
            UIApplication.shared.open(webURL)
            return
        }
        let web = webURL
        UIApplication.shared.open(app, options: [:]) { opened in
            if !opened { UIApplication.shared.open(web) }
        }
        #elseif os(macOS)
        if let app = appURL, NSWorkspace.shared.open(app) { return }
        NSWorkspace.shared.open(webURL)
        #endif
    }
}
