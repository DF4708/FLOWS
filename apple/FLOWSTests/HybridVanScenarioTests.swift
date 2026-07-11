// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The canonical trip: a 10-foot-high hybrid van towing heavy, Mexico →
/// Canada passing north of New York. Diesel every 350 mi, charge every
/// 500 mi, a surprise cuisine every 100 mi, rest every 200 mi; cannot clear
/// bridges posted 12 ft or smaller; cannot climb grades over 14°; shelters
/// from a storm midway (+1 h to the ETA); red alerts must auto-open shelters
/// and short-lived upper-yellow risk must recommend a rest-area wait.
final class HybridVanScenarioTests: XCTestCase {

    // MARK: clearances — 10 ft van, 12 ft posts impassable

    func testTenFootVanCannotPassTwelveFootPost() {
        let van = FilterLimits(vehicleHeightMeters: 10 * 0.3048)
        // A 12 ft post is "12 foot limits or smaller" → impassable.
        XCTAssertFalse(van.passesClearances([12 * 0.3048]))
        // 11'11" — clearly under.
        XCTAssertFalse(van.passesClearances([(11 + 11.0 / 12) * 0.3048]))
        // 12'1" exceeds height + 2 ft margin → passable.
        XCTAssertTrue(van.passesClearances([(12 + 1.0 / 12) * 0.3048]))
        // 13'6" interstate standard → fine.
        XCTAssertTrue(van.passesClearances([13.5 * 0.3048]))
        // One bad bridge among good ones still fails the route.
        XCTAssertFalse(van.passesClearances([13.5 * 0.3048, 12 * 0.3048]))
        // No clearance data yet must never exclude a route.
        XCTAssertTrue(van.passesClearances(nil))
    }

    // MARK: grades — the driver thinks in DEGREES (14° towing heavy)

    func testGradeLimitInDegrees() {
        // 14° = tan(14°) ≈ 24.93% — the slider's unit conversion.
        XCTAssertEqual(FilterLimits.degreesToPercent(14), 24.933, accuracy: 0.001)
        XCTAssertEqual(FilterLimits.degreesToPercent(0), 0, accuracy: 1e-12)

        let van = FilterLimits(maxGradePercent: FilterLimits.degreesToPercent(14))
        // A 20% grade (≈11.3°) is within the 14° ceiling.
        XCTAssertTrue(van.passesGrade(20))
        // A 26% grade (≈14.6°) exceeds it.
        XCTAssertFalse(van.passesGrade(26))
        // Unknown grade data never excludes a route.
        XCTAssertTrue(van.passesGrade(nil))

        // A gentler 6° ceiling rejects the 20% grade.
        let cautious = FilterLimits(maxGradePercent: FilterLimits.degreesToPercent(6))
        XCTAssertFalse(cautious.passesGrade(20))
    }

    // MARK: trip needs — diesel 350 / electric 500 / food 100 / rest 200

    func testHybridVanScheduleCadences() {
        // Roughly Monterrey → Ottawa keeping north of New York City.
        let schedule = TripNeeds.schedule(totalMiles: 2000, intervals: .hybridVan, seed: 42)

        let diesel = schedule.filter { $0.need == .fuel(.diesel) }.map(\.mile)
        XCTAssertEqual(diesel, [350, 700, 1050, 1400, 1750])

        let electric = schedule.filter { $0.need == .fuel(.electric) }.map(\.mile)
        XCTAssertEqual(electric, [500, 1000, 1500])

        let rests = schedule.filter { $0.need == .rest }.map(\.mile)
        XCTAssertEqual(rests, stride(from: 200.0, to: 2000, by: 200).map { $0 })

        let food = schedule.filter {
            if case .food = $0.need { return true } else { return false }
        }
        XCTAssertEqual(food.count, 19, "food every 100 mi over 2000 mi")
        XCTAssertEqual(food.map(\.mile), stride(from: 100.0, to: 2000, by: 100).map { $0 })

        // Whole schedule is mile-ordered.
        XCTAssertEqual(schedule.map(\.mile), schedule.map(\.mile).sorted())
    }

    func testFoodCategoryIsRandomButDeterministicPerSeed() {
        func categories(seed: UInt64) -> [FoodCategory] {
            TripNeeds.schedule(totalMiles: 2000, intervals: .hybridVan, seed: seed)
                .compactMap { if case .food(let c) = $0.need { return c } else { return nil } }
        }
        // Same trip seed → same cuisines (replayable).
        XCTAssertEqual(categories(seed: 42), categories(seed: 42))
        // The draw actually varies (more than one distinct cuisine over 19 stops).
        XCTAssertGreaterThan(Set(categories(seed: 42)).count, 1)
        // A different trip draws a different sequence.
        XCTAssertNotEqual(categories(seed: 42), categories(seed: 43))
    }

    func testNextNeedTracksOdometer() {
        let schedule = TripNeeds.schedule(totalMiles: 2000, intervals: .hybridVan, seed: 1)
        XCTAssertEqual(TripNeeds.next(after: 0, in: schedule)?.mile, 100)     // first food
        XCTAssertEqual(TripNeeds.next(after: 340, in: schedule)?.mile, 350)  // diesel next
        XCTAssertEqual(TripNeeds.next(after: 499, in: schedule)?.mile, 500)
        // Last event is food at mile 1900 — nothing scheduled after it.
        XCTAssertNil(TripNeeds.next(after: 1999, in: schedule))
        XCTAssertNil(TripNeeds.next(after: 2100, in: schedule))
    }

    func testSingleFuelVehicleHasNoElectricStops() {
        let dieselOnly = TripNeeds.Intervals(
            dieselMiles: 350, electricMiles: nil, foodMiles: nil, restMiles: nil)
        let schedule = TripNeeds.schedule(totalMiles: 1000, intervals: dieselOnly)
        XCTAssertEqual(schedule.map(\.mile), [350, 700])
        XCTAssertTrue(schedule.allSatisfy { $0.need == .fuel(.diesel) })
    }

    // MARK: storm shelter — +1 hour folds into the ETA

    func testShelterDelayAdjustsETA() {
        // 6 h remaining, driver shelters for 1 h → 7 h shown.
        XCTAssertEqual(
            TripNeeds.adjustedRemainingSeconds(baseline: 6 * 3600, stopDelaySeconds: 3600),
            7 * 3600)
        // No delay → baseline untouched.
        XCTAssertEqual(TripNeeds.adjustedRemainingSeconds(baseline: 1234, stopDelaySeconds: 0), 1234)
        // Negative delay is nonsense — clamped.
        XCTAssertEqual(TripNeeds.adjustedRemainingSeconds(baseline: 1234, stopDelaySeconds: -50), 1234)
    }

    // MARK: imminent alerts — 10 minutes ahead at current speed

    func testImminenceWindowScalesWithSpeed() {
        // 65 mph ≈ 29 m/s: 15 km ahead is ~8.6 min → imminent.
        XCTAssertTrue(ImminentAlerts.isImminent(distanceMeters: 15_000, speedMps: 29))
        // 20 km at the same speed is ~11.5 min → not yet.
        XCTAssertFalse(ImminentAlerts.isImminent(distanceMeters: 20_000, speedMps: 29))
        // Stopped at a light: the floor speed still sees ~3 km ahead…
        XCTAssertTrue(ImminentAlerts.isImminent(distanceMeters: 2_900, speedMps: 0))
        // …but not 10 km.
        XCTAssertFalse(ImminentAlerts.isImminent(distanceMeters: 10_000, speedMps: 0))
    }

    func testRedWarningsDemandShelter() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        // The scenario's red set: active tornado / hurricane / fire /
        // radioactive — regardless of expiry.
        for event in ["Tornado Warning", "Hurricane Warning", "Fire Warning",
                      "Radiological Hazard Warning", "Shelter In Place Warning"] {
            XCTAssertEqual(
                ImminentAlerts.classify(event: event, severityScore: 0.95, expires: nil, now: now),
                .shelter, event)
        }
        // Extreme severity is red even without a keyword match.
        XCTAssertEqual(
            ImminentAlerts.classify(event: "Storm Surge Alert", severityScore: 0.95,
                                    expires: nil, now: now),
            .shelter)
    }

    func testTransientUpperYellowRecommendsRestArea() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        // Severe thunderstorm (0.72, upper yellow) blowing through in 90 min
        // → wait it out at a rest area.
        XCTAssertEqual(
            ImminentAlerts.classify(event: "Severe Thunderstorm Warning", severityScore: 0.72,
                                    expires: now.addingTimeInterval(90 * 60), now: now),
            .restArea)
        // Same event lasting 5 more hours → not transient, keep driving/monitoring.
        XCTAssertEqual(
            ImminentAlerts.classify(event: "Severe Thunderstorm Warning", severityScore: 0.72,
                                    expires: now.addingTimeInterval(5 * 3600), now: now),
            .monitor)
        // Minor advisory expiring soon → below the upper-yellow floor.
        XCTAssertEqual(
            ImminentAlerts.classify(event: "Wind Advisory", severityScore: 0.45,
                                    expires: now.addingTimeInterval(3600), now: now),
            .monitor)
        // Already expired → nothing to wait out.
        XCTAssertEqual(
            ImminentAlerts.classify(event: "Severe Thunderstorm Warning", severityScore: 0.72,
                                    expires: now.addingTimeInterval(-60), now: now),
            .monitor)
    }

    func testWorstImminentAlertWins() {
        let candidates = [
            ImminentAlerts.Candidate(alertID: "flood", distanceMeters: 5_000, severityScore: 0.72),
            ImminentAlerts.Candidate(alertID: "tornado", distanceMeters: 12_000, severityScore: 0.95),
            ImminentAlerts.Candidate(alertID: "far-storm", distanceMeters: 100_000, severityScore: 0.99),
        ]
        // At 29 m/s both near alerts are inside the window; the far one is
        // not; the TORNADO (worst severity in reach) is surfaced.
        XCTAssertEqual(ImminentAlerts.firstImminent(candidates, speedMps: 29)?.alertID, "tornado")
        // Nothing in reach → nothing surfaced.
        XCTAssertNil(ImminentAlerts.firstImminent(
            [ImminentAlerts.Candidate(alertID: "x", distanceMeters: 500_000, severityScore: 1)],
            speedMps: 29))
    }

    func testShelterSearchMatchesTheSpecificWarning() {
        XCTAssertEqual(ImminentAlerts.shelterQuery(forEvent: "Tornado Warning"),
                       "tornado shelter storm shelter")
        XCTAssertEqual(ImminentAlerts.shelterQuery(forEvent: "Fire Warning"),
                       "evacuation center emergency shelter")
        XCTAssertEqual(ImminentAlerts.shelterQuery(forEvent: "Radiological Hazard Warning"),
                       "fallout shelter emergency shelter")
        XCTAssertEqual(ImminentAlerts.shelterQuery(forEvent: "Hurricane Warning"),
                       "hurricane shelter evacuation center")
        XCTAssertEqual(ImminentAlerts.shelterQuery(forEvent: "Dense Fog Advisory"),
                       "emergency shelter")
    }

    // MARK: risk badges — one symbol at the cluster's central weight

    func testBadgeSitsAtScoreWeightedCentroid() {
        let items = [
            BadgeClustering.Item(coordinate: CLLocationCoordinate2D(latitude: 45.0, longitude: -90.0),
                                 kind: "storm", score: 0.9),
            BadgeClustering.Item(coordinate: CLLocationCoordinate2D(latitude: 45.09, longitude: -90.0),
                                 kind: "storm", score: 0.3),
        ]
        let badges = BadgeClustering.cluster(items, minSeparationMeters: 100_000)
        XCTAssertEqual(badges.count, 1, "same-kind neighbors collapse to one symbol")
        // Weighted centroid: (45.0·0.9 + 45.09·0.3) / 1.2 = 45.0225.
        XCTAssertEqual(badges[0].coordinate.latitude, 45.0225, accuracy: 1e-6)
        XCTAssertEqual(badges[0].coordinate.longitude, -90.0, accuracy: 1e-9)
        // The badge keeps the worst member's score.
        XCTAssertEqual(badges[0].score, 0.9)
    }

    // MARK: favorites — star, persist, one-press lookup

    @MainActor
    func testFavoritesPersistAcrossStores() throws {
        let suiteName = "flows.tests.favorites"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let store = FavoritesStore(defaults: defaults)
        XCTAssertFalse(store.contains(name: "Home"))
        store.add(FavoriteAddress(name: "Home", symbol: .home,
                                  latitude: 43.0731, longitude: -89.4012))
        store.add(FavoriteAddress(name: "Office", symbol: .office,
                                  latitude: 43.0389, longitude: -87.9065))
        XCTAssertTrue(store.contains(name: "Home"))

        // A fresh store (fresh launch) reads the same favorites back.
        let relaunched = FavoritesStore(defaults: defaults)
        XCTAssertEqual(relaunched.favorites.count, 2)
        XCTAssertEqual(relaunched.favorites.first?.symbol, .home)
        XCTAssertEqual(relaunched.favorites.first?.coordinate.latitude ?? 0, 43.0731, accuracy: 1e-9)

        // Re-starring the same name updates instead of duplicating.
        relaunched.add(FavoriteAddress(name: "Home", symbol: .other,
                                       latitude: 44.0, longitude: -90.0))
        XCTAssertEqual(relaunched.favorites.count, 2)
        XCTAssertEqual(relaunched.favorites.first { $0.name == "Home" }?.symbol, .other)

        // Removal persists too.
        if let office = relaunched.favorites.first(where: { $0.name == "Office" }) {
            relaunched.remove(office)
        }
        XCTAssertEqual(FavoritesStore(defaults: defaults).favorites.count, 1)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
