// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation
#if os(iOS) && canImport(MusicKit)
import MusicKit
#endif

/// Full-catalog Apple Music discovery (MusicKit, a system framework — no
/// dependency): a spoken ask ("rainy day jazz") searches the ENTIRE
/// catalog and queues the best playlist or song on the SYSTEM player —
/// the same player the transport buttons and lock screen already drive.
///
/// Degrades honestly at every gate: MusicKit's automatic developer token
/// requires the MusicKit app service to be enabled for this bundle id in
/// the Apple Developer portal (a signing task, not code), catalog
/// playback needs an Apple Music subscription, and the user must grant
/// media access — any missing piece returns false and the caller falls
/// back to the library-genre path exactly as before.
enum MusicKitCatalog {
    static func playSearch(_ term: String) async -> Bool {
        #if os(iOS) && canImport(MusicKit)
        guard await MusicAuthorization.request() == .authorized else { return false }
        var request = MusicCatalogSearchRequest(
            term: term, types: [Playlist.self, Song.self])
        request.limit = 5
        // A thrown error here is the portal gate (no developer token), no
        // subscription, or no network — all mean "fall back", not "fail".
        guard let response = try? await request.response() else { return false }
        let player = SystemMusicPlayer.shared
        // Playlists first: a genre/mood ask wants a running mix, not one
        // three-minute song followed by silence.
        if let playlist = response.playlists.first {
            player.queue = SystemMusicPlayer.Queue(for: [playlist])
        } else if let song = response.songs.first {
            player.queue = SystemMusicPlayer.Queue(for: [song])
        } else {
            return false
        }
        guard (try? await player.play()) != nil else { return false }
        return true
        #else
        return false
        #endif
    }
}
