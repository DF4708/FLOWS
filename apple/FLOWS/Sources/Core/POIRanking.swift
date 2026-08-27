// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// Pure route-aware POI ranking — no UI, no MapKit search types, fully
/// unit-testable (FLOWSTests).
///
/// The contract from the driver's seat:
///   * a stop must be AHEAD along the route — never send the vehicle
///     backwards from its destination;
///   * it must not deviate significantly from the corridor (hard detour cap);
///   * food is ranked "soonest reachable": along-route distance plus a
///     penalty for off-route detour;
///   * fuel is ranked by TOTAL COST: fill cost at the station's price plus
///     the driver's detour time valued in dollars — significantly cheaper
///     fuel therefore earns a longer justified detour, exactly as asked.
enum POIRanking {

    /// The active route's geometry, flattened once per leg.
    struct RoutePath {
        let coords: [CLLocationCoordinate2D]
        let cumulative: [CLLocationDistance]   // meters from origin to coords[i]

        // Uniform lat/lon grid over the route vertices so `nearest` is ~O(1)
        // instead of O(V): a POI search projects every POI onto the route, and a
        // linear scan of ≤1500 vertices per POI was the search's dominant cost.
        private struct Cell: Hashable { let x: Int; let y: Int }
        private static let cellDeg = 0.1        // ~11 km lat; still small vs routes
        private let grid: [Cell: [Int]]

        private static func cell(_ c: CLLocationCoordinate2D) -> Cell {
            Cell(x: Int((c.longitude / cellDeg).rounded(.down)),
                 y: Int((c.latitude / cellDeg).rounded(.down)))
        }

        init(coords: [CLLocationCoordinate2D]) {
            self.coords = coords
            var running: CLLocationDistance = 0
            var cum: [CLLocationDistance] = []
            cum.reserveCapacity(coords.count)
            var prev: CLLocationCoordinate2D?
            var g: [Cell: [Int]] = [:]
            for (i, c) in coords.enumerated() {
                if let p = prev { running += POIRanking.meters(p, c) }
                cum.append(running)
                g[Self.cell(c), default: []].append(i)
                prev = c
            }
            self.cumulative = cum
            self.grid = g
        }

        /// Nearest route vertex to a coordinate → (index, off-route meters).
        /// Expanding-ring grid search: scan the query's cell, then each
        /// surrounding ring, stopping once no unscanned ring could hold a closer
        /// point. Identical result to the full O(V) scan — same min distance and,
        /// on an exact tie, the same lowest index — but ~O(1) on the dense route.
        func nearest(to coord: CLLocationCoordinate2D) -> (index: Int, offRoute: CLLocationDistance)? {
            guard !coords.isEmpty else { return nil }
            let c0 = Self.cell(coord)
            // Conservative min meters spanned by one cell (longitude is the
            // narrower axis; clamp cos so a high-latitude bound stays valid).
            let cellMinMeters = Self.cellDeg * 111_320
                * max(cos(coord.latitude * .pi / 180), 0.1)
            var bestIdx = -1
            var bestD = CLLocationDistance.greatestFiniteMagnitude
            // Lowest index wins on an exact tie — matches the old strict-less scan.
            func consider(_ cx: Int, _ cy: Int) {
                guard let idxs = grid[Cell(x: cx, y: cy)] else { return }
                for i in idxs {
                    let d = POIRanking.meters(coords[i], coord)
                    if d < bestD || (d == bestD && (bestIdx < 0 || i < bestIdx)) {
                        bestD = d
                        bestIdx = i
                    }
                }
            }
            // Scan expanding rings, visiting only each ring's BORDER cells (O(r),
            // not the whole O(r²) square). A near query (a POI along the corridor)
            // resolves in the first ring or two. If the query is far enough that
            // we'd expand past `maxRings`, a full linear scan is both correct and
            // cheaper than more rings — and such a point is beyond any usable
            // detour anyway, so the caller discards it.
            let maxRings = 16
            var r = 0
            while r <= maxRings {
                if r == 0 {
                    consider(c0.x, c0.y)
                } else {
                    for dx in -r...r {                       // top & bottom rows
                        consider(c0.x + dx, c0.y - r)
                        consider(c0.x + dx, c0.y + r)
                    }
                    for dy in (-r + 1)...(r - 1) {            // left & right columns
                        consider(c0.x - r, c0.y + dy)
                        consider(c0.x + r, c0.y + dy)
                    }
                }
                // The next ring (r+1) is ≥ r·cellMinMeters away; once that exceeds
                // the best found, no unscanned cell can hold a closer point.
                if bestIdx >= 0 && Double(r) * cellMinMeters > bestD {
                    return (bestIdx, bestD)
                }
                r += 1
            }
            // Far from the route: full scan (correct, and O(V) beats more rings).
            bestIdx = -1
            bestD = CLLocationDistance.greatestFiniteMagnitude
            for (i, c) in coords.enumerated() {
                let d = POIRanking.meters(c, coord)
                if d < bestD || (d == bestD && (bestIdx < 0 || i < bestIdx)) {
                    bestD = d
                    bestIdx = i
                }
            }
            return bestIdx >= 0 ? (bestIdx, bestD) : nil
        }
    }

    struct Candidate<Item> {
        let item: Item
        let coordinate: CLLocationCoordinate2D
        /// Meters ahead of the vehicle along the route (negative = behind).
        let aheadMeters: CLLocationDistance
        /// Straight-line meters off the corridor.
        let detourMeters: CLLocationDistance
        /// Unit price when a price source is available (fuel $/unit, hotels
        /// $/night; nil otherwise).
        let pricePerUnit: Double?
        /// Public review rating 0…5 when a source is available (hotels).
        var rating: Double? = nil
    }

    /// Tolerated backtrack (GPS jitter / stations at the previous exit) and
    /// the hard "don't deviate significantly" cap.
    static let backtrackToleranceMeters: CLLocationDistance = 500
    static let maxDetourMeters: CLLocationDistance = 12_000

    /// Assumed detour driving speed for time costing (surface roads).
    static let detourSpeedMps = 13.4          // ≈ 30 mph
    /// What an hour of the driver's time is worth in the fuel cost model.
    static let dollarsPerHour = 30.0

    /// Annotate an item with route metrics; nil when the route can't place it.
    static func annotate<Item>(
        item: Item, at coord: CLLocationCoordinate2D,
        route: RoutePath, vehicleAlong: CLLocationDistance,
        pricePerUnit: Double? = nil, rating: Double? = nil
    ) -> Candidate<Item>? {
        guard let hit = route.nearest(to: coord) else { return nil }
        return Candidate(
            item: item,
            coordinate: coord,
            aheadMeters: route.cumulative[hit.index] - vehicleAlong,
            detourMeters: hit.offRoute,
            pricePerUnit: pricePerUnit,
            rating: rating)
    }

    /// Direction-of-travel filter shared by every kind: ahead of the vehicle
    /// (within jitter tolerance) and within the corridor deviation cap
    /// (long-haul trucker mode widens the cap — savings justify range).
    static func admissible<Item>(_ c: Candidate<Item>, maxDetour: CLLocationDistance) -> Bool {
        c.aheadMeters > -backtrackToleranceMeters && c.detourMeters <= maxDetour
    }

    /// Food (and general POI) ordering: soonest reachable along the route —
    /// along-route distance plus a 3x penalty on off-corridor detour (a stop
    /// 2 km off the exit "costs" like 6 km of highway).
    static func rankFood<Item>(
        _ candidates: [Candidate<Item>],
        maxDetour: CLLocationDistance = maxDetourMeters
    ) -> [Candidate<Item>] {
        candidates.filter { admissible($0, maxDetour: maxDetour) }.sorted {
            ($0.aheadMeters + 3 * $0.detourMeters) < ($1.aheadMeters + 3 * $1.detourMeters)
        }
    }

    /// Fuel ordering: minimize fill cost + detour time cost. Stations with no
    /// known price rank by detour time only, after any priced station whose
    /// total beats them (nil price treated as the fleet-average fill so the
    /// two groups stay comparable).
    static func rankFuel<Item>(
        _ candidates: [Candidate<Item>], fillUnits: Double, averagePricePerUnit: Double,
        maxDetour: CLLocationDistance = maxDetourMeters
    ) -> [Candidate<Item>] {
        func totalCost(_ c: Candidate<Item>) -> Double {
            let fill = (c.pricePerUnit ?? averagePricePerUnit) * fillUnits
            // Detour there and back, valued at the driver's hourly rate.
            let detourHours = (2 * c.detourMeters / detourSpeedMps) / 3600
            return fill + detourHours * dollarsPerHour
        }
        return candidates.filter { admissible($0, maxDetour: maxDetour) }
            .sorted { totalCost($0) < totalCost($1) }
    }

    /// Hotels: balance PUBLIC REVIEW quality against COST, still respecting
    /// the corridor. Value = rating (weight 2, neutral 3.5★ when unknown)
    /// minus price relative to the average nightly rate (neutral when
    /// unknown) minus detour time — so with no licensed rating/price feed the
    /// ordering gracefully degrades to closest-to-corridor.
    static let averageNightlyPrice = 120.0

    static func rankHotels<Item>(
        _ candidates: [Candidate<Item>],
        averageNightly: Double = averageNightlyPrice,
        maxDetour: CLLocationDistance = maxDetourMeters
    ) -> [Candidate<Item>] {
        func value(_ c: Candidate<Item>) -> Double {
            let rating = (c.rating ?? 3.5) / 5
            let price = (c.pricePerUnit ?? averageNightly) / max(averageNightly, 1)
            let detourHours = (2 * c.detourMeters / detourSpeedMps) / 3600
            return rating * 2 - price - detourHours * 1.5
        }
        return candidates.filter { admissible($0, maxDetour: maxDetour) }
            .sorted { value($0) > value($1) }
    }

    /// Parking: FREE AND CLOSE beats EXPENSIVE AND FAR. With no live rate
    /// feed, cost tier comes from the name (free lots / street / park & ride
    /// = 0; garages / ramps / valet = 2; unknown = 1), then detour breaks
    /// ties inside a tier via a strong weight.
    static func parkingCostTier(name: String?) -> Int {
        let lower = (name ?? "").lowercased()
        if lower.contains("free") || lower.contains("park & ride")
            || lower.contains("park and ride") || lower.contains("street parking") {
            return 0
        }
        if lower.contains("garage") || lower.contains("ramp") || lower.contains("valet")
            || lower.contains("premium") || lower.contains("airport") {
            return 2
        }
        return 1
    }

    static func rankParking<Item>(
        _ candidates: [Candidate<Item>], costTier: (Item) -> Int,
        maxDetour: CLLocationDistance = maxDetourMeters
    ) -> [Candidate<Item>] {
        func score(_ c: Candidate<Item>) -> Double {
            // A cost tier is worth ~4 km of detour; hourly $ when a live
            // feed lands can replace the tier directly (pricePerUnit).
            let cost = c.pricePerUnit ?? Double(costTier(c.item)) * 4.0
            return cost + (c.aheadMeters + 3 * c.detourMeters) / 1000
        }
        return candidates.filter { admissible($0, maxDetour: maxDetour) }
            .sorted { score($0) < score($1) }
    }

    /// THE app-wide short-range distance primitive (BadgeClustering and the
    /// POI rankers share it). Equirectangular approximation — pure math, no
    /// CLLocation allocations (review finding: nearest() allocated two
    /// CLLocations per vertex × per item on the main thread). Error is <0.1%
    /// at the corridor scales callers use it for (compare + accumulate short
    /// hops), matching RiskFieldService's grid math.
    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let metersPerDegree = 111_320.0
        let dLat = (b.latitude - a.latitude) * metersPerDegree
        let dLon = (b.longitude - a.longitude) * metersPerDegree
            * cos((a.latitude + b.latitude) * .pi / 360)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }
}

/// Fuel sub-categories. The chosen type is remembered (UserDefaults via
/// POIService) so the driver is not re-prompted; changeable in Settings.
enum FuelType: String, CaseIterable, Identifiable, Codable {
    case gas = "Gas"
    case diesel = "Diesel"
    case electric = "Electric"

    var id: String { rawValue }

    var searchQuery: String {
        switch self {
        case .gas: return "gas station"
        case .diesel: return "diesel truck stop"
        case .electric: return "EV charging station"
        }
    }

    /// Typical fill for the cost model (gal / gal / kWh).
    var fillUnits: Double {
        switch self {
        case .gas: return 15
        case .diesel: return 25
        case .electric: return 60
        }
    }

    /// Fleet-average unit price used ONLY to keep unpriced stations
    /// comparable in the cost model — station-level prices need a licensed
    /// feed (GasBuddy/OPIS) wired into POIService.priceProvider.
    var averagePricePerUnit: Double {
        switch self {
        case .gas: return 3.20
        case .diesel: return 3.90
        case .electric: return 0.36
        }
    }

    var symbol: String {
        switch self {
        case .gas: return "fuelpump.fill"
        case .diesel: return "truck.box.fill"
        case .electric: return "bolt.car.fill"
        }
    }
}

/// Food cuisine categories offered when the driver taps Food.
enum FoodCategory: String, CaseIterable, Identifiable {
    case fastFood = "Fast food"
    case pizza = "Pizza"
    case american = "American"
    case mexican = "Mexican"
    case italian = "Italian"
    case chinese = "Chinese"
    case greek = "Greek"
    case coffee = "Coffee"
    case breakfast = "Breakfast"

    var id: String { rawValue }

    var searchQuery: String {
        switch self {
        case .fastFood: return "fast food drive through"
        case .coffee: return "coffee shop"
        case .breakfast: return "breakfast diner"
        default: return "\(rawValue.lowercased()) restaurant"
        }
    }
}

/// Store categories offered when the driver taps Stores — same picker flow as
/// Food. "General" covers the everything-stores (Walmart sells every category).
enum StoreCategory: String, CaseIterable, Identifiable {
    case grocery = "Grocery"
    case general = "General"
    case hardware = "Hardware"
    case electronics = "Electronics"
    case pets = "Pets"
    case gun = "Gun"
    case auto = "Auto parts"
    case clothing = "Clothing"

    var id: String { rawValue }

    /// SEPARATE queries, one per term — not one string of brand names.
    /// MKLocalSearch matches a query as a PHRASE, so "grocery supermarket
    /// Publix Kroger Safeway Aldi" matched no business at all: nothing is
    /// called that. Issuing the generic word and each chain as their own
    /// searches is what actually finds them ("no stores found" on routes
    /// lined with stores).
    var searchQueries: [String] {
        switch self {
        case .grocery:
            return ["grocery store", "supermarket", "Publix", "Kroger",
                    "Safeway", "Aldi", "Trader Joe's", "Whole Foods"]
        case .general:
            return ["Walmart", "Target", "Costco", "department store",
                    "Sam's Club", "dollar store"]
        case .hardware:
            return ["hardware store", "Home Depot", "Lowe's", "Ace Hardware",
                    "Menards", "Tractor Supply"]
        case .electronics:
            return ["electronics store", "Best Buy", "Apple Store"]
        case .pets:
            return ["pet store", "PetSmart", "Petco", "pet supplies"]
        case .gun:
            return ["gun shop", "firearms dealer", "sporting goods",
                    "Bass Pro Shops", "Cabela's"]
        case .auto:
            return ["auto parts store", "AutoZone", "O'Reilly Auto Parts",
                    "Advance Auto Parts", "NAPA Auto Parts"]
        case .clothing:
            return ["clothing store", "TJ Maxx", "Ross", "Kohl's", "Old Navy"]
        }
    }

    /// The single-string form, for callers that want one label.
    var searchQuery: String { searchQueries.first ?? rawValue }

    var symbol: String {
        switch self {
        case .grocery: return "cart.fill"
        case .general: return "bag.fill"
        case .hardware: return "hammer.fill"
        case .electronics: return "tv.fill"
        case .pets: return "pawprint.fill"
        case .gun: return "scope"
        case .auto: return "wrench.and.screwdriver.fill"
        case .clothing: return "tshirt.fill"
        }
    }
}

extension POIRanking {
    /// National-brand market-share order (rough US retail revenue rank; lower =
    /// bigger). The tie-break when Yelp ratings are unavailable — Walmart
    /// outranks Target, Home Depot outranks Ace, and unknown local names sort
    /// after every recognized national brand (then by corridor position).
    static let storeMarketShareOrder: [String] = [
        "walmart", "amazon fresh", "costco", "kroger", "home depot", "target",
        "lowe's", "lowes", "albertsons", "safeway", "publix", "aldi", "sam's club",
        "best buy", "meijer", "heb", "h-e-b", "dollar general", "dollar tree",
        "walgreens", "cvs", "whole foods", "trader joe", "menards", "ace hardware",
        "tractor supply", "petsmart", "petco", "autozone", "o'reilly", "oreilly",
        "advance auto", "napa", "bass pro", "cabela", "academy sports",
        "sportsman's warehouse", "scheels", "big 5", "tj maxx", "ross", "kohl's",
        "macy's", "nordstrom", "burlington", "marshalls",
    ]

    /// Index into the market-share table for a store name (case-insensitive
    /// substring), or count (= after every known brand) when unrecognized.
    static func storeMarketShareRank(name: String?) -> Int {
        guard let lower = name?.lowercased(), !lower.isEmpty
        else { return storeMarketShareOrder.count }
        return storeMarketShareOrder.firstIndex(where: { lower.contains($0) })
            ?? storeMarketShareOrder.count
    }

    /// Stores ordering: highest Yelp rating first; stores WITHOUT a rating
    /// follow, ordered by national market share (Walmart before Target), then
    /// by corridor position. Corridor admissibility still applies — a
    /// top-rated store 40 mi off-route is not a stop.
    static func rankStores<Item>(
        _ candidates: [Candidate<Item>], name: (Item) -> String?,
        maxDetour: CLLocationDistance = maxDetourMeters
    ) -> [Candidate<Item>] {
        candidates.filter { admissible($0, maxDetour: maxDetour) }.sorted { a, b in
            switch (a.rating, b.rating) {
            case let (ra?, rb?):
                if ra != rb { return ra > rb }
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none):
                let (ma, mb) = (storeMarketShareRank(name: name(a.item)),
                                storeMarketShareRank(name: name(b.item)))
                if ma != mb { return ma < mb }
            }
            return (a.aheadMeters + 3 * a.detourMeters)
                < (b.aheadMeters + 3 * b.detourMeters)
        }
    }
}
