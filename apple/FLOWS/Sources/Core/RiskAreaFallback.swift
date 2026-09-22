// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// When the planning map outlines a risk point with its real ZIP boundary,
/// and when a rough hull ("blob") stands in for it.
enum RiskAreaFallback {
    /// The box the ZIP layer is asked about (`ZCTAFetcher`): the lower 48,
    /// roughly. It also takes in southern Canada, northern Mexico and the
    /// Great Lakes, where no ZIP ever comes back — so only a point's own
    /// lookup, never this box, says it has no ZIP.
    static func inZIPBox(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude > 24 && c.latitude < 50 && c.longitude > -125 && c.longitude < -66
    }

    /// Whether a risk point's blob waits for this sweep's ZIP lookups
    /// instead of drawing now. Inside the box a blob is a placeholder that
    /// snaps into the ZIP outline a moment later, so a point new to the map
    /// waits for its outline. A point an earlier sweep's lookups already
    /// placed keeps what they decided: for Toronto or open water that is its
    /// blob for good, and waiting again blinked it out at every re-sweep.
    /// Outside the box the blob is the only answer and never waits.
    static func blobWaits(at c: CLLocationCoordinate2D, lookupsDone: Bool,
                          placedBefore: Bool) -> Bool {
        inZIPBox(c) && !lookupsDone && !placedBefore
    }
}
