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
    static let hardCapMiles = 20.0
    /// Trips before mean + SD is statistically meaningful enough to shrink
    /// the circle below the default.
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
    var radiusMiles: Double {
        guard tripMiles.count >= Self.minTripsForRadius,
              let mean = meanTripMiles, let sd = tripMilesSD else { return Self.hardCapMiles }
        return min(Self.hardCapMiles, mean + sd)
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
            guard let category = EverydayCategory(rawValue: raw),
                  let catIndex = EverydayCategory.allCases.firstIndex(of: category)
            else { continue }
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
        let c = Double(EverydayCategory.allCases.firstIndex(of: category) ?? 0)
        return [sin(a), cos(a), weekend ? 1 : 0,
                startLat / 90, startLon / 180, placeLat / 90, placeLon / 180,
                c / Double(EverydayCategory.allCases.count)]
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
    private let persistQueue = DispatchQueue(label: "com.flows.everyday.persist",
                                             qos: .default)

    init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_everyday_places.json")
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(EverydayStore.self, from: data) {
            store = loaded
        }
    }

    /// The circle's current radius (miles) — Settings surfaces it as
    /// "Your everyday area".
    var radiusMiles: Double { store.radiusMiles }

    /// Learn from a completed trip: the straight-line start→end miles feed
    /// the radius estimate, and the home anchor refreshes from the seasonal
    /// model's learned home (which just absorbed the same trip).
    func recordTrip(origin: CLLocationCoordinate2D, dest: CLLocationCoordinate2D) {
        store.recordTrip(miles: EverydayStore.miles(from: origin, to: dest))
        if let home = SeasonalRiskModel.shared.learnedHomeCoordinate() {
            store.setHome(lat: home.latitude, lon: home.longitude)
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
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
