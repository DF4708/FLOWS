// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

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

    #if os(iOS)
    private let player = MPMusicPlayerController.systemMusicPlayer

    static let isAvailable = true

    /// Now-playing artwork thumbnail. Stored + published: a computed read of
    /// nowPlayingItem never invalidates SwiftUI, so the mini-player would
    /// keep the placeholder forever.
    @Published private(set) var artwork: CGImage?

    init() {
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

    private func refresh() {
        isPlaying = player.playbackState == .playing
        shuffleOn = player.shuffleMode != .off
    }

    private func updateNowPlaying() {
        trackName = player.nowPlayingItem?.title ?? ""
        artwork = player.nowPlayingItem?.artwork?
            .image(at: CGSize(width: 64, height: 64))?.cgImage
    }

    func playPause() {
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

    /// The guaranteed-resolvable queue: the whole library, shuffled.
    private func playLibraryShuffled() {
        player.setQueue(with: MPMediaQuery.songs())
        player.shuffleMode = .songs
        playOrder = .shuffle
        player.prepareToPlay()
        player.play()
    }

    /// Resume the system player's existing queue (it survives app exits);
    /// shuffled library when there is none.
    func resumeRecent() {
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
        playLibraryShuffled()
        refresh()
    }

    /// One-tap genre play from the library; when the library carries no
    /// matching track, deep-link into Music's search instead of silence.
    func playGenre(_ genre: String) {
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

    func skip() {
        player.skipToNextItem()
    }

    func back() {
        player.skipToPreviousItem()
    }

    /// shuffle → ordered → loop → shuffle.
    func cyclePlayOrder() {
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

    func playPause() {
        playWithLibraryFallback("tell application \"Music\" to playpause")
    }

    /// Resume whatever Music last had queued; shuffled library when empty.
    func resumeRecent() {
        playWithLibraryFallback("tell application \"Music\" to play")
    }

    /// Personal Apple Music stations aren't scriptable via Apple Events —
    /// the shuffled library is the stand-in.
    func playMyStation() {
        playLibraryShuffled()
    }

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
        run("tell application \"Music\" to next track")
        refreshSoon()
    }

    func back() {
        run("tell application \"Music\" to previous track")
        refreshSoon()
    }

    var artwork: CGImage? { nil }   // Music.app artwork needs raw AppleEvent data

    func cyclePlayOrder() {
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
    init() {}
    func playPause() {}
    func skip() {}
    func back() {}
    func cyclePlayOrder() {}
    func toggleShuffle() {}
    func resumeRecent() {}
    func playMyStation() {}
    func playGenre(_ genre: String) {}
    var artwork: CGImage? { nil }
    #endif
}
