// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation
#if os(iOS)
import MediaPlayer
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

    #if os(iOS)
    private let player = MPMusicPlayerController.systemMusicPlayer

    static let isAvailable = true

    init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: player, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        player.beginGeneratingPlaybackNotifications()
    }

    private func refresh() {
        isPlaying = player.playbackState == .playing
        shuffleOn = player.shuffleMode != .off
    }

    func playPause() {
        if player.playbackState == .playing { player.pause() } else { player.play() }
        refresh()
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

    var artwork: CGImage? {
        player.nowPlayingItem?.artwork?
            .image(at: CGSize(width: 64, height: 64))?.cgImage
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

    func playPause() {
        run("tell application \"Music\" to playpause")
        refreshSoon()
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
    var artwork: CGImage? { nil }
    #endif
}
