// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// Which NOAA Weather Radio transmitter the app should be tuned to, and when
/// to move to the next one. Pure math, pinned by FLOWSTests — the player
/// itself (AVPlayer, network, audio session) stays out of the way.
///
/// NOAA transmitters cover roughly 40 miles of ground each, so a day's drive
/// crosses several. The rule is: follow the closest one, but only MOVE when
/// the new one is meaningfully closer, because two coverage circles meet
/// along a line where the distances are equal and a naive "closest wins"
/// tuner flips back and forth every few seconds while driving down it.
enum RadioTuning {
    /// A candidate transmitter, reduced to what the choice actually needs.
    struct Station: Equatable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        /// False when the position came from a state fallback rather than
        /// the transmitter's own listing — a coarse guess loses a tie.
        var isExact = true

        static func == (a: Station, b: Station) -> Bool {
            a.id == b.id && a.isExact == b.isExact
                && a.coordinate.latitude == b.coordinate.latitude
                && a.coordinate.longitude == b.coordinate.longitude
        }
    }

    /// How much closer the next transmitter has to be before the tuner
    /// moves: 20%. Below that the two are effectively the same distance and
    /// switching is just flapping.
    static let switchMargin = 0.8

    /// The closest transmitter to a position, with its distance. Exact
    /// listings beat state fallbacks at the same distance.
    static func nearest(to position: CLLocationCoordinate2D,
                        in stations: [Station]) -> (station: Station, meters: Double)? {
        stations
            .map { (station: $0, meters: POIRanking.meters($0.coordinate, position)) }
            .min {
                $0.meters == $1.meters
                    ? ($0.station.isExact && !$1.station.isExact)
                    : $0.meters < $1.meters
            }
    }

    /// The station to switch to as the driver moves, or nil to stay put.
    ///
    /// Nothing playing means nothing to retune — the app never starts audio
    /// on its own. With something playing whose transmitter has no known
    /// position, any located station is an improvement.
    static func retarget(playingID: String?,
                         playingCoordinate: CLLocationCoordinate2D?,
                         position: CLLocationCoordinate2D,
                         stations: [Station]) -> String? {
        guard let playingID,
              let best = nearest(to: position, in: stations),
              best.station.id != playingID else { return nil }
        guard let playingCoordinate else { return best.station.id }
        let current = POIRanking.meters(playingCoordinate, position)
        return best.meters < current * switchMargin ? best.station.id : nil
    }
}
