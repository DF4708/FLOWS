// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Combine
import Foundation
#if os(iOS)
import MediaPlayer
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Hands-free music while driving: play/pause, skip, shuffle — surfaced as
/// HUD buttons and as Siri App Intents so nobody reaches for the screen.
/// iOS/iPadOS/CarPlay drive the system Music player (MPMusicPlayerController);
/// macOS drives Music.app via Apple Events (sandbox carries the
/// com.apple.Music temporary exception + usage description — the OS asks the
/// user once for Automation consent on first press).
/// Spotify: scripted over Apple Events on macOS; on iOS the same buttons
/// drive Spotify's Web API when the user added a token in Settings
/// (SpotifyRemote — the optional-key pattern), and deep-link otherwise.
@MainActor
final class MusicController: ObservableObject {
    static let shared = MusicController()

    @Published private(set) var isPlaying = false
    @Published private(set) var shuffleOn = false
    /// Cycled play order: shuffle → in order → loop-all.
    enum PlayOrder: String { case shuffle, ordered, loop
        var symbol: String {
            switch self {
            case .shuffle: return "shuffle"
            case .ordered: return "arrow.forward.to.line"
            case .loop: return "repeat"
            }
        }
    }
    @Published private(set) var playOrder: PlayOrder = .ordered
    /// Track name (tooltip under the art placeholder).
    @Published private(set) var trackName: String = ""

    /// One-tap genre rows in the HUD music menu.
    static let genreRows = ["Country", "Rock", "Pop", "Hip-Hop", "Jazz"]

    // MARK: radio as the music service (all platforms)

    /// The radio FLOWS drives when radio is the picked service — handed
    /// over by AppModel at startup (weak: the model owns it). A direct
    /// reference, not a reach through AppModel, so the transport logic
    /// stays testable without the whole app model.
    weak var radioService: TruckerRadio?

    /// True when the driver's picked "service" is FLOWS's own radio — the
    /// transport buttons then drive the station queue: play/pause
    /// silences the stream, next/previous walk the genre's stations.
    var radioActive: Bool { provider == .radio }

    /// Mirror the radio's state into the published fields the mini
    /// player, Siri replies, and CarPlay all read.
    func syncFromRadio() {
        guard radioActive, let radio = radioService else { return }
        isPlaying = radio.playingChannelID != nil && !radio.isPaused
        trackName = radio.lastPlayed?.name ?? ""
        shuffleOn = false
        playOrder = .ordered
    }

    /// Transport for the radio service. Returns false when radio isn't
    /// the active service, so each platform's method falls through to its
    /// own player.
    private func radioTransport(_ action: (TruckerRadio) -> Void) -> Bool {
        guard radioActive, let radio = radioService else { return false }
        action(radio)
        syncFromRadio()
        return true
    }

    #if os(iOS)
    private let player = MPMusicPlayerController.systemMusicPlayer

    static let isAvailable = true

    /// Which service the transport buttons drive (set from the user's
    /// provider pick). Apple Music rides MPMusicPlayerController; Spotify —
    /// when the user added a token in Settings — rides SpotifyRemote's
    /// Web API calls. Everything else deep-links, so never reaches here.
    /// Seeded from the stored pick, not hard-wired to Apple Music: Siri and
    /// CarPlay can call in before the SwiftUI scene (and AppModel) exist.
    var provider: MusicProvider = MusicProvider(
        rawValue: UserDefaults.standard.string(forKey: "flows.musicProvider") ?? ""
    ) ?? .appleMusic

    /// True when the transport calls drive the PICKED service rather than
    /// falling through to Apple Music — the one gate every surface checks
    /// (HUD mini player, Siri intents, CarPlay). Truth table + per-service
    /// survey: MusicProvider.controllable(onMac:spotifyLinked:).
    var controlsInPlace: Bool {
        provider.controllable(onMac: false,
                              spotifyLinked: SpotifyRemote.shared.linked)
    }

    /// Now-playing artwork thumbnail. Stored + published: a computed read of
    /// nowPlayingItem never invalidates SwiftUI, so the mini-player would
    /// keep the placeholder forever.
    @Published private(set) var artwork: CGImage?

    private var spotifySync: AnyCancellable?

    /// The transport buttons drive Spotify's Web API instead of the system
    /// Music player.
    private var spotifyActive: Bool {
        provider == .spotify && SpotifyRemote.shared.linked
    }

    /// Touching the system player triggers the media-library permission
    /// dialog — so nothing touches it until the driver actually uses music.
    /// A fresh install's first launch must not ask for the music library.
    private var activated = false

    init() {
        // The HUD watches THIS object — mirror the Spotify remote's state
        // in so play/pause icons and the track tooltip stay live.
        // (objectWillChange fires before the value lands; the task hop
        // reads it after.)
        spotifySync = SpotifyRemote.shared.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncFromSpotify() }
            }
        // A driver who already picked a music service has been through the
        // permission ask — reconnect to the system player right away so
        // now-playing state is live at launch, exactly as before.
        if UserDefaults.standard.string(forKey: "flows.musicProvider") != nil {
            activateIfNeeded()
        }
    }

    private func activateIfNeeded() {
        guard !activated else { return }
        activated = true
        refresh()
        updateNowPlaying()
        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: player, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: player, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
        player.beginGeneratingPlaybackNotifications()
    }

    private func syncFromSpotify() {
        guard spotifyActive else { return }
        isPlaying = SpotifyRemote.shared.isPlaying
        trackName = SpotifyRemote.shared.trackName
        playOrder = SpotifyRemote.shared.playOrder
        shuffleOn = playOrder == .shuffle
    }

    private func refresh() {
        guard !spotifyActive else { return }   // Music.app state isn't ours
        isPlaying = player.playbackState == .playing
        shuffleOn = player.shuffleMode != .off
    }

    private func updateNowPlaying() {
        // Fire the one-shot boundary hook even for Spotify (the track
        // change is the seam a switch-back should land on).
        if let action = trackBoundaryAction {
            trackBoundaryAction = nil
            action()
        }
        guard !spotifyActive else { return }
        trackName = player.nowPlayingItem?.title ?? ""
        artwork = player.nowPlayingItem?.artwork?
            .image(at: CGSize(width: 64, height: 64))?.cgImage
    }

    private var trackBoundaryAction: (() -> Void)?

    /// Run `action` when the current song ENDS — the seam where switching
    /// back to a streaming service goes unnoticed, instead of cutting a
    /// song off mid-chorus. Runs immediately when nothing is playing, so
    /// a paused or silent player never strands the caller.
    func atNextTrackBoundary(_ action: @escaping () -> Void) {
        guard isPlaying, player.nowPlayingItem != nil else {
            action()
            return
        }
        trackBoundaryAction = action
    }

    func playPause() {
        if radioTransport({ $0.pauseOrResume() }) { return }
        if spotifyActive {
            SpotifyRemote.shared.playPause()
            syncFromSpotify()   // Siri reads isPlaying right back — no hop
            return
        }
        activateIfNeeded()
        if player.playbackState == .playing {
            player.pause()
        } else if player.nowPlayingItem == nil {
            // Cold start (Music app not running, nothing queued): a bare
            // play() stays silent — queue the shuffled library instead.
            playLibraryShuffled()
        } else {
            // prepareToPlay launches the Music service in the background
            // when the app isn't running; play() alone can be dropped.
            player.prepareToPlay()
            player.play()
        }
        refresh()
    }

    /// Songs that live ON THIS DEVICE — cloud items excluded, because a
    /// cloud item is exactly what STOPS working when the signal drops.
    private static func deviceSongsQuery() -> MPMediaQuery {
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: false, forProperty: MPMediaItemPropertyIsCloudItem))
        return query
    }

    /// Is there downloaded/synced music to fall back on? Checked WITHOUT
    /// triggering the media-library prompt — an un-granted library reads
    /// as "nothing local", which sends the handoff to radio instead.
    var hasLocalMusic: Bool {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return false }
        return Self.deviceSongsQuery().items?.isEmpty == false
    }

    /// Does what's playing right now depend on the network? Drives the
    /// offline handoff — local files keep playing and must not be yanked.
    var currentPlaybackNeedsNetwork: Bool {
        if radioActive { return true }             // every station is a stream
        if spotifyActive { return true }           // Web API + Spotify's own stream
        return player.nowPlayingItem?.isCloudItem ?? false
    }

    /// The offline fallback: shuffle what's actually on the device.
    func playLocalLibrary() {
        activateIfNeeded()
        player.setQueue(with: Self.deviceSongsQuery())
        player.shuffleMode = .songs
        playOrder = .shuffle
        player.prepareToPlay()
        player.play()
        refresh()
    }

    /// The guaranteed-resolvable queue: the whole library, shuffled.
    private func playLibraryShuffled() {
        player.setQueue(with: MPMediaQuery.songs())
        player.shuffleMode = .songs
        playOrder = .shuffle
        player.prepareToPlay()
        player.play()
    }

    /// Resume the system player's existing queue (it survives app exits);
    /// shuffled library when there is none. Spotify: resume its last queue.
    func resumeRecent() {
        if radioTransport({ $0.pauseOrResume() }) { return }
        if spotifyActive {
            SpotifyRemote.shared.resume()
            syncFromSpotify()
            return
        }
        activateIfNeeded()
        if player.nowPlayingItem == nil {
            playLibraryShuffled()
        } else {
            player.prepareToPlay()
            player.play()
        }
        refresh()
    }

    /// The user's personal Apple Music station needs a MusicKit developer
    /// token to resolve — the shuffled library is the on-device stand-in.
    func playMyStation() {
        if spotifyActive {
            SpotifyRemote.shared.resume()   // stations are an Apple Music idea
            return
        }
        activateIfNeeded()
        playLibraryShuffled()
        refresh()
    }

    /// One-tap genre play from the library; when the library carries no
    /// matching track, deep-link into Music's search instead of silence.
    /// (The genre rows are hidden for Spotify — its Web API has no library
    /// genre query — so this path stays Apple Music's.)
    func playGenre(_ genre: String) {
        activateIfNeeded()
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: genre, forProperty: MPMediaItemPropertyGenre,
            comparisonType: .contains))
        if query.items?.isEmpty == false {
            player.setQueue(with: query)
            player.shuffleMode = .songs
            playOrder = .shuffle
            player.prepareToPlay()
            player.play()
            refresh()
        } else if let url = URL(string: "music://music.apple.com/search?term="
            + (genre.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? genre)) {
            UIApplication.shared.open(url)
        }
    }

    /// A spoken/tapped music ask: the FULL Apple Music catalog first
    /// (MusicKit — plays on the same system player the transport buttons
    /// drive), the on-device library genre path when the catalog can't
    /// serve (no portal token, no subscription, offline).
    func playSearchOrGenre(_ term: String) {
        activateIfNeeded()
        Task { [weak self] in
            if await MusicKitCatalog.playSearch(term) { return }
            await MainActor.run { self?.playGenre(term) }
        }
    }

    func skip() {
        // Radio: the next station of the same genre.
        if radioTransport({ $0.nextStation() }) { return }
        if spotifyActive {
            SpotifyRemote.shared.skip()
            return
        }
        activateIfNeeded()
        player.skipToNextItem()
    }

    func back() {
        if radioTransport({ $0.previousStation() }) { return }
        if spotifyActive {
            SpotifyRemote.shared.back()
            return
        }
        activateIfNeeded()
        player.skipToPreviousItem()
    }

    /// shuffle → ordered → loop → shuffle.
    func cyclePlayOrder() {
        // Live radio has no play order — the button is hidden for it.
        if radioActive { return }
        if spotifyActive {
            let next: PlayOrder
            switch playOrder {
            case .ordered: next = .shuffle
            case .shuffle: next = .loop
            case .loop: next = .ordered
            }
            playOrder = next
            shuffleOn = next == .shuffle
            SpotifyRemote.shared.setOrder(next)
            return
        }
        activateIfNeeded()
        switch playOrder {
        case .ordered:
            player.shuffleMode = .songs
            player.repeatMode = .none
            playOrder = .shuffle
        case .shuffle:
            player.shuffleMode = .off
            player.repeatMode = .all
            playOrder = .loop
        case .loop:
            player.shuffleMode = .off
            player.repeatMode = .none
            playOrder = .ordered
        }
    }

    func toggleShuffle() { cyclePlayOrder() }

    #elseif os(macOS)
    static let isAvailable = true

    // No state query at init — an Apple Events round-trip would LAUNCH
    // Music.app on FLOWS startup. State refreshes after each user press.
    init() {}

    @discardableResult
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    private func refresh() {
        isPlaying = run("tell application \"Music\" to player state is playing")?
            .booleanValue ?? false
        shuffleOn = run("tell application \"Music\" to shuffle enabled")?
            .booleanValue ?? false
    }

    /// Music.app updates its player state a beat AFTER the command lands —
    /// refreshing immediately read the OLD state (the "flipped icon" bug).
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refresh()
            self?.trackName = self?.run(
                "tell application \"Music\" to get name of current track")?
                .stringValue ?? ""
        }
    }

    /// Runs a play command (the Apple Events round-trip launches Music.app
    /// when it isn't running), then falls back to the shuffled library when
    /// the player is STILL stopped — a cold launch with an empty queue
    /// swallows play/playpause silently.
    private func playWithLibraryFallback(_ source: String) {
        run(source)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if self.run("tell application \"Music\" to player state is stopped")?
                .booleanValue == true {
                self.playLibraryShuffled()
            }
        }
        refreshSoon()
    }

    /// The guaranteed queue: the whole library, shuffled.
    private func playLibraryShuffled() {
        run("tell application \"Music\" to set shuffle enabled to true")
        run("tell application \"Music\" to play library playlist 1")
        playOrder = .shuffle
        refreshSoon()
    }

    /// Which service the transport buttons drive (set from the user's
    /// provider pick, seeded from the stored value). macOS can script
    /// Spotify as well as Music.
    var provider: MusicProvider = MusicProvider(
        rawValue: UserDefaults.standard.string(forKey: "flows.musicProvider") ?? ""
    ) ?? .appleMusic

    /// Same gate as iOS: Apple Music and Spotify script in place here;
    /// no other service exposes a way in (see MusicProvider.controllable).
    var controlsInPlace: Bool {
        provider.controllable(onMac: true, spotifyLinked: false)
    }

    func playPause() {
        if radioTransport({ $0.pauseOrResume() }) { return }
        if provider == .spotify {
            run("tell application \"Spotify\" to playpause")
            refreshSoon()
            return
        }
        playWithLibraryFallback("tell application \"Music\" to playpause")
    }

    /// Resume whatever Music last had queued; shuffled library when empty.
    /// Spotify: resume its own queue (same Apple Events path as playPause).
    func resumeRecent() {
        if radioTransport({ $0.pauseOrResume() }) { return }
        if provider == .spotify {
            run("tell application \"Spotify\" to play")
            refreshSoon()
            return
        }
        playWithLibraryFallback("tell application \"Music\" to play")
    }

    /// Personal Apple Music stations aren't scriptable via Apple Events —
    /// the shuffled library is the stand-in.
    func playMyStation() {
        playLibraryShuffled()
    }

    /// macOS has no MusicKit system-player path — a music ask goes
    /// straight to the scripted library-genre play.
    func playSearchOrGenre(_ term: String) { playGenre(term) }

    /// Apple Events can't tell a downloaded track from a cloud one, so
    /// macOS reports no offline library and the handoff prefers radio.
    /// (The in-car offline case is the phone's, not the desktop's.)
    var hasLocalMusic: Bool { false }

    var currentPlaybackNeedsNetwork: Bool { radioActive || provider == .spotify }

    func playLocalLibrary() { playLibraryShuffled() }

    /// macOS can't observe Music.app track boundaries over Apple Events —
    /// switch back right away rather than never.
    func atNextTrackBoundary(_ action: @escaping () -> Void) { action() }

    /// One-tap genre play from the library; shuffled library when no track
    /// carries the genre (genre strings come from the fixed genreRows list,
    /// so no AppleScript quoting is needed).
    func playGenre(_ genre: String) {
        run("tell application \"Music\" to set shuffle enabled to true")
        if run("tell application \"Music\" to play (some track of library playlist 1 "
               + "whose genre contains \"\(genre)\")") == nil {
            playLibraryShuffled()
        } else {
            playOrder = .shuffle
            refreshSoon()
        }
    }

    func skip() {
        if radioTransport({ $0.nextStation() }) { return }
        run(provider == .spotify
            ? "tell application \"Spotify\" to next track"
            : "tell application \"Music\" to next track")
        refreshSoon()
    }

    func back() {
        if radioTransport({ $0.previousStation() }) { return }
        run(provider == .spotify
            ? "tell application \"Spotify\" to previous track"
            : "tell application \"Music\" to previous track")
        refreshSoon()
    }

    var artwork: CGImage? { nil }   // Music.app artwork needs raw AppleEvent data

    func cyclePlayOrder() {
        if radioActive { return }   // live radio has no play order
        switch playOrder {
        case .ordered:
            run("tell application \"Music\" to set shuffle enabled to true")
            playOrder = .shuffle
        case .shuffle:
            run("tell application \"Music\" to set shuffle enabled to false")
            run("tell application \"Music\" to set song repeat to all")
            playOrder = .loop
        case .loop:
            run("tell application \"Music\" to set song repeat to off")
            playOrder = .ordered
        }
        refreshSoon()
    }

    func toggleShuffle() { cyclePlayOrder() }

    #else
    static let isAvailable = false
    var provider: MusicProvider = .appleMusic
    var controlsInPlace: Bool { false }
    init() {}
    func playPause() {}
    func skip() {}
    func back() {}
    func cyclePlayOrder() {}
    func toggleShuffle() {}
    func resumeRecent() {}
    func playMyStation() {}
    func playGenre(_ genre: String) {}
    func playSearchOrGenre(_ term: String) {}
    var hasLocalMusic: Bool { false }
    var currentPlaybackNeedsNetwork: Bool { false }
    func playLocalLibrary() {}
    func atNextTrackBoundary(_ action: @escaping () -> Void) { action() }
    var artwork: CGImage? { nil }
    #endif
}
