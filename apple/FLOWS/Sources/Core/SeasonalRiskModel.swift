// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// On-device, referable prediction store — the DATA FOUNDATION the ANE/Core ML
/// route model trains on (phase 2). It records what FLOWS predicted vs. what
/// actually happened on the driver's OWN frequent routes, bucketed by
/// week-of-year, with recent observations weighted more heavily (exponential
/// decay). A route/week only starts influencing routing once it has accrued a
/// statistically meaningful number of samples; one-off trips accumulate but
/// steer nothing yet. Cross-country trips (rare but valuable) cross that bar on
/// fewer repeats than local ones. The road graph is modeled as hubs
/// (intersections) and edges (roads between hubs) so a graph neural net can
/// consume it directly later.
///
/// `SeasonalStore` is the pure, `Codable`, unit-tested core — it takes an
/// explicit time so the decay is deterministic in tests. `SeasonalRiskModel`
/// wraps it with disk persistence and wall-clock/week helpers.

// MARK: - Pure core

/// One completed-trip observation: what we predicted vs. what was encountered.
struct TripObservation {
    let key: RouteKey
    let week: Int            // 0…51, week-of-year
    let predicted: Double    // 0…1 risk FLOWS predicted at plan time
    let observed: Double     // 0…1 worst realized risk actually encountered
    let distanceKm: Double
    let t: Double            // absolute time (epoch seconds) — drives decay
}

/// Canonical route id: origin & destination quantized to ~11 km (0.1°) so trips
/// between the same two areas group together ("the drive I always take").
struct RouteKey: Hashable, Codable {
    let oLat: Int, oLon: Int, dLat: Int, dLon: Int
    init(origin: CLLocationCoordinate2D, dest: CLLocationCoordinate2D) {
        func q(_ v: Double) -> Int { Int((v * 10).rounded()) }
        oLat = q(origin.latitude); oLon = q(origin.longitude)
        dLat = q(dest.latitude); dLon = q(dest.longitude)
    }
}

/// Decaying-weighted accumulators for a (route, week) or (edge, week) cell. Each
/// observation enters with weight 1; existing weight decays by a half-life so a
/// season two years ago counts a quarter as much as this one.
struct WeekStat: Codable {
    var wSum = 0.0        // Σ weights
    var wObserved = 0.0   // Σ weight · observed
    var wSqErr = 0.0      // Σ weight · (predicted − observed)²
    var lastT = 0.0       // time of last update
    var count = 0         // raw sample count (undecayed)

    private static let secondsPerWeek = 7.0 * 24 * 3600

    mutating func decay(to t: Double, halfLifeWeeks: Double) {
        guard count > 0, t > lastT, halfLifeWeeks > 0 else { return }
        let weeks = (t - lastT) / Self.secondsPerWeek
        let f = pow(0.5, weeks / halfLifeWeeks)
        wSum *= f; wObserved *= f; wSqErr *= f
        lastT = t
    }
    mutating func add(observed: Double, predicted: Double, t: Double, halfLifeWeeks: Double) {
        decay(to: t, halfLifeWeeks: halfLifeWeeks)
        let o = min(max(observed, 0), 1), p = min(max(predicted, 0), 1)
        wSum += 1; wObserved += o; wSqErr += (p - o) * (p - o)
        lastT = max(lastT, t); count += 1
    }
    var mean: Double { wSum > 0 ? wObserved / wSum : 0 }
}

/// Per-route accumulator: trip count (for frequency gating), whether it is a
/// cross-country route, and the per-week seasonal stats.
struct RouteRecord: Codable {
    var tripCount = 0
    var crossCountry = false
    var weeks: [Int: WeekStat] = [:]
}

/// Undirected road edge between two ~1 km hubs (intersections), sorted so
/// A→B and B→A share one record. The GNN's edge features come from here.
struct EdgeKey: Hashable, Codable {
    let aLat: Int, aLon: Int, bLat: Int, bLon: Int
    init(_ h1: CLLocationCoordinate2D, _ h2: CLLocationCoordinate2D) {
        func q(_ v: Double) -> Int { Int((v * 100).rounded()) }   // ~1.1 km
        let p1 = (q(h1.latitude), q(h1.longitude))
        let p2 = (q(h2.latitude), q(h2.longitude))
        let (a, b) = p1 <= p2 ? (p1, p2) : (p2, p1)
        aLat = a.0; aLon = a.1; bLat = b.0; bLon = b.1
    }
}
struct EdgeRecord: Codable { var weeks: [Int: WeekStat] = [:] }

struct SeasonalStore: Codable {
    var routes: [RouteKey: RouteRecord] = [:]
    // Edge graph keyed by a string (RouteKey/EdgeKey aren't JSON dictionary keys
    // without extra coding); the string is EdgeKey's four ints joined.
    var edges: [String: EdgeRecord] = [:]

    // Tunables (documented so phase-2 training can reference them).
    static let crossCountryKm = 300.0
    static let localTripThreshold = 6        // local: common, filter noise
    static let crossCountryTripThreshold = 2 // cross-country: rare but valuable
    static let minWeekSamplesForConfidence = 5.0
    static let decayHalfLifeWeeks = 52.0     // weight halves each year
    static let homeMinTrips = 15             // origin trips before "home" is inferred

    /// A route is "modeled" (allowed to steer ranking) only past its frequency
    /// gate — one-offs accrue history but don't yet influence routing.
    func isModeled(_ key: RouteKey) -> Bool {
        guard let rec = routes[key] else { return false }
        let gate = rec.crossCountry ? Self.crossCountryTripThreshold : Self.localTripThreshold
        return rec.tripCount >= gate
    }

    mutating func record(_ obs: TripObservation) {
        var rec = routes[obs.key] ?? RouteRecord()
        rec.tripCount += 1
        rec.crossCountry = obs.distanceKm >= Self.crossCountryKm
        var ws = rec.weeks[obs.week] ?? WeekStat()
        ws.add(observed: obs.observed, predicted: obs.predicted, t: obs.t,
               halfLifeWeeks: Self.decayHalfLifeWeeks)
        rec.weeks[obs.week] = ws
        routes[obs.key] = rec
    }

    /// Accumulate a driven route's per-edge observed risk into the hub/edge
    /// graph (the GNN's training substrate). `hubPath` is the ordered sequence
    /// of hub coordinates the route traversed.
    mutating func recordEdges(hubPath: [CLLocationCoordinate2D], week: Int,
                              observed: Double, t: Double) {
        guard hubPath.count >= 2 else { return }
        for i in 1..<hubPath.count {
            let k = EdgeKey(hubPath[i - 1], hubPath[i])
            let s = "\(k.aLat),\(k.aLon),\(k.bLat),\(k.bLon)"
            var er = edges[s] ?? EdgeRecord()
            var ws = er.weeks[week] ?? WeekStat()
            ws.add(observed: observed, predicted: observed, t: t,
                   halfLifeWeeks: Self.decayHalfLifeWeeks)
            er.weeks[week] = ws
            edges[s] = er
        }
    }

    /// The learned seasonal prior for a route at a week: the decaying-weighted
    /// mean of what was actually encountered, borrowing from the two adjacent
    /// weeks (seasons change gradually) so a sparse target week is still usable.
    /// `confidence` (0…1) scales with how many samples the target week holds —
    /// the caller blends toward this prior as confidence grows. `nil` until the
    /// route passes its frequency gate.
    func seasonalPrior(for key: RouteKey, week: Int, now t: Double)
        -> (risk: Double, confidence: Double)? {
        guard let rec = routes[key], isModeled(key) else { return nil }
        var wSum = 0.0, wObs = 0.0, targetWeight = 0.0
        for (dw, wt) in [(0, 1.0), (-1, 0.5), (1, 0.5)] {
            let wk = ((week + dw) % 52 + 52) % 52
            guard var ws = rec.weeks[wk] else { continue }
            ws.decay(to: t, halfLifeWeeks: Self.decayHalfLifeWeeks)
            wSum += wt * ws.wSum
            wObs += wt * ws.wObserved
            if dw == 0 { targetWeight = ws.wSum }
        }
        guard wSum > 0 else { return nil }
        return (wObs / wSum, min(1, targetWeight / Self.minWeekSamplesForConfidence))
    }

    /// Decaying-weighted RMSE of prediction vs. observation for a route — the
    /// referable accuracy that later tells the model where it is weak. Lower is
    /// better; `nil` if the route has no history.
    func accuracy(for key: RouteKey, now t: Double) -> Double? {
        guard let rec = routes[key], rec.tripCount > 0 else { return nil }
        var wSum = 0.0, wErr = 0.0
        for (_, stat) in rec.weeks {
            var ws = stat
            ws.decay(to: t, halfLifeWeeks: Self.decayHalfLifeWeeks)
            wSum += ws.wSum; wErr += ws.wSqErr
        }
        guard wSum > 0 else { return nil }
        return (wErr / wSum).squareRoot()
    }

    /// The driver's likely HOME: the trip-origin cell appearing in the most
    /// trips. Local driving reuses it constantly, so its climate/data radius is
    /// worth caching; and a large, well-established shift from the saved "Home"
    /// favorite means the driver probably moved without updating settings. `nil`
    /// until an origin clears `homeMinTrips`.
    func learnedHome() -> (lat: Double, lon: Double, trips: Int)? {
        struct OriginCell: Hashable { let lat: Int; let lon: Int }
        var byOrigin: [OriginCell: Int] = [:]
        for (key, rec) in routes {
            byOrigin[OriginCell(lat: key.oLat, lon: key.oLon), default: 0] += rec.tripCount
        }
        guard let (cell, n) = byOrigin.max(by: { $0.value < $1.value }), n >= Self.homeMinTrips
        else { return nil }
        return (Double(cell.lat) / 10, Double(cell.lon) / 10, n)
    }

    /// Flat, worker-friendly training rows: one per (route, populated week).
    /// The background trainer reads these instead of the store's internal
    /// dictionary encoding, so the on-disk model format can evolve freely.
    func trainingRows(now t: Double) -> [[String: Double]] {
        var rows: [[String: Double]] = []
        for (key, rec) in routes {
            for (wk, stat) in rec.weeks {
                var ws = stat
                ws.decay(to: t, halfLifeWeeks: Self.decayHalfLifeWeeks)
                guard ws.wSum > 0 else { continue }
                rows.append([
                    "oLat": Double(key.oLat) / 10, "oLon": Double(key.oLon) / 10,
                    "dLat": Double(key.dLat) / 10, "dLon": Double(key.dLon) / 10,
                    "week": Double(wk), "target": ws.mean, "weight": ws.wSum,
                    "crossCountry": rec.crossCountry ? 1 : 0,
                ])
            }
        }
        return rows
    }
}

// MARK: - Learned head (phase 2a)

/// Great-circle km between two lat/lon points — for the distance feature.
private func haversineKm(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
    let r = 6371.0, toRad = Double.pi / 180
    let dLat = (bLat - aLat) * toRad, dLon = (bLon - aLon) * toRad
    let s = sin(dLat / 2) * sin(dLat / 2)
        + cos(aLat * toRad) * cos(bLat * toRad) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * r * atan2(s.squareRoot(), (1 - s).squareRoot())
}

/// The route/week feature vector — IDENTICAL order in the Rust trainer
/// (rust/flows-train/src/main.rs::features) and here. Pre-normalized to
/// ~[-1, 1]; change one side ⇒ change both AND retrain (the head's input
/// width is gated below, so a stale head degrades instead of misfiring).
/// v2 adds LONGITUDES: without them Phoenix and Moore, OK (same latitude)
/// were indistinguishable — desert heat and tornado alley blurred together.
enum RouteFeatures {
    static func vector(oLat: Double, oLon: Double, dLat: Double, dLon: Double,
                       week: Int, crossCountry: Bool) -> [Double] {
        let a = 2 * Double.pi * Double(week) / 52
        let dist = haversineKm(oLat, oLon, dLat, dLon)
        return [sin(a), cos(a), oLat / 90, dLat / 90, oLon / 180, dLon / 180,
                min(dist, 4000) / 4000, crossCountry ? 1 : 0]
    }
    static let count = 8
}

/// A small trained MLP (features → risk 0…1) — the phase-2a regression head the
/// background worker produces. Runs its forward pass in Swift (the net is tiny;
/// ANE pays off only at the batched-graph scale of the phase-2b GNN). Weights
/// are dropped in by the worker; absent ⇒ the statistical seasonal prior is
/// used instead, so the app degrades gracefully.
struct LearnedHead: Codable {
    let w1: [[Double]]   // [hidden][in]
    let b1: [Double]     // [hidden]
    let w2: [Double]     // [hidden] → single output
    let b2: Double
    let version: Int
    /// Training-set size (absent in old heads) — the richer model wins.
    var rows: Int? = nil

    /// Input width this head was trained for — must equal RouteFeatures.count
    /// or the head is stale (feature-contract change) and is not used.
    var inputWidth: Int { w1.first?.count ?? 0 }

    func predict(_ x: [Double]) -> Double {
        var out = b2
        // A corrupt/mismatched head file must degrade, not crash the app.
        let hidden = min(b1.count, w1.count, w2.count)
        for j in 0..<hidden {
            var s = b1[j]
            let row = w1[j]
            let n = min(row.count, x.count)
            for i in 0..<n { s += row[i] * x[i] }
            out += w2[j] * max(0, s)                 // relu hidden
        }
        return 1 / (1 + exp(-out))                    // sigmoid output
    }
}

// MARK: - Persisted wrapper

/// Disk-backed façade over `SeasonalStore`: loads/saves JSON in Application
/// Support and supplies wall-clock time + week-of-year. Everything the app
/// touches goes through here; the pure store stays testable.
@MainActor
final class SeasonalRiskModel: ObservableObject {
    static let shared = SeasonalRiskModel()

    private var store = SeasonalStore()
    private let url: URL           // the seasonal store
    private let exportURL: URL     // flat training rows the worker reads
    private let headURL: URL       // the trained MLP the worker drops in
    private var head: LearnedHead? // nil until the worker has produced one

    init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_seasonal_model.json")
        exportURL = dir.appendingPathComponent("flows_training_export.csv")
        headURL = dir.appendingPathComponent("flows_route_head.json")
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(SeasonalStore.self, from: data) {
            store = loaded
        }
        loadHead()
    }

    /// (Re)load the background worker's trained head from disk. Called at launch;
    /// the worker rewrites the file, so the app picks up a fresher model next
    /// launch. Missing/corrupt ⇒ the statistical prior is used.
    func loadHead() {
        func decode(_ data: Data?) -> LearnedHead? {
            guard let data,
                  let h = try? JSONDecoder().decode(LearnedHead.self, from: data),
                  h.inputWidth == RouteFeatures.count   // stale contract → unusable
            else { return nil }
            return h
        }
        let local = decode(try? Data(contentsOf: headURL))
        // The SHIPPED baseline: trained on 20 years of NOAA Storm Events
        // (2005–2024) so a fresh install predicts from history, not zero. A
        // newer locally-trained head (the weekly worker's output, which folds
        // in the driver's own trips) wins by version.
        let bundled = decode(Bundle.main.url(
            forResource: "baseline_route_head", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) })
        switch (local, bundled) {
        case let (l?, b?):
            // The model trained on MORE data wins: a local head from a few
            // hundred of the driver's trips must refine, not replace, the
            // 20-year historical baseline. (The weekly worker folds history
            // rows in over time, at which point local overtakes honestly.)
            head = (l.rows ?? 0) >= (b.rows ?? 0) ? l : b
        case let (l?, nil): head = l
        case let (nil, b?): head = b
        default: head = nil
        }
    }

    /// Week-of-year 0…51 (ISO-ish: day-of-year / 7, clamped).
    nonisolated static func week(_ date: Date = Date()) -> Int {
        let day = Calendar(identifier: .gregorian).ordinality(of: .day, in: .year, for: date) ?? 1
        return min(51, max(0, (day - 1) / 7))
    }

    /// Blend the on-device seasonal prior into a route's ranking. Returns
    /// (prior, confidence) or (0, 0) when the route isn't modeled yet. When the
    /// worker's trained head is present it REFINES the prior's risk (a smooth
    /// learned function of week + geography) while confidence stays gated by how
    /// much real data backs this route — so a fresh model never overreaches.
    func priorForRanking(origin: CLLocationCoordinate2D, dest: CLLocationCoordinate2D)
        -> (risk: Double, confidence: Double) {
        let key = RouteKey(origin: origin, dest: dest)
        guard let stat = store.seasonalPrior(
            for: key, week: Self.week(), now: Date().timeIntervalSince1970) else { return (0, 0) }
        guard let head else { return stat }
        let x = RouteFeatures.vector(
            oLat: Double(key.oLat) / 10, oLon: Double(key.oLon) / 10,
            dLat: Double(key.dLat) / 10, dLon: Double(key.dLon) / 10,
            week: Self.week(), crossCountry: store.routes[key]?.crossCountry ?? false)
        return (head.predict(x), stat.confidence)
    }

    /// The home coordinate to anchor the always-cached climate/data radius on:
    /// the saved "Home" favorite, unless the frequency-inferred home is both FAR
    /// (>40 km) and well-established (≥25 trips) — meaning the driver moved and
    /// never updated settings, so the trip history is the truer signal.
    func homeAnchor(favorite: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        guard let learned = store.learnedHome() else { return favorite }
        let learnedC = CLLocationCoordinate2D(latitude: learned.lat, longitude: learned.lon)
        guard let favorite else { return learnedC }
        let movedKm = haversineKm(favorite.latitude, favorite.longitude,
                                  learnedC.latitude, learnedC.longitude)
        return (movedKm > 40 && learned.trips >= 25) ? learnedC : favorite
    }

    /// Record a completed trip's prediction vs. what was encountered, plus the
    /// per-edge history, then persist.
    func recordTrip(origin: CLLocationCoordinate2D, dest: CLLocationCoordinate2D,
                    predicted: Double, observed: Double, distanceKm: Double,
                    hubPath: [CLLocationCoordinate2D] = []) {
        let now = Date().timeIntervalSince1970
        let wk = Self.week()
        store.record(TripObservation(
            key: RouteKey(origin: origin, dest: dest), week: wk,
            predicted: predicted, observed: observed, distanceKm: distanceKm, t: now))
        if hubPath.count >= 2 {
            store.recordEdges(hubPath: hubPath, week: wk, observed: observed, t: now)
        }
        persist()
    }

    private func persist() {
        // Snapshot the value-type store, then encode + write OFF the main
        // actor: persist() fires at arrival time — the exact moment the
        // arrived banner renders — and the encode/CSV cost grows with trip
        // history. Atomic writes keep the reader-side contract.
        let snapshot = store
        let url = self.url, exportURL = self.exportURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
            // Flat CSV training view for the Rust trainer (rust/flows-train).
            let rows = snapshot.trainingRows(now: Date().timeIntervalSince1970)
            var csv = "oLat,oLon,dLat,dLon,week,target,weight,crossCountry\n"
            for r in rows {
                csv += "\(r["oLat"] ?? 0),\(r["oLon"] ?? 0),\(r["dLat"] ?? 0),\(r["dLon"] ?? 0),"
                csv += "\(Int(r["week"] ?? 0)),\(r["target"] ?? 0),\(r["weight"] ?? 0),"
                csv += "\(Int(r["crossCountry"] ?? 0))\n"
            }
            try? csv.write(to: exportURL, atomically: true, encoding: .utf8)
        }
    }
}
