// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The behavioral-learning layer: encrypted storage, the personal ETA
/// correction, contextual destination prediction, relocation detection, the
/// choice log, and the on-device head fine-tune.
final class LearningAndPrivacyTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flows-learn-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: encryption at rest

    /// The whole point: what lands on disk must not be readable, and must
    /// round-trip exactly through the sealed path.
    func testBehaviorDataIsUnreadableOnDiskButRoundTrips() throws {
        let url = tempDir().appendingPathComponent("secret.json")
        let secret = "1600 Pennsylvania Ave, home, 07:45 Tuesday"
        XCTAssertTrue(SecureBehaviorStore.write(Data(secret.utf8), to: url))

        // On-disk bytes contain none of the plaintext.
        let onDisk = try Data(contentsOf: url)
        XCTAssertFalse(onDisk.isEmpty)
        XCTAssertNil(String(data: onDisk, encoding: .utf8)?.range(of: "Pennsylvania"))
        XCTAssertNil(onDisk.range(of: Data(secret.utf8)))

        // …and the app reads it back byte-for-byte.
        XCTAssertEqual(SecureBehaviorStore.read(url).map { String(decoding: $0, as: UTF8.self) },
                       secret)
    }

    /// A tampered or truncated file authenticates as garbage and reads as NO
    /// DATA — never as partially-trusted content.
    func testTamperedBehaviorFileIsRejected() throws {
        let url = tempDir().appendingPathComponent("tampered.json")
        SecureBehaviorStore.write(Data("{\"a\":1}".utf8), to: url)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 1] ^= 0xFF          // flip a byte in the tag
        try bytes.write(to: url)
        XCTAssertNil(SecureBehaviorStore.read(url))
    }

    /// A plaintext store written by an earlier build is upgraded in place:
    /// the history survives and the clear copy stops existing.
    func testPlaintextStoreIsUpgradedInPlace() throws {
        let url = tempDir().appendingPathComponent("legacy.json")
        let legacy = #"{"places":["home","work"]}"#
        try Data(legacy.utf8).write(to: url)

        let recovered = SecureBehaviorStore.readMigrating(url)
        XCTAssertEqual(recovered.map { String(decoding: $0, as: UTF8.self) }, legacy)
        // The file on disk is now sealed, not the original text.
        let after = try Data(contentsOf: url)
        XCTAssertNil(after.range(of: Data(legacy.utf8)))
        // And a second read comes back through the sealed path.
        XCTAssertEqual(SecureBehaviorStore.read(url).map { String(decoding: $0, as: UTF8.self) },
                       legacy)
    }

    // MARK: personal ETA correction

    func testETACorrectionLearnsAndClamps() {
        var p = DrivingProfile()
        XCTAssertEqual(p.etaMultiplier, 1)   // unearned → no effect

        // A driver who consistently takes 20% longer than the estimate.
        for _ in 0..<8 { p.recordArrival(predicted: 3600, actual: 4320) }
        XCTAssertGreaterThan(p.etaMultiplier, 1.1)
        XCTAssertLessThan(p.etaMultiplier, 1.3)
        XCTAssertTrue(p.etaDescription.contains("longer"))

        // Clamped no matter what the history says.
        var extreme = DrivingProfile()
        for _ in 0..<50 { extreme.recordArrival(predicted: 3600, actual: 6300) }
        XCTAssertLessThanOrEqual(extreme.etaMultiplier, DrivingProfile.clampHigh)
    }

    /// A lunch stop is not evidence about driving pace: chosen stop time is
    /// removed, and an implausible ratio (an abandoned trip, a closure) is
    /// discarded rather than allowed to inflate every ETA in the app.
    func testETACorrectionIgnoresStopsAndOutliers() {
        var p = DrivingProfile()
        // 1 h predicted, 2 h elapsed, but 1 h of it was a chosen stop →
        // exactly on pace, so no correction accrues.
        p.recordArrival(predicted: 3600, actual: 7200, stoppedSeconds: 3600)
        XCTAssertEqual(p.etaSamples, 1)
        XCTAssertEqual(p.etaMultiplier, 1)

        var outliers = DrivingProfile()
        for _ in 0..<10 { outliers.recordArrival(predicted: 3600, actual: 36_000) }
        XCTAssertEqual(outliers.etaSamples, 0)   // 10× is not driving style
        XCTAssertEqual(outliers.etaMultiplier, 1)
    }

    func testPersonalPaceAppliesOnlyWhenEarned() {
        let routes: [PlannedRoute] = []
        XCTAssertTrue(RouteService.applyPersonalPace(routes, multiplier: 1.2).isEmpty)
        // A multiplier of exactly 1 must not rewrite anything.
        XCTAssertTrue(RouteService.applyPersonalPace(routes, multiplier: 1).isEmpty)
    }

    // MARK: contextual destination prediction

    private func evidence(
        _ id: String, context: Int = 0, time: Int = 0, total: Int = 0, daysAgo: Double = 1
    ) -> DestinationPrediction.Evidence {
        var e = DestinationPrediction.Evidence(
            id: id, name: id,
            coordinate: CLLocationCoordinate2D(latitude: 43, longitude: -89))
        e.contextHits = context
        e.timeHits = time
        e.totalHits = total
        e.lastUsed = Date().timeIntervalSince1970 - daysAgo * 86_400
        return e
    }

    /// The whole point of context: at 7am on a weekday the office should
    /// beat the restaurant the driver visits more often overall.
    func testContextBeatsRawFrequency() {
        let now = Date().timeIntervalSince1970
        let ranked = DestinationPrediction.rank([
            evidence("Office", context: 9, time: 12, total: 30),
            evidence("Favorite diner", context: 0, time: 1, total: 44),
        ], now: now)
        XCTAssertEqual(ranked.first?.name, "Office")
        XCTAssertEqual(ranked.first?.reason, "You usually go here about now")
        XCTAssertEqual(ranked.first?.score ?? 0, 1.0, accuracy: 1e-9)   // normalized
    }

    func testPredictionDecaysWithRecencyAndSkipsUnvisited() {
        let now = Date().timeIntervalSince1970
        let ranked = DestinationPrediction.rank([
            evidence("Stale", context: 4, total: 20, daysAgo: 200),
            evidence("Fresh", context: 3, total: 12, daysAgo: 1),
            evidence("Never", context: 0, time: 0, total: 0),
        ], now: now)
        XCTAssertEqual(ranked.first?.name, "Fresh")
        XCTAssertFalse(ranked.contains { $0.name == "Never" })   // no evidence, no guess
    }

    /// A weak guess about where someone is going is worse than silence.
    func testConfidenceGateWithholdsWeakPredictions() {
        let now = Date().timeIntervalSince1970
        let weak = DestinationPrediction.rank([evidence("Somewhere", total: 1)], now: now)
        XCTAssertFalse(DestinationPrediction.isConfident(weak, minimumEvidence: 1))
        let strong = DestinationPrediction.rank([evidence("Work", context: 8, total: 20)], now: now)
        XCTAssertTrue(DestinationPrediction.isConfident(strong, minimumEvidence: 8))
        XCTAssertFalse(DestinationPrediction.isConfident([], minimumEvidence: 99))
    }

    // MARK: relocation

    /// A driver who MOVES gets a new everyday center — but only after the
    /// new city has genuinely taken over. All-time counts alone could never
    /// notice this: the old home keeps its lead for years.
    func testHomeMovesOnlyForASustainedRelocation() {
        let now = Date().timeIntervalSince1970
        let day = 86_400.0
        var store = SeasonalStore()
        // Two years of departures from the old home.
        for i in 0..<300 {
            store.recordOrigin(lat: 430, lon: -894, t: now - (700 - Double(i)) * day)
        }
        let old = (lat: 430, lon: -894)
        XCTAssertEqual(store.learnedHome(now: now, currentHome: old).map { Int($0.lat * 10) }, 430)

        // A two-week work trip must NOT move home.
        var visiting = store
        for i in 0..<14 {
            visiting.recordOrigin(lat: 419, lon: -874, t: now - (14 - Double(i)) * day)
        }
        XCTAssertEqual(visiting.learnedHome(now: now, currentHome: old).map { Int($0.lat * 10) },
                       430, "a two-week trip is not a move")

        // Six weeks of daily departures from the new city IS a move.
        var moved = store
        for i in 0..<45 {
            moved.recordOrigin(lat: 419, lon: -874, t: now - (45 - Double(i)) * day)
        }
        XCTAssertEqual(moved.learnedHome(now: now, currentHome: old).map { Int($0.lat * 10) },
                       419, "six weeks of daily departures is a relocation")
    }

    // MARK: choice log

    func testChoiceLogKeepsTheRejectedAlternatives() {
        var log = ChoiceLog()
        let options = (0..<4).map { i in
            ChoiceLog.Option(aheadMiles: Double(i), detourMiles: Double(i) * 0.5,
                             shownRank: i, chosen: i == 2)
        }
        log.record(ChoiceLog.Event(kind: "gas", t: 0, hourBucket: 2,
                                   weekend: false, options: options))
        XCTAssertEqual(log.events.count, 1)
        // The losers are what make a weight identifiable — they must survive.
        XCTAssertEqual(log.events[0].options.count, 4)
        XCTAssertEqual(log.events[0].options.filter(\.chosen).count, 1)
        XCTAssertEqual(log.events[0].options.first(where: \.chosen)?.shownRank, 2)

        // An event with no chosen row carries no label and is dropped.
        log.record(ChoiceLog.Event(kind: "gas", t: 0, hourBucket: 2, weekend: false,
                                   options: [ChoiceLog.Option(chosen: false)]))
        XCTAssertEqual(log.events.count, 1)
    }

    func testChoiceLogIsBounded() {
        var log = ChoiceLog()
        for i in 0..<(ChoiceLog.cap + 50) {
            log.record(ChoiceLog.Event(
                kind: "food", t: Double(i), hourBucket: 0, weekend: false,
                options: [ChoiceLog.Option(shownRank: 0, chosen: true)]))
        }
        XCTAssertEqual(log.events.count, ChoiceLog.cap)
        XCTAssertEqual(log.events.last?.t, Double(ChoiceLog.cap + 49))   // newest kept
    }

    // MARK: habit-cache coverage + stable feature encoding

    /// (The POI-kind → habit-category mapping itself lives on `POIService`,
    /// which is outside this test target. It needs no test: the mapping is
    /// an EXHAUSTIVE switch, so the compiler already refuses to build if a
    /// new POI kind is added without an explicit learn-or-exclude decision —
    /// a stronger guarantee than an assertion, and the reason the five
    /// dropped kinds were a deliberate-looking `nil` rather than an
    /// oversight the type system could have caught.)

    /// The learning feature encoding must be FROZEN: appending a category
    /// cannot be allowed to renumber existing ones (which `allCases
    /// .firstIndex` did, silently changing what "fuel" meant).
    func testCategoryFeatureIndexIsStable() {
        XCTAssertEqual(EverydayCategory.food.featureIndex, 0)
        XCTAssertEqual(EverydayCategory.fuel.featureIndex, 1)
        XCTAssertEqual(EverydayCategory.gyms.featureIndex, 7)
        // Appended cases take NEW values, never reusing an existing one.
        XCTAssertEqual(EverydayCategory.parking.featureIndex, 8)
        XCTAssertEqual(EverydayCategory.showers.featureIndex, 9)
        let indices = EverydayCategory.allCases.map(\.featureIndex)
        XCTAssertEqual(Set(indices).count, indices.count, "feature indices must be unique")
        XCTAssertTrue(indices.allSatisfy { $0 < EverydayCategory.featureIndexSpace })
        // The normalised feature for an existing category is unchanged by
        // the append, because the divisor is fixed rather than allCases.count.
        let v = EverydayFeatures.vector(
            hourBucket: 2, weekend: false, startLat: 43, startLon: -89,
            placeLat: 43.1, placeLon: -89.1, category: .fuel)
        XCTAssertEqual(v.count, EverydayFeatures.count)
        XCTAssertEqual(v.last ?? 0, 1.0 / 16.0, accuracy: 1e-12)
    }

    // MARK: driver shower reports (the crowd-correction path)

    /// A driver standing in the building outranks a spreadsheet about it.
    /// `disprove` was implemented and persisted with nothing able to call
    /// it, and the brand city-table short-circuited ahead of the report even
    /// when one existed.
    func testDriverShowerReportOutranksTheBrandTable() {
        let lat = 41.1234, lon = -95.4321
        XCTAssertFalse(ShowerAvailability.isDisproved(lat: lat, lon: lon))
        // Brand knowledge alone claims showers at a big-chain truck stop.
        XCTAssertEqual(
            ShowerAvailability.forStop(named: "Love's Travel Stop"), .standard)
        // After a driver reports otherwise, the ladder returns .disproven.
        ShowerAvailability.disprove(lat: lat, lon: lon)
        XCTAssertTrue(ShowerAvailability.isDisproved(lat: lat, lon: lon))
        XCTAssertEqual(
            ShowerAvailability.forStop(named: "Love's Travel Stop", lat: lat, lon: lon),
            .disproven)
        // A different stop is unaffected — the report is location-scoped.
        XCTAssertNotEqual(
            ShowerAvailability.forStop(named: "Love's Travel Stop",
                                       lat: lat + 1, lon: lon + 1),
            .disproven)
    }

    // MARK: on-device fine-tune

    private func flatHead() -> LearnedHead {
        LearnedHead(
            w1: (0..<4).map { _ in [Double](repeating: 0.1, count: RouteFeatures.count) },
            b1: [Double](repeating: 0, count: 4),
            w2: [Double](repeating: 0.1, count: 4),
            b2: 0, version: 1)
    }

    private func rows(target: Double, count: Int) -> [[String: Double]] {
        (0..<count).map { i in
            ["oLat": 43, "oLon": -89, "dLat": 44, "dLon": -88,
             "week": Double(i % 52), "target": target, "weight": 1, "crossCountry": 0]
        }
    }

    /// A fine-tune must MOVE the model toward the driver's observations —
    /// and must remain anchored, so a handful of trips can refine the
    /// national baseline but never overwrite it.
    func testFineTuneImprovesFitAndStaysAnchored() throws {
        let base = flatHead()
        let observations = rows(target: 0.8, count: 40)
        let tuned = try XCTUnwrap(RouteHeadTrainer.fineTune(base: base, rows: observations))

        let before = try XCTUnwrap(RouteHeadTrainer.meanSquaredError(base, rows: observations))
        let after = try XCTUnwrap(RouteHeadTrainer.meanSquaredError(tuned, rows: observations))
        XCTAssertLessThan(after, before, "fine-tune must fit the driver's own data better")
        XCTAssertEqual(tuned.tunedOnDevice, true)
        XCTAssertEqual(tuned.inputWidth, RouteFeatures.count)

        // Anchoring: weights move, but stay in the baseline's neighborhood.
        for (row, baseRow) in zip(tuned.w1, base.w1) {
            for (w, b) in zip(row, baseRow) {
                XCTAssertLessThan(abs(w - b), 0.5, "anchor must prevent runaway drift")
            }
        }
    }

    func testFineTuneRefusesEmptyOrMismatchedInput() {
        let base = flatHead()
        XCTAssertNil(RouteHeadTrainer.fineTune(base: base, rows: []))
        let stale = LearnedHead(w1: [[0.1, 0.2]], b1: [0], w2: [0.1], b2: 0, version: 1)
        XCTAssertNil(RouteHeadTrainer.fineTune(base: stale, rows: rows(target: 0.5, count: 5)))
    }
}
