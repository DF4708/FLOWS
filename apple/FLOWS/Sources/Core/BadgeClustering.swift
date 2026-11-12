// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import FlowsBridge
import Foundation

/// One symbol per risk area, not dozens: greedy severity-first clustering.
/// A badge is kept only if no already-kept badge of the SAME hazard kind sits
/// within the separation radius — so a 300-mile heat corridor shows a few
/// well-spaced heat symbols at the centers of its clusters, while a tornado
/// cell next to a flood zone keeps BOTH symbols (different kinds overlap by
/// design; identical kinds merge).
///
/// The rules run in Rust (flows-core `badges`, pinned by a frozen oracle of
/// this file's original Swift). Swift keeps the generic items: each call
/// numbers its kinds, equal kinds alike, and maps the answers back.
enum BadgeClustering {
    struct Item<Kind: Hashable> {
        let coordinate: CLLocationCoordinate2D
        let kind: Kind
        let score: Double
    }

    /// Returns the representative badges, worst-first. Each badge sits at the
    /// SCORE-WEIGHTED CENTROID of its cluster's members ("the central weight
    /// of all affected ZIPs"), not at the worst member — so a storm area's
    /// single symbol marks the middle of the storm, and it stays put as
    /// members at the fringe come and go. The badge keeps its worst member's
    /// score and kind.
    ///
    /// Seed assignment is greedy severity-first: each item joins the
    /// EARLIEST-INSERTED (= highest-score) already-kept seed of its own kind
    /// within `minSeparationMeters`, else becomes a new seed. Large inputs
    /// use a spatial grid in Rust, with the same answer as the linear scan.
    static func cluster<Kind: Hashable>(
        _ items: [Item<Kind>], minSeparationMeters: CLLocationDistance
    ) -> [Item<Kind>] {
        var kinds = Kinds<Kind>()
        let e = kinds.encode(items)
        let flat = e.points.lent { p in
            e.kinds.lent { k in Array(flows_badges_cluster(p, k, minSeparationMeters)) }
        }
        return stride(from: 0, to: flat.count / 3 * 3, by: 3).compactMap { j in
            guard let s = Int(exactly: flat[j]), items.indices.contains(s) else { return nil }
            return Item(
                coordinate: CLLocationCoordinate2D(latitude: flat[j + 1], longitude: flat[j + 2]),
                kind: items[s].kind, score: items[s].score)
        }
    }

    /// One icon per area, thinned so the map never crowds: worst first, an
    /// icon is kept only if no icon already kept — of ANY kind — stands
    /// within `minSeparationMeters`. The caller sets the spacing from the
    /// visible map, so zooming in leaves room for more of them. Icons keep
    /// their own places (each is its area's own anchor); equal scores keep
    /// the input order.
    static func declutter<Kind: Hashable>(
        _ items: [Item<Kind>], minSeparationMeters: CLLocationDistance
    ) -> [Item<Kind>] {
        var kinds = Kinds<Kind>()
        let e = kinds.encode(items)
        let kept = e.points.lent { p in
            e.kinds.lent { k in Array(flows_badges_declutter(p, k, minSeparationMeters)) }
        }
        return picked(kept, from: items)
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
        var kinds = Kinds<Kind>()
        let b = kinds.encode(badges)
        let l = kinds.encode(labelled.map(\.item))
        let picks = b.points.lent { bp in
            b.kinds.lent { bk in
                l.points.lent { lp in
                    l.kinds.lent { lk in Array(flows_badges_labels(bp, bk, lp, lk, radiusMeters)) }
                }
            }
        }
        return badges.indices.map { i in
            guard i < picks.count, let j = Int(exactly: picks[i]), labelled.indices.contains(j)
            else { return nil }
            return labelled[j].label
        }
    }

    /// Whether an alert event is a warning (or an emergency) — never a
    /// `minor` badge. Winter storms, high wind, extreme heat and cold and red
    /// flags are zone warnings with no outline on the map: the route's badge
    /// is their only symbol, and giving way to a nearby badge of another
    /// kind took them off the map. Watches, advisories and statements can
    /// give way.
    static func isWarning(_ event: String) -> Bool {
        flows_badges_is_warning(event)
    }

    /// Whether a shown badge of the same kind draws the same hazard as a
    /// route badge (`unshown`'s `sameHazard`), from the alert each names. A
    /// warning is the same hazard only as a badge naming that warning; any
    /// other badge is one hazard with its kind.
    static func sameHazard(badgeEvent: String?, shownEvent: String?) -> Bool {
        flows_badges_same_hazard(badgeEvent != nil, badgeEvent ?? "", shownEvent != nil, shownEvent ?? "")
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
    ///
    /// `sameHazard` is asked only about shown badges of the badge's kind
    /// within `mergeMeters` (Rust names those pairs first), and `minor`
    /// once per badge; both must be pure.
    static func unshown<Kind: Hashable>(
        _ badges: [Item<Kind>], shown: [Item<Kind>], areas: [[CLLocationCoordinate2D]],
        mergeMeters: CLLocationDistance, minor: (Item<Kind>) -> Bool,
        sameHazard: (_ badge: Item<Kind>, _ shown: Item<Kind>) -> Bool = { _, _ in true }
    ) -> [Item<Kind>] {
        var kinds = Kinds<Kind>()
        let b = kinds.encode(badges)
        let s = kinds.encode(shown)
        let pairs = b.points.lent { bp in
            b.kinds.lent { bk in
                s.points.lent { sp in
                    s.kinds.lent { sk in Array(flows_badges_near_pairs(bp, bk, sp, sk, mergeMeters)) }
                }
            }
        }
        var same: [Int64] = []
        for j in stride(from: 0, to: pairs.count / 2 * 2, by: 2) {
            guard let bi = Int(exactly: pairs[j]), let si = Int(exactly: pairs[j + 1]),
                badges.indices.contains(bi), shown.indices.contains(si)
            else { continue }
            if sameHazard(badges[bi], shown[si]) {
                same.append(pairs[j])
                same.append(pairs[j + 1])
            }
        }
        let minors: [UInt8] = badges.map { minor($0) ? 1 : 0 }
        var lens: [Int64] = []
        var ringPoints: [Double] = []
        for ring in areas {
            lens.append(Int64(ring.count))
            for c in ring {
                ringPoints.append(c.latitude)
                ringPoints.append(c.longitude)
            }
        }
        let kept = b.points.lent { bp in
            b.kinds.lent { bk in
                s.points.lent { sp in
                    s.kinds.lent { sk in
                        lens.lent { rl in
                            ringPoints.lent { rp in
                                minors.lent { mi in
                                    same.lent { sa in
                                        Array(flows_badges_unshown(bp, bk, sp, sk, rl, rp, mergeMeters, mi, sa))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return picked(kept, from: badges)
    }

    /// The items Rust picked, by index, in its order.
    private static func picked<Kind: Hashable>(_ indices: [Int64], from items: [Item<Kind>]) -> [Item<Kind>] {
        indices.compactMap { i in
            guard let j = Int(exactly: i), items.indices.contains(j) else { return nil }
            return items[j]
        }
    }

    /// One call's kind numbers: the first kind seen is 0, and equal kinds
    /// share a number, so Rust's `==` on them is the kinds' own.
    private struct Kinds<K: Hashable> {
        private var ids: [K: Int64] = [:]

        mutating func encode(_ items: [Item<K>]) -> (points: [Double], kinds: [Int64]) {
            var points: [Double] = []
            var kinds: [Int64] = []
            points.reserveCapacity(items.count * 3)
            kinds.reserveCapacity(items.count)
            for item in items {
                points.append(item.coordinate.latitude)
                points.append(item.coordinate.longitude)
                points.append(item.score)
                kinds.append(id(item.kind))
            }
            return (points, kinds)
        }

        private mutating func id(_ kind: K) -> Int64 {
            if let id = ids[kind] { return id }
            let id = Int64(ids.count)
            ids[kind] = id
            return id
        }
    }
}
