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

    /// The label each badge carries (the live warning that names it, for
    /// its tap card), in `badges` order; nil where none reaches it.
    ///
    /// A badge sits at its members' weighted centroid — the map may then
    /// snap it again to its ZIP's centre — so no labelled point lies exactly
    /// under it, and a lookup by coordinate finds nothing. Instead each
    /// labelled point joins the NEAREST badge of its own kind within
    /// `radiusMeters`, and a badge takes the label of the worst point that
    /// joined it (the first such point on a tie).
    static func labels<Kind: Hashable>(
        for badges: [Item<Kind>], from labelled: [(item: Item<Kind>, label: String)],
        radiusMeters: CLLocationDistance
    ) -> [String?] {
        var best: [(score: Double, label: String)?] = Array(repeating: nil, count: badges.count)
        for (item, label) in labelled {
            var nearest: (index: Int, meters: CLLocationDistance)?
            for (i, badge) in badges.enumerated() where badge.kind == item.kind {
                let d = POIRanking.meters(badge.coordinate, item.coordinate)
                if d < radiusMeters, d < (nearest?.meters ?? .infinity) { nearest = (i, d) }
            }
            guard let i = nearest?.index else { continue }
            if item.score > (best[i]?.score ?? -.infinity) { best[i] = (item.score, label) }
        }
        return best.map { $0?.label }
    }

    /// Whether an alert event is a warning (or an emergency) — never a
    /// `minor` badge. Winter storms, high wind, extreme heat and cold and red
    /// flags are zone warnings with no outline on the map: the route's badge
    /// is their only symbol, and giving way to a nearby badge of another
    /// kind took them off the map. Watches, advisories and statements can
    /// give way.
    static func isWarning(_ event: String) -> Bool {
        let lower = event.lowercased()
        return lower.contains("warning") || lower.contains("emergency")
    }

    /// Whether a shown badge of the same kind draws the same hazard as a
    /// route badge (`unshown`'s `sameHazard`), from the alert each names. A
    /// warning is the same hazard only as a badge naming that warning; any
    /// other badge is one hazard with its kind.
    static func sameHazard(badgeEvent: String?, shownEvent: String?) -> Bool {
        guard let badgeEvent, isWarning(badgeEvent) else { return true }
        return shownEvent == badgeEvent
    }

    /// A second layer's badges less those a first layer already shows, in
    /// `badges` order (the chosen route's badges beside the planning map's
    /// own). A badge goes when a shown badge of its kind that `sameHazard`
    /// accepts sits within `mergeMeters`: the same hazard drawn twice. (A
    /// route badge named by a warning is the same hazard only as a shown
    /// badge naming that warning: one of its kind from a forecast or an
    /// advisory nearby took the warning's symbol and its tap card away.) A
    /// `minor` badge, one that names nothing the shown symbols don't, also
    /// goes when ANY shown badge sits that close or it lies inside one of
    /// the shown `areas`: two symbols for one area. Any other badge stays,
    /// since different hazards may share an area (the rule `cluster` keeps).
    static func unshown<Kind: Hashable>(
        _ badges: [Item<Kind>], shown: [Item<Kind>], areas: [[CLLocationCoordinate2D]],
        mergeMeters: CLLocationDistance, minor: (Item<Kind>) -> Bool,
        sameHazard: (_ badge: Item<Kind>, _ shown: Item<Kind>) -> Bool = { _, _ in true }
    ) -> [Item<Kind>] {
        // This runs as the map draws: a ring's exact test only where its
        // bounding box could hold the badge.
        let boxes = areas.map(Box.init)
        return badges.filter { badge in
            let near = shown.filter {
                POIRanking.meters($0.coordinate, badge.coordinate) < mergeMeters
            }
            if near.contains(where: { $0.kind == badge.kind && sameHazard(badge, $0) }) {
                return false
            }
            guard minor(badge) else { return true }
            guard near.isEmpty else { return false }
            return !zip(areas, boxes).contains { ring, box in
                box.contains(badge.coordinate)
                    && HazardFeedScores.pointInPolygon(badge.coordinate, ring)
            }
        }
    }

    /// A ring's latitude/longitude bounds.
    private struct Box {
        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLon = Double.infinity, maxLon = -Double.infinity

        init(_ ring: [CLLocationCoordinate2D]) {
            for c in ring {
                minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
                minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
            }
        }

        func contains(_ c: CLLocationCoordinate2D) -> Bool {
            c.latitude >= minLat && c.latitude <= maxLat
                && c.longitude >= minLon && c.longitude <= maxLon
        }
    }
}
