// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// Time-aware risk, vehicle range/fuel timing, and hotel value ranking.
final class DriverFeaturesTests: XCTestCase {

    // MARK: time-aware risk — the storm must still be there when you are

    func testAlertExpiredBeforeArrivalCarriesNoRisk() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        // The canonical case: 10 h route, alert at the far end expires in 1 h.
        XCTAssertFalse(
            RiskTiming.isActive(expires: now.addingTimeInterval(3600),
                                arrivalOffset: 10 * 3600, now: now),
            "risk that ends in 1 h is GONE when you arrive 10 h from now")
        // Same alert encountered 30 minutes in → very much still there.
        XCTAssertTrue(
            RiskTiming.isActive(expires: now.addingTimeInterval(3600),
                                arrivalOffset: 30 * 60, now: now))
        // No expiry information → never silently discounted.
        XCTAssertTrue(RiskTiming.isActive(expires: nil, arrivalOffset: 10 * 3600, now: now))
        // All-day alert → active at the far end of a 10 h route.
        XCTAssertTrue(
            RiskTiming.isActive(expires: now.addingTimeInterval(24 * 3600),
                                arrivalOffset: 10 * 3600, now: now))
    }

    func testArrivalOffsetsProrateAcrossTheRoute() {
        let offsets = RiskTiming.arrivalOffsets(sampleCount: 5, totalTravelSeconds: 8 * 3600)
        let expected: [TimeInterval] = [0, 7200, 14400, 21600, 28800]
        XCTAssertEqual(offsets, expected)
        XCTAssertEqual(RiskTiming.arrivalOffsets(sampleCount: 1, totalTravelSeconds: 3600), [0])
        XCTAssertTrue(RiskTiming.arrivalOffsets(sampleCount: 0, totalTravelSeconds: 3600).isEmpty)
    }

    // MARK: vehicle range — mpg + tank + how you actually drive

    private var van: VehicleProfile {
        VehicleProfile(make: "Ford", model: "Transit", fuelType: .diesel,
                       tankCapacityUnits: 25, ratedMilesPerUnit: 20)
    }

    func testRatedRangeAndCalmDrivingKeepsIt() {
        XCTAssertEqual(van.ratedRangeMiles, 500)
        // ≤ 55 mph, no idling → full rated range.
        XCTAssertEqual(VehicleProfile.efficiencyFactor(averageSpeedMph: 50, idleFraction: 0), 1)
        XCTAssertEqual(
            van.expectedRangeMiles(milesSinceFill: 0, averageSpeedMph: 50, idleFraction: 0), 500)
    }

    func testSpeedAndIdlingShrinkRange() {
        // 75 mph: 20 mph over → −24% economy.
        XCTAssertEqual(VehicleProfile.efficiencyFactor(averageSpeedMph: 75, idleFraction: 0),
                       0.76, accuracy: 1e-9)
        // Heavy idling costs too.
        XCTAssertEqual(VehicleProfile.efficiencyFactor(averageSpeedMph: 50, idleFraction: 0.2),
                       0.9, accuracy: 1e-9)
        // Floor at 0.5 — the model never claims the tank evaporates.
        XCTAssertEqual(VehicleProfile.efficiencyFactor(averageSpeedMph: 120, idleFraction: 0.8),
                       0.5, accuracy: 1e-9)
        // 250 mi into a 500 mi rated tank at 75 mph → 0.76·500 − 250 = 130 mi left.
        XCTAssertEqual(
            van.expectedRangeMiles(milesSinceFill: 250, averageSpeedMph: 75, idleFraction: 0),
            130, accuracy: 1e-9)
    }

    func testFuelRecommendationTiming() {
        // 130 mi of range, station assumed ~25 mi out, 40 mi reserve → 90 mi
        // of margin: no nag yet.
        XCTAssertFalse(VehicleProfile.shouldRecommendFuel(
            rangeRemainingMiles: 130, milesToNextStation: 25))
        // 60 mi of range → 20 mi past reserve, station 25 mi out: recommend NOW.
        XCTAssertTrue(VehicleProfile.shouldRecommendFuel(
            rangeRemainingMiles: 60, milesToNextStation: 25))
        // Exactly at the boundary counts as recommend (don't cut it fine).
        XCTAssertTrue(VehicleProfile.shouldRecommendFuel(
            rangeRemainingMiles: 65, milesToNextStation: 25))
    }

    @MainActor
    func testVehicleStorePersistsAndTracksHabits() throws {
        let suite = "flows.tests.vehicle"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let store = VehicleStore(defaults: defaults)
        store.profile = van
        // Simulate 10 highway fixes: 33.5 m/s (~75 mph), 100 m apart.
        for _ in 0..<10 { store.recordFix(speedMps: 33.5, deltaMeters: 100) }
        XCTAssertEqual(store.milesSinceFill, 1000 / 1609.344, accuracy: 1e-9)
        XCTAssertGreaterThan(store.averageSpeedMph, 55, "habits drift toward actual speed")

        // Fresh store (relaunch) reads profile + odometer back.
        let relaunched = VehicleStore(defaults: defaults)
        XCTAssertEqual(relaunched.profile, van)
        XCTAssertEqual(relaunched.milesSinceFill, store.milesSinceFill, accuracy: 1e-9)

        relaunched.filledUp()
        XCTAssertEqual(relaunched.milesSinceFill, 0)
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: hotels — review/cost balance

    private func hotel(_ name: String, rating: Double?, nightly: Double?,
                       detour: Double = 1000) -> POIRanking.Candidate<String> {
        POIRanking.Candidate(item: name, coordinate: CLLocationCoordinate2D(),
                             aheadMeters: 10_000, detourMeters: detour,
                             pricePerUnit: nightly, rating: rating)
    }

    func testHotelValueBalancesRatingAndPrice() {
        // Well-reviewed and cheap beats poorly-reviewed and expensive.
        let ranked = POIRanking.rankHotels([
            hotel("overpriced-dive", rating: 2.5, nightly: 180),
            hotel("gem", rating: 4.6, nightly: 90),
        ])
        XCTAssertEqual(ranked.map(\.item), ["gem", "overpriced-dive"])
        // A great rating justifies a moderate premium…
        let premium = POIRanking.rankHotels([
            hotel("meh-cheap", rating: 3.0, nightly: 80),
            hotel("great-fair", rating: 4.8, nightly: 120),
        ])
        XCTAssertEqual(premium.first?.item, "great-fair")
        // …but detour still matters: same value, 10 km off-route loses.
        let near = POIRanking.rankHotels([
            hotel("far", rating: 4.0, nightly: 100, detour: 10_000),
            hotel("near", rating: 4.0, nightly: 100, detour: 500),
        ])
        XCTAssertEqual(near.first?.item, "near")
    }

    func testHotelRankingDegradesGracefullyWithoutData() {
        // No ratings/prices wired → closest-to-corridor ordering, no crash.
        let ranked = POIRanking.rankHotels([
            hotel("b", rating: nil, nightly: nil, detour: 8_000),
            hotel("a", rating: nil, nightly: nil, detour: 300),
        ])
        XCTAssertEqual(ranked.map(\.item), ["a", "b"])
        // Behind-the-vehicle hotels are filtered like every other kind.
        let behind = POIRanking.Candidate(
            item: "behind", coordinate: CLLocationCoordinate2D(),
            aheadMeters: -5000, detourMeters: 100, pricePerUnit: nil, rating: nil)
        XCTAssertTrue(POIRanking.rankHotels([behind]).isEmpty)
    }
}

/// Vehicle spec table, parking ranking, and price estimates.
final class SpecTableAndParkingTests: XCTestCase {

    func testSpecTableFiltersByMakeAndFillsProfile() {
        XCTAssertTrue(VehicleSpecs.makes.contains("Toyota"))
        let toyotas = VehicleSpecs.models(make: "Toyota")
        XCTAssertFalse(toyotas.isEmpty)
        XCTAssertTrue(toyotas.allSatisfy { $0.make == "Toyota" })

        let camry = try! XCTUnwrap(VehicleSpecs.spec(make: "Toyota", model: "Camry"))
        // EPA 55/45 blend sits between city and highway.
        XCTAssertGreaterThan(camry.combinedMPU, camry.cityMPU)
        XCTAssertLessThan(camry.combinedMPU, camry.highwayMPU)
        let profile = camry.profile
        XCTAssertEqual(profile.fuelType, .gas)
        XCTAssertEqual(profile.tankCapacityUnits, 15.8)
        // A sedan's height seeds the low-bridge filter, not a default 13'6".
        XCTAssertLessThan(camry.heightFeet, 5.0)

        // The slider floor is a real car height, not 10 ft.
        XCTAssertLessThan(VehicleSpecs.minimumHeightFeet, 5.0)
        XCTAssertGreaterThan(VehicleSpecs.minimumHeightFeet, 4.0)

        // Semis carry the 13'6" standard.
        let semi = try! XCTUnwrap(VehicleSpecs.spec(make: "Freightliner", model: "Cascadia (semi)"))
        XCTAssertEqual(semi.heightFeet, 13.5)
        XCTAssertEqual(semi.fuelType, .diesel)
    }

    func testParkingFreeAndCloseBeatsExpensiveAndFar() {
        func lot(_ name: String, detour: Double) -> POIRanking.Candidate<String> {
            POIRanking.Candidate(item: name, coordinate: CLLocationCoordinate2D(),
                                 aheadMeters: 2_000, detourMeters: detour,
                                 pricePerUnit: nil, rating: nil)
        }
        XCTAssertEqual(POIRanking.parkingCostTier(name: "Free Public Lot"), 0)
        XCTAssertEqual(POIRanking.parkingCostTier(name: "City Park & Ride"), 0)
        XCTAssertEqual(POIRanking.parkingCostTier(name: "Premium Parking Garage"), 2)
        XCTAssertEqual(POIRanking.parkingCostTier(name: "Main St Lot"), 1)

        let ranked = POIRanking.rankParking(
            [lot("Premium Parking Garage", detour: 200),
             lot("Free Public Lot", detour: 900),
             lot("Main St Lot", detour: 100)],
            costTier: { POIRanking.parkingCostTier(name: $0) })
        // Free wins even 800 m farther; unknown-cost close lot beats the garage.
        XCTAssertEqual(ranked.map(\.item),
                       ["Free Public Lot", "Main St Lot", "Premium Parking Garage"])
    }

    func testFuelPriceEstimatesFollowStatePatterns() {
        let wi = FuelPrices.estimate(fuel: .gas, state: "WI")
        let ca = FuelPrices.estimate(fuel: .gas, state: "California")
        let tx = FuelPrices.estimate(fuel: .gas, state: "TX")
        // Well-known ordering: CA >> national > TX; WI near national.
        XCTAssertGreaterThan(ca, wi)
        XCTAssertGreaterThan(wi, tx)
        XCTAssertEqual(wi, FuelPrices.nationalGas * 0.98, accuracy: 0.011)
        // Diesel above gas everywhere; electric in $/kWh territory.
        XCTAssertGreaterThan(FuelPrices.estimate(fuel: .diesel, state: "WI"), wi)
        XCTAssertLessThan(FuelPrices.estimate(fuel: .electric, state: "WI"), 1.0)
        // Unknown region → national baseline, never nil/zero.
        XCTAssertEqual(FuelPrices.estimate(fuel: .gas, state: nil), FuelPrices.nationalGas)
        XCTAssertEqual(FuelPrices.estimate(fuel: .gas, state: "Ontario"), FuelPrices.nationalGas)
    }

    func testVehicleDerivedFuelCadenceUsesGasLabel() {
        // A gas vehicle's scheduled fuel stop must be labeled Gas, not Diesel.
        let intervals = TripNeeds.Intervals(gasMiles: 300)
        let schedule = TripNeeds.schedule(totalMiles: 700, intervals: intervals)
        XCTAssertEqual(schedule.map(\.mile), [300, 600])
        XCTAssertTrue(schedule.allSatisfy { $0.need == .fuel(.gas) })
    }
}
