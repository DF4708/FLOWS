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
///
/// The ranking itself — the route's nearest-vertex grid, the metrics, the
/// corridor filter, every kind's ordering and the name tables — lives in
/// rust/flows-core (places.rs) behind rust/flows-bridge; this enum keeps the
/// generic candidate type its callers rank and the short-range distance
/// primitive. Pinned to the original by
/// rust/flows-bridge/tests/fixtures/swift_places_oracle.tsv.
enum POIRanking {

    /// The active route's geometry, flattened once per leg. The meters along
    /// it and the nearest-vertex search (a 0.1° grid scanned ring by ring,
    /// then a full scan past sixteen rings) are the Rust route behind
    /// `handle`; this struct keeps the vertices and their cumulative meters
    /// for its readers. Nothing mutates the handle after init, which is what
    /// makes the value safe to hand to the ranking task off the main actor.
    struct RoutePath: @unchecked Sendable {
        let coords: [CLLocationCoordinate2D]
        let cumulative: [CLLocationDistance]   // meters from origin to coords[i]
        let handle: FlowsRoutePath

        init(coords: [CLLocationCoordinate2D]) {
            self.coords = coords
            guard !coords.isEmpty else {
                handle = flows_places_route_path_empty()
                cumulative = []
                return
            }
            let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
            handle = lats.withUnsafeBufferPointer { la in
                lons.withUnsafeBufferPointer { lo in flows_places_route_path(la, lo) }
            }
            cumulative = Array(handle.cumulative())
        }

        /// Nearest route vertex to a coordinate → (index, off-route meters).
        /// Identical to a full scan — same minimum distance and, on an exact
        /// tie, the same lowest index — but about O(1) on a dense route.
        func nearest(to coord: CLLocationCoordinate2D) -> (index: Int, offRoute: CLLocationDistance)? {
            let hit = handle.nearest(coord.latitude, coord.longitude)
            return hit.has ? (Int(hit.index), hit.off_route) : nil
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
    static let backtrackToleranceMeters: CLLocationDistance = flows_places_limits().backtrack_tolerance_meters
    static let maxDetourMeters: CLLocationDistance = flows_places_limits().max_detour_meters

    /// Assumed detour driving speed for time costing (surface roads, ≈ 30 mph).
    static let detourSpeedMps = flows_places_limits().detour_speed_mps
    /// What an hour of the driver's time is worth in the fuel cost model.
    static let dollarsPerHour = flows_places_limits().dollars_per_hour

    /// Annotate an item with route metrics; nil when the route can't place it.
    static func annotate<Item>(
        item: Item, at coord: CLLocationCoordinate2D,
        route: RoutePath, vehicleAlong: CLLocationDistance,
        pricePerUnit: Double? = nil, rating: Double? = nil
    ) -> Candidate<Item>? {
        let metrics = route.handle.annotate(coord.latitude, coord.longitude, vehicleAlong)
        guard metrics.count == 2 else { return nil }
        return Candidate(
            item: item,
            coordinate: coord,
            aheadMeters: metrics[0],
            detourMeters: metrics[1],
            pricePerUnit: pricePerUnit,
            rating: rating)
    }

    /// Direction-of-travel filter shared by every kind: ahead of the vehicle
    /// (within jitter tolerance) and within the corridor deviation cap
    /// (long-haul trucker mode widens the cap — savings justify range).
    static func admissible<Item>(_ c: Candidate<Item>, maxDetour: CLLocationDistance) -> Bool {
        flows_places_admissible(c.aheadMeters, c.detourMeters, maxDetour)
    }

    /// A Rust ranker over the candidate columns: ahead, detour, prices and
    /// their presence, ratings and their presence.
    private typealias Ranker = (UnsafeBufferPointer<Double>, UnsafeBufferPointer<Double>,
                                UnsafeBufferPointer<Double>, UnsafeBufferPointer<UInt8>,
                                UnsafeBufferPointer<Double>, UnsafeBufferPointer<UInt8>) -> RustVec<Int64>

    /// The candidates in a Rust ranker's order: it keeps the admissible ones
    /// and sorts them with Swift's own sort on the kind's comparator. The
    /// candidates cross as parallel columns, an optional as a value and a
    /// presence flag; an empty list is answered here, because swift-bridge
    /// must never see an empty buffer.
    private static func ordered<Item>(_ candidates: [Candidate<Item>], by ranker: Ranker) -> [Candidate<Item>] {
        guard !candidates.isEmpty else { return [] }
        let ahead = candidates.map(\.aheadMeters), detour = candidates.map(\.detourMeters)
        let prices = candidates.map { $0.pricePerUnit ?? 0 }
        let hasPrice = candidates.map { UInt8($0.pricePerUnit == nil ? 0 : 1) }
        let ratings = candidates.map { $0.rating ?? 0 }
        let hasRating = candidates.map { UInt8($0.rating == nil ? 0 : 1) }
        let order = ahead.withUnsafeBufferPointer { a in
            detour.withUnsafeBufferPointer { d in
                prices.withUnsafeBufferPointer { p in
                    hasPrice.withUnsafeBufferPointer { hp in
                        ratings.withUnsafeBufferPointer { r in
                            hasRating.withUnsafeBufferPointer { hr in ranker(a, d, p, hp, r, hr) }
                        }
                    }
                }
            }
        }
        return order.map { candidates[Int($0)] }
    }

    /// Food (and general POI) ordering: soonest reachable along the route —
    /// along-route distance plus a 3x penalty on off-corridor detour (a stop
    /// 2 km off the exit "costs" like 6 km of highway).
    static func rankFood<Item>(
        _ candidates: [Candidate<Item>],
        maxDetour: CLLocationDistance = maxDetourMeters
    ) -> [Candidate<Item>] {
        ordered(candidates) { flows_places_rank_food($0, $1, $2, $3, $4, $5, maxDetour) }
    }

    /// Fuel ordering: minimize fill cost + detour time cost (there and back,
    /// valued at the driver's hourly rate). Stations with no known price fill
    /// at the fleet average, so the two groups stay comparable.
    static func rankFuel<Item>(
        _ candidates: [Candidate<Item>], fillUnits: Double, averagePricePerUnit: Double,
        maxDetour: CLLocationDistance = maxDetourMeters
    ) -> [Candidate<Item>] {
        ordered(candidates) {
            flows_places_rank_fuel($0, $1, $2, $3, $4, $5, fillUnits, averagePricePerUnit, maxDetour)
        }
    }

    /// Hotels: balance PUBLIC REVIEW quality against COST, still respecting
    /// the corridor. Value = rating (weight 2, neutral 3.5★ when unknown)
    /// minus price relative to the average nightly rate (neutral when
    /// unknown) minus detour time — so with no licensed rating/price feed the
    /// ordering gracefully degrades to closest-to-corridor.
    static let averageNightlyPrice = flows_places_limits().average_nightly_price

    static func rankHotels<Item>(
        _ candidates: [Candidate<Item>],
        averageNightly: Double = averageNightlyPrice,
        maxDetour: CLLocationDistance = maxDetourMeters
    ) -> [Candidate<Item>] {
        ordered(candidates) { flows_places_rank_hotels($0, $1, $2, $3, $4, $5, averageNightly, maxDetour) }
    }

    /// Parking: FREE AND CLOSE beats EXPENSIVE AND FAR. With no live rate
    /// feed, cost tier comes from the name (free lots / street / park & ride
    /// = 0; garages / ramps / valet = 2; unknown = 1), then detour breaks
    /// ties inside a tier via a strong weight.
    static func parkingCostTier(name: String?) -> Int {
        Int(flows_places_parking_cost_tier(name ?? "", name != nil))
    }

    /// A cost tier is worth ~4 km of detour; an hourly price from a live feed
    /// replaces the tier directly (pricePerUnit).
    static func rankParking<Item>(
        _ candidates: [Candidate<Item>], costTier: (Item) -> Int,
        maxDetour: CLLocationDistance = maxDetourMeters
    ) -> [Candidate<Item>] {
        let tiers = candidates.map { Int64(costTier($0.item)) }
        guard !tiers.isEmpty else { return [] }
        return tiers.withUnsafeBufferPointer { t in
            ordered(candidates) { flows_places_rank_parking($0, $1, $2, $3, $4, $5, t, maxDetour) }
        }
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
    var fillUnits: Double { flows_places_fuel_fill_units(rustCode) }

    /// Fleet-average unit price used ONLY to keep unpriced stations
    /// comparable in the cost model — station-level prices need a licensed
    /// feed (GasBuddy/OPIS) wired into POIService.priceProvider.
    var averagePricePerUnit: Double { flows_places_fuel_average_price(rustCode) }

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
    /// bigger), lowercase. The tie-break when Yelp ratings are unavailable —
    /// Walmart outranks Target, Home Depot outranks Ace, and unknown local
    /// names sort after every recognized national brand (then by corridor
    /// position). The table is spelled once, in places.rs.
    static let storeMarketShareOrder: [String] = flows_places_store_market_share_order().map { $0.text }

    /// Index into the market-share table for a store name (case-insensitive
    /// substring), or count (= after every known brand) when unrecognized.
    static func storeMarketShareRank(name: String?) -> Int {
        Int(flows_places_store_market_share_rank(name ?? "", name != nil))
    }

    /// Stores ordering: highest Yelp rating first; stores WITHOUT a rating
    /// follow, ordered by national market share (Walmart before Target), then
    /// by corridor position. Corridor admissibility still applies — a
    /// top-rated store 40 mi off-route is not a stop.
    static func rankStores<Item>(
        _ candidates: [Candidate<Item>], name: (Item) -> String?,
        maxDetour: CLLocationDistance = maxDetourMeters
    ) -> [Candidate<Item>] {
        let ranks = candidates.map { Int64(storeMarketShareRank(name: name($0.item))) }
        guard !ranks.isEmpty else { return [] }
        return ranks.withUnsafeBufferPointer { m in
            ordered(candidates) { flows_places_rank_stores($0, $1, $2, $3, $4, $5, m, maxDetour) }
        }
    }

    /// Points by straight-line meters to `center`, nearest first, the first
    /// `limit`, as (index, meters): Swift's own sort, in places.rs
    /// (`rank_by_distance`). A negative limit answers nothing.
    static func byDistance(_ points: [CLLocationCoordinate2D], from center: CLLocationCoordinate2D,
                           limit: Int) -> [(index: Int, meters: CLLocationDistance)] {
        guard !points.isEmpty else { return [] }
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let flat = lats.withUnsafeBufferPointer { la in
            lons.withUnsafeBufferPointer { lo in
                flows_places_rank_by_distance(la, lo, center.latitude, center.longitude, Int64(limit))
            }
        }
        return stride(from: 0, to: flat.count, by: 2).map { (index: Int(flat[$0]), meters: flat[$0 + 1]) }
    }

    /// The first point no later point is strictly nearer to `target` than
    /// (`min(by:)` on straight-line meters, in places.rs); nil for no points.
    static func firstNearest(_ points: [CLLocationCoordinate2D], to target: CLLocationCoordinate2D) -> Int? {
        guard !points.isEmpty else { return nil }
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let i = lats.withUnsafeBufferPointer { la in
            lons.withUnsafeBufferPointer { lo in
                flows_places_first_nearest(la, lo, target.latitude, target.longitude)
            }
        }
        return i < 0 ? nil : Int(i)
    }

    /// Indices of `count` corridor points a sweep searches around: all of
    /// them when they fit in `cap - 1` slots, else spread evenly (places.rs
    /// `center_picks`).
    static func centerPicks(count: Int, cap: Int) -> [Int] {
        guard count > 0 else { return [] }
        return flows_places_center_picks(Int64(count), Int64(cap)).map { Int($0) }
    }
}

/// A list of texts as the Rust side reads one: the texts joined, each text's
/// UTF-8 length, and a presence flag per text (a nil crosses as an empty
/// text flagged absent). Lengths rather than a separator, so a name holding
/// any character splits back exactly. swift-bridge must never see an empty
/// buffer, so an empty list carries one placeholder that its count ignores.
struct RustTextColumn {
    let joined: String
    let lengths: [Int64]
    let present: [UInt8]

    init(_ texts: [String?]) {
        joined = texts.map { $0 ?? "" }.joined()
        let lens = texts.map { Int64($0?.utf8.count ?? 0) }
        let flags = texts.map { UInt8($0 == nil ? 0 : 1) }
        lengths = lens.isEmpty ? [0] : lens
        present = flags.isEmpty ? [0] : flags
    }

    init(_ texts: [String]) { self.init(texts.map { Optional($0) }) }

    func with<R>(_ body: (String, UnsafeBufferPointer<Int64>, UnsafeBufferPointer<UInt8>) -> R) -> R {
        lengths.withUnsafeBufferPointer { l in present.withUnsafeBufferPointer { p in body(joined, l, p) } }
    }
}
