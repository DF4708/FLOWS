// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
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
///
/// Every number and decision here — the accumulators and their decay, the
/// frequency gate, the prior, the calibration, the keys, both evictions, the
/// learned home, the route features, the head's forward pass, the tune gates
/// and the ranking blend — is computed in rust/flows-core (seasonal.rs) and
/// called through rust/flows-bridge. The store's dictionaries, persistence
/// and calendar stay here, recomposing the pure pieces the way the oracle
/// does. Pinned bit for bit to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_seasonal_oracle.tsv.

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
        // A coordinate that is not a number has no cell (the Swift this
        // replaced crashed); 0 keeps the key finite.
        func q(_ v: Double) -> Int {
            let cell = flows_seasonal_route_cell(v)
            return cell.is_some == 1 ? Int(cell.value) : 0
        }
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

    /// The cell as the bridge carries it.
    var bridge: FlowsSeasonalWeekStat {
        FlowsSeasonalWeekStat(w_sum: wSum, w_observed: wObserved, w_sq_err: wSqErr, last_t: lastT, count: Int64(count))
    }

    init(bridge b: FlowsSeasonalWeekStat) {
        wSum = b.w_sum; wObserved = b.w_observed; wSqErr = b.w_sq_err; lastT = b.last_t; count = Int(b.count)
    }

    init(wSum: Double = 0, wObserved: Double = 0, wSqErr: Double = 0, lastT: Double = 0, count: Int = 0) {
        self.wSum = wSum; self.wObserved = wObserved; self.wSqErr = wSqErr; self.lastT = lastT; self.count = count
    }

    mutating func decay(to t: Double, halfLifeWeeks: Double) {
        self = WeekStat(bridge: flows_seasonal_week_stat_decayed(bridge, t, halfLifeWeeks))
    }

    mutating func add(observed: Double, predicted: Double, t: Double, halfLifeWeeks: Double) {
        self = WeekStat(bridge: flows_seasonal_week_stat_added(bridge, observed, predicted, t, halfLifeWeeks))
    }

    var mean: Double { flows_seasonal_mean_observed(wSum, wObserved) }
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
        // ~1.1 km hub cells, as the bridge's edge keys quantize them; a
        // coordinate that is not a number has no cell (the Swift crashed) and
        // answers 0.
        func q(_ v: Double) -> Int {
            let cell = flows_seasonal_route_cell(v * 10)
            return cell.is_some == 1 ? Int(cell.value) : 0
        }
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
    static let crossCountryKm = flows_seasonal_cross_country_km()
    static let localTripThreshold = Int(flows_seasonal_local_trip_threshold())        // local: common, filter noise
    static let crossCountryTripThreshold = Int(flows_seasonal_cross_country_trip_threshold()) // cross-country: rare but valuable
    static let minWeekSamplesForConfidence = flows_seasonal_min_week_samples_for_confidence()
    static let decayHalfLifeWeeks = flows_seasonal_decay_half_life_weeks()     // weight halves each year
    static let homeMinTrips = Int(flows_seasonal_home_min_trips())             // origin trips before "home" is inferred

    /// Total recorded trips across every route — the gate for on-device
    /// fine-tuning (a head must not be re-fit from three trips).
    var totalTrips: Int { routes.values.reduce(0) { $0 + $1.tripCount } }

    /// A route is "modeled" (allowed to steer ranking) only past its frequency
    /// gate — one-offs accrue history but don't yet influence routing.
    func isModeled(_ key: RouteKey) -> Bool {
        guard let rec = routes[key] else { return false }
        return flows_seasonal_is_modeled(Int64(rec.tripCount), rec.crossCountry)
    }

    mutating func record(_ obs: TripObservation) {
        var rec = routes[obs.key] ?? RouteRecord()
        rec.tripCount = Int(flows_seasonal_next_count(Int64(rec.tripCount)))
        rec.crossCountry = flows_seasonal_is_cross_country(obs.distanceKm)
        var ws = rec.weeks[obs.week] ?? WeekStat()
        ws.add(observed: obs.observed, predicted: obs.predicted, t: obs.t,
               halfLifeWeeks: Self.decayHalfLifeWeeks)
        rec.weeks[obs.week] = ws
        routes[obs.key] = rec
        // Recency-decayed origin history — how a relocation becomes visible.
        recordOrigin(lat: obs.key.oLat, lon: obs.key.oLon, t: obs.t)
    }

    /// Accumulate a driven route's per-edge observed risk into the hub/edge
    /// graph (the GNN's training substrate). `hubPath` is the ordered sequence
    /// of hub coordinates the route traversed.
    /// Upper bound on the edge graph. It is written on every arrival and
    /// read by nothing yet (the phase-2b GNN substrate), so it MUST NOT grow
    /// without limit: at 3 km hub spacing a single 950-mile trip appends
    /// ~500 records, and the whole store is re-encoded and re-sealed on each
    /// arrival. Capped and decay-evicted, it stays a usable substrate at a
    /// bounded cost; uncapped it was a pure write-amplifier.
    static let maxEdges = Int(flows_seasonal_max_edges())

    mutating func recordEdges(hubPath: [CLLocationCoordinate2D], week: Int,
                              observed: Double, t: Double) {
        guard hubPath.count >= 2 else { return }
        // Consecutive hub pairs to the persisted "aLat,aLon,bLat,bLon" keys.
        let hubs = hubPath.flatMap { [$0.latitude, $0.longitude] }
        let keys = hubs.withUnsafeBufferPointer { flows_seasonal_path_edge_keys($0) }
        for key in keys {
            let s = key.as_str().toString()
            var er = edges[s] ?? EdgeRecord()
            var ws = er.weeks[week] ?? WeekStat()
            ws.add(observed: observed, predicted: observed, t: t,
                   halfLifeWeeks: Self.decayHalfLifeWeeks)
            er.weeks[week] = ws
            edges[s] = er
        }
        guard flows_seasonal_edges_over_cap(Int64(edges.count)) else { return }
        // Evict the least-recently-reinforced half — roads the driver has
        // stopped using decay out, corridors they still drive survive.
        let order = Array(edges.keys)
        let freshness: [Double] = order.map { key in
            let lastTs = edges[key]?.weeks.values.map(\.lastT) ?? []
            // A record with no weeks is as stale as it gets (and an empty
            // buffer never crosses).
            return lastTs.isEmpty ? 0 : lastTs.withUnsafeBufferPointer { flows_seasonal_edge_freshness($0) }
        }
        let doomed = freshness.withUnsafeBufferPointer { flows_seasonal_edge_evictions($0) }
        for position in doomed {
            if let i = Int(exactly: position), i < order.count { edges.removeValue(forKey: order[i]) }
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
        guard let rec = routes[key] else { return nil }
        // The target week and its two neighbours, wrapped; empty where the
        // week arithmetic overflowed (the Swift this replaced crashed).
        let keys = flows_seasonal_prior_week_keys(Int64(week))
        guard keys.len() == 3 else { return nil }
        var cells: [Double] = []
        var present: [Double] = []
        for k in keys {
            let ws = rec.weeks[Int(k)]
            let b = (ws ?? WeekStat()).bridge
            cells += [b.w_sum, b.w_observed, b.w_sq_err, b.last_t, Double(b.count)]
            present.append(ws == nil ? 0 : 1)
        }
        let prior = cells.withUnsafeBufferPointer { c in
            present.withUnsafeBufferPointer { p in
                flows_seasonal_prior(Int64(rec.tripCount), rec.crossCountry, Int64(week), c, p, t)
            }
        }
        return prior.has == 1 ? (prior.risk, prior.confidence) : nil
    }

    /// Decaying-weighted RMSE of prediction vs. observation for a route — the
    /// referable accuracy that later tells the model where it is weak. Lower is
    /// better; `nil` if the route has no history.
    func accuracy(for key: RouteKey, now t: Double) -> Double? {
        guard let rec = routes[key], !rec.weeks.isEmpty else { return nil }
        let stats = rec.weeks.values.flatMap { ws -> [Double] in
            let b = ws.bridge
            return [b.w_sum, b.w_observed, b.w_sq_err, b.last_t, Double(b.count)]
        }
        let r = stats.withUnsafeBufferPointer { flows_seasonal_accuracy(Int64(rec.tripCount), $0, t) }
        return r.is_some == 1 ? r.value : nil
    }

    /// The driver's likely HOME: the trip-origin cell appearing in the most
    /// trips. Local driving reuses it constantly, so its climate/data radius is
    /// worth caching; and a large, well-established shift from the saved "Home"
    /// favorite means the driver probably moved without updating settings. `nil`
    /// until an origin clears `homeMinTrips`.
    /// Per-origin-cell trip history with RECENCY DECAY — the substrate for
    /// detecting that a driver has moved. All-time counts alone can never
    /// notice a relocation: a driver with three years at the old address
    /// carries hundreds of trips there, so a new city would need years to
    /// out-count it and "home" would stay wrong the entire time.
    struct OriginStat: Codable {
        /// Trips decayed toward the present (30-day half-life), so the last
        /// month or two dominates.
        var weighted: Double = 0
        var lastSeen: Double = 0
        var firstSeen: Double = 0
        var trips: Int = 0
    }

    /// Keyed "lat|lon" in 0.1° cell units (JSON dictionaries need String keys).
    var origins: [String: OriginStat] = [:]

    static let originHalfLifeDays = flows_seasonal_origin_half_life_days()
    /// A challenger must beat the incumbent by this factor to take over as
    /// home — hysteresis, so the anchor doesn't oscillate week to week.
    static let relocationMargin = flows_seasonal_relocation_margin()
    /// …and must have been in use at least this long, so a month-long job,
    /// a hospital stay, or a summer at the lake does not become "home".
    static let relocationMinDays = flows_seasonal_relocation_min_days()

    mutating func recordOrigin(lat: Int, lon: Int, t: Double) {
        let key = flows_seasonal_origin_key(Int64(lat), Int64(lon)).toString()
        let prior = origins[key] ?? OriginStat()
        let next = flows_seasonal_origin_after_trip(
            FlowsSeasonalOriginStat(weighted: prior.weighted, last_seen: prior.lastSeen,
                                    first_seen: prior.firstSeen, trips: Int64(prior.trips)), t)
        origins[key] = OriginStat(weighted: next.weighted, lastSeen: next.last_seen,
                                  firstSeen: next.first_seen, trips: Int(next.trips))
        // Bound the map: cells the driver has genuinely left decay to noise.
        guard flows_seasonal_origins_over_cap(Int64(origins.count)) else { return }
        let order = Array(origins.keys)
        let stats: [Double] = order.flatMap { key -> [Double] in
            let stat = origins[key]
            return [stat?.weighted ?? 0, stat?.lastSeen ?? 0]
        }
        let doomed = stats.withUnsafeBufferPointer { flows_seasonal_origin_evictions($0, t) }
        for position in doomed {
            if let i = Int(exactly: position), i < order.count { origins.removeValue(forKey: order[i]) }
        }
    }

    /// The learned home anchor: the origin cell the driver actually departs
    /// from THESE DAYS. Recency-decayed, gated on total trips, and — once an
    /// anchor exists — protected by hysteresis so only a sustained move
    /// (dominant for over a month, by a clear margin) shifts it.
    /// `currentHome` is the anchor in force; pass nil on first inference.
    func learnedHome(
        now: Double = Date().timeIntervalSince1970,
        currentHome: (lat: Int, lon: Int)? = nil
    ) -> (lat: Double, lon: Double, trips: Int)? {
        // Fall back to the all-time origin scan for stores written before
        // origin tracking existed, so an upgrading driver keeps their anchor.
        guard !origins.isEmpty else { return legacyLearnedHome() }
        // Seven numbers an entry: cell present, lat, lon, weighted, last seen,
        // first seen, trips — in the store's order.
        let entries: [Double] = origins.flatMap { key, stat -> [Double] in
            let cell = flows_seasonal_parse_origin_key(key)
            return [cell.has, Double(cell.lat), Double(cell.lon),
                    stat.weighted, stat.lastSeen, stat.firstSeen, Double(stat.trips)]
        }
        let home = entries.withUnsafeBufferPointer {
            flows_seasonal_learned_home($0, now, Int64(currentHome?.lat ?? 0), Int64(currentHome?.lon ?? 0), currentHome != nil)
        }
        return home.has == 1 ? (home.lat, home.lon, Int(home.trips)) : nil
    }

    /// Pre-origin-tracking behavior, kept for stores that predate it.
    private func legacyLearnedHome() -> (lat: Double, lon: Double, trips: Int)? {
        guard !routes.isEmpty else { return nil }
        let list: [Double] = routes.flatMap { key, rec in [Double(key.oLat), Double(key.oLon), Double(rec.tripCount)] }
        let home = list.withUnsafeBufferPointer { flows_seasonal_legacy_home($0) }
        return home.has == 1 ? (home.lat, home.lon, Int(home.trips)) : nil
    }

    /// Flat, worker-friendly training rows: one per (route, populated week).
    /// The background trainer reads these instead of the store's internal
    /// dictionary encoding, so the on-disk model format can evolve freely.
    func trainingRows(now t: Double) -> [[String: Double]] {
        // Eleven numbers a cell: the four route cells, the week, cross
        // (1 or 0), then the five stat numbers — in the store's order.
        var cells: [Double] = []
        for (key, rec) in routes {
            for (wk, stat) in rec.weeks {
                let b = stat.bridge
                cells += [Double(key.oLat), Double(key.oLon), Double(key.dLat), Double(key.dLon), Double(wk),
                          rec.crossCountry ? 1 : 0, b.w_sum, b.w_observed, b.w_sq_err, b.last_t, Double(b.count)]
            }
        }
        guard !cells.isEmpty else { return [] }
        let flat = cells.withUnsafeBufferPointer { flows_seasonal_training_rows($0, t) }
        var rows: [[String: Double]] = []
        var i = 0
        while i + 7 < flat.len() {
            rows.append([
                "oLat": flat[i], "oLon": flat[i + 1], "dLat": flat[i + 2], "dLon": flat[i + 3],
                "week": flat[i + 4], "target": flat[i + 5], "weight": flat[i + 6], "crossCountry": flat[i + 7],
            ])
            i += 8
        }
        return rows
    }
}

// MARK: - Learned head (phase 2a)


/// The route/week feature vector — IDENTICAL order in the Rust trainer
/// (rust/flows-train/src/main.rs::features) and here. Pre-normalized to
/// ~[-1, 1]; change one side ⇒ change both AND retrain (the head's input
/// width is gated below, so a stale head degrades instead of misfiring).
/// v2 adds LONGITUDES: without them Phoenix and Moore, OK (same latitude)
/// were indistinguishable — desert heat and tornado alley blurred together.
enum RouteFeatures {
    static func vector(oLat: Double, oLon: Double, dLat: Double, dLon: Double,
                       week: Int, crossCountry: Bool) -> [Double] {
        Array(flows_seasonal_route_features(oLat, oLon, dLat, dLon, Int64(week), crossCountry))
    }
    static let count = Int(flows_seasonal_route_feature_count())
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
    /// Training-set size (absent in old heads). INFORMATIONAL ONLY now: it
    /// used to select between a device head and the bundled baseline, but a
    /// device head can never reach the baseline's 1,164,376 rows, so the
    /// weekly worker's output was always discarded. Device training is now a
    /// warm-started fine-tune OF the baseline (RouteHeadTrainer), so there
    /// is one head, not two competing ones.
    var rows: Int? = nil
    /// True when this head has been fine-tuned on THIS driver's trips.
    var tunedOnDevice: Bool? = nil

    /// Input width this head was trained for — must equal RouteFeatures.count
    /// or the head is stale (feature-contract change) and is not used.
    var inputWidth: Int { w1.first?.count ?? 0 }

    /// The head flat, as the bridge carries it: hidden count, b2, b1, w2, the
    /// row widths, then the rows (which may be ragged).
    var bridgeFlat: [Double] {
        [Double(w1.count), b2] + b1 + w2 + w1.map { Double($0.count) } + w1.flatMap { $0 }
    }

    /// A head from the bridge's flat form; nil for a buffer that is not one.
    static func weights(fromBridgeFlat flat: ArraySlice<Double>) -> (w1: [[Double]], b1: [Double], w2: [Double], b2: Double)? {
        var at = flat.startIndex
        func take(_ n: Int) -> [Double]? {
            guard n >= 0, at + n <= flat.endIndex else { return nil }
            defer { at += n }
            return Array(flat[at..<(at + n)])
        }
        guard let hidden = take(1)?.first.flatMap({ Int(exactly: $0) }), hidden >= 0,
              let b2 = take(1)?.first,
              let b1 = take(hidden), let w2 = take(hidden), let widths = take(hidden) else { return nil }
        var w1: [[Double]] = []
        for w in widths {
            guard let n = Int(exactly: w), let row = take(n) else { return nil }
            w1.append(row)
        }
        guard at == flat.endIndex else { return nil }
        return (w1, b1, w2, b2)
    }

    /// The forward pass: ReLU hidden layer, sigmoid output, tolerant of a
    /// corrupt or mismatched head file (it degrades, never crashes).
    func predict(_ x: [Double]) -> Double {
        // One buffer, `[n, x…, head…]`, so an empty input and a head with no
        // hidden units still cross as a non-empty buffer.
        let buffer = [Double(x.count)] + x + bridgeFlat
        return buffer.withUnsafeBufferPointer { flows_seasonal_head_predict($0) }
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
    /// SERIAL writer for persistence: snapshots are enqueued in call order
    /// and drain FIFO, so a later trip's write can never be clobbered by an
    /// earlier one landing late (the hazard of independent detached tasks).
    /// Off the main actor (arrival-render moment) but at default QoS, not
    /// .utility — .utility is deprioritized exactly when the app is being
    /// suspended, widening the window where a just-recorded trip is lost
    /// before its write drains.
    /// Shared with every other behaviour store so the erase button's key
    /// deletion cannot overtake a seal that is still queued.
    private var persistQueue: DispatchQueue { SecureBehaviorStore.persistQueue }

    /// Completes when the on-disk store and learned heads have loaded. The
    /// store decode grows with every recorded trip, and `.shared` is first
    /// touched inside route RANKING — decoding synchronously in this
    /// @MainActor init made the driver pay for it mid-plan. Reads before the
    /// load lands degrade to the statistical prior (the documented no-model
    /// behavior); MUTATIONS await it, so an arrival seconds after the first
    /// touch can't persist a one-trip store over the undecoded history.
    private var diskLoad: Task<Void, Never>?

    init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_seasonal_model.json")
        exportURL = dir.appendingPathComponent("flows_training_export.csv")
        headURL = dir.appendingPathComponent("flows_route_head.json")
        let storeURL = url
        let headFileURL = headURL
        diskLoad = Task.detached(priority: .utility) { [weak self] in
            // Sealed store, upgrading in place from any plaintext file an
            // earlier build left at this path.
            let loadedStore = SecureBehaviorStore.readMigrating(storeURL).flatMap {
                try? JSONDecoder().decode(SeasonalStore.self, from: $0)
            }
            let local = Self.decodeHead(SecureBehaviorStore.readMigrating(headFileURL))
            let bundled = Self.decodeHead(Bundle.main.url(
                forResource: "baseline_route_head", withExtension: "json")
                .flatMap { try? Data(contentsOf: $0) })
            await MainActor.run { [weak self] in
                guard let self else { return }
                // An erase that landed while this read must win: what was
                // read is the history the driver just erased, and putting it
                // back let the next arrival persist it under a fresh key.
                // Keep only the shipped baseline, and shred again in case the
                // read upgraded an old plaintext file after the erase's shred.
                guard self.eraseGeneration == 0 else {
                    self.applyHead(local: nil, bundled: bundled)
                    SecureBehaviorStore.persistQueue.async {
                        SecureBehaviorStore.shred(storeURL)
                        SecureBehaviorStore.shred(headFileURL)
                    }
                    return
                }
                if let loadedStore { self.store = loadedStore }
                self.applyHead(local: local, bundled: bundled)
            }
        }
    }

    nonisolated private static func decodeHead(_ data: Data?) -> LearnedHead? {
        guard let data,
              let h = try? JSONDecoder().decode(LearnedHead.self, from: data),
              h.inputWidth == RouteFeatures.count   // stale contract → unusable
        else { return nil }
        return h
    }

    /// Choose between the on-device head and the shipped baseline (trained
    /// on 20 years of NOAA Storm Events, 2005–2024, so a fresh install
    /// predicts from history, not zero).
    ///
    /// The local head is a warm-started FINE-TUNE of that baseline, anchored
    /// to it (RouteHeadTrainer) — so preferring it is refinement, not
    /// replacement, and the feature contract is identical by construction. A
    /// local head whose feature width is stale was already rejected at
    /// decode. The previous rule compared raw row counts, which a device
    /// head could never win against a 1.16M-row baseline; that made every
    /// locally-trained head dead on arrival.
    private func applyHead(local: LearnedHead?, bundled: LearnedHead?) {
        baselineHead = bundled
        // 1 the on-device head, 2 the bundled baseline, 0 none.
        switch flows_seasonal_choose_head(
            local != nil, Int64(local?.rows ?? 0), local?.rows != nil,
            local?.tunedOnDevice ?? false, local?.tunedOnDevice != nil,
            bundled != nil, Int64(bundled?.rows ?? 0), bundled?.rows != nil) {
        case 1: head = local
        case 2: head = bundled
        default: head = nil
        }
    }

    /// The untuned baseline, kept so a fine-tune always warm-starts from the
    /// national model rather than from the previous fine-tune (which would
    /// let drift compound across sessions).
    private var baselineHead: LearnedHead?

    /// Shared calendar: `Calendar(identifier:)` resolves locale/timezone on
    /// every construction, and week() runs twice per route ranking plus per
    /// map tick in the seasonal readout.
    nonisolated private static let gregorian = Calendar(identifier: .gregorian)

    /// Week-of-year 0…51 (ISO-ish: day-of-year / 7, clamped).
    nonisolated static func week(_ date: Date = Date()) -> Int {
        let day = Self.gregorian.ordinality(of: .day, in: .year, for: date)
        return Int(flows_seasonal_week_of_year(Int64(day ?? 0), day != nil))
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
        // REFINE, don't replace. This returned `head.predict(x)` and threw
        // `stat.risk` away, so the driver's own decaying-weighted
        // observations of THIS route never reached the ranking number —
        // they only gated its confidence. The model generalizes across
        // corridors; the direct observation is the ground truth for this
        // one, so confidence (which rises with the count of week-samples
        // for this exact route) decides how far to move from the model
        // toward what the driver actually met.
        let modeled = head.predict(x)
        return (flows_seasonal_blend_prior(modeled, stat.risk, stat.confidence), stat.confidence)
    }

    /// Fine-tune the head on this driver's history, warm-started from the
    /// shipped baseline and anchored to it. Runs OFF the main actor after an
    /// arrival, gated so it is a rare background cost: at least a day since
    /// the last tune and at least 5 new trips. A tune that scores WORSE than
    /// the baseline on the driver's own rows is discarded.
    func fineTuneHeadIfDue(now: Date = Date()) {
        guard let baseline = baselineHead else { return }
        let trips = store.totalTrips
        // At least 12 trips, a day since the last tune, and 5 new trips.
        guard flows_seasonal_tune_due(
            Int64(trips), lastTunedAt.map { now.timeIntervalSince($0) } ?? 0, lastTunedAt != nil,
            Int64(tunedAtTripCount)) else { return }
        lastTunedAt = now
        tunedAtTripCount = trips
        let rows = store.trainingRows(now: now.timeIntervalSince1970)
        let headURL = self.headURL
        let generation = eraseGeneration
        Task.detached(priority: .utility) { [weak self] in
            guard let tuned = RouteHeadTrainer.fineTune(base: baseline, rows: rows),
                  let tunedError = RouteHeadTrainer.meanSquaredError(tuned, rows: rows),
                  let baseError = RouteHeadTrainer.meanSquaredError(baseline, rows: rows),
                  flows_seasonal_accept_tune(tunedError, baseError)
            else {
                FlowsDiag.log(.info, "learning",
                              "route head fine-tune discarded — no improvement on own trips")
                return
            }
            // An erase while this trained must win: the rows it learned
            // from are gone. The save used to run here, off the persist
            // queue, and could land after the erase destroyed the key —
            // minting a fresh one and writing the trained model back,
            // readable — and the head came back in memory too. Checked on
            // the main actor, then sealed on the one persist queue, so an
            // erase after this point still runs its key delete after the
            // write (FIFO) and leaves only ciphertext nothing can open.
            await MainActor.run { [weak self] in
                guard let self, self.eraseGeneration == generation else { return }
                self.head = tuned
                SecureBehaviorStore.persistQueue.async {
                    SecureBehaviorStore.save(tuned, to: headURL)
                }
                FlowsDiag.log(.info, "learning", String(
                    format: "route head fine-tuned on %d rows (MSE %.4f → %.4f)",
                    rows.count, baseError, tunedError))
            }
        }
    }

    private var lastTunedAt: Date?
    /// Bumped by every erase; a fine-tune started before one is discarded.
    private var eraseGeneration = 0
    private var tunedAtTripCount = 0

    /// Plain-words summary of what the model has learned, for the Settings
    /// "What FLOWS has learned" section. Also the first consumer of the
    /// per-route calibration (`accuracy(for:)` and the `wSqErr` accumulator
    /// behind it), which was computed into storage and read by nothing.
    var learningSummary: (trips: Int, routes: Int, calibration: Double?, tuned: Bool) {
        let now = Date().timeIntervalSince1970
        let errors = store.routes.keys.compactMap { store.accuracy(for: $0, now: now) }
        // No routes is no calibration (and an empty buffer never crosses).
        let meanOpt = errors.isEmpty ? nil : errors.withUnsafeBufferPointer { flows_seasonal_mean_in_order($0) }
        let mean: Double? = (meanOpt?.is_some ?? 0) == 1 ? meanOpt?.value : nil
        return (store.totalTrips, store.routes.count, mean, head?.tunedOnDevice ?? false)
    }

    /// Erase everything learned about the driver and destroy the file.
    func eraseLearnedHistory() {
        eraseGeneration &+= 1
        store = SeasonalStore()
        lastTunedAt = nil
        tunedAtTripCount = 0
        SecureBehaviorStore.shred(url)
        SecureBehaviorStore.shred(exportURL)
        SecureBehaviorStore.shred(headURL)
        head = baselineHead   // back to the shipped national model
    }


    /// The learned home anchor (the most-frequent trip-origin cell) — the
    /// everyday POI cache centers its circle here. `nil` until an origin
    /// clears `homeMinTrips`.
    /// The learned home anchor, hysteresis-aware: the anchor currently in
    /// force is passed in so only a sustained relocation displaces it.
    func learnedHomeCoordinate(
        current: CLLocationCoordinate2D? = nil
    ) -> CLLocationCoordinate2D? {
        let incumbent = current.map {
            (lat: Int(($0.latitude * 10).rounded()), lon: Int(($0.longitude * 10).rounded()))
        }
        return store.learnedHome(currentHome: incumbent).map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
    }

    /// Record a completed trip's prediction vs. what was encountered, plus the
    /// per-edge history, then persist. Awaits the initial disk load first —
    /// recording into a store whose history hadn't decoded yet would persist
    /// a one-trip file over everything the driver ever recorded. Timestamps
    /// are captured NOW (at arrival), not when the task runs.
    func recordTrip(origin: CLLocationCoordinate2D, dest: CLLocationCoordinate2D,
                    predicted: Double, observed: Double, distanceKm: Double,
                    hubPath: [CLLocationCoordinate2D] = []) {
        let now = Date().timeIntervalSince1970
        let wk = Self.week()
        Task { [weak self] in
            guard let self else { return }
            await self.diskLoad?.value
            self.store.record(TripObservation(
                key: RouteKey(origin: origin, dest: dest), week: wk,
                predicted: predicted, observed: observed, distanceKm: distanceKm, t: now))
            if hubPath.count >= 2 {
                self.store.recordEdges(hubPath: hubPath, week: wk, observed: observed, t: now)
            }
            self.persist()
        }
    }

    private func persist() {
        // Snapshot the value-type store on the main actor (a true copy — no
        // shared ref), then encode + write on the serial persistQueue: the
        // encode/CSV cost grows with trip history and this fires at arrival,
        // the exact moment the arrived banner renders. FIFO ordering means
        // two quick trips can't clobber each other; the store write is done
        // FIRST (the durability-critical one) before the CSV export.
        let snapshot = store
        let url = self.url, exportURL = self.exportURL
        let now = Date().timeIntervalSince1970
        persistQueue.async {
            // ENCRYPTED AT REST: a trip history is a map of someone's life.
            // Sealed with the device-only Keychain key (SecureBehaviorStore);
            // decrypted only into memory, only while reading or training.
            if let data = try? JSONEncoder().encode(snapshot) {
                SecureBehaviorStore.write(data, to: url)
            }
            // Flat CSV training view for the trainer — the rawest rows the
            // app holds, so it is sealed too.
            let rows = snapshot.trainingRows(now: now)
            var csv = "oLat,oLon,dLat,dLon,week,target,weight,crossCountry\n"
            for r in rows {
                csv += "\(r["oLat"] ?? 0),\(r["oLon"] ?? 0),\(r["dLat"] ?? 0),\(r["dLon"] ?? 0),"
                csv += "\(Int(r["week"] ?? 0)),\(r["target"] ?? 0),\(r["weight"] ?? 0),"
                csv += "\(Int(r["crossCountry"] ?? 0))\n"
            }
            if let csvData = csv.data(using: .utf8) {
                SecureBehaviorStore.write(csvData, to: exportURL)
            }
        }
    }
}
