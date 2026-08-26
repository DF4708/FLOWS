// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// How long to WAIT before assuming a dropped connection killed the music.
///
/// The signal dropping is not the moment the music stops: every player is
/// already holding buffered audio, and it keeps playing from that buffer
/// for a while. Handing off the instant the network path fails would cut
/// off audio that was going to play just fine — and would turn a ten
/// second tunnel into a jarring source switch for no reason.
///
/// So FLOWS waits out the buffer, and hands off only if the connection is
/// STILL down when that audio would have run out. Two things end the wait
/// early, and both are better than the timer:
///   * the connection comes back — nothing happened, no handoff at all;
///   * playback actually stalls — the buffer was shorter than expected,
///     so there is no reason to sit in silence waiting for a clock.
///
/// The timer is the upper bound; a real stall is the true trigger.
enum PlaybackGrace {
    enum Source: Equatable {
        /// FLOWS's own AVPlayer — the buffer here is MEASURED, not guessed.
        case radio
        /// A cloud (not downloaded) track on the system music player.
        case appleMusicCloud
        /// Playing on Spotify's own device; its buffer is invisible to us.
        case spotify
    }

    /// Live streams keep small buffers — a few seconds is normal, and the
    /// floor covers the moment right after tuning when little is loaded.
    static let radioFloorSeconds: Double = 4
    /// Even a generous stream buffer shouldn't hold the handoff forever.
    static let radioCapSeconds: Double = 45
    /// Apple Music's read-ahead isn't published, so this is a CONSERVATIVE
    /// estimate, not a measurement — and it only bounds the wait, because
    /// the system player tells us when playback actually stops.
    static let appleMusicCapSeconds: Double = 30
    /// Spotify plays on its own device and reports nothing while the link
    /// is down, so this cap is the only signal available there. Waiting
    /// costs nothing while its buffer is still producing sound.
    static let spotifyCapSeconds: Double = 40

    /// - Parameter measuredBuffer: seconds of audio already loaded, when
    ///   the player is ours and can be asked. nil for players that can't.
    static func graceSeconds(for source: Source,
                             measuredBuffer: Double? = nil) -> Double {
        switch source {
        case .radio:
            guard let measuredBuffer, measuredBuffer.isFinite else {
                return radioFloorSeconds
            }
            return min(max(measuredBuffer, radioFloorSeconds), radioCapSeconds)
        case .appleMusicCloud:
            return appleMusicCapSeconds
        case .spotify:
            return spotifyCapSeconds
        }
    }
}
