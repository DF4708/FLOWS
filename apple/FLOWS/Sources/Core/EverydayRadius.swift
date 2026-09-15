// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// The learned "everyday radius": FLOWS watches how far the driver's trips
/// actually go (straight-line start→end miles) and, once the sample is
/// statistically meaningful (30+ trips), learns the everyday circle around the
/// home anchor from the 85th percentile of those distances, held between 3
/// and 150 miles. It starts at 20 and moves in EITHER direction with
/// evidence: a city driver's circle shrinks, a regional driver's grows.
///
/// These comments used to say the circle was capped at 20 miles and "only
/// ever SHRINKS", which stopped being true when the quantile replaced
/// `min(20, mean + sd)`. The Settings copy repeated the same stale claim to
/// the driver, promising a 20-mile maximum on a circle that could reach 150
/// — a privacy disclosure people decide on. Both now say what the code does.
///
/// Stops the driver looks up inside that circle (food,
/// fuel, stores, …) are remembered per category and come back INSTANTLY on the
/// next lookup, most-used first, before any network search returns.
///
/// Every lookup is counted against a unique context attribute id (time-of-day
/// bucket, weekday/weekend, ~11 km start cell) so a small on-device pattern
/// net (Core ML/ANE, phase 2 — same plan as SeasonalRiskModel's LearnedHead)
/// can later refine the frequency ranking from those correlations.
///
/// `EverydayStore` is the pure, `Codable`, unit-tested core — it takes explicit
/// times so tests are deterministic. `EverydayPlaces` wraps it with disk
/// persistence and wall-clock helpers (the SeasonalStore/SeasonalRiskModel
/// split). Everything stays on this device: the store writes to Application
/// Support only and is never exported, synced, or committed.
///
/// The radius statistics, the trip gate, the ranking and eviction orders,
/// the hour bucket and the feature vector are computed in rust/flows-core
/// (learning.rs) and called through rust/flows-bridge; the store, its keys
/// and its persistence stay here. Pinned bit for bit to the Swift this
/// replaced by rust/flows-bridge/tests/fixtures/swift_learning_oracle.tsv.

// MARK: - Pure core

/// The categories worth remembering — the everyday habits. Raw values are
/// storage keys; renaming one orphans that category's saved entries.
enum EverydayCategory: String, Codable, CaseIterable {
    case food, fuel, stores, rest, shelter, medical, hotels, gyms
    // Appended 2026-08: repeat-visit stop types that were being discarded.
    // A trucker returns to the same shower and the same overnight parking;
    // a commuter parks in the same garage. Those are habits by any
    // definition, and their taps were silently dropped.
    case parking, showers

    /// STABLE ordinal for the learning feature vector. Deliberately NOT
    /// `allCases.firstIndex` — that renumbers every category the moment a
    /// case is added (and shifts the normalisation denominator too), so
    /// appending `parking`/`showers` would have silently changed what
    /// "fuel" means to anything trained on the old encoding. These numbers
    /// are frozen: give a NEW case the next unused value, never reuse or
    /// renumber.
    var featureIndex: Int {
        // The frozen ordinal is Rust's; a key that is not a category (never
        // one of these cases) would answer -1.
        let index = flows_learning_everyday_feature_index(rawValue)
        return index >= 0 ? Int(index) : 0
    }

    /// Fixed divisor for the normalised feature — frozen alongside
    /// `featureIndex` so the encoding is stable as cases are appended.
    static let featureIndexSpace = Int(flows_learning_everyday_feature_index_space())
}

/// One remembered stop inside the everyday circle. `id` is the stable
/// attribute id (name + ~220 m coordinate cell — the same cell size
/// POIService's dedup uses), so the same real-world place always accumulates
/// into one record, and the same id keys the rows the pattern net trains on.
struct EverydayPlace: Codable, Equatable {
    let id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var street: String
    var city: String
    /// Times the driver actually tapped this stop in a result list.
    var uses = 0
    /// Times a search returned it (cold-start ranking before any taps).
    var seen = 0
    /// Last tap time (epoch seconds) — recency breaks frequency ties.
    var lastUsedT = 0.0
    /// Lookup context attribute id → tap count ("Saturday morning, leaving
    /// from home" as one countable key). The pattern net's training signal.
    var contexts: [String: Int] = [:]

    /// `name|Int(lat·500)|Int(lon·500)`, a name and a ~220 m cell — built in
    /// rust/flows-core places.rs. A coordinate that cannot become an Int
    /// (where this used to trap) writes its cell as `-|-`.
    static func attributeID(name: String, latitude: Double, longitude: Double) -> String {
        flows_places_attribute_id(name, latitude, longitude).text
    }
}

struct EverydayStore: Codable, Equatable {
    /// Learned home anchor — supplied by SeasonalStore.learnedHome() (the
    /// most-frequent trip-origin cell), not guessed independently here.
    struct Anchor: Codable, Equatable { var lat: Double; var lon: Double }

    /// Straight-line start→end miles of completed trips, most recent last
    /// (rolling window so decades of history can't freeze the estimate).
    var tripMiles: [Double] = []
    var home: Anchor?
    /// EverydayCategory.rawValue → remembered stops (string keys: enum-keyed
    /// dictionaries don't encode as JSON objects — same precedent as
    /// SeasonalStore.edges).
    var categories: [String: [EverydayPlace]] = [:]

    // Tunables (documented so phase-2 training can reference them).
    /// The STARTING radius, not a ceiling: 20 miles (40-mile diameter) from
    /// home, used until enough trips have been seen to learn one. Evidence
    /// moves it either way, within floorMiles…hardCapMiles.
    static let defaultMiles = flows_learning_everyday_default_miles()
    /// Sanity rails on the learned quantile — a circle smaller than this is
    /// useless, larger than this stops meaning "everyday".
    static let floorMiles = flows_learning_everyday_floor_miles()
    static let hardCapMiles = flows_learning_everyday_hard_cap_miles()
    /// Trips before the observed quantile is meaningful enough to replace
    /// the default (in EITHER direction).
    static let minTripsForRadius = Int(flows_learning_everyday_min_trips_for_radius())
    static let tripWindow = Int(flows_learning_everyday_trip_window())
    static let maxPlacesPerCategory = Int(flows_learning_everyday_max_places_per_category())

    // MARK: Radius math

    /// Great-circle miles between two points (haversine), computed in Rust.
    static func miles(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        flows_learning_everyday_miles(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    var tripCount: Int { tripMiles.count }

    var meanTripMiles: Double? {
        // No trips is no mean (and an empty buffer never crosses).
        guard !tripMiles.isEmpty else { return nil }
        let r = tripMiles.withUnsafeBufferPointer { flows_learning_everyday_mean_trip_miles($0) }
        return r.is_some == 1 ? r.value : nil
    }

    /// Sample standard deviation (n − 1) of the trip distances.
    var tripMilesSD: Double? {
        guard tripMiles.count >= 2 else { return nil }
        let r = tripMiles.withUnsafeBufferPointer { flows_learning_everyday_trip_miles_sd($0) }
        return r.is_some == 1 ? r.value : nil
    }

    /// The everyday radius in miles: the 20-mile default until the sample is
    /// significant, then mean + SD — still capped at 20.
    /// The learned everyday radius — free to GROW as well as shrink.
    ///
    /// This used to be `min(20, mean + sd)`: capped at the 20-mile default
    /// and, because the default was also the ceiling, able only to shrink.
    /// A rural driver whose genuine everyday range is 45 miles therefore got
    /// NO instant results, permanently, by construction — and experienced it
    /// as "the app doesn't remember my places" rather than as a capped
    /// radius. It is now an observed QUANTILE (p85 of recent trip lengths),
    /// which adapts in both directions: a city driver's circle tightens, a
    /// rural one's widens to match how far they actually go. The remaining
    /// bounds are sanity rails, not policy — the cache is really bounded by
    /// `maxPlacesPerCategory`.
    var radiusMiles: Double {
        // No trips is the default (and an empty buffer never crosses).
        guard !tripMiles.isEmpty else { return Self.defaultMiles }
        return tripMiles.withUnsafeBufferPointer { flows_learning_everyday_radius_miles($0) }
    }

    /// Inclusive-rank quantile over the trip-length window. Pure, tested.
    static func quantile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let r = values.withUnsafeBufferPointer { flows_learning_everyday_quantile($0, q) }
        return r.is_some == 1 ? r.value : nil
    }

    mutating func recordTrip(miles: Double) {
        guard flows_learning_everyday_accepts_trip(miles) else { return }
        tripMiles.append(miles)
        if tripMiles.count > Self.tripWindow {
            tripMiles.removeFirst(tripMiles.count - Self.tripWindow)
        }
    }

    mutating func setHome(lat: Double, lon: Double) {
        home = Anchor(lat: lat, lon: lon)
    }

    /// Inside the learned circle around home? False until home is learned —
    /// with no anchor there is nothing to cache around.
    func isInsideEverydayRadius(lat: Double, lon: Double) -> Bool {
        guard let home else { return false }
        return Self.miles(from: CLLocationCoordinate2D(latitude: home.lat, longitude: home.lon),
                          to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            <= radiusMiles
    }

    // MARK: Cache

    /// Remember a search result — admitted only inside the everyday circle.
    /// Repeat sightings of the same place (same attribute id) accumulate into
    /// one record. Returns whether the place is (now) cached.
    @discardableResult
    mutating func remember(name: String, lat: Double, lon: Double,
                           street: String, city: String,
                           in category: EverydayCategory) -> Bool {
        guard isInsideEverydayRadius(lat: lat, lon: lon) else { return false }
        let id = EverydayPlace.attributeID(name: name, latitude: lat, longitude: lon)
        var places = categories[category.rawValue] ?? []
        if let i = places.firstIndex(where: { $0.id == id }) {
            places[i].seen += 1
            // A tap arrives without address parts — never blank a stored one.
            if !street.isEmpty { places[i].street = street }
            if !city.isEmpty { places[i].city = city }
        } else {
            places.append(EverydayPlace(id: id, name: name, latitude: lat, longitude: lon,
                                        street: street, city: city, seen: 1))
            // Bounded store: evict the least-used (then least-seen, then
            // stalest) entry so one category can't grow without limit.
            if places.count > Self.maxPlacesPerCategory {
                let uses = places.map { Int64($0.uses) }, seen = places.map { Int64($0.seen) }
                let last = places.map(\.lastUsedT)
                let evict = uses.withUnsafeBufferPointer { u in
                    seen.withUnsafeBufferPointer { s in
                        last.withUnsafeBufferPointer { l in flows_learning_everyday_evict_index(u, s, l) }
                    }
                }
                if evict >= 0, Int(evict) < places.count { places.remove(at: Int(evict)) }
            }
        }
        categories[category.rawValue] = places
        return categories[category.rawValue]?.contains { $0.id == id } ?? false
    }

    /// Count a real lookup (the driver tapped the row) with its context.
    mutating func recordUse(id: String, in category: EverydayCategory,
                            contextID: String, t: Double) {
        guard var places = categories[category.rawValue],
              let i = places.firstIndex(where: { $0.id == id }) else { return }
        places[i].uses += 1
        places[i].lastUsedT = max(places[i].lastUsedT, t)
        places[i].contexts[contextID, default: 0] += 1
        categories[category.rawValue] = places
    }

    /// Cached entries for a category, most-used first (then most-seen, then
    /// most recent, then name so the order is deterministic).
    func ranked(in category: EverydayCategory) -> [EverydayPlace] {
        let places = categories[category.rawValue] ?? []
        // Nothing to rank (and an empty buffer never crosses).
        guard !places.isEmpty else { return [] }
        let uses = places.map { Int64($0.uses) }, seen = places.map { Int64($0.seen) }
        let last = places.map(\.lastUsedT)
        // Names cross in Unicode NFC, joined by U+001F (which no place name
        // holds; one that did is written as a space), so the byte order Rust
        // sorts by is the order Swift's `<` gives NFC text.
        let names = places.map {
            $0.name.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\u{1F}", with: " ")
        }.joined(separator: "\u{1F}")
        let order = uses.withUnsafeBufferPointer { u in
            seen.withUnsafeBufferPointer { s in
                last.withUnsafeBufferPointer { l in flows_learning_everyday_ranked_order(u, s, l, names) }
            }
        }
        guard order.len() == places.count else { return places }
        return order.compactMap { i in Int(exactly: i).flatMap { $0 < places.count ? places[$0] : nil } }
    }

    // MARK: Context attribute ids

    /// Time-of-day bucket: six 4-hour bins (0 = night 12–4 am … 5 = 8 pm–12).
    static func hourBucket(_ hour: Int) -> Int {
        Int(flows_learning_everyday_hour_bucket(Int64(hour)))
    }

    /// Unique attribute id for a lookup context: time-of-day bucket,
    /// weekday/weekend, and the ~11 km start cell (same 0.1° quantization as
    /// RouteKey). "h2|we|c433,-894" = weekend morning leaving the home cell.
    static func contextID(hourBucket: Int, weekend: Bool,
                          startLat: Double, startLon: Double) -> String {
        "h\(hourBucket)|\(weekend ? "we" : "wd")"
            + "|c\(Int((startLat * 10).rounded())),\(Int((startLon * 10).rounded()))"
    }

    /// Decode a context id back to its parts — the training-row export reads
    /// the stored keys, so the id format and this parser move together.
    static func parseContext(_ id: String)
        -> (hourBucket: Int, weekend: Bool, startLat: Double, startLon: Double)? {
        let parts = id.split(separator: "|")
        guard parts.count == 3, parts[0].hasPrefix("h"), parts[2].hasPrefix("c"),
              let bucket = Int(parts[0].dropFirst()) else { return nil }
        let cell = parts[2].dropFirst().split(separator: ",")
        guard cell.count == 2, let lat = Double(cell[0]), let lon = Double(cell[1])
        else { return nil }
        return (bucket, parts[1] == "we", lat / 10, lon / 10)
    }

    /// Flat, worker-friendly training rows: one per (place, context) — the
    /// substrate the phase-2 pattern net trains on (mirrors
    /// SeasonalStore.trainingRows so the on-disk format can evolve freely).
    func trainingRows() -> [[String: Double]] {
        var rows: [[String: Double]] = []
        for (raw, places) in categories {
            guard let category = EverydayCategory(rawValue: raw) else { continue }
            let catIndex = category.featureIndex   // frozen; see featureIndex
            for place in places {
                for (ctx, count) in place.contexts {
                    guard let c = Self.parseContext(ctx) else { continue }
                    rows.append([
                        "hourBucket": Double(c.hourBucket),
                        "weekend": c.weekend ? 1 : 0,
                        "startLat": c.startLat, "startLon": c.startLon,
                        "placeLat": place.latitude, "placeLon": place.longitude,
                        "category": Double(catIndex),
                        "uses": Double(count),
                    ])
                }
            }
        }
        return rows
    }
}

/// The lookup-context feature vector — pre-normalized to ~[-1, 1], IDENTICAL
/// order everywhere (change it ⇒ retrain), mirroring RouteFeatures for the
/// route head. The future pattern net maps (context, place) → use likelihood
/// to refine the frequency ranking.
enum EverydayFeatures {
    static func vector(hourBucket: Int, weekend: Bool,
                       startLat: Double, startLon: Double,
                       placeLat: Double, placeLon: Double,
                       category: EverydayCategory) -> [Double] {
        Array(flows_learning_everyday_features(Int64(hourBucket), weekend, startLat, startLon,
                                               placeLat, placeLon, Int64(category.featureIndex)))
    }
    static let count = Int(flows_learning_everyday_feature_count())
}

// MARK: - Persisted wrapper

/// Disk-backed façade over `EverydayStore`: loads/saves JSON in Application
/// Support and supplies wall-clock time. The app touches the cache through
/// here; the pure store stays testable.
@MainActor
final class EverydayPlaces: ObservableObject {
    /// Shared calendar — Calendar(identifier:) re-resolves locale/timezone
    /// per construction, and lookups record context on every tap.
    nonisolated private static let gregorian = Calendar(identifier: .gregorian)

    static let shared = EverydayPlaces()

    private var store = EverydayStore()
    private let url: URL
    /// SERIAL writer, same rationale as SeasonalRiskModel.persist: snapshots
    /// drain FIFO so a later write can never be clobbered by an earlier one
    /// landing late.
    /// Shared with every other behaviour store so the erase button's key
    /// deletion cannot overtake a seal that is still queued.
    private var persistQueue: DispatchQueue { SecureBehaviorStore.persistQueue }

    init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_everyday_places.json")
        if let data = SecureBehaviorStore.readMigrating(url),
           let loaded = try? JSONDecoder().decode(EverydayStore.self, from: data) {
            store = loaded
        }
    }

    /// The circle's current radius (miles) — Settings surfaces it as
    /// "Your everyday area".
    var radiusMiles: Double { store.radiusMiles }
    /// The learned home anchor — the centre of the driver's everyday area —
    /// for a starting point or a map centre when there is no GPS fix.
    var homeAnchor: CLLocationCoordinate2D? {
        store.home.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    /// Every remembered place across categories — the evidence base for
    /// destination prediction (DestinationPrediction).
    var allPlaces: [EverydayPlace] {
        store.categories.values.flatMap { $0 }
    }

    /// Forget every remembered place, context, and the learned circle.
    func erase() {
        store = EverydayStore()
        SecureBehaviorStore.shred(url)
    }

    /// Likely destinations for the driver's current moment, built from the
    /// context histogram this app has been writing and never reading.
    /// `position` is where they're setting out from; nil falls back to
    /// time-of-day evidence alone.
    func predictions(
        from position: CLLocationCoordinate2D?, now: Date = Date(), limit: Int = 4
    ) -> [DestinationPrediction.Candidate] {
        let cal = Self.gregorian
        let bucket = EverydayStore.hourBucket(cal.component(.hour, from: now))
        let weekday = cal.component(.weekday, from: now)
        let weekend = weekday == 1 || weekday == 7
        let contextKey = position.map {
            EverydayStore.contextID(hourBucket: bucket, weekend: weekend,
                                    startLat: $0.latitude, startLon: $0.longitude)
        }
        let timePrefix = "h\(bucket)|\(weekend ? "we" : "wd")"
        let evidence = allPlaces.map { p -> DestinationPrediction.Evidence in
            var e = DestinationPrediction.Evidence(
                id: p.id, name: p.name,
                coordinate: CLLocationCoordinate2D(latitude: p.latitude,
                                                   longitude: p.longitude))
            if let contextKey { e.contextHits = p.contexts[contextKey] ?? 0 }
            // Back-off tier: same hour + day type, any starting point.
            e.timeHits = p.contexts
                .filter { $0.key.hasPrefix(timePrefix) }
                .reduce(0) { $0 + $1.value }
            e.totalHits = p.uses
            e.lastUsed = p.lastUsedT
            return e
        }
        return DestinationPrediction.rank(
            evidence, now: now.timeIntervalSince1970, limit: limit)
    }

    /// Learn from a completed trip: the straight-line start→end miles feed
    /// the radius estimate, and the home anchor refreshes from the seasonal
    /// model's learned home (which just absorbed the same trip).
    func recordTrip(origin: CLLocationCoordinate2D, dest: CLLocationCoordinate2D) {
        store.recordTrip(miles: EverydayStore.miles(from: origin, to: dest))
        // The anchor in force is passed back in so the seasonal model can
        // apply relocation hysteresis: only a cell that has dominated recent
        // departures for over a month, by a clear margin, displaces it. A
        // long assignment or a summer away does not move home; an actual
        // move does — and the circle travels with the driver.
        let current = store.home.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
        if let home = SeasonalRiskModel.shared.learnedHomeCoordinate(current: current) {
            let moved = current.map {
                EverydayStore.miles(from: $0, to: home) > 15
            } ?? false
            store.setHome(lat: home.latitude, lon: home.longitude)
            if moved {
                // NO COORDINATES IN THE JOURNAL. The diagnostic log is
                // plaintext in Caches and copyable from Settings, so it must
                // never carry the very data the encrypted store exists to
                // protect — logging a home location at 2 decimal places
                // (~1.1 km) names the driver's neighbourhood in a file the
                // encryption does not cover. The event is what's useful for
                // support; the position is not.
                FlowsDiag.log(.info, "learning",
                              "everyday center moved — sustained new origin")
            }
        }
        persist()
    }

    /// Remember a batch of fresh search results (one persist for the batch).
    /// Entries outside the everyday circle are ignored by the store.
    func remember(_ sightings: [(name: String, lat: Double, lon: Double,
                                 street: String, city: String)],
                  in category: EverydayCategory) {
        guard !sightings.isEmpty else { return }
        for s in sightings {
            store.remember(name: s.name, lat: s.lat, lon: s.lon,
                           street: s.street, city: s.city, in: category)
        }
        persist()
    }

    /// The instant result set: remembered stops for a category, most-used
    /// first — only when the driver is inside the everyday circle (away from
    /// home the cache is the wrong answer, so the network path runs alone).
    func instantResults(in category: EverydayCategory,
                        near position: CLLocationCoordinate2D?) -> [EverydayPlace] {
        guard let position,
              store.isInsideEverydayRadius(lat: position.latitude,
                                           lon: position.longitude) else { return [] }
        return store.ranked(in: category)
    }

    /// The driver tapped a result row: make sure the place is cached (if it
    /// is inside the circle) and count the lookup with its context.
    func noteUse(name: String, lat: Double, lon: Double,
                 in category: EverydayCategory, from start: CLLocationCoordinate2D?) {
        let now = Date()
        let t = now.timeIntervalSince1970
        guard store.remember(name: name, lat: lat, lon: lon, street: "", city: "",
                             in: category) else { return }
        let cal = Self.gregorian
        let weekday = cal.component(.weekday, from: now)
        let ctx = EverydayStore.contextID(
            hourBucket: EverydayStore.hourBucket(cal.component(.hour, from: now)),
            weekend: weekday == 1 || weekday == 7,
            startLat: start?.latitude ?? store.home?.lat ?? 0,
            startLon: start?.longitude ?? store.home?.lon ?? 0)
        store.recordUse(id: EverydayPlace.attributeID(name: name, latitude: lat, longitude: lon),
                        in: category, contextID: ctx, t: t)
        persist()
    }

    private func persist() {
        // Snapshot the value-type store on the main actor, encode + write on
        // the serial queue (same shape as SeasonalRiskModel.persist).
        let snapshot = store
        let url = self.url
        persistQueue.async {
            // ENCRYPTED AT REST — the places someone visits every day (home,
            // work, clinic, place of worship) are exactly the set that must
            // not be readable off a lost or seized device.
            if let data = try? JSONEncoder().encode(snapshot) {
                SecureBehaviorStore.write(data, to: url)
            }
        }
    }
}
