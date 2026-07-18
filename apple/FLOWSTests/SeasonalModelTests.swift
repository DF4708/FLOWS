// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The on-device seasonal prediction foundation (`SeasonalStore`) and the
/// two-truths route ranking. Uses explicit times so the exponential decay is
/// deterministic.
final class SeasonalModelTests: XCTestCase {
    private let base = 1_000_000.0     // arbitrary epoch base
    private let week = 7.0 * 24 * 3600 // one week in seconds

    private func key(_ o: (Double, Double), _ d: (Double, Double)) -> RouteKey {
        RouteKey(origin: CLLocationCoordinate2D(latitude: o.0, longitude: o.1),
                 dest: CLLocationCoordinate2D(latitude: d.0, longitude: d.1))
    }
    private func obs(_ k: RouteKey, week wk: Int, pred: Double, obs o: Double,
                     km: Double, t: Double) -> TripObservation {
        TripObservation(key: k, week: wk, predicted: pred, observed: o, distanceKm: km, t: t)
    }

    // A LOCAL route isn't modeled until it crosses localTripThreshold trips.
    func testLocalFrequencyGate() {
        var s = SeasonalStore()
        let k = key((43.0, -89.4), (43.1, -89.3))     // ~11 km → local
        for i in 0..<(SeasonalStore.localTripThreshold - 1) {
            s.record(obs(k, week: 10, pred: 0.3, obs: 0.3, km: 12, t: base + Double(i) * week))
        }
        XCTAssertFalse(s.isModeled(k))
        XCTAssertNil(s.seasonalPrior(for: k, week: 10, now: base))
        s.record(obs(k, week: 10, pred: 0.3, obs: 0.3, km: 12, t: base + 10 * week))
        XCTAssertTrue(s.isModeled(k))
        XCTAssertNotNil(s.seasonalPrior(for: k, week: 10, now: base + 10 * week))
    }

    // Cross-country routes cross the gate on FEWER repeats — rare but valuable.
    func testCrossCountryLowerGate() {
        var s = SeasonalStore()
        let k = key((25.8, -80.2), (41.9, -87.6))     // Miami→Chicago
        for i in 0..<SeasonalStore.crossCountryTripThreshold {
            s.record(obs(k, week: 5, pred: 0.5, obs: 0.5, km: 2000, t: base + Double(i) * week))
        }
        XCTAssertTrue(s.isModeled(k))
        XCTAssertLessThan(SeasonalStore.crossCountryTripThreshold, SeasonalStore.localTripThreshold)
    }

    // Decay: a recent observation outweighs a 2-year-old one → mean leans recent.
    func testDecayWeightsRecentMore() {
        var s = SeasonalStore()
        let k = key((40.0, -100.0), (48.0, -100.0))   // cross-country (gate 2)
        s.record(obs(k, week: 20, pred: 0.1, obs: 0.1, km: 900, t: base))
        s.record(obs(k, week: 20, pred: 0.9, obs: 0.9, km: 900, t: base + 104 * week))
        let prior = s.seasonalPrior(for: k, week: 20, now: base + 104 * week)
        XCTAssertNotNil(prior)
        // 52-week half-life: the 2-yr-old 0.1 is worth ¼ of the fresh 0.9.
        XCTAssertGreaterThan(prior!.risk, 0.6)
    }

    // Seasonal buckets stay separate: a summer week ≠ a fall week.
    func testSeasonalBucketsSeparate() {
        var s = SeasonalStore()
        let k = key((30.0, -95.0), (40.0, -95.0))     // cross-country
        for i in 0..<4 { s.record(obs(k, week: 20, pred: 0.8, obs: 0.8, km: 800, t: base + Double(i) * week)) }
        for i in 0..<4 { s.record(obs(k, week: 40, pred: 0.2, obs: 0.2, km: 800, t: base + Double(10 + i) * week)) }
        XCTAssertGreaterThan(s.seasonalPrior(for: k, week: 20, now: base + 20 * week)!.risk, 0.7)
        XCTAssertLessThan(s.seasonalPrior(for: k, week: 40, now: base + 20 * week)!.risk, 0.3)
    }

    // Confidence scales with sample count, saturating at the threshold.
    func testConfidenceScalesWithSamples() {
        var s = SeasonalStore()
        let k = key((35.0, -110.0), (45.0, -110.0))   // cross-country
        s.record(obs(k, week: 15, pred: 0.5, obs: 0.5, km: 800, t: base))
        s.record(obs(k, week: 15, pred: 0.5, obs: 0.5, km: 800, t: base))
        XCTAssertLessThan(s.seasonalPrior(for: k, week: 15, now: base)!.confidence, 1.0)
        for _ in 0..<5 { s.record(obs(k, week: 15, pred: 0.5, obs: 0.5, km: 800, t: base)) }
        XCTAssertEqual(s.seasonalPrior(for: k, week: 15, now: base)!.confidence, 1.0, accuracy: 1e-9)
    }

    // Accuracy (decaying-weighted RMSE): perfect → ~0, wrong → high.
    func testAccuracyRMSE() {
        var s = SeasonalStore()
        let good = key((40.0, -74.0), (40.5, -74.0))
        let bad = key((34.0, -118.0), (34.5, -118.0))
        for i in 0..<SeasonalStore.localTripThreshold {
            s.record(obs(good, week: 1, pred: 0.4, obs: 0.4, km: 20, t: base + Double(i) * week))
            s.record(obs(bad, week: 1, pred: 0.1, obs: 0.9, km: 20, t: base + Double(i) * week))
        }
        XCTAssertEqual(s.accuracy(for: good, now: base)!, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(s.accuracy(for: bad, now: base)!, 0.5)
    }

    // Hub/edge graph accumulates per road segment (the GNN substrate).
    func testEdgeGraphAccumulates() {
        var s = SeasonalStore()
        let path = [CLLocationCoordinate2D(latitude: 40.00, longitude: -83.0),
                    CLLocationCoordinate2D(latitude: 40.02, longitude: -83.0),
                    CLLocationCoordinate2D(latitude: 40.04, longitude: -83.0)]
        s.recordEdges(hubPath: path, week: 3, observed: 0.6, t: base)
        XCTAssertEqual(s.edges.count, 2)              // two edges among three hubs
        for (_, er) in s.edges { XCTAssertEqual(er.weeks[3]?.mean ?? -1, 0.6, accuracy: 1e-9) }
    }

    // Codable round-trip — the referable on-device persistence.
    func testCodableRoundTrip() throws {
        var s = SeasonalStore()
        let k = key((43.0, -89.0), (44.0, -88.0))
        for i in 0..<3 { s.record(obs(k, week: 8, pred: 0.5, obs: 0.55, km: 800, t: base + Double(i) * week)) }
        s.recordEdges(hubPath: [CLLocationCoordinate2D(latitude: 43.0, longitude: -89.0),
                                CLLocationCoordinate2D(latitude: 43.1, longitude: -89.0)],
                      week: 8, observed: 0.5, t: base)
        let back = try JSONDecoder().decode(
            SeasonalStore.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(back.routes[k]?.tripCount, 3)
        XCTAssertEqual(back.edges.count, 1)
    }

    // Two-truths ranking: identified ZIP risk raises rank even with no alert; a
    // realized Red dominates; the learned prior takes over as confidence → 1.
    func testRankingRiskTwoTruths() {
        let cleanBand = RiskEquations.rankingRisk(band: 0.1, zipExposure: 0.0)
        let riskyZips = RiskEquations.rankingRisk(band: 0.1, zipExposure: 0.9)
        XCTAssertGreaterThan(riskyZips, cleanBand + 0.2, "identified ZIP risk must raise the rank")
        XCTAssertGreaterThanOrEqual(RiskEquations.rankingRisk(band: 0.95, zipExposure: 0.0), 0.95,
                                    "a realized Red dominates")
        let fieldDriven = RiskEquations.rankingRisk(band: 0.1, zipExposure: 0.8,
                                                    seasonalPrior: 0.1, priorConfidence: 0.0)
        let priorDriven = RiskEquations.rankingRisk(band: 0.1, zipExposure: 0.8,
                                                    seasonalPrior: 0.1, priorConfidence: 1.0)
        XCTAssertGreaterThan(fieldDriven, priorDriven, "a confident calmer prior must lower the rank")
    }

    // The learned head decodes the worker's JSON (extra keys ignored) and its
    // forward pass (relu → sigmoid) matches a hand computation — the cross-
    // language contract with ml/route-gnn/train_worker.py.
    func testLearnedHeadDecodeAndForward() throws {
        let json = """
        {"w1":[[1,0,0,0,0,0],[0,1,0,0,0,0]],"b1":[0,0],"w2":[1,1],"b2":0,
         "version":3,"in":6,"hidden":2}
        """.data(using: .utf8)!
        let head = try JSONDecoder().decode(LearnedHead.self, from: json)
        XCTAssertEqual(head.version, 3)
        // x=[0.5,-0.5,…]: h=[relu(0.5)=0.5, relu(-0.5)=0]; out=0.5; sigmoid(0.5).
        XCTAssertEqual(head.predict([0.5, -0.5, 0.3, 0.4, 0.2, 1]),
                       1 / (1 + exp(-0.5)), accuracy: 1e-9)
    }

    // Feature vector shape/order matches the trainer's `features(...)` — the
    // v2 contract with longitudes (the Phoenix-vs-Moore fix).
    func testRouteFeatureVector() {
        let x = RouteFeatures.vector(oLat: 43, oLon: -89, dLat: 44, dLon: -88,
                                     week: 0, crossCountry: false)
        XCTAssertEqual(x.count, RouteFeatures.count)
        XCTAssertEqual(RouteFeatures.count, 8)
        XCTAssertEqual(x[0], 0, accuracy: 1e-9)            // sin(0)
        XCTAssertEqual(x[1], 1, accuracy: 1e-9)            // cos(0)
        XCTAssertEqual(x[2], 43.0 / 90, accuracy: 1e-9)    // oLat/90
        XCTAssertEqual(x[4], -89.0 / 180, accuracy: 1e-9)  // v2: origin lon
        XCTAssertEqual(x[5], -88.0 / 180, accuracy: 1e-9)  // v2: dest lon
        XCTAssertEqual(x[7], 0)                            // crossCountry (tail)
        // Same latitude, different longitude must differ (desert ≠ tornado alley).
        let phx = RouteFeatures.vector(oLat: 33.45, oLon: -112.07, dLat: 33.45,
                                       dLon: -112.07, week: 26, crossCountry: false)
        let moore = RouteFeatures.vector(oLat: 33.45, oLon: -97.49, dLat: 33.45,
                                         dLon: -97.49, week: 26, crossCountry: false)
        XCTAssertNotEqual(phx, moore)
    }

    // Learned home = the most-frequent trip origin, once past the threshold.
    func testLearnedHome() {
        var s = SeasonalStore()
        let home = (43.07, -89.40)   // quantizes to (43.1, -89.4)
        for d in [(43.2, -89.2), (44.0, -88.0), (42.5, -90.1)] {
            let k = key(home, d)
            for i in 0..<SeasonalStore.homeMinTrips {
                s.record(obs(k, week: i % 52, pred: 0.3, obs: 0.3, km: 30, t: base + Double(i) * week))
            }
        }
        // A rare origin must not win.
        let other = key((30.0, -95.0), (31.0, -95.0))
        for i in 0..<2 { s.record(obs(other, week: 5, pred: 0.4, obs: 0.4, km: 80, t: base + Double(i) * week)) }
        let lh = s.learnedHome()
        XCTAssertNotNil(lh)
        XCTAssertEqual(lh!.lat, 43.1, accuracy: 0.001)
        XCTAssertEqual(lh!.lon, -89.4, accuracy: 0.001)
        XCTAssertEqual(lh!.trips, 3 * SeasonalStore.homeMinTrips)
    }

    func testLearnedHomeNilBelowThreshold() {
        var s = SeasonalStore()
        let k = key((40.0, -100.0), (41.0, -100.0))
        for i in 0..<(SeasonalStore.homeMinTrips - 1) {
            s.record(obs(k, week: 0, pred: 0.3, obs: 0.3, km: 30, t: base + Double(i) * week))
        }
        XCTAssertNil(s.learnedHome())
    }
}
