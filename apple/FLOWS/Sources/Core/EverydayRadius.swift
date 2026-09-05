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
/// home anchor as mean + one standard deviation — hard-capped at 20 miles.
/// The circle only ever SHRINKS below the 20-mile default with evidence; it
/// never grows past it. Stops the driver looks up inside that circle (food,
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
        switch self {
        case .food: return 0
        case .fuel: return 1
        case .stores: return 2
        case .rest: return 3
        case .shelter: return 4
        case .medical: return 5
        case .hotels: return 6
        case .gyms: return 7
        case .parking: return 8
        case .showers: return 9
        }
    }

    /// Fixed divisor for the normalised feature — frozen alongside
    /// `featureIndex` so the encoding is stable as cases are appended.
    static let featureIndexSpace = 16
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

    static func attributeID(name: String, latitude: Double, longitude: Double) -> String {
        "\(name)|\(Int(latitude * 500))|\(Int(longitude * 500))"
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
    /// The default AND the ceiling: a 20-mile radius (40-mile diameter) from
    /// home. Evidence can shrink the circle, never widen it.
    /// Radius before enough trips have been seen to learn one.
    static let defaultMiles = 20.0
    /// Sanity rails on the learned quantile — a circle smaller than this is
    /// useless, larger than this stops meaning "everyday".
    static let floorMiles = 3.0
    static let hardCapMiles = 150.0
    /// Trips before the observed quantile is meaningful enough to replace
    /// the default (in EITHER direction).
    static let minTripsForRadius = 30
    static let tripWindow = 200
    static let maxPlacesPerCategory = 50

    // MARK: Radius math

    /// Great-circle miles between two points (haversine).
    static func miles(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let r = 3958.8, toRad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * toRad
        let dLon = (b.longitude - a.longitude) * toRad
        let s = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * toRad) * cos(b.latitude * toRad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(s.squareRoot(), (1 - s).squareRoot())
    }

    var tripCount: Int { tripMiles.count }

    var meanTripMiles: Double? {
        guard !tripMiles.isEmpty else { return nil }
        return tripMiles.reduce(0, +) / Double(tripMiles.count)
    }

    /// Sample standard deviation (n − 1) of the trip distances.
    var tripMilesSD: Double? {
        guard tripMiles.count >= 2, let mean = meanTripMiles else { return nil }
        let sqSum = tripMiles.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (sqSum / Double(tripMiles.count - 1)).squareRoot()
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
        guard tripMiles.count >= Self.minTripsForRadius,
              let q = Self.quantile(tripMiles, 0.85) else { return Self.defaultMiles }
        return min(max(q, Self.floorMiles), Self.hardCapMiles)
    }

    /// Inclusive-rank quantile over the trip-length window. Pure, tested.
    static func quantile(_ values: [Double], _ q: Double) -> Double? {
        let clean = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !clean.isEmpty else { return nil }
        let position = min(max(q, 0), 1) * Double(clean.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, clean.count - 1)
        let fraction = position - Double(lower)
        return clean[lower] * (1 - fraction) + clean[upper] * fraction
    }

    mutating func recordTrip(miles: Double) {
        guard miles.isFinite, miles >= 0 else { return }
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
            if places.count > Self.maxPlacesPerCategory,
               let evict = places.indices.min(by: {
                   (places[$0].uses, places[$0].seen, places[$0].lastUsedT)
                       < (places[$1].uses, places[$1].seen, places[$1].lastUsedT)
               }) {
                places.remove(at: evict)
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
        (categories[category.rawValue] ?? []).sorted {
            ($1.uses, $1.seen, $1.lastUsedT, $0.name)
                < ($0.uses, $0.seen, $0.lastUsedT, $1.name)
        }
    }

    // MARK: Context attribute ids

    /// Time-of-day bucket: six 4-hour bins (0 = night 12–4 am … 5 = 8 pm–12).
    static func hourBucket(_ hour: Int) -> Int {
        (((hour % 24) + 24) % 24) / 4
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
        let a = 2 * Double.pi * Double(hourBucket) / 6
        // Frozen ordinal + fixed divisor: appending a category must never
        // change what an existing one encodes to.
        let c = Double(category.featureIndex)
        return [sin(a), cos(a), weekend ? 1 : 0,
                startLat / 90, startLon / 180, placeLat / 90, placeLon / 180,
                c / Double(EverydayCategory.featureIndexSpace)]
    }
    static let count = 8
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
