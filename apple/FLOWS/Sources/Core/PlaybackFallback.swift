// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// What to play when the signal drops mid-drive — pure, so the ladder is
/// pinned by tests instead of discovered on a dead stretch of highway.
///
/// The ladder, in order of what actually survives:
///   1. **Music on the phone** (downloads/synced files) — the ONLY thing
///      that plays with no connection at all.
///   2. **Radio of the same kind** — an internet stream still needs *some*
///      signal, but a 32–64 kbps station survives a weak one-bar link that
///      a music service's high-bitrate stream and its API cannot. This is
///      the degraded-signal rung, not the no-signal rung.
///   3. **Nothing** — said plainly rather than pretending.
///
/// Playback that does NOT need the network (local files already playing)
/// is never touched: the best handoff is the one that doesn't happen.
enum PlaybackFallback {
    enum Source: Equatable {
        /// Shuffle what's downloaded on the device.
        case localLibrary
        /// Tune stations matching what they were listening to.
        case radio(genre: String)
        /// No offline music and no genre to match — say so.
        case nothingAvailable
        /// Leave playback alone (nothing playing, or it isn't network-fed).
        case keepPlaying
    }

    /// - Parameters:
    ///   - isPlaying: something is playing right now (else nothing to save).
    ///   - needsNetwork: what's playing depends on the connection.
    ///   - hasLocalMusic: downloaded songs exist on the device.
    ///   - lastGenre: what they asked for last ("rock"), for a like-for-like
    ///     radio match; empty/nil when unknown.
    static func onConnectionLost(isPlaying: Bool, needsNetwork: Bool,
                                 hasLocalMusic: Bool,
                                 lastGenre: String?) -> Source {
        guard isPlaying, needsNetwork else { return .keepPlaying }
        if hasLocalMusic { return .localLibrary }
        let genre = (lastGenre ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return genre.isEmpty ? .nothingAvailable : .radio(genre: genre)
    }

    /// Plain-words line spoken as the handoff happens — it always names
    /// what changed and why, so silence is never a mystery.
    static func spokenLine(for source: Source) -> String? {
        switch source {
        case .keepPlaying:
            return nil
        case .localLibrary:
            return "Signal dropped — playing the music saved on your phone."
        case .radio(let genre):
            return "Signal dropped and there's no music saved on your phone — "
                + "trying \(genre) radio."
        case .nothingAvailable:
            return "Signal dropped, and there's no music saved on your phone "
                + "to fall back on."
        }
    }
}
