// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The learned everyday-radius cache (`EverydayStore`): radius math and the
/// significance gate, the 20-mile hard cap, in-circle cache admission, and
/// most-used-first ranking. Explicit times throughout — no wall clock.
final class EverydayRadiusTests: XCTestCase {
    private let home = CLLocationCoordinate2D(latitude: 43.0, longitude: -89.4)

    /// A point `miles` due north of home (1° latitude ≈ 69.09 mi).
    private func north(_ miles: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: home.latitude + miles / 69.09,
                               longitude: home.longitude)
    }

    private func store(trips: [Double], withHome: Bool = true) -> EverydayStore {
        var s = EverydayStore()
        if withHome { s.setHome(lat: home.latitude, lon: home.longitude) }
        for miles in trips { s.recordTrip(miles: miles) }
        return s
    }

    // MARK: Radius math

    func testHaversineMiles() {
        // 0.1° of latitude ≈ 6.9 miles, at any longitude.
        let d = EverydayStore.miles(
            from: home,
            to: CLLocationCoordinate2D(latitude: 43.1, longitude: -89.4))
        XCTAssertEqual(d, 6.909, accuracy: 0.05)
        XCTAssertEqual(EverydayStore.miles(from: home, to: home), 0, accuracy: 0.001)
    }

    func testDefaultRadiusIsTheTwentyMileCap() {
        XCTAssertEqual(EverydayStore().radiusMiles, 20.0)
        XCTAssertEqual(EverydayStore.hardCapMiles, 20.0)
    }

    func testMeanAndSDMatchHandComputedValues() {
        // 10 × 3 mi, 10 × 5 mi, 10 × 7 mi: mean 5, sample SD √(80/29).
        let s = store(trips: Array(repeating: 3.0, count: 10)
            + Array(repeating: 5.0, count: 10)
            + Array(repeating: 7.0, count: 10))
        XCTAssertEqual(s.meanTripMiles!, 5.0, accuracy: 0.0001)
        XCTAssertEqual(s.tripMilesSD!, (80.0 / 29.0).squareRoot(), accuracy: 0.0001)
        XCTAssertEqual(s.radiusMiles, 5.0 + (80.0 / 29.0).squareRoot(), accuracy: 0.0001)
    }

    // MARK: Significance gating

    func testRadiusHoldsTheDefaultBelowThirtyTrips() {
        // 29 consistent 4-mile trips: not significant yet → the 20-mile default.
        let s = store(trips: Array(repeating: 4.0, count: EverydayStore.minTripsForRadius - 1))
        XCTAssertEqual(s.radiusMiles, 20.0)
        // The 30th trip crosses the gate → the circle shrinks to mean + SD.
        var t = s
        t.recordTrip(miles: 4.0)
        XCTAssertLessThan(t.radiusMiles, 5.0)
    }

    func testRadiusNeverGrowsPastTheCap() {
        // A long-range driver (mean 35 mi) still gets the 20-mile ceiling.
        let s = store(trips: Array(repeating: 35.0, count: 40))
        XCTAssertEqual(s.radiusMiles, 20.0)
        // Even with a huge spread pushing mean + SD way past 20.
        let wild = store(trips: (0..<40).map { Double($0 % 2 == 0 ? 5 : 90) })
        XCTAssertEqual(wild.radiusMiles, 20.0)
    }

    func testRadiusShrinksOnlyWithSignificance() {
        // Tight local driving: 30 × ~5 mi → radius lands near 5–6, under 20.
        let miles = (0..<30).map { 5.0 + Double($0 % 3) * 0.5 }
        let s = store(trips: miles)
        XCTAssertLessThan(s.radiusMiles, 7.0)
        XCTAssertGreaterThan(s.radiusMiles, 4.0)
    }

    func testTripWindowIsBounded() {
        var s = EverydayStore()
        for i in 0..<(EverydayStore.tripWindow + 25) { s.recordTrip(miles: Double(i)) }
        XCTAssertEqual(s.tripCount, EverydayStore.tripWindow)
        // Oldest trips fell off the front: the first kept value is trip #25.
        XCTAssertEqual(s.tripMiles.first!, 25.0, accuracy: 0.0001)
    }

    func testBogusTripDistancesAreIgnored() {
        var s = EverydayStore()
        s.recordTrip(miles: -3)
        s.recordTrip(miles: .nan)
        s.recordTrip(miles: .infinity)
        XCTAssertEqual(s.tripCount, 0)
    }

    // MARK: Cache admission (inside the circle only)

    func testCacheRejectsPlacesOutsideTheLearnedCircle() {
        // 30 × 5 mi trips → radius ≈ 5. A stop 10 mi out must be refused;
        // one 2 mi out is admitted.
        var s = store(trips: Array(repeating: 5.0, count: 30))
        let far = north(10), near = north(2)
        XCTAssertFalse(s.remember(name: "Far Diner", lat: far.latitude, lon: far.longitude,
                                  street: "", city: "", in: .food))
        XCTAssertTrue(s.remember(name: "Near Diner", lat: near.latitude, lon: near.longitude,
                                 street: "", city: "", in: .food))
        XCTAssertEqual(s.ranked(in: .food).map(\.name), ["Near Diner"])
    }

    func testCacheNeedsAHomeAnchor() {
        var s = store(trips: Array(repeating: 5.0, count: 30), withHome: false)
        XCTAssertFalse(s.remember(name: "Cafe", lat: home.latitude, lon: home.longitude,
                                  street: "", city: "", in: .food))
    }

    func testDefaultCircleAdmitsUpToTwentyMilesBeforeSignificance() {
        // No trips yet: the default 20-mile circle still caches near home.
        var s = store(trips: [])
        XCTAssertTrue(s.remember(name: "Fuel Stop", lat: north(18).latitude,
                                 lon: north(18).longitude, street: "", city: "",
                                 in: .fuel))
        XCTAssertFalse(s.remember(name: "Too Far", lat: north(22).latitude,
                                  lon: north(22).longitude, street: "", city: "",
                                  in: .fuel))
    }

    func testRepeatSightingsAccumulateIntoOneRecord() {
        var s = store(trips: [])
        let p = north(1)
        for _ in 0..<3 {
            s.remember(name: "Grocery", lat: p.latitude, lon: p.longitude,
                       street: "1 Main St", city: "Madison", in: .stores)
        }
        let entries = s.ranked(in: .stores)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].seen, 3)
        XCTAssertEqual(entries[0].street, "1 Main St")
    }

    func testCategoryStoreIsBoundedAndEvictsLeastUsed() {
        var s = store(trips: [])
        for i in 0..<EverydayStore.maxPlacesPerCategory {
            let p = north(Double(i) * 0.02 + 0.1)
            s.remember(name: "Stop \(i)", lat: p.latitude, lon: p.longitude,
                       street: "", city: "", in: .food)
        }
        // Use everything except "Stop 7", then overflow the cap.
        for e in s.ranked(in: .food) where e.name != "Stop 7" {
            s.recordUse(id: e.id, in: .food,
                        contextID: EverydayStore.contextID(
                            hourBucket: 2, weekend: false,
                            startLat: home.latitude, startLon: home.longitude),
                        t: 1)
        }
        let p = north(5)
        s.remember(name: "Newcomer", lat: p.latitude, lon: p.longitude,
                   street: "", city: "", in: .food)
        let names = s.ranked(in: .food).map(\.name)
        XCTAssertEqual(names.count, EverydayStore.maxPlacesPerCategory)
        XCTAssertFalse(names.contains("Stop 7"), "the never-used entry is evicted")
        XCTAssertTrue(names.contains("Newcomer"))
    }

    // MARK: Frequency ranking

    func testMostUsedRanksFirst() {
        var s = store(trips: [])
        let ctx = EverydayStore.contextID(hourBucket: 3, weekend: false,
                                          startLat: home.latitude, startLon: home.longitude)
        for (i, name) in ["Rarely", "Often", "Sometimes"].enumerated() {
            let p = north(Double(i + 1))
            s.remember(name: name, lat: p.latitude, lon: p.longitude,
                       street: "", city: "", in: .fuel)
        }
        func id(_ name: String) -> String {
            s.ranked(in: .fuel).first { $0.name == name }!.id
        }
        for _ in 0..<5 { s.recordUse(id: id("Often"), in: .fuel, contextID: ctx, t: 1) }
        for _ in 0..<2 { s.recordUse(id: id("Sometimes"), in: .fuel, contextID: ctx, t: 2) }
        XCTAssertEqual(s.ranked(in: .fuel).map(\.name), ["Often", "Sometimes", "Rarely"])
    }

    func testUnusedEntriesFallBackToSeenCountThenRecency() {
        var s = store(trips: [])
        let a = north(1), b = north(2)
        s.remember(name: "Seen Twice", lat: a.latitude, lon: a.longitude,
                   street: "", city: "", in: .hotels)
        s.remember(name: "Seen Twice", lat: a.latitude, lon: a.longitude,
                   street: "", city: "", in: .hotels)
        s.remember(name: "Seen Once", lat: b.latitude, lon: b.longitude,
                   street: "", city: "", in: .hotels)
        XCTAssertEqual(s.ranked(in: .hotels).map(\.name), ["Seen Twice", "Seen Once"])
    }

    // MARK: Context attribute ids (habit correlations)

    func testHourBuckets() {
        XCTAssertEqual(EverydayStore.hourBucket(0), 0)
        XCTAssertEqual(EverydayStore.hourBucket(3), 0)
        XCTAssertEqual(EverydayStore.hourBucket(4), 1)
        XCTAssertEqual(EverydayStore.hourBucket(12), 3)
        XCTAssertEqual(EverydayStore.hourBucket(23), 5)
        XCTAssertEqual(EverydayStore.hourBucket(24), 0)   // wraps, never crashes
    }

    func testContextIDsAreUniquePerContextAndRoundTrip() {
        let morning = EverydayStore.contextID(hourBucket: 2, weekend: false,
                                              startLat: 43.0, startLon: -89.4)
        let weekend = EverydayStore.contextID(hourBucket: 2, weekend: true,
                                              startLat: 43.0, startLon: -89.4)
        let elsewhere = EverydayStore.contextID(hourBucket: 2, weekend: false,
                                                startLat: 44.5, startLon: -88.0)
        XCTAssertEqual(Set([morning, weekend, elsewhere]).count, 3)
        let parsed = EverydayStore.parseContext(morning)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.hourBucket, 2)
        XCTAssertFalse(parsed!.weekend)
        XCTAssertEqual(parsed!.startLat, 43.0, accuracy: 0.05)
        XCTAssertEqual(parsed!.startLon, -89.4, accuracy: 0.05)
        XCTAssertNil(EverydayStore.parseContext("junk"))
    }

    func testUsesAccumulatePerContext() {
        var s = store(trips: [])
        let p = north(1)
        s.remember(name: "Gym", lat: p.latitude, lon: p.longitude,
                   street: "", city: "", in: .gyms)
        let id = s.ranked(in: .gyms)[0].id
        let weekdayMorning = EverydayStore.contextID(hourBucket: 2, weekend: false,
                                                     startLat: 43.0, startLon: -89.4)
        let weekendMorning = EverydayStore.contextID(hourBucket: 2, weekend: true,
                                                     startLat: 43.0, startLon: -89.4)
        for _ in 0..<3 { s.recordUse(id: id, in: .gyms, contextID: weekdayMorning, t: 1) }
        s.recordUse(id: id, in: .gyms, contextID: weekendMorning, t: 2)
        let entry = s.ranked(in: .gyms)[0]
        XCTAssertEqual(entry.uses, 4)
        XCTAssertEqual(entry.contexts[weekdayMorning], 3)
        XCTAssertEqual(entry.contexts[weekendMorning], 1)
    }

    // MARK: Pattern-net substrate

    func testTrainingRowsExportOneRowPerPlaceContext() {
        var s = store(trips: [])
        let p = north(1)
        s.remember(name: "Cafe", lat: p.latitude, lon: p.longitude,
                   street: "", city: "", in: .food)
        let id = s.ranked(in: .food)[0].id
        let c1 = EverydayStore.contextID(hourBucket: 1, weekend: false,
                                         startLat: 43.0, startLon: -89.4)
        let c2 = EverydayStore.contextID(hourBucket: 4, weekend: true,
                                         startLat: 43.0, startLon: -89.4)
        s.recordUse(id: id, in: .food, contextID: c1, t: 1)
        s.recordUse(id: id, in: .food, contextID: c1, t: 2)
        s.recordUse(id: id, in: .food, contextID: c2, t: 3)
        let rows = s.trainingRows()
        XCTAssertEqual(rows.count, 2)
        let counts = Set(rows.map { Int($0["uses"] ?? 0) })
        XCTAssertEqual(counts, [2, 1])
        for row in rows {
            XCTAssertEqual(row["category"], 0)   // food is the first category
            XCTAssertEqual(row["placeLat"] ?? 0, p.latitude, accuracy: 0.001)
        }
    }

    func testFeatureVectorIsBoundedAndStable() {
        let x = EverydayFeatures.vector(hourBucket: 5, weekend: true,
                                        startLat: 43.0, startLon: -89.4,
                                        placeLat: 43.1, placeLon: -89.3,
                                        category: .gyms)
        XCTAssertEqual(x.count, EverydayFeatures.count)
        for v in x { XCTAssertLessThanOrEqual(abs(v), 1.0) }
        // Same inputs → same vector (the net's contract).
        XCTAssertEqual(x, EverydayFeatures.vector(hourBucket: 5, weekend: true,
                                                  startLat: 43.0, startLon: -89.4,
                                                  placeLat: 43.1, placeLon: -89.3,
                                                  category: .gyms))
    }

    // MARK: Persistence shape

    func testStoreSurvivesACodableRoundTrip() throws {
        var s = store(trips: Array(repeating: 5.0, count: 30))
        let p = north(2)
        s.remember(name: "Diner", lat: p.latitude, lon: p.longitude,
                   street: "2 Oak St", city: "Madison", in: .food)
        s.recordUse(id: s.ranked(in: .food)[0].id, in: .food,
                    contextID: EverydayStore.contextID(hourBucket: 2, weekend: false,
                                                       startLat: 43.0, startLon: -89.4),
                    t: 11)
        let decoded = try JSONDecoder().decode(
            EverydayStore.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
        XCTAssertEqual(decoded.radiusMiles, s.radiusMiles, accuracy: 0.0001)
        XCTAssertEqual(decoded.ranked(in: .food), s.ranked(in: .food))
    }
}
