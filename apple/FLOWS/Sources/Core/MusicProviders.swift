// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation
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
    case appleMusic
    case spotify
    case youtubeMusic
    case amazonMusic
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
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .youtubeMusic: return "YouTube Music"
        case .amazonMusic: return "Amazon Music"
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
        case .appleMusic: return "music.note"
        case .spotify: return "music.note.list"
        case .youtubeMusic: return "play.rectangle.fill"
        case .amazonMusic: return "music.quarternote.3"
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

    /// True when FLOWS can play/pause/skip this service in place. Everything
    /// else deep-links to the service's own app.
    var controllable: Bool { self == .appleMusic }

    /// The service's public app URL scheme (launches the installed app).
    var appURL: URL? {
        let scheme: String
        switch self {
        case .appleMusic: scheme = "music://"
        case .spotify: scheme = "spotify://"
        case .youtubeMusic: scheme = "youtubemusic://"
        case .amazonMusic: scheme = "amznmp3://"
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
        case .appleMusic: address = "https://music.apple.com"
        case .spotify: address = "https://open.spotify.com"
        case .youtubeMusic: address = "https://music.youtube.com"
        case .amazonMusic: address = "https://music.amazon.com"
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
