// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// One symbol per risk area, not dozens: greedy severity-first clustering.
/// A badge is kept only if no already-kept badge of the SAME hazard kind sits
/// within the separation radius — so a 300-mile heat corridor shows a few
/// well-spaced heat symbols at the centers of its clusters, while a tornado
/// cell next to a flood zone keeps BOTH symbols (different kinds overlap by
/// design; identical kinds merge).
enum BadgeClustering {
    struct Item<Kind: Hashable> {
        let coordinate: CLLocationCoordinate2D
        let kind: Kind
        let score: Double
    }

    /// Cell key for the spatial index: hazard kind + integer grid cell. Same
    /// kind + same cell hash together; different kinds never collide (matching
    /// the `seed.kind == item.kind` guard).
    private struct GridKey<K: Hashable>: Hashable {
        let kind: K
        let cx: Int
        let cy: Int
    }

    /// Above this many items the O(N²) linear seed scan is replaced by the
    /// grid; below it the linear path is both simpler and faster (a 3×3 hash
    /// probe costs more than a handful of distance checks). Both paths are
    /// byte-identical, so the threshold only trades constant factors.
    private static let gridThreshold = 64

    /// Returns the representative badges, worst-first. Each badge sits at the
    /// SCORE-WEIGHTED CENTROID of its cluster's members ("the central weight
    /// of all affected ZIPs"), not at the worst member — so a storm area's
    /// single symbol marks the middle of the storm, and it stays put as
    /// members at the fringe come and go. The badge keeps its worst member's
    /// score and kind.
    ///
    /// Seed assignment is greedy severity-first: each item joins the
    /// EARLIEST-INSERTED (= highest-score) already-kept seed of its own kind
    /// within `minSeparationMeters`, else becomes a new seed. The linear form
    /// is O(N²) (every item scans every seed). For large inputs a spatial grid
    /// makes it ≈O(N): a same-kind seed within `minSeparationMeters` is
    /// guaranteed to fall in the query cell's 3×3 neighborhood — the grid uses
    /// the SAME 111 320 m/deg constant as `POIRanking.meters`, and the E-W term
    /// there scales by cos(mean-latitude) ≥ cos(max |lat|), so cells are never
    /// too small to miss a true neighbor. The exact `meters(…) < minSep` test
    /// still gates membership, and the minimum in-range seed index is chosen —
    /// so the grid returns the byte-identical result of `firstIndex(where:)`.
    static func cluster<Kind: Hashable>(
        _ items: [Item<Kind>], minSeparationMeters: CLLocationDistance
    ) -> [Item<Kind>] {
        let sorted = items.sorted(by: { $0.score > $1.score })
        var seeds: [Item<Kind>] = []
        var members: [[Item<Kind>]] = []

        if sorted.count >= gridThreshold && minSeparationMeters > 0 {
            // Cell sized so any in-range same-kind seed sits in the 3×3 block.
            let maxAbsLat = sorted.reduce(0.0) { max($0, abs($1.coordinate.latitude)) }
            let cosMin = max(cos(maxAbsLat * .pi / 180), 1e-6)
            let latCell = minSeparationMeters / 111_320.0
            let lonCell = minSeparationMeters / (111_320.0 * cosMin)
            var grid: [GridKey<Kind>: [Int]] = [:]
            for item in sorted {
                let cx = Int((item.coordinate.longitude / lonCell).rounded(.down))
                let cy = Int((item.coordinate.latitude / latCell).rounded(.down))
                var best = -1
                for dx in -1...1 {
                    for dy in -1...1 {
                        guard let idxs = grid[GridKey(kind: item.kind, cx: cx + dx, cy: cy + dy)]
                        else { continue }
                        for si in idxs where best < 0 || si < best {
                            if POIRanking.meters(seeds[si].coordinate, item.coordinate) < minSeparationMeters {
                                best = si
                            }
                        }
                    }
                }
                if best >= 0 {
                    members[best].append(item)
                } else {
                    grid[GridKey(kind: item.kind, cx: cx, cy: cy), default: []].append(seeds.count)
                    seeds.append(item)
                    members.append([item])
                }
            }
        } else {
            for item in sorted {
                if let si = seeds.firstIndex(where: { seed in
                    seed.kind == item.kind
                        && POIRanking.meters(seed.coordinate, item.coordinate) < minSeparationMeters
                }) {
                    members[si].append(item)
                } else {
                    seeds.append(item)
                    members.append([item])
                }
            }
        }

        return zip(seeds, members).map { seed, group in
            let weight = group.reduce(0.0) { $0 + max($1.score, 1e-4) }
            let lat = group.reduce(0.0) { $0 + $1.coordinate.latitude * max($1.score, 1e-4) } / weight
            let lon = group.reduce(0.0) { $0 + $1.coordinate.longitude * max($1.score, 1e-4) } / weight
            return Item(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                        kind: seed.kind, score: seed.score)
        }
    }
}
