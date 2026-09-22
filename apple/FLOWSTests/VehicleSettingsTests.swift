// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// Vehicle, towing and fuel rules behind the settings sheet and the route
/// cards: clearances as the sign reads, the rig weight, towing's filters and
/// fuel cadence, EPA electric economy, real fuel data that ages out, and a
/// Smartcar sign-in that only Smartcar can end.
final class VehicleSettingsTests: XCTestCase {

    private let inch = 0.0254

    // MARK: clearances read like the sign

    func testClearancesShowThePostedFeetAndInches() {
        // 13'6" parses to 162 × 0.0254 m, which is 13.4999… ft: truncating
        // feet and then inches showed 13'5".
        XCTAssertEqual(FilterLimits.feetAndInches(meters: 162 * inch), "13'6\"")
        XCTAssertEqual(FilterLimits.feetAndInches(meters: 156 * inch), "13'0\"")
        // Rounding the inches alone showed 14'0" as 13'12".
        XCTAssertEqual(FilterLimits.feetAndInches(meters: 168 * inch), "14'0\"")
        XCTAssertEqual(FilterLimits.feetAndInches(meters: 192 * inch), "16'0\"")
        XCTAssertEqual(FilterLimits.feetAndInches(feet: 13.5), "13'6\"")
        XCTAssertEqual(FilterLimits.feetAndInches(feet: 15.99), "16'0\"")
        XCTAssertEqual(FilterLimits.feetAndInches(feet: 13.35), "13'4\"")
        XCTAssertEqual(FilterLimits.feetAndInches(meters: .nan), "—")
    }

    func testTheHeightSlidersCanLandOnThirteenSix() {
        // A stepped slider only lands on floor + n × 0.25.
        let floor = VehicleSpecs.heightSliderFloorFeet
        XCTAssertLessThanOrEqual(floor, VehicleSpecs.minimumHeightFeet)
        XCTAssertEqual(floor * 4, (floor * 4).rounded())
        let steps = (13.5 - floor) / 0.25
        XCTAssertEqual(steps, steps.rounded())
    }

    // MARK: the rig weight the bridge-weight check uses

    func testATrailerAloneIsNotTheRig() {
        // A trailer with no vehicle weight counts the vehicle at its max.
        XCTAssertEqual(FilterLimits.rigVehicleLbs(entered: 0, towedLbs: 7_000,
                                                  ratedMaxLbs: 6_000), 6_000)
        // An entered weight is used as given.
        XCTAssertEqual(FilterLimits.rigVehicleLbs(entered: 5_500, towedLbs: 7_000,
                                                  ratedMaxLbs: 6_000), 5_500)
        // Nothing entered: no weight, so no road is excluded on a guess.
        XCTAssertEqual(FilterLimits.rigVehicleLbs(entered: 0, towedLbs: 0,
                                                  ratedMaxLbs: 6_000), 0)
        XCTAssertEqual(FilterLimits.rigVehicleLbs(entered: 0, towedLbs: 7_000,
                                                  ratedMaxLbs: nil), 0)
        // A 13,000 lb rig does not take a 10,000 lb bridge.
        XCTAssertFalse(FilterLimits(rigWeightLbs: 6_000 + 7_000).passesWeightLimits([10_000]))
    }

    // MARK: towing's filters

    func testTowingOffTakesBackOnlyWhatTowingAdded() {
        var filters: Set<RouteFilter> = [.avoidTraffic, .lowBridges]
        var hold = TowingFilterHold()
        hold.towingOn(&filters)
        XCTAssertTrue(RouteFilter.towingSafety.isSubset(of: filters))
        hold.towingOff(&filters)
        // The driver's own Low bridges survives unhitching.
        XCTAssertEqual(filters, [.avoidTraffic, .lowBridges])
    }

    func testAFilterTheDriverTouchesWhileTowingIsTheirs() {
        var filters: Set<RouteFilter> = [.avoidTraffic]
        var hold = TowingFilterHold()
        hold.towingOn(&filters)
        // Switched off and back on by hand while towing.
        hold.driverChose(.bridgeWeight)
        filters.remove(.bridgeWeight)
        hold.driverChose(.bridgeWeight)
        filters.insert(.bridgeWeight)
        hold.towingOff(&filters)
        XCTAssertEqual(filters, [.avoidTraffic, .bridgeWeight])
    }

    func testTheTowingCardNamesOnlyTheFiltersOn() {
        XCTAssertEqual(RouteFilter.towingSummary(active: RouteFilter.towingSafety),
                       "Route filters set: avoiding steep grades, low bridges, high winds, "
                       + "and roads with weight signs under your vehicle + towing weight.")
        XCTAssertEqual(RouteFilter.towingSummary(active: [.mountainGrades, .noHighWinds, .bridgeWeight]),
                       "Route filters set: avoiding steep grades, high winds, and roads "
                       + "with weight signs under your vehicle + towing weight.")
        XCTAssertEqual(RouteFilter.towingSummary(active: [.lowBridges, .noHighWinds]),
                       "Route filters set: avoiding low bridges and high winds.")
        XCTAssertEqual(RouteFilter.towingSummary(active: [.lowBridges, .avoidTraffic]),
                       "Route filters set: avoiding low bridges.")
        XCTAssertEqual(RouteFilter.towingSummary(active: [.avoidTraffic]),
                       "Towing route filters are off.")
    }

    // MARK: fuel stops while towing

    func testTowingFuelStopsComeSooner() {
        XCTAssertEqual(TripNeeds.fuelIntervalMiles(ratedRangeMiles: 580, efficiencyFactor: 1,
                                                   towing: false), 435)
        // 75% of the TOWING range — a stop at 75% of the untowed range
        // lands on an empty tank.
        XCTAssertEqual(TripNeeds.fuelIntervalMiles(ratedRangeMiles: 580, efficiencyFactor: 1,
                                                   towing: true),
                       435 * TowingLimits.towingEconomyFactor, accuracy: 1e-9)
        XCTAssertLessThan(TowingLimits.towingEconomyFactor, 1)
    }

    // MARK: EPA electric economy

    func testAnEPAElectricCarIsRatedPerKWh() {
        // 2024 Nissan Leaf: 123 / 99 MPGe, EPA range 149 mi.
        let leaf = EPAClassSpecs.filledIn(cityEPA: 123, highwayEPA: 99, fuelType: .electric,
                                          epaRangeMiles: 149, classTank: 14.5)
        XCTAssertEqual(leaf.city, 123 / 33.705, accuracy: 1e-9)
        XCTAssertEqual(leaf.highway, 99 / 33.705, accuracy: 1e-9)
        XCTAssertEqual(leaf.combined, 3.29, accuracy: 0.01)
        // The battery comes from EPA's range, not the class's gas tank.
        XCTAssertEqual(leaf.tank * leaf.combined, 149, accuracy: 0.5)
        XCTAssertEqual(leaf.tank, 45.3, accuracy: 1e-9)
        // No EPA range: a typical pack, never the ~600 mi the old path gave.
        let unknown = EPAClassSpecs.filledIn(cityEPA: 123, highwayEPA: 99, fuelType: .electric,
                                             epaRangeMiles: 0, classTank: 14.5)
        XCTAssertEqual(unknown.tank, EPAClassSpecs.typicalPackKWh)
        XCTAssertLessThan(unknown.tank * unknown.combined, 300)
    }

    func testEPAGasEconomyPassesThrough() {
        let car = EPAClassSpecs.filledIn(cityEPA: 30, highwayEPA: 40, fuelType: .gas,
                                         epaRangeMiles: nil, classTank: 12.5)
        XCTAssertEqual(car.city, 30)
        XCTAssertEqual(car.highway, 40)
        XCTAssertEqual(car.combined, 1 / (0.55 / 30 + 0.45 / 40), accuracy: 1e-12)
        XCTAssertEqual(car.tank, EPAClassSpecs.validatedTank(12.5, combinedMPU: car.combined))
    }

    // MARK: real fuel data — only while it is current

    func testAnOldFuelReadingNoLongerStandsInForTheTank() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let fresh = FuelReading(fraction: 0.4, at: now.addingTimeInterval(-60))
        let launch = FuelReading(fraction: 0.8, at: now.addingTimeInterval(-3 * 3600))
        XCTAssertNil(FuelReading.freshest([launch, nil], now: now))
        XCTAssertEqual(FuelReading.freshest([launch, fresh], now: now), fresh)
        // Both current: the newer one wins, whichever source it came from.
        let newer = FuelReading(fraction: 0.35, at: now.addingTimeInterval(-5))
        XCTAssertEqual(FuelReading.freshest([fresh, newer], now: now), newer)
        XCTAssertEqual(FuelReading.freshest([newer, fresh], now: now), newer)
        XCTAssertNil(FuelReading.freshest([nil, nil], now: now))
    }

    @MainActor
    func testTheGaugeShowsRealFuelWhenThereIsSome() throws {
        let suite = "flows.tests.vehicle.gauge"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = VehicleStore(defaults: defaults)
        XCTAssertNil(store.displayedFuelFraction, "no vehicle, no gauge")

        store.profile = VehicleProfile(make: "Ford", model: "Transit", fuelType: .diesel,
                                       tankCapacityUnits: 25, ratedMilesPerUnit: 20)
        for _ in 0..<50 { store.recordFix(speedMps: 30, deltaMeters: 8_000) }
        store.telemetry = { (0.6, nil) }
        XCTAssertEqual(store.displayedFuelFraction, 0.6)
        store.telemetry = { (nil, nil) }
        XCTAssertEqual(store.displayedFuelFraction, store.predictedFuelFraction)
        defaults.removePersistentDomain(forName: suite)
    }

    // Which token answers end a Smartcar sign-in: SmartcarExchangeTests.

    // MARK: shapes and big rigs

    func testANamedBusIsDrawnAsABusAtAnyWeight() {
        XCTAssertEqual(VehicleShape.matching(make: "Generic", model: "Bus",
                                             gvwrLbs: 36_200, isTrucker: false), .bus)
        // Weight still beats a name that says nothing about the body.
        XCTAssertEqual(VehicleShape.matching(make: "Freightliner", model: "Cascadia",
                                             gvwrLbs: 80_000, isTrucker: true), .semi)
    }

    func testBigRigWordsMatchWholeWordsOnly() {
        XCTAssertFalse(VehicleSpecs.soundsLikeBigRig("Corvette"))
        XCTAssertFalse(VehicleSpecs.soundsLikeBigRig("Corvette Stingray"))
        XCTAssertFalse(VehicleSpecs.soundsLikeBigRig("Silverado 1500"))
        XCTAssertTrue(VehicleSpecs.soundsLikeBigRig("Class C motorhome"))
        XCTAssertTrue(VehicleSpecs.soundsLikeBigRig("16 ft box truck"))
        XCTAssertTrue(VehicleSpecs.soundsLikeBigRig("Bus"))
        XCTAssertTrue(VehicleSpecs.soundsLikeBigRig("E-450 Econoline cutaway"))
        XCTAssertTrue(VehicleSpecs.soundsLikeBigRig("F53 RV chassis"))
    }

    // MARK: the day's driving total

    func testYesterdaysMilesAreNotToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday = Date(timeIntervalSince1970: 1_750_000_000)
        let tuesday = monday.addingTimeInterval(86_400)
        var log = DailyDriveLog.empty(on: monday, calendar: calendar)
        log.add(meters: 402_000, at: monday, calendar: calendar)
        XCTAssertEqual(log.metersDriven(on: monday, calendar: calendar), 402_000)
        // No fix yet on Tuesday: the log still holds Monday's total.
        XCTAssertEqual(log.meters, 402_000)
        XCTAssertEqual(log.metersDriven(on: tuesday, calendar: calendar), 0)
    }
}
