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

/// The live hazard feeds, fetched once for an area, scored per point.
///
/// The map sweep and the route scorer used to differ here: the sweep scored
/// every grid point against fire perimeters and hotspots, earthquakes, space
/// weather, volcanoes, avalanche zones, tropical storms, tsunami events and
/// the SPC outlook, while the route scorer saw none of them — so a route
/// through an active wildfire with no NWS alert was not Red while the map
/// beside it was. Both now score through `HazardFeedScores.live`, from one
/// snapshot per area, and the route folds the result into the same two-tier
/// band input the map uses.
struct LiveHazardSnapshot: Sendable {
    typealias Point = CLLocationCoordinate2D
    var hotspots: [(lat: Double, lon: Double, frp: Double)]
    var perimeters: [[Point]]
    var quakes: [(lat: Double, lon: Double, magnitude: Double, ageHours: Double)]
    var space: (r: Int, s: Int, g: Int)
    var volcanoes: [(lat: Double, lon: Double, level: String)]
    var avalancheZones: [(rings: [[Point]], rating: Int)]
    var storms: [(lat: Double, lon: Double, maxWindKt: Double)]
    var tsunamis: [(lat: Double, lon: Double, level: String)]
    var spcZones: [(rings: [[Point]], score: Double)]

    /// The feeds as the Rust scorer holds them (rust/flows-core hazard_feeds.rs
    /// through rust/flows-bridge), built once here so every per-point score
    /// reads them in place, never copied per sample. Nothing mutates the
    /// handle after this init, which is what makes the struct safe to hand
    /// between the fetcher and the actors that score (`RustShared`). Pinned to
    /// the original by rust/flows-bridge/tests/fixtures/swift_hazard_feeds_oracle.tsv.
    private let shared: RustShared<FlowsHazardSnapshot>
    var handle: FlowsHazardSnapshot { shared.handle }

    init(
        hotspots: [(lat: Double, lon: Double, frp: Double)] = [],
        perimeters: [[Point]] = [],
        quakes: [(lat: Double, lon: Double, magnitude: Double, ageHours: Double)] = [],
        space: (r: Int, s: Int, g: Int) = (0, 0, 0),
        volcanoes: [(lat: Double, lon: Double, level: String)] = [],
        avalancheZones: [(rings: [[Point]], rating: Int)] = [],
        storms: [(lat: Double, lon: Double, maxWindKt: Double)] = [],
        tsunamis: [(lat: Double, lon: Double, level: String)] = [],
        spcZones: [(rings: [[Point]], score: Double)] = []
    ) {
        self.hotspots = hotspots
        self.perimeters = perimeters
        self.quakes = quakes
        self.space = space
        self.volcanoes = volcanoes
        self.avalancheZones = avalancheZones
        self.storms = storms
        self.tsunamis = tsunamis
        self.spcZones = spcZones
        let h = flows_hazard_snapshot_new()
        if !hotspots.isEmpty {
            HazardFeedScores.three(hotspots.map { $0.lat }, hotspots.map { $0.lon }, hotspots.map { $0.frp }) {
                h.add_hotspots($0, $1, $2)
            }
        }
        if !perimeters.isEmpty {
            let flat = HazardFeedScores.flatten(perimeters)
            flat.lens.lent { lens in HazardFeedScores.two(flat.lats, flat.lons) { h.add_perimeters(lens, $0, $1) } }
        }
        if !quakes.isEmpty {
            let ages = quakes.map { $0.ageHours }
            HazardFeedScores.three(quakes.map { $0.lat }, quakes.map { $0.lon }, quakes.map { $0.magnitude }) {
                la, lo, mag in
                ages.lent { h.add_quakes(la, lo, mag, $0) }
            }
        }
        h.set_space(Int64(space.r), Int64(space.s), Int64(space.g))
        if !volcanoes.isEmpty {
            HazardFeedScores.two(volcanoes.map { $0.lat }, volcanoes.map { $0.lon }) {
                h.add_volcanoes($0, $1, HazardFeedScores.joined(volcanoes.map { $0.level }))
            }
        }
        if !avalancheZones.isEmpty {
            let counts = avalancheZones.map { Int64($0.rings.count) }
            let ratings = avalancheZones.map { Int64($0.rating) }
            let flat = HazardFeedScores.flatten(avalancheZones.flatMap { $0.rings })
            counts.lent { zc in
                ratings.lent { rt in
                    flat.lens.lent { lens in
                        HazardFeedScores.two(flat.lats, flat.lons) { h.add_avalanche_zones(zc, rt, lens, $0, $1) }
                    }
                }
            }
        }
        if !storms.isEmpty {
            HazardFeedScores.three(storms.map { $0.lat }, storms.map { $0.lon }, storms.map { $0.maxWindKt }) {
                h.add_storms($0, $1, $2)
            }
        }
        if !tsunamis.isEmpty {
            HazardFeedScores.two(tsunamis.map { $0.lat }, tsunamis.map { $0.lon }) {
                h.add_tsunamis($0, $1, HazardFeedScores.joined(tsunamis.map { $0.level }))
            }
        }
        if !spcZones.isEmpty {
            let counts = spcZones.map { Int64($0.rings.count) }
            let scores = spcZones.map { $0.score }
            let flat = HazardFeedScores.flatten(spcZones.flatMap { $0.rings })
            counts.lent { zc in
                scores.lent { sc in
                    flat.lens.lent { lens in
                        HazardFeedScores.two(flat.lats, flat.lons) { h.add_spc_zones(zc, sc, lens, $0, $1) }
                    }
                }
            }
        }
        shared = RustShared(h)
    }

    /// A snapshot the Rust side produced (a clip): its lists are read back
    /// so the fields stay inspectable.
    private init(handle: FlowsHazardSnapshot) {
        shared = RustShared(handle)
        let hot = Array(handle.hotspots_flat())
        hotspots = stride(from: 0, to: hot.count - 2, by: 3).map { (lat: hot[$0], lon: hot[$0 + 1], frp: hot[$0 + 2]) }
        perimeters = Self.rings(Array(handle.perimeters_flat()))
        let q = Array(handle.quakes_flat())
        quakes = stride(from: 0, to: q.count - 3, by: 4).map {
            (lat: q[$0], lon: q[$0 + 1], magnitude: q[$0 + 2], ageHours: q[$0 + 3])
        }
        let sp = Array(handle.space())
        space = sp.count == 3 ? (r: Int(sp[0]), s: Int(sp[1]), g: Int(sp[2])) : (0, 0, 0)
        let v = Array(handle.volcanoes_flat())
        let vl = handle.volcano_levels().map { $0.text }
        volcanoes = zip(stride(from: 0, to: v.count - 1, by: 2), vl).map { (lat: v[$0], lon: v[$0 + 1], level: $1) }
        avalancheZones = zip(Self.zones(Array(handle.avalanche_zones_flat())), Array(handle.avalanche_ratings())).map {
            (rings: $0, rating: Int($1))
        }
        let st = Array(handle.storms_flat())
        storms = stride(from: 0, to: st.count - 2, by: 3).map { (lat: st[$0], lon: st[$0 + 1], maxWindKt: st[$0 + 2]) }
        let t = Array(handle.tsunamis_flat())
        let tl = handle.tsunami_levels().map { $0.text }
        tsunamis = zip(stride(from: 0, to: t.count - 1, by: 2), tl).map { (lat: t[$0], lon: t[$0 + 1], level: $1) }
        spcZones = zip(Self.zones(Array(handle.spc_zones_flat())), Array(handle.spc_scores())).map {
            (rings: $0, score: $1)
        }
    }

    /// Rings from the bridge's flat form: `[n, len_1…len_n, lat, lon…]`.
    static func decodeRings(_ flat: [Double]) -> [[Point]] { rings(flat) }

    private static func rings(_ flat: [Double]) -> [[Point]] {
        guard let first = flat.first else { return [] }
        let n = Int(first)
        guard n >= 0, flat.count >= 1 + n else { return [] }
        var at = 1 + n
        return (0..<n).map { k in
            let len = Int(flat[1 + k])
            var ring: [Point] = []
            for _ in 0..<max(len, 0) where at + 1 < flat.count {
                ring.append(Point(latitude: flat[at], longitude: flat[at + 1]))
                at += 2
            }
            return ring
        }
    }

    /// Zones from the bridge's flat form: `[n, rings_1…rings_n, <flat rings>]`.
    private static func zones(_ flat: [Double]) -> [[[Point]]] {
        guard let first = flat.first else { return [] }
        let n = Int(first)
        guard n >= 0, flat.count >= 1 + n else { return [] }
        let all = rings(Array(flat[(1 + n)...]))
        var at = 0
        return (0..<n).map { k in
            let count = max(Int(flat[1 + k]), 0)
            let zone = Array(all[at..<min(at + count, all.count)])
            at += count
            return zone
        }
    }

    static let empty = LiveHazardSnapshot()

    /// The widest influence any scorer has: `tsunamiScore` reaches 500 km.
    /// Six degrees of latitude is 667 km, and six degrees of longitude is at
    /// least 500 km anywhere south of 41° N. North of that a degree of
    /// longitude is shorter, so the clip widens its east and west margin to
    /// stay 500 km wide: it keeps every point that could score.
    static let clipMarginDegrees = flows_hazard_clip_margin_degrees()

    /// The same snapshot with every point or ring that cannot influence a
    /// score inside the box removed — one linear pass in Rust. It changes no
    /// score: a point farther than the margin from the box is farther than
    /// any scorer's radius from every sample in it.
    func clipped(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) -> LiveHazardSnapshot {
        LiveHazardSnapshot(handle: handle.clipped(minLat, minLon, maxLat, maxLon))
    }
}

extension LiveHazardFeedFetcher {
    /// Every live feed the map sweep uses, fetched concurrently and clipped
    /// to the box. Each fetch is cached by its own TTL inside the fetcher, so
    /// a second call for a nearby box is cheap.
    func liveSnapshot(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)
        async -> LiveHazardSnapshot
    {
        async let hotspots = hotspots()
        async let quakes = recentQuakes()
        async let perimeters = firePerimeters(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
        async let space = spaceWeather()
        async let volcanoes = elevatedVolcanoes()
        async let avalanche = avalanche()
        async let storms = tropicalStorms()
        async let tsunamis = tsunamiEvents()
        async let spc = convectiveOutlook()
        let snap = LiveHazardSnapshot(
            hotspots: await hotspots, perimeters: await perimeters, quakes: await quakes,
            space: await space, volcanoes: await volcanoes, avalancheZones: await avalanche,
            storms: await storms, tsunamis: await tsunamis, spcZones: await spc)
        return snap.clipped(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
    }
}

extension HazardFeedScores {
    /// One point's raw score from each live feed. Every field is the exact
    /// expression the map sweep evaluated inline before this existed, so the
    /// map's numbers are unchanged and the route gets the same ones.
    struct LiveFamilies: Equatable {
        var fire: Double
        var seismic: Double
        /// Space weather only; the sweep adds the per-point UV reading itself.
        var spaceRadiation: Double
        var volcanic: Double
        var avalanche: Double
        var tropical: Double
        var tsunami: Double
        var convective: Double

        /// The families this point's live feeds put into the two-tier band
        /// input — only those that registered. Merged by max per key, so the
        /// order they are read in cannot reach a product.
        var bandInputContribution: [String: Double] {
            var out: [String: Double] = [:]
            if fire > 0 { out["fire"] = fire }
            if seismic > 0 { out["seismic"] = seismic }
            if spaceRadiation > 0 { out["radiation"] = spaceRadiation }
            if volcanic > 0 { out["volcanic"] = volcanic }
            if avalanche > 0 { out["avalanche"] = avalanche }
            if tropical > 0 { out["tropical"] = tropical }
            if tsunami > 0 { out["tsunami"] = tsunami }
            if convective > 0 { out["convective"] = convective }
            return out
        }
    }

    /// One point's score from every live feed, read from the snapshot's Rust
    /// handle in place — the same numbers the map sweep and the route get.
    static func live(at pt: CLLocationCoordinate2D, snapshot s: LiveHazardSnapshot) -> LiveFamilies {
        liveChecked(at: pt, snapshot: s)
            ?? LiveFamilies(
                fire: 0, seismic: 0, spaceRadiation: 0, volcanic: 0,
                avalanche: 0, tropical: 0, tsunami: 0, convective: 0)
    }

    /// The same, or nil when the scorer gave no answer (it failed inside
    /// Rust and sent back nothing). No answer is not "nothing there": the
    /// route and the map treat the point as unchecked.
    static func liveChecked(
        at pt: CLLocationCoordinate2D,
        snapshot s: LiveHazardSnapshot
    ) -> LiveFamilies? {
        let v = s.handle.live(pt.latitude, pt.longitude)
        guard v.len() == 8 else { return nil }
        return LiveFamilies(
            fire: v[0], seismic: v[1], spaceRadiation: v[2], volcanic: v[3],
            avalanche: v[4], tropical: v[5], tsunami: v[6], convective: v[7])
    }
}

/// The corridor blend: every check point of a road scored with the SAME
/// two-tier equation the map uses (`RiskEquations.realizedRisk` over
/// `RiskEquations.bandInput`). The modeled ZIP field and the on-device
/// forecast are predictors; an in-progress-danger alert, a reported closure
/// and the live feeds are what can reach Red.
///
/// One call scores a whole list of check points, so the planner, the live
/// corridor watch and the route card's progress all band alike. What a
/// caller does not have, it leaves out: no forecasts means no forecast
/// predictors and no flood amplifier, no snapshot means no live feeds.
enum RouteBlend {
    struct Answer: Sendable {
        /// One realized risk per check point, in order.
        var risks: [Double]
        /// The worst reading per family along the road (the route filters
        /// and the route card's live-hazard name read these).
        var peaks: [String: Double]
        /// The sum of the ZIP field's "environmental" score over the points.
        var identifiedSum: Double
        /// A point the live scorer could not answer: not a clear point.
        var liveUnchecked: Bool
    }

    /// The route filters' families, in the order their peaks are read.
    static let filterFamilies = ["wind", "qpf_flood", "winter", "convective"]

    static func blend(
        samples: [RiskSample],
        onDevice: [Int: (ForecastConditions, Double?)] = [:],
        field: RiskField?,
        gauges: HazardFeedScores.PreparedGauges? = nil,
        water: HazardFeedScores.PreparedPoints? = nil,
        closures: HazardFeedScores.PreparedPoints? = nil,
        live snapshot: LiveHazardSnapshot? = nil
    ) -> Answer {
        var peaks: [String: Double] = [:]
        func nearestOnDevice(_ i: Int) -> (ForecastConditions, Double?)? {
            // Nearest fetched sample (they're every other one).
            let candidates = [i, i - 1, i + 1, i - 2, i + 2].filter { onDevice[$0] != nil }
            return candidates.first.flatMap { onDevice[$0] }
        }
        // A sample with no forecast of its own borrows its neighbour's: the
        // pair would work the same point out twice, so each point is done once.
        var predictorsAt: [Int: [String: Double]] = [:]
        func onDevicePredictors(near i: Int) -> [String: Double] {
            let candidates = [i, i - 1, i + 1, i - 2, i + 2].filter { onDevice[$0] != nil }
            guard let j = candidates.first, let (c, elev) = onDevice[j] else { return [:] }
            if let done = predictorsAt[j] { return done }
            let coord = samples[j].coordinate
            let made = c.predictorFamilies(
                latitude: coord.latitude, longitude: coord.longitude,
                elevationMeters: elev)
            predictorsAt[j] = made
            return made
        }

        // WINDOWED local minimum elevation: the nearby pooling low, NOT the
        // corridor-global low (which on a long/mountain route sits hundreds of
        // km away and breaks "local minimum waterline"). Min over the fetched
        // elevations within ±4 samples of the query point.
        let elevBySample: [Int: Double?] = onDevice.mapValues(\.1)
        func localMinElevation(near i: Int) -> Double? {
            var lo: Double?
            for j in max(i - 4, 0)...min(i + 4, max(samples.count - 1, 0)) {
                if let e = elevBySample[j] ?? nil { lo = lo.map { Swift.min($0, e) } ?? e }
            }
            return lo
        }

        // Family indices are loop-invariant — resolve once, not per sample.
        let envIdx = field?.familyIndex("environmental")
        let filterIdx = filterFamilies.map { ($0, field?.familyIndex($0)) }
        var identifiedSum = 0.0
        var liveUnchecked = false
        let risks = samples.enumerated().map { i, s -> Double in
            let c = s.coordinate
            let dev = onDevicePredictors(near: i)
            let near = nearestOnDevice(i)
            // One nearest-ZIP row per sample, shared by the filter peaks, the
            // identified-exposure accumulation and the band input below.
            let row = field.flatMap { f in f.nearest(c).map { f.scores(at: $0) } }
            func rowScore(_ fi: Int?) -> Double {
                guard let row, let fi, fi < row.count else { return 0 }
                return row[fi]
            }
            identifiedSum += rowScore(envIdx)
            // Evidence gate = noisy-OR of a gauge in flood and mapped water near.
            let gaugeEvid = gauges.map { HazardFeedScores.floodGaugeScore(prepared: $0, at: c) } ?? 0
            let waterEvid = water.map { HazardFeedScores.waterProximityScore(prepared: $0, at: c) } ?? 0
            let floodEvidence = 1 - (1 - gaugeEvid) * (1 - waterEvid)
            let floodMult = RiskEquations.floodElevationMultiplier(
                sampleElevation: near?.1, localMinElevation: localMinElevation(near: i),
                qpfInches: near?.0.qpfInches, supportingEvidence: floodEvidence)
            // Route filters track per-family peaks (display): worse of the ZIP
            // export and the on-device forecast decomposition.
            for (fam, fi) in filterIdx {
                let deviceKey = fam == "qpf_flood" ? "precip" : fam
                let v = max(rowScore(fi), dev[deviceKey] ?? 0)
                if v > (peaks[fam] ?? 0) { peaks[fam] = v }
            }
            // Live feeds: a fire perimeter or a fresh epicentre on the route
            // is a realized primary here exactly as it is on the map, and its
            // peak reaches the route card so the card can name it.
            // A point the live scorer could not answer is not a clear point.
            var live: [String: Double] = [:]
            if let snapshot {
                let liveAnswer = HazardFeedScores.liveChecked(at: c, snapshot: snapshot)
                if liveAnswer == nil { liveUnchecked = true }
                live = liveAnswer?.bandInputContribution ?? [:]
            }
            for (fam, v) in live where v > (peaks[fam] ?? 0) { peaks[fam] = v }
            func fieldScore(_ fam: String) -> Double {
                guard let row, let fi = field?.familyIndex(fam), fi < row.count else { return 0 }
                return row[fi]
            }
            // The assembly itself is RiskEquations.bandInput — Core, tested.
            return RiskEquations.realizedRisk(
                RiskEquations.bandInput(
                    field: fieldScore, onDevice: dev,
                    alertEvent: s.worstEvent, alertSeverity: s.risk,
                    floodMultiplier: floodMult,
                    closureScore: closures.map { HazardFeedScores.closureScore(prepared: $0, at: c) } ?? 0,
                    live: live))
        }
        return Answer(
            risks: risks, peaks: peaks, identifiedSum: identifiedSum, liveUnchecked: liveUnchecked)
    }
}
