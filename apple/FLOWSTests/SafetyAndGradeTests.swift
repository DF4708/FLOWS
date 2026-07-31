// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import MapKit
import XCTest

/// Red-alert entity parsing, crash logic, HOS rules, the grade table, and
/// speed-interpolated economy.
final class SafetyAndGradeTests: XCTestCase {

    // MARK: red-alert entities — "red Toyota truck" → red truck + TOYOTA

    func testVehicleDescriptionParses() throws {
        let amber = "AMBER Alert: suspect last seen driving a red Toyota pickup "
            + "truck northbound on I-39. The child was wearing a blue jacket."
        let v = try XCTUnwrap(AlertEntityParser.vehicle(in: amber))
        XCTAssertEqual(v.colorName, "red")
        XCTAssertEqual(v.kind, .truck)
        XCTAssertEqual(v.brand, "Toyota")
        XCTAssertEqual(v.kind.symbol, "truck.pickup.side.fill")

        // Chevy normalizes to Chevrolet; SUV classifies as SUV.
        let blue = AlertEntityParser.vehicle(in: "a dark blue Chevy SUV heading west")
        XCTAssertEqual(blue?.colorName, "dark blue")
        XCTAssertEqual(blue?.kind, .suv)
        XCTAssertEqual(blue?.brand, "Chevrolet")

        // No vehicle mentioned → nil, not a fabricated car.
        XCTAssertNil(AlertEntityParser.vehicle(in: "Tornado warning for Dane County"))
    }

    func testPersonDescriptionParses() throws {
        let amber = "The child is a 7-year-old girl wearing a blue jacket."
        let p = try XCTUnwrap(AlertEntityParser.person(in: amber))
        XCTAssertTrue(p.isChild)
        XCTAssertEqual(p.colorName, "blue")
        XCTAssertEqual(p.symbol, "figure.child")

        let adult = try XCTUnwrap(AlertEntityParser.person(
            in: "Suspect is an adult male wearing a black hoodie."))
        XCTAssertFalse(adult.isChild)
        XCTAssertEqual(adult.colorName, "black")
        XCTAssertEqual(adult.symbol, "figure.stand")

        XCTAssertNil(AlertEntityParser.person(in: "Flash flood warning until 9 PM"))
    }

    func testEmergencyBroadcastsClassifyRed() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        for event in ["Child Abduction Emergency", "AMBER Alert",
                      "Law Enforcement Warning", "Blue Alert", "Civil Emergency Message"] {
            XCTAssertEqual(
                ImminentAlerts.classify(event: event, severityScore: 0.5, expires: nil, now: now),
                .shelter, "\(event) must go red (press-to-dismiss card)")
        }
    }

    // MARK: crash logic

    func testImpactThresholdAndReplies() {
        XCTAssertFalse(CrashLogic.isImpact(accelerationG: 1.0))   // normal driving
        XCTAssertFalse(CrashLogic.isImpact(accelerationG: 2.5))   // hard braking/pothole
        XCTAssertTrue(CrashLogic.isImpact(accelerationG: 4.0))    // crash pulse
        XCTAssertTrue(CrashLogic.isImpact(accelerationG: 8.0))

        // Windowed detector: a hard spike fires even if isolated (never miss a
        // violent crash); a moderate spike needs corroboration; a lone 4–5 g
        // spike that settles to rest (phone drop) does NOT fire.
        let rest = [Double](repeating: 1.0, count: 24)
        XCTAssertTrue(CrashLogic.isImpact(window: rest + [7.0]),
                      "a hard >=6 g spike must fire immediately")
        XCTAssertFalse(CrashLogic.isImpact(window: rest + [4.5]),
                       "a lone moderate spike then rest must NOT fire (phone drop)")
        // Real crash: 4.5 g peak with continued disturbance (tumble/skid).
        let crash = [1.0, 1.2, 4.5, 3.1, 2.8, 2.6, 1.5] + [Double](repeating: 1.0, count: 18)
        XCTAssertTrue(CrashLogic.isImpact(window: crash),
                      "a corroborated moderate impact must fire")
        XCTAssertFalse(CrashLogic.isImpact(window: rest),
                       "calm driving never fires")

        XCTAssertEqual(CrashLogic.interpretReply("Yes I need help"), true)
        XCTAssertEqual(CrashLogic.interpretReply("call 911"), true)
        XCTAssertEqual(CrashLogic.interpretReply("no I'm fine"), false)
        XCTAssertEqual(CrashLogic.interpretReply("I'm OK really"), false)
        XCTAssertNil(CrashLogic.interpretReply("uh what happened"))
        // The loop must keep re-asking, never one-and-done.
        XCTAssertEqual(CrashLogic.checkInRepeatSeconds, 20)
    }

    func testEmergencyMessageTemplate() {
        let vehicle = VehicleProfile(make: "Ford", model: "Transit", fuelType: .diesel,
                                     tankCapacityUnits: 25, ratedMilesPerUnit: 20)
        let msg = CrashLogic.emergencyMessage(
            latitude: 43.07295, longitude: -89.40123,
            address: "123 W Main St, Madison, WI",
            time: Date(timeIntervalSince1970: 1_750_000_000),
            vehicle: vehicle, medicalNotes: "Type 1 diabetic")
        XCTAssertTrue(msg.contains("43.07295"))
        XCTAssertTrue(msg.contains("123 W Main St"))
        XCTAssertTrue(msg.contains("Ford Transit"))
        XCTAssertTrue(msg.contains("Type 1 diabetic"))
        XCTAssertTrue(msg.contains("CRASH REPORT"))
        // No GPS fix must NOT fabricate 0,0 (a real point in the Atlantic).
        let noFix = CrashLogic.emergencyMessage(
            latitude: nil, longitude: nil, address: nil,
            time: Date(timeIntervalSince1970: 1_750_000_000),
            vehicle: nil, medicalNotes: nil)
        XCTAssertFalse(noFix.contains("0.00000"))
        XCTAssertTrue(noFix.contains("GPS: unavailable"))
    }

    // MARK: FMCSA hours of service

    func testHOSCheckpoints() {
        XCTAssertEqual(HOSRules.status(drivingSeconds: 3 * 3600), .ok)
        XCTAssertEqual(HOSRules.status(drivingSeconds: 7.5 * 3600 + 60),
                       .breakSoon(secondsUntilDue: 0.5 * 3600 - 60))
        XCTAssertEqual(HOSRules.status(drivingSeconds: 8 * 3600), .breakDue)
        XCTAssertEqual(HOSRules.status(drivingSeconds: 11 * 3600), .limitReached)
        XCTAssertEqual(HOSRules.breakResetSeconds, 30 * 60)
    }

    // MARK: the grade table — localized, honest

    func testGradeTableRegistersNeighborhoodHill() {
        // 300 m spacing: flat, flat, 24 m climb (8%), flat.
        let elevs: [Double?] = [100, 100, 100, 124, 124]
        let segs = GradeProfile.segments(elevations: elevs, spacingMeters: 300)
        XCTAssertEqual(segs.count, 4)
        let steepest = GradeProfile.steepest(segs, top: 1)
        XCTAssertEqual(steepest.first?.gradePercent ?? 0, 8, accuracy: 1e-9)
        // The mile position localizes it (3rd segment: 600–900 m in).
        XCTAssertEqual(steepest.first?.startMile ?? 0, 600 / 1609.344, accuracy: 1e-9)
        // Failed samples break the chain rather than faking a grade.
        let gappy = GradeProfile.segments(elevations: [100, nil, 200], spacingMeters: 300)
        XCTAssertTrue(gappy.isEmpty)
    }

    func testNextSteepLookahead() {
        let segs = [
            GradeSegment(startMile: 1, endMile: 2, gradePercent: 2),
            GradeSegment(startMile: 5, endMile: 6, gradePercent: 7.5),
            GradeSegment(startMile: 20, endMile: 21, gradePercent: 9),
        ]
        // From mile 3: the 7.5% at mile 5 is within the 8-mile lookahead;
        // the 9% at mile 20 is not.
        XCTAssertEqual(GradeProfile.nextSteep(after: 3, in: segs)?.gradePercent, 7.5)
        // Past it → nothing steep in reach.
        XCTAssertNil(GradeProfile.nextSteep(after: 7, in: segs))
        // Steep DESCENTS register too (brakes).
        let down = [GradeSegment(startMile: 2, endMile: 3, gradePercent: -8)]
        XCTAssertEqual(GradeProfile.nextSteep(after: 0, in: down)?.gradePercent, -8)
    }

    // MARK: speed-interpolated economy (city ↔ highway)

    func testEconomyInterpolatesBetweenCityAndHighway() {
        let camry = VehicleProfile(make: "Toyota", model: "Camry", fuelType: .gas,
                                   tankCapacityUnits: 15.8, ratedMilesPerUnit: 32,
                                   cityMilesPerUnit: 28, highwayMilesPerUnit: 39)
        XCTAssertEqual(camry.milesPerUnit(atSpeedMph: 20), 28)          // city
        XCTAssertEqual(camry.milesPerUnit(atSpeedMph: 42.5), 33.5,      // midpoint of ramp
                       accuracy: 1e-9)
        XCTAssertEqual(camry.milesPerUnit(atSpeedMph: 60), 39)          // highway
        XCTAssertEqual(camry.milesPerUnit(atSpeedMph: 75), 39 * 0.88,   // drag past 65
                       accuracy: 1e-9)
        // Hand-entered vehicle (no split) → flat rated number at any speed.
        let custom = VehicleProfile(make: "Custom", model: "vehicle", fuelType: .gas,
                                    tankCapacityUnits: 20, ratedMilesPerUnit: 25)
        XCTAssertEqual(custom.milesPerUnit(atSpeedMph: 20), 25)
        XCTAssertEqual(custom.milesPerUnit(atSpeedMph: 75), 25)
    }
}

/// Towing limits, refuel learning, pursuit reach, radar tiles, live-feed
/// score mappings, and the broadened crash vocabulary.
final class TowingSafetyFeedTests: XCTestCase {

    func testBroadCrashVocabulary() {
        for phrase in ["yeah please hurry", "I'm bleeding", "send help now",
                       "yep", "call an ambulance", "mayday mayday"] {
            XCTAssertEqual(CrashLogic.interpretReply(phrase), true, phrase)
        }
        for phrase in ["nah all good", "false alarm sorry", "we're fine thanks",
                       "nope", "stop asking", "never mind, don't call"] {
            XCTAssertEqual(CrashLogic.interpretReply(phrase), false, phrase)
        }
        // Word boundaries: "know" is not "no", "yesterday" is not "yes".
        XCTAssertNil(CrashLogic.interpretReply("I don't know what happened"))
        XCTAssertNil(CrashLogic.interpretReply("it was fine yesterday"))
    }

    func testTowingLimitChecks() {
        let f150 = TowingLimits.Ratings(gvwrLbs: 7050, towCapacityLbs: 11200,
                                        gcwrLbs: 17100)
        // Inside every rating → no violations.
        XCTAssertTrue(TowingLimits.check(vehicleWeightLbs: 6500,
                                         towedWeightLbs: 8000, ratings: f150).isEmpty)
        // Over GVWR by 450.
        let overG = TowingLimits.check(vehicleWeightLbs: 7500,
                                       towedWeightLbs: 1000, ratings: f150)
        XCTAssertEqual(overG, [.overGVWR(by: 450)])
        XCTAssertTrue(overG[0].consequences.contains("brake") || overG[0].consequences.contains("Brake")
                      || overG[0].consequences.lowercased().contains("brakes"))
        // Over tow capacity AND combined GCWR.
        let overT = TowingLimits.check(vehicleWeightLbs: 7000,
                                       towedWeightLbs: 12000, ratings: f150)
        XCTAssertTrue(overT.contains(.overTowCapacity(by: 800)))
        XCTAssertTrue(overT.contains(.overGCWR(by: 1900)))
        // Unknown ratings never fabricate violations.
        let unrated = TowingLimits.Ratings(gvwrLbs: nil, towCapacityLbs: nil, gcwrLbs: nil)
        XCTAssertTrue(TowingLimits.check(vehicleWeightLbs: 99999,
                                         towedWeightLbs: 99999, ratings: unrated).isEmpty)
    }

    func testRefuelLearningAccuracyGate() {
        var learning = RefuelLearning()
        // No data → must prompt (accuracy 0 < 80%).
        XCTAssertTrue(learning.shouldPrompt(checkInsEnabled: true))
        XCTAssertFalse(learning.shouldPrompt(checkInsEnabled: false), "opt-out wins")
        // Accurate answers push accuracy over the floor → prompts go quiet.
        for _ in 0..<5 { learning.record(predictedFraction: 0.4, reportedFraction: 0.45) }
        XCTAssertEqual(learning.accuracy, 0.95, accuracy: 1e-9)
        XCTAssertFalse(learning.shouldPrompt(checkInsEnabled: true))
        // Accuracy decays below the floor → prompting re-arms.
        for _ in 0..<10 { learning.record(predictedFraction: 0.2, reportedFraction: 0.7) }
        XCTAssertLessThan(learning.accuracy, RefuelLearning.accuracyFloor)
        XCTAssertTrue(learning.shouldPrompt(checkInsEnabled: true))
    }

    func testPursuitReachGrowsWithTimeAndSpeed() {
        // 25 min at 55 mph ≈ 36.9 km.
        XCTAssertEqual(PursuitReach.radiusMeters(elapsedSeconds: 25 * 60, speedMph: 55),
                       25 * 60 * 55 * 0.44704, accuracy: 1)
        // Just happened → still a visible circle.
        XCTAssertEqual(PursuitReach.radiusMeters(elapsedSeconds: 0, speedMph: 55),
                       PursuitReach.minimumRadiusMeters)
        // Capped at 3 h so the circle keeps meaning something.
        XCTAssertEqual(PursuitReach.radiusMeters(elapsedSeconds: 10 * 3600, speedMph: 55),
                       PursuitReach.radiusMeters(elapsedSeconds: 3 * 3600, speedMph: 55))
    }


    func testLiveFeedScoreMappings() {
        // AQI category edges (EPA).
        XCTAssertEqual(HazardFeedScores.airScore(usAQI: 25), 0.1, accuracy: 1e-9)
        XCTAssertEqual(HazardFeedScores.airScore(usAQI: 150), 0.7, accuracy: 1e-9)
        XCTAssertGreaterThan(HazardFeedScores.airScore(usAQI: 250), 0.9)
        // UV bands (WHO).
        XCTAssertEqual(HazardFeedScores.uvScore(index: 6), 0.4, accuracy: 1e-9)
        XCTAssertGreaterThan(HazardFeedScores.uvScore(index: 11), 0.84)
        // Fire: a strong hotspot 5 km away scores high; 50 km away, nothing.
        let madison = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)
        let near = [(lat: 43.11, lon: -89.40, frp: 150.0)]
        XCTAssertGreaterThan(HazardFeedScores.fireScore(hotspots: near, at: madison), 0.6)
        let far = [(lat: 43.6, lon: -89.40, frp: 150.0)]
        XCTAssertEqual(HazardFeedScores.fireScore(hotspots: far, at: madison), 0, accuracy: 1e-9)
        // A SWARM of weak, distant detections (correlated pixels of one far fire)
        // must NOT multiply up to a false RED — max-of-detection, not noisy-OR.
        let swarm = (0..<50).map { i in
            (lat: 43.07 + Double(i) * 0.0002, lon: -89.63, frp: 1.0)  // ~18 km west
        }
        XCTAssertLessThan(HazardFeedScores.fireScore(hotspots: swarm, at: madison), FlowsCore.riskYellowMin,
                          "50 weak distant detections must not saturate the fire family to red")
        // Seismic: fresh M6 at 20 km is serious; a 30-hour-old quake is not.
        let m6 = [(lat: 43.25, lon: -89.40, magnitude: 6.0, ageHours: 1.0)]
        XCTAssertGreaterThan(HazardFeedScores.seismicScore(quakes: m6, at: madison), 0.5)
        let stale = [(lat: 43.25, lon: -89.40, magnitude: 6.0, ageHours: 30.0)]
        XCTAssertEqual(HazardFeedScores.seismicScore(quakes: stale, at: madison), 0, accuracy: 1e-9)
    }

    func testEveryTableSpecInterpolatesItsOwnNumbers() {
        // The user's OWN vehicle drives predictions — every table entry must
        // hit ITS city figure in town and ITS highway figure at speed.
        for spec in VehicleSpecs.all {
            let profile = spec.profile
            XCTAssertEqual(profile.milesPerUnit(atSpeedMph: 20), spec.cityMPU,
                           accuracy: 1e-9, spec.id)
            XCTAssertEqual(profile.milesPerUnit(atSpeedMph: 60), spec.highwayMPU,
                           accuracy: 1e-9, spec.id)
        }
        // Type fallback exists for unlisted vehicles ("trucks" vs "sedans" vs "bus").
        XCTAssertNotNil(VehicleSpecs.spec(make: "Generic", model: "Pickup truck"))
        XCTAssertNotNil(VehicleSpecs.spec(make: "Generic", model: "Bus"))
        XCTAssertNotNil(VehicleSpecs.spec(make: "Nissan", model: "Versa"))
        XCTAssertNotNil(VehicleSpecs.spec(make: "Ford", model: "E-450 Econoline cutaway"))
    }
}

/// TPMS/OBD parsing, cost tiers, star/$ colors, shower table, EPA class map.
final class TelemetryAndRatingsTests: XCTestCase {

    func testTPMSAdvertisementParsing() {
        // 32 psi ≈ 220.6 kPa → raw 220,632 (LE at offset 8); 25.00 °C at 12.
        var data = Data(repeating: 0, count: 16)
        var pressure = UInt32(220_632).littleEndian
        var temp = UInt32(2_500).littleEndian
        data.replaceSubrange(8..<12, with: Data(bytes: &pressure, count: 4))
        data.replaceSubrange(12..<16, with: Data(bytes: &temp, count: 4))
        let parsed = VehicleLink.parseTPMSAdvertisement(name: "TPMS3_A1B2C3",
                                                        manufacturerData: data)
        XCTAssertEqual(parsed?.psi ?? 0, 32.0, accuracy: 0.05)
        XCTAssertEqual(parsed?.celsius ?? 0, 25.0, accuracy: 0.01)
        XCTAssertEqual(parsed?.id, "Tire 3")
        // Non-TPMS device → nil; absurd pressure → nil.
        XCTAssertNil(VehicleLink.parseTPMSAdvertisement(name: "JBL Speaker",
                                                        manufacturerData: data))
        var zero = Data(repeating: 0, count: 16)
        XCTAssertNil(VehicleLink.parseTPMSAdvertisement(name: "TPMS1_X",
                                                        manufacturerData: zero))
        zero.removeAll()
        XCTAssertNil(VehicleLink.parseTPMSAdvertisement(name: "TPMS1_X",
                                                        manufacturerData: zero))
    }

    func testOBDFuelReplyParsing() {
        // SAE 01 2F: A/255. 0x80 = 50.2%.
        XCTAssertEqual(VehicleLink.parseFuelReply("41 2F 80") ?? 0, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(VehicleLink.parseFuelReply("SEARCHING...\r41 2F FF\r>") ?? 0, 1.0,
                       accuracy: 1e-9)
        XCTAssertNil(VehicleLink.parseFuelReply("NO DATA"))
        XCTAssertNil(VehicleLink.parseFuelReply("41 0C 1A F8"))   // that's RPM
    }

    func testIncomeAnchoredCostTiers() {
        // $ = minimum-wage affordable (≤ $12 average check).
        XCTAssertEqual(RatingsAndCost.costTier(averageCheckUSD: 9), 1)
        XCTAssertEqual(RatingsAndCost.costTier(averageCheckUSD: 25), 2)
        XCTAssertEqual(RatingsAndCost.costTier(averageCheckUSD: 45), 3)
        XCTAssertEqual(RatingsAndCost.costTier(averageCheckUSD: 100), 4)
        // $$$$$ = top 1–3% territory (> $120/person).
        XCTAssertEqual(RatingsAndCost.costTier(averageCheckUSD: 300), 5)
        // Yelp mapping: $$$$ splits into 4 vs 5 on luxury prestige.
        XCTAssertEqual(RatingsAndCost.costTier(yelpPrice: "$", rating: 3.0), 1)
        XCTAssertEqual(RatingsAndCost.costTier(yelpPrice: "$$$$", rating: 3.8), 4)
        XCTAssertEqual(RatingsAndCost.costTier(yelpPrice: "$$$$", rating: 4.8), 5)
    }

    func testColorRamps() {
        // Stars: yellow at 1 → gold at 5 (red stays high, green drops).
        let y = RatingsAndCost.starColor(stars: 1)
        let g = RatingsAndCost.starColor(stars: 5)
        XCTAssertEqual(y.g, 0.85, accuracy: 1e-9)
        XCTAssertEqual(g.g, 0.65, accuracy: 1e-9)
        XCTAssertGreaterThan(y.b, g.b)
        // Dollars: dark green at 1 → light green at 5.
        let dark = RatingsAndCost.dollarColor(tier: 1)
        let light = RatingsAndCost.dollarColor(tier: 5)
        XCTAssertLessThan(dark.g, light.g)
        XCTAssertLessThan(dark.r, light.r)
    }

    func testShowerBrandTable() {
        // "Assume showers at every Love's unless disproven."
        XCTAssertEqual(ShowerAvailability.forStop(named: "Love's Travel Stop #312"), .standard)
        XCTAssertEqual(ShowerAvailability.forStop(named: "Pilot Travel Center"), .standard)
        XCTAssertEqual(ShowerAvailability.forStop(named: "Flying J #605"), .standard)
        XCTAssertEqual(ShowerAvailability.forStop(named: "TA Travel Center"), .standard)
        XCTAssertEqual(ShowerAvailability.forStop(named: "Buc-ee's"), .none)
        XCTAssertEqual(ShowerAvailability.forStop(named: "Casey's General Store"), .none)
        XCTAssertEqual(ShowerAvailability.forStop(named: "Kwik Trip #900"), .likely)
        XCTAssertEqual(ShowerAvailability.forStop(named: "Joe's Gas"), .unknown)
    }

    func testEPAClassPhysicalMapping() {
        let pickup = EPAClassSpecs.physical(forVClass: "Standard Pickup Trucks 2WD")
        XCTAssertEqual(pickup.height, 6.4, accuracy: 1e-9)
        XCTAssertNotNil(pickup.towCap)
        let compact = EPAClassSpecs.physical(forVClass: "Compact Cars")
        XCTAssertEqual(compact.height, 4.7, accuracy: 1e-9)
        XCTAssertNil(compact.towCap)
        let suv = EPAClassSpecs.physical(forVClass: "Sport Utility Vehicle - 4WD")
        XCTAssertEqual(suv.height, 5.7, accuracy: 1e-9)
        XCTAssertEqual(EPAClassSpecs.fuelType(forEPA: "Electricity"), .electric)
        XCTAssertEqual(EPAClassSpecs.fuelType(forEPA: "Diesel"), .diesel)
        XCTAssertEqual(EPAClassSpecs.fuelType(forEPA: "Premium Gasoline"), .gas)
    }
}

/// Country-specific cost tiers + the shower resolution ladder.
final class CountryCostAndShowerTests: XCTestCase {

    func testCountryTiersAndGPSSwitch() {
        // Same casual-dinner spend, three economies.
        XCTAssertEqual(RatingsAndCost.costTier(averageCheck: 25, country: .us), 2)
        XCTAssertEqual(RatingsAndCost.costTier(averageCheck: 25, country: .canada), 2)
        XCTAssertEqual(RatingsAndCost.costTier(averageCheck: 25, country: .mexico), 1,
                       "MX$25 is street-food territory — tier 1 in pesos")
        // Tier 5 = top-percentile territory in each currency.
        XCTAssertEqual(RatingsAndCost.costTier(averageCheck: 200, country: .us), 5)
        XCTAssertEqual(RatingsAndCost.costTier(averageCheck: 200, country: .canada), 5)
        XCTAssertEqual(RatingsAndCost.costTier(averageCheck: 200, country: .mexico), 2,
                       "MX$200 is a solid sit-down meal — tier 2 in pesos")
        XCTAssertEqual(RatingsAndCost.costTier(averageCheck: 2000, country: .mexico), 5)
        // GPS → country: Madison, Toronto (below 49!), Monterrey, Vancouver.
        XCTAssertEqual(RatingsAndCost.Country.forCoordinate(latitude: 43.07, longitude: -89.40), .us)
        XCTAssertEqual(RatingsAndCost.Country.forCoordinate(latitude: 43.65, longitude: -79.38), .canada)
        XCTAssertEqual(RatingsAndCost.Country.forCoordinate(latitude: 25.67, longitude: -100.31), .mexico)
        XCTAssertEqual(RatingsAndCost.Country.forCoordinate(latitude: 49.28, longitude: -123.12), .canada)
        XCTAssertEqual(RatingsAndCost.Country.forCoordinate(latitude: 25.76, longitude: -80.19), .us,
                       "Miami is south of 32.7 but east of the Mexico box")
        XCTAssertEqual(RatingsAndCost.Country.us.currencySymbol, "US$")
        XCTAssertEqual(RatingsAndCost.Country.canada.currencySymbol, "C$")
        XCTAssertEqual(RatingsAndCost.Country.mexico.currencySymbol, "MX$")
    }

    func testShowerResolutionLadder() {
        // Driver report beats everything.
        ShowerAvailability.disprove(lat: 41.111, lon: -95.222)
        XCTAssertEqual(ShowerAvailability.forStop(named: "Love's Travel Stop",
                                                  lat: 41.111, lon: -95.222,
                                                  table: nil),
                       .disproven)
        // Explicit table tag beats the brand default.
        let table = ShowerAvailability.LocationTable(entries: [
            .init(lat: 42.5, lon: -90.5, brand: "Love's", shower: "no"),
            .init(lat: 43.5, lon: -91.5, brand: "Pilot", shower: "yes"),
        ])
        XCTAssertEqual(ShowerAvailability.forStop(named: "Love's Travel Stop",
                                                  lat: 42.5001, lon: -90.5001,
                                                  table: table),
                       .none)
        XCTAssertEqual(ShowerAvailability.forStop(named: "Pilot Travel Center",
                                                  lat: 43.5, lon: -91.5, table: table),
                       .standard)
        // No report, no tag → the brand assumption ("Love's unless disproven").
        XCTAssertEqual(ShowerAvailability.forStop(named: "Love's Travel Stop #99",
                                                  lat: 44.0, lon: -92.0, table: table),
                       .standard)
        // Cleanup the report.
        UserDefaults.standard.removeObject(forKey: "flows.showersDisproved")
    }
}

/// Mexico CRE fuel-price XML parsing (PrimarySources.swift) — shapes match
/// the live files probed at publicacionexterna.azurewebsites.net.
final class PrimarySourceTests: XCTestCase {
    func testCREPriceParsing() {
        let prices = MexicoFuelParsing.parsePrices("""
            <places><place place_id="11702">\
            <gas_price type="regular">24.9</gas_price>\
            <gas_price type="premium">30.5</gas_price>\
            <gas_price type="diesel">27.99</gas_price>\
            </place><place place_id="11703">\
            <gas_price type="regular">22.95</gas_price>\
            </place></places>
            """)
        XCTAssertEqual(prices["11702"]?["diesel"] ?? 0, 27.99, accuracy: 1e-9)
        XCTAssertEqual(prices["11703"]?["regular"] ?? 0, 22.95, accuracy: 1e-9)
        XCTAssertNil(prices["11703"]?["diesel"])
    }

    func testCREPlaceParsing() {
        let places = MexicoFuelParsing.parsePlaces("""
            <places><place place_id="2039"><name>E10</name>\
            <location><x>-116.9214</x><y>32.47641</y></location>\
            </place><place place_id="9999"><name>BAD</name>\
            <location><x>-116.9</x><y>55.0</y></location></place></places>
            """)
        XCTAssertEqual(places["2039"]?.latitude ?? 0, 32.47641, accuracy: 1e-9)
        XCTAssertEqual(places["2039"]?.longitude ?? 0, -116.9214, accuracy: 1e-9)
        XCTAssertNil(places["9999"], "coordinates outside Mexico are rejected")
    }
}

/// New keyless primary hazard feeds (SWPC space weather → radiation, WFIGS
/// perimeters → fire, NWS/NWPS gauges → flood). Pure scoring, endpoints
/// probed live before shipping.
final class PrimaryHazardFeedTests: XCTestCase {
    func testFloodCategoryMapping() {
        XCTAssertEqual(HazardFeedScores.floodCategoryScore("no_flooding"), 0)
        XCTAssertEqual(HazardFeedScores.floodCategoryScore("out_of_service"), 0)
        XCTAssertEqual(HazardFeedScores.floodCategoryScore("action"), 0.25, accuracy: 1e-9)
        XCTAssertEqual(HazardFeedScores.floodCategoryScore("major"), 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(HazardFeedScores.floodCategoryScore("moderate"),
                             HazardFeedScores.floodCategoryScore("minor"))
    }

    func testFloodGaugeProximityAndReach() {
        let here = CLLocationCoordinate2D(latitude: 43.0, longitude: -89.0)
        // A major-flood gauge right here scores near 1; a no_flooding gauge 0.
        let atGauge = HazardFeedScores.floodGaugeScore(
            gauges: [(43.0, -89.0, "major")], at: here)
        XCTAssertEqual(atGauge, 1.0, accuracy: 0.02)
        XCTAssertEqual(HazardFeedScores.floodGaugeScore(
            gauges: [(43.0, -89.0, "no_flooding")], at: here), 0)
        // A flooding gauge >20 km away is out of reach.
        let far = CLLocationCoordinate2D(latitude: 43.5, longitude: -89.0) // ~55 km
        XCTAssertEqual(HazardFeedScores.floodGaugeScore(
            gauges: [(43.0, -89.0, "major")], at: far), 0)
    }

    func testFirePerimeterInsideAndBuffer() {
        // Unit square around (43,-89).
        let ring = [
            CLLocationCoordinate2D(latitude: 42.9, longitude: -89.1),
            CLLocationCoordinate2D(latitude: 43.1, longitude: -89.1),
            CLLocationCoordinate2D(latitude: 43.1, longitude: -88.9),
            CLLocationCoordinate2D(latitude: 42.9, longitude: -88.9),
        ]
        let inside = CLLocationCoordinate2D(latitude: 43.0, longitude: -89.0)
        XCTAssertTrue(HazardFeedScores.pointInPolygon(inside, ring))
        XCTAssertEqual(HazardFeedScores.firePerimeterScore(perimeters: [ring], at: inside), 1.0)
        // Far outside the 12 km buffer → 0.
        let away = CLLocationCoordinate2D(latitude: 44.0, longitude: -89.0)
        XCTAssertFalse(HazardFeedScores.pointInPolygon(away, ring))
        XCTAssertEqual(HazardFeedScores.firePerimeterScore(perimeters: [ring], at: away), 0)
    }

    func testSpaceWeatherScaleAndLatitude() {
        // Quiet space weather contributes nothing.
        XCTAssertEqual(HazardFeedScores.radiationSpaceWeatherScore(
            sScale: 0, gScale: 0, latitude: 45), 0)
        // A strong solar radiation storm (S4) is felt everywhere.
        XCTAssertEqual(HazardFeedScores.spaceWeatherScore(scale: 4), 0.78, accuracy: 1e-9)
        // A severe geomagnetic storm hits high latitudes harder than low ones.
        let high = HazardFeedScores.radiationSpaceWeatherScore(
            sScale: 0, gScale: 5, latitude: 65)
        let low = HazardFeedScores.radiationSpaceWeatherScore(
            sScale: 0, gScale: 5, latitude: 20)
        XCTAssertGreaterThan(high, low)
        XCTAssertEqual(high, 1.0, accuracy: 1e-9)
    }
}

/// The four acute live-feed families added from the cross-country sweep:
/// volcanic (USGS HANS), avalanche (Avalanche.org/Canada), tropical (NHC),
/// tsunami (NWS Tsunami Warning Centers). Pure scoring, feeds probed live.
final class AcuteFamilyTests: XCTestCase {
    private let here = CLLocationCoordinate2D(latitude: 46.85, longitude: -121.76)

    func testVolcanicAlertLevels() {
        XCTAssertEqual(HazardFeedScores.volcanoAlertScore("NORMAL"), 0)
        XCTAssertEqual(HazardFeedScores.volcanoAlertScore("ADVISORY"), 0.42, accuracy: 1e-9)
        XCTAssertEqual(HazardFeedScores.volcanoAlertScore("WARNING"), 1.0, accuracy: 1e-9)
        // A WATCH volcano right here scores ~0.72; one >80 km away is out of reach.
        XCTAssertEqual(HazardFeedScores.volcanicScore(
            volcanoes: [(46.85, -121.76, "WATCH")], at: here), 0.72, accuracy: 0.02)
        XCTAssertEqual(HazardFeedScores.volcanicScore(
            volcanoes: [(48.0, -121.76, "WARNING")], at: here), 0) // ~128 km away
    }

    func testAvalancheRatingAndZone() {
        XCTAssertEqual(HazardFeedScores.avalancheRatingScore(0), 0)
        XCTAssertGreaterThan(HazardFeedScores.avalancheRatingScore(4),
                             HazardFeedScores.avalancheRatingScore(2))
        let ring = [
            CLLocationCoordinate2D(latitude: 46.8, longitude: -121.9),
            CLLocationCoordinate2D(latitude: 46.9, longitude: -121.9),
            CLLocationCoordinate2D(latitude: 46.9, longitude: -121.6),
            CLLocationCoordinate2D(latitude: 46.8, longitude: -121.6),
        ]
        XCTAssertEqual(HazardFeedScores.avalancheScore(
            zones: [(rings: [ring], rating: 4)], at: here), 0.90, accuracy: 1e-9)
        // Considerable (3) is dangerous enough to land in the yellow band.
        XCTAssertGreaterThanOrEqual(HazardFeedScores.avalancheRatingScore(3),
                                    FlowsCore.riskYellowMin)
        let outside = CLLocationCoordinate2D(latitude: 40.0, longitude: -105.0)
        XCTAssertEqual(HazardFeedScores.avalancheScore(
            zones: [(rings: [ring], rating: 4)], at: outside), 0)
    }

    func testTropicalIntensityAndReach() {
        XCTAssertGreaterThan(HazardFeedScores.tropicalIntensityScore(maxWindKt: 130),
                             HazardFeedScores.tropicalIntensityScore(maxWindKt: 40))
        // A category-4 storm at the point scores near 1; the same storm far
        // outside its (intensity-scaled) reach scores 0.
        let atStorm = HazardFeedScores.tropicalScore(
            storms: [(46.85, -121.76, 120)], at: here)
        XCTAssertGreaterThan(atStorm, 0.85)
        let far = CLLocationCoordinate2D(latitude: 40.0, longitude: -121.76) // ~760 km
        XCTAssertEqual(HazardFeedScores.tropicalScore(
            storms: [(46.85, -121.76, 120)], at: far), 0)
    }

    func testTsunamiLevelAndReach() {
        XCTAssertEqual(HazardFeedScores.tsunamiLevelScore("Tsunami Information Statement"), 0)
        XCTAssertEqual(HazardFeedScores.tsunamiLevelScore("Tsunami Warning Number 1"), 1.0, accuracy: 1e-9)
        XCTAssertEqual(HazardFeedScores.tsunamiLevelScore("Tsunami Advisory"), 0.82, accuracy: 1e-9)
        // A warning at the coast scores high; an information statement never scores.
        XCTAssertGreaterThan(HazardFeedScores.tsunamiScore(
            events: [(46.85, -121.76, "Tsunami Warning")], at: here), 0.9)
        XCTAssertEqual(HazardFeedScores.tsunamiScore(
            events: [(46.85, -121.76, "Tsunami Information Statement")], at: here), 0)
    }

    func testConvectiveOutlookScore() {
        // SPC categories map proportionally: SLGT reaches green→yellow edge,
        // MDT and HIGH (tornado-outbreak potential) are red.
        XCTAssertEqual(HazardFeedScores.spcCategoricalScore(dn: 2), 0.35, accuracy: 1e-9)
        XCTAssertGreaterThan(HazardFeedScores.spcCategoricalScore(dn: 6), 0.8751) // MDT = red
        XCTAssertEqual(HazardFeedScores.spcCategoricalScore(dn: 8), 1.0, accuracy: 1e-9)
        let ring = [
            CLLocationCoordinate2D(latitude: 34.9, longitude: -98.1),
            CLLocationCoordinate2D(latitude: 35.1, longitude: -98.1),
            CLLocationCoordinate2D(latitude: 35.1, longitude: -97.9),
            CLLocationCoordinate2D(latitude: 34.9, longitude: -97.9),
        ]
        let inside = CLLocationCoordinate2D(latitude: 35.0, longitude: -98.0)
        XCTAssertEqual(HazardFeedScores.outlookScore(
            zones: [(rings: [ring], score: 0.88)], at: inside), 0.88, accuracy: 1e-9)
        XCTAssertEqual(HazardFeedScores.outlookScore(
            zones: [(rings: [ring], score: 0.88)],
            at: CLLocationCoordinate2D(latitude: 40, longitude: -98)), 0)
    }

    /// Proportionality guardrail: the acute families reach RED only at their
    /// genuinely life-threatening levels, and the flood weight resolves under
    /// BOTH the app key (`qpf_flood`) and the R-export key (`flood`).
    func testFamilyProportionalityToBands() {
        let red = 0.8751
        // Life-threatening ends are red…
        XCTAssertGreaterThan(HazardFeedScores.tsunamiLevelScore("warning"), red)
        XCTAssertGreaterThan(HazardFeedScores.volcanoAlertScore("WARNING"), red)
        XCTAssertGreaterThan(HazardFeedScores.avalancheRatingScore(4), red)     // High
        XCTAssertGreaterThan(HazardFeedScores.tropicalIntensityScore(maxWindKt: 100), red) // Cat 3
        // …and the low ends are NOT red (a tropical storm / Considerable-1 stay sub-red).
        XCTAssertLessThan(HazardFeedScores.tropicalIntensityScore(maxWindKt: 45), red)
        XCTAssertLessThan(HazardFeedScores.avalancheRatingScore(2), red)
        // Flood weight resolves the same under either key.
        XCTAssertEqual(RiskEquations.familyWeights["qpf_flood"],
                       RiskEquations.familyWeights["flood"])
    }
}

/// WMO Alert Hub CAP parsing (Mexico + Central America + Caribbean official
/// alerts). Feeds probed live on severeweather.wmo.int before shipping.
final class WMOAlertTests: XCTestCase {
    func testFeedRouting() {
        // Mexico City → Mexico feed; San José → Costa Rica; Panama City → Panama.
        XCTAssertEqual(WMOAlertParsing.feedCode(
            for: .init(latitude: 19.43, longitude: -99.13)), "mx-smn-es")
        XCTAssertEqual(WMOAlertParsing.feedCode(
            for: .init(latitude: 9.93, longitude: -84.08)), "cr-imn-es")
        XCTAssertEqual(WMOAlertParsing.feedCode(
            for: .init(latitude: 8.98, longitude: -79.52)), "pa-imhpa-es")
        // Belize's small box wins over Mexico's regional catch-all.
        XCTAssertEqual(WMOAlertParsing.feedCode(
            for: .init(latitude: 17.19, longitude: -88.5)), "bz-nms-en")
        // US point → no WMO feed (handled by NWS).
        XCTAssertNil(WMOAlertParsing.feedCode(
            for: .init(latitude: 43.07, longitude: -89.4)))
    }

    func testRSSAndCAPParsing() {
        let rss = """
        <rss><channel><item><title>Zona de inestabilidad</title>\
        <cap:event>Aviso de lluvias</cap:event><cap:severity>Moderate</cap:severity>\
        <cap:expires>Tue, 16 Jun 2026 17:00:00 +0000</cap:expires>\
        <link>https://severeweather.wmo.int/v2/cap-alerts/mx-smn-es/2026/06/16/13/00/00-abc.xml</link>\
        </item></channel></rss>
        """
        let items = WMOAlertParsing.parseRSSItems(rss)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.event, "Aviso de lluvias")
        XCTAssertEqual(items.first?.severity, "Moderate")
        XCTAssertTrue(items.first?.link.hasSuffix(".xml") ?? false)

        let cap = """
        <alert><info><event>Aviso de lluvias</event><severity>Severe</severity>\
        <area><areaDesc>SLP, TAMPS, VER</areaDesc>\
        <polygon>22.0,-98.0 22.5,-98.0 22.5,-97.5 22.0,-97.5 22.0,-98.0</polygon></area>\
        <web>https://smn.conagua.gob.mx/</web></info></alert>
        """
        let parsed = WMOAlertParsing.parseCAP(cap)
        XCTAssertEqual(parsed?.severity, "Severe")
        XCTAssertEqual(parsed?.polygon.count, 5)
        // CAP polygon is lat,lon — first vertex must decode to (22.0, -98.0).
        XCTAssertEqual(parsed?.polygon.first?.latitude ?? 0, 22.0, accuracy: 1e-9)
        XCTAssertEqual(parsed?.polygon.first?.longitude ?? 0, -98.0, accuracy: 1e-9)
        // A point inside the box is matched; one outside is not.
        let ring = parsed!.polygon
        XCTAssertTrue(HazardFeedScores.pointInPolygon(
            .init(latitude: 22.25, longitude: -97.75), ring))
        XCTAssertFalse(HazardFeedScores.pointInPolygon(
            .init(latitude: 25.0, longitude: -97.75), ring))
    }
}

/// Device-adaptive tuning + the global request gate that keep FLOWS from
/// barraging sources and let it run on old and new Apple hardware alike.
final class AdaptiveTuningTests: XCTestCase {
    func testBaseTierFromHardware() {
        // iPhone 7 (A10): 2 cores / 2 GB → low. iPhone 12: 6 / 4 → standard.
        // iPad Pro / M-series: 8 / 8 → high.
        XCTAssertEqual(AdaptiveTuning.baseTier(cores: 2, memoryGB: 2), .low)
        XCTAssertEqual(AdaptiveTuning.baseTier(cores: 6, memoryGB: 4), .standard)
        XCTAssertEqual(AdaptiveTuning.baseTier(cores: 8, memoryGB: 8), .high)
        // A single weak axis (RAM) pins it down even with many cores.
        XCTAssertEqual(AdaptiveTuning.baseTier(cores: 8, memoryGB: 2), .low)
    }

    func testSettingsScaleAndBackOff() {
        let low = AdaptiveTuning.settings(tier: .low, thermal: .nominal, lowPower: false)
        let high = AdaptiveTuning.settings(tier: .high, thermal: .nominal, lowPower: false)
        // Weaker devices → smaller grid, fewer concurrent requests.
        XCTAssertLessThan(low.viewportGridSpan, high.viewportGridSpan)
        XCTAssertLessThan(low.maxInFlight, high.maxInFlight)
        XCTAssertEqual(low.viewportGridSpan, 3)
        XCTAssertEqual(high.viewportGridSpan, 5)
        // Heat and Low Power Mode throttle a high-tier device HARD.
        let hot = AdaptiveTuning.settings(tier: .high, thermal: .critical, lowPower: false)
        XCTAssertLessThanOrEqual(hot.maxInFlight, 2)
        XCTAssertGreaterThanOrEqual(hot.ttlMultiplier, 3.0)   // refresh far less often
        let saving = AdaptiveTuning.settings(tier: .high, thermal: .nominal, lowPower: true)
        XCTAssertGreaterThanOrEqual(saving.ttlMultiplier, 2.0)
        XCTAssertLessThanOrEqual(saving.maxInFlight, 5)
        // ttl() stretches a base interval by the multiplier.
        XCTAssertEqual(hot.ttlMultiplier * 1800, 5400, accuracy: 1e-6)
    }

    /// The gate must never let more than the device cap run at once, no matter
    /// how wide the fan-out.
    func testRequestGateCapsConcurrency() async {
        let cap = AdaptiveTuning.shared.maxInFlight
        actor Peak { var cur = 0; var hi = 0
            func enter() { cur += 1; hi = Swift.max(hi, cur) }
            func leave() { cur -= 1 }
            func peak() -> Int { hi } }
        let peak = Peak()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<50 {
                g.addTask {
                    try? await RequestGate.shared.withPermit {
                        await peak.enter()
                        try? await Task.sleep(for: .milliseconds(3))
                        await peak.leave()
                    }
                }
            }
        }
        let hi = await peak.peak()
        XCTAssertGreaterThan(hi, 0)
        XCTAssertLessThanOrEqual(hi, cap, "gate exceeded the device concurrency cap")
    }

    /// Rental recommendations at a transit destination: nearest office PER
    /// BRAND (airport + downtown Enterprise = one booking), biggest brands
    /// first, unknown independents keep their own dedupe key and sort last,
    /// capped at three; the booking link falls back to the brand site.
    func testRentalCarRecommendations() {
        func office(_ name: String, _ miles: Double) -> RentalCars.Office {
            RentalCars.Office(name: name, miles: miles, url: nil)
        }
        let picks = RentalCars.recommend([
            office("Hertz Car Rental - Columbia Airport", 6.2),
            office("Hertz", 1.1),                      // nearer Hertz wins the brand
            office("Enterprise Rent-A-Car", 0.8),
            office("Bob's Rent-a-Wreck", 0.2),         // unknown: sorts after brands
            office("Avis Car Rental", 2.5),
        ])
        XCTAssertEqual(picks.map(\.name),
                       ["Enterprise Rent-A-Car", "Hertz", "Avis Car Rental"],
                       "brand-size order, nearest per brand, top 3")
        XCTAssertEqual(picks[1].miles, 1.1, accuracy: 1e-9,
                       "the 1.1 mi Hertz beats the airport one")
        // Two different independents both survive dedupe (own-name keys).
        let locals = RentalCars.recommend([
            office("Bob's Rentals", 0.5), office("Carol's Cars", 0.7)])
        XCTAssertEqual(locals.count, 2)
        // Booking fallback: recognized brands link to their own site;
        // unknown agencies get nil (name + distance still shown).
        XCTAssertEqual(RentalCars.bookingURL(name: "Hertz Car Rental")?.host,
                       "www.hertz.com")
        XCTAssertEqual(RentalCars.bookingURL(name: "Enterprise Rent-A-Car")?.host,
                       "www.enterprise.com")
        XCTAssertNil(RentalCars.bookingURL(name: "Bob's Rent-a-Wreck"))
    }

    /// Per-host circuit breaker: transport failures trip it after N in a row,
    /// an open breaker refuses the host (fast-fail — zombie sockets must not
    /// hold the permit pool), the cooldown admits exactly ONE probe whose
    /// outcome closes or re-opens it, and other hosts are never affected.
    func testHostBreakerTripProbeAndRecovery() async {
        let b = HostBreaker(trip: 3, cooldown: 0.15)
        // Below the trip count the host is still admitted.
        await b.recordFailure("epqs.gov"); await b.recordFailure("epqs.gov")
        var ok = await b.admits("epqs.gov")
        XCTAssertTrue(ok, "2 failures with trip=3 must still admit")
        // Third straight failure opens it; a healthy host is unaffected.
        await b.recordFailure("epqs.gov")
        ok = await b.admits("epqs.gov")
        XCTAssertFalse(ok, "3rd failure must open the breaker")
        ok = await b.admits("overpass.de")
        XCTAssertTrue(ok, "breaker is per-host — other hosts stay open")
        // After the cooldown exactly one probe goes through at a time.
        try? await Task.sleep(for: .milliseconds(200))
        let first = await b.admits("epqs.gov")
        let second = await b.admits("epqs.gov")
        XCTAssertTrue(first, "cooldown elapsed → one probe admitted")
        XCTAssertFalse(second, "no thundering herd — only ONE probe in flight")
        // Probe fails → re-opens for a fresh cooldown.
        await b.recordFailure("epqs.gov")
        ok = await b.admits("epqs.gov")
        XCTAssertFalse(ok, "failed probe re-opens the breaker")
        // Next probe succeeds → fully closed again.
        try? await Task.sleep(for: .milliseconds(200))
        _ = await b.admits("epqs.gov")
        await b.recordSuccess("epqs.gov")
        ok = await b.admits("epqs.gov")
        XCTAssertTrue(ok, "successful probe closes the breaker")
    }

    /// The source-fallback primitive must return the FIRST non-nil source, try
    /// sources strictly in order, short-circuit once one succeeds (never touch
    /// later sources), and return nil only when every source failed.
    func testFirstNonNilFallbackOrderAndShortCircuit() async {
        // Primary fails, secondary succeeds → secondary's value, tertiary untouched.
        let touched = Sendable_Box()
        let got = await ThrottledNet.firstNonNil([
            { await touched.mark(0); return Int?.none },       // primary down
            { await touched.mark(1); return 42 },              // secondary works
            { await touched.mark(2); return 99 },              // must NOT run
        ])
        XCTAssertEqual(got, 42, "returns the first source that yields a value")
        let order = await touched.order
        XCTAssertEqual(order, [0, 1], "tries in order and short-circuits after success")

        // All sources fail → nil (feed degrades, doesn't crash).
        let none = await ThrottledNet.firstNonNil([
            { Int?.none }, { Int?.none },
        ])
        XCTAssertNil(none, "nil only when every source failed")

        // Primary succeeds → later sources never consulted (cheapest path).
        let box2 = Sendable_Box()
        let first = await ThrottledNet.firstNonNil([
            { await box2.mark(0); return 7 },
            { await box2.mark(1); return 8 },
        ])
        XCTAssertEqual(first, 7)
        let order2 = await box2.order
        XCTAssertEqual(order2, [0], "primary success means no fallback fetch")
    }
}

/// Records the order sources were consulted, for the fallback-ordering test.
private actor Sendable_Box {
    private(set) var order: [Int] = []
    func mark(_ i: Int) { order.append(i) }
}

/// Multi-leg transit itinerary logic — the no-car last mile and the in-app
/// board/alight steps that replace the Apple Maps hand-off.
final class TransitItineraryTests: XCTestCase {
    func testRideStepsAndDuration() {
        let steps = TransitPlanning.rideSteps(
            mode: "Amtrak", board: "Miami Amtrak", alight: "Toronto Union", seconds: 39 * 3600)
        XCTAssertEqual(steps.count, 3)
        XCTAssertTrue(steps[0].contains("Board the Amtrak at Miami Amtrak"))
        XCTAssertTrue(steps[2].contains("Get off at Toronto Union"))
        XCTAssertEqual(TransitPlanning.durationPhrase(45 * 60), "about 45 min")
        XCTAssertEqual(TransitPlanning.durationPhrase(2 * 3600), "about 2h 0m")
        XCTAssertEqual(TransitPlanning.durationPhrase(nil), "(check the schedule)")
    }

    func testConnectorGeometry() {
        let a = CLLocationCoordinate2D(latitude: 25.77, longitude: -80.19)   // Miami
        let b = CLLocationCoordinate2D(latitude: 43.65, longitude: -79.38)   // Toronto
        let line = TransitPlanning.connector(a, b)
        XCTAssertEqual(line.pointCount, 2)
    }

    func testRideDurationAnchorsToDriveTimeThenFallsBack() {
        let drive: TimeInterval = 22 * 3600   // a real 22 h drive corridor
        let bus = TransitPlanning.rideDuration(mode: "Greyhound", driveSeconds: drive, miles: 1500)
        let rail = TransitPlanning.rideDuration(mode: "Amtrak", driveSeconds: drive, miles: 1500)
        // A scheduled service is always slower door-to-door than solo driving.
        XCTAssertGreaterThan(bus, drive)
        XCTAssertGreaterThan(rail, drive)
        // The estimate is mode-differentiated (the old .transit ETA was not):
        // long-haul US rail rides slower than the coach here (transfers).
        XCTAssertGreaterThan(rail, bus)
        // Stays in a sane band for a ~1500 mi corridor (no runaway numbers).
        XCTAssertLessThan(bus, 40 * 3600)
        XCTAssertLessThan(rail, 40 * 3600)

        // No drivable base (e.g. over-water leg) → distance ÷ effective speed,
        // positive and linear in distance.
        let f1 = TransitPlanning.rideDuration(mode: "Greyhound", driveSeconds: nil, miles: 500)
        let f2 = TransitPlanning.rideDuration(mode: "Greyhound", driveSeconds: nil, miles: 1000)
        XCTAssertGreaterThan(f1, 0)
        XCTAssertEqual(f2, f1 * 2, accuracy: 1)
        // Mode ordering must NOT flip between the two paths: Amtrak is slower than
        // Greyhound on the drive-scaled path, so it must also be slower on the
        // fallback path (fallbackMPH kept monotonic with rideMultiplier).
        let railFb = TransitPlanning.rideDuration(mode: "Amtrak", driveSeconds: nil, miles: 1500)
        let busFb = TransitPlanning.rideDuration(mode: "Greyhound", driveSeconds: nil, miles: 1500)
        XCTAssertGreaterThan(railFb, busFb, "Amtrak must stay slower than Greyhound on BOTH paths")
        // Degenerate inputs never crash or go negative/NaN.
        XCTAssertEqual(TransitPlanning.rideDuration(mode: "Bus", driveSeconds: 0, miles: 0),
                       0, accuracy: 0.0001)
        XCTAssertEqual(TransitPlanning.rideDuration(mode: "Bus", driveSeconds: nil, miles: 0),
                       0, accuracy: 0.0001)
        // Every mode has a >1 overhead (transit is never faster than driving here)
        // and a positive fallback speed.
        for mode in ["Amtrak", "Greyhound", "Rail", "Bus"] {
            XCTAssertGreaterThan(TransitPlanning.rideMultiplier(mode), 1.0)
            XCTAssertGreaterThan(TransitPlanning.fallbackMPH(mode), 0)
        }
    }

    func testItineraryEndsWithWalkNotDrive() {
        // The last leg of a transit itinerary must be a WALK — the traveller
        // has no car at the destination.
        let legs = [
            TransitLeg(kind: .walk, fromName: "Start", toName: "Miami Amtrak",
                       seconds: 700, miles: 0.5, polyline: nil, steps: ["a"]),
            TransitLeg(kind: .ride, fromName: "Miami Amtrak", toName: "Toronto Union",
                       seconds: 140_000, miles: 1400, polyline: nil, steps: ["b"]),
            TransitLeg(kind: .walk, fromName: "Toronto Union", toName: "Destination",
                       seconds: 500, miles: 0.4, polyline: nil, steps: ["c"]),
        ]
        let itin = TransitItinerary(mode: "Amtrak", legs: legs, fare: 185,
            mapsDestination: MKMapItem(placemark: MKPlacemark(
                coordinate: CLLocationCoordinate2D(latitude: 43.65, longitude: -79.38))),
            rideGeometryIsApproximate: true)
        XCTAssertEqual(itin.legs.last?.kind, .walk, "last mile must be a walk, never a drive")
        XCTAssertEqual(itin.legs.first?.kind, .walk)
        XCTAssertEqual(itin.totalSeconds, 141_200, accuracy: 1)
        // Default provenance is "real geometry"; the flag can flip to false so
        // the UI can honestly downgrade the "follows the roads" claim.
        XCTAssertTrue(itin.rideGeometryIsReal)
    }

    func testGeometryProvenanceAndZeroFare() {
        // A walk-only collapse (no ride found) carries no fare and a straight
        // (non-real) ride geometry flag — the card must not claim road-following
        // nor show a phantom minimum fare.
        let legs = [
            TransitLeg(kind: .walk, fromName: "Start", toName: "Central Station",
                       seconds: 600, miles: 0.4, polyline: nil, steps: ["a"]),
            TransitLeg(kind: .walk, fromName: "Central Station", toName: "Destination",
                       seconds: 500, miles: 0.3, polyline: nil, steps: ["b"]),
        ]
        let itin = TransitItinerary(mode: "Bus", legs: legs, fare: 0,
            mapsDestination: MKMapItem(placemark: MKPlacemark(
                coordinate: CLLocationCoordinate2D(latitude: 40, longitude: -80))),
            rideGeometryIsApproximate: false, rideGeometryIsReal: false)
        XCTAssertEqual(itin.legs.last?.kind, .walk)
        XCTAssertEqual(itin.fare, 0, "walk-only collapse must not show a phantom fare")
        XCTAssertFalse(itin.rideGeometryIsReal)
    }
}

/// Grade-slider default from the vehicle — "the grade where a parking brake
/// is highly encouraged" (FilterLimits.vehicleDefaultMaxGradeDegrees).
final class GradeDefaultTests: XCTestCase {

    func testGradeDefaultByWeightClass() {
        // Sedan (GVWR under 6,000): 18% ≈ 10.2° → rounds to the 0.5° step.
        XCTAssertEqual(FilterLimits.vehicleDefaultMaxGradeDegrees(
            publishedMaxGradePercent: nil, gvwrLbs: 3_910, towCapacityLbs: 1_500,
            heightFeet: 4.8, towing: false, trailerWeightLbs: 0), 10.0)
        // Half-ton pickup (7,050): 15% ≈ 8.5°.
        XCTAssertEqual(FilterLimits.vehicleDefaultMaxGradeDegrees(
            publishedMaxGradePercent: nil, gvwrLbs: 7_050, towCapacityLbs: 11_200,
            heightFeet: 6.4, towing: false, trailerWeightLbs: 0), 8.5)
        // HD pickup (10,800): 12% ≈ 6.8° → 7.0°.
        XCTAssertEqual(FilterLimits.vehicleDefaultMaxGradeDegrees(
            publishedMaxGradePercent: nil, gvwrLbs: 10_800, towCapacityLbs: 20_000,
            heightFeet: 6.8, towing: false, trailerWeightLbs: 0), 7.0)
        // Box truck (14,500): 9% ≈ 5.1° → 5.0°.
        XCTAssertEqual(FilterLimits.vehicleDefaultMaxGradeDegrees(
            publishedMaxGradePercent: nil, gvwrLbs: 14_500, towCapacityLbs: 6_000,
            heightFeet: 12.0, towing: false, trailerWeightLbs: 0), 5.0)
    }

    func testGradeDefaultPublishedGuidanceWins() {
        // Semi: the maker's 6% steep-grade guidance beats the weight ladder.
        XCTAssertEqual(FilterLimits.vehicleDefaultMaxGradeDegrees(
            publishedMaxGradePercent: 6, gvwrLbs: 35_000, towCapacityLbs: 45_000,
            heightFeet: 13.5, towing: false, trailerWeightLbs: 0), 3.5)
        // And the curated table actually carries it for the semis.
        XCTAssertEqual(VehicleSpecs.spec(make: "Freightliner",
                                         model: "Cascadia (semi)")?.publishedMaxGradePercent, 6)
    }

    func testGradeDefaultLowersWhenTowing() {
        // F-150 towing at all: 15% base capped to 10% ≈ 5.7° → 5.5°.
        XCTAssertEqual(FilterLimits.vehicleDefaultMaxGradeDegrees(
            publishedMaxGradePercent: nil, gvwrLbs: 7_050, towCapacityLbs: 11_200,
            heightFeet: 6.4, towing: true, trailerWeightLbs: 2_000), 5.5)
        // Trailer at 60%+ of capacity: capped to 8% ≈ 4.6° → 4.5°.
        XCTAssertEqual(FilterLimits.vehicleDefaultMaxGradeDegrees(
            publishedMaxGradePercent: nil, gvwrLbs: 7_050, towCapacityLbs: 11_200,
            heightFeet: 6.4, towing: true, trailerWeightLbs: 8_000), 4.5)
        // At/over capacity: capped to 6% ≈ 3.4° → 3.5°.
        XCTAssertEqual(FilterLimits.vehicleDefaultMaxGradeDegrees(
            publishedMaxGradePercent: nil, gvwrLbs: 7_050, towCapacityLbs: 11_200,
            heightFeet: 6.4, towing: true, trailerWeightLbs: 11_200), 3.5)
        // Unknown capacity: a 5,000+ lb trailer counts as heavy.
        XCTAssertEqual(FilterLimits.vehicleDefaultMaxGradeDegrees(
            publishedMaxGradePercent: nil, gvwrLbs: 7_050, towCapacityLbs: nil,
            heightFeet: 6.4, towing: true, trailerWeightLbs: 6_000), 4.5)
    }

    func testGradeDefaultHeightFallbackAndClamp() {
        // No ratings at all → the height ladder (13'6" default = semi-ish).
        XCTAssertEqual(FilterLimits.vehicleDefaultMaxGradeDegrees(
            publishedMaxGradePercent: nil, gvwrLbs: nil, towCapacityLbs: nil,
            heightFeet: 13.5, towing: false, trailerWeightLbs: 0), 5.0)
        XCTAssertEqual(FilterLimits.vehicleDefaultMaxGradeDegrees(
            publishedMaxGradePercent: nil, gvwrLbs: nil, towCapacityLbs: nil,
            heightFeet: 4.8, towing: false, trailerWeightLbs: 0), 10.0)
        // The result always lands inside the slider's 2°–15° range.
        let extreme = FilterLimits.vehicleDefaultMaxGradeDegrees(
            publishedMaxGradePercent: 1, gvwrLbs: 99_000, towCapacityLbs: 0,
            heightFeet: 20, towing: true, trailerWeightLbs: 99_000)
        XCTAssertGreaterThanOrEqual(extreme, 2)
        XCTAssertLessThanOrEqual(extreme, 15)
    }
}

/// The O(1) grid indexes (RoutePath.nearest, LocationTable.entry) must return
/// results IDENTICAL to the O(N) brute-force scans they replaced.
final class SpatialIndexTests: XCTestCase {
    /// Tiny deterministic LCG so the fuzz is reproducible without a rng dependency.
    private struct Lcg {
        var s: UInt64
        mutating func d(_ lo: Double, _ hi: Double) -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return lo + Double(s >> 11) / Double(UInt64(1) << 53) * (hi - lo)
        }
        mutating func i(_ lo: Int, _ hi: Int) -> Int { Int(d(Double(lo), Double(hi))) }
    }

    func testRoutePathNearestGridEqualsBruteForce() {
        var rng = Lcg(s: 0x9E3779B97F4A7C15)
        for _ in 0..<25 {
            let n = rng.i(2, 400)
            var coords: [CLLocationCoordinate2D] = []
            var lat = rng.d(20, 60), lon = rng.d(-120, -70)
            for _ in 0..<n {
                lat += rng.d(-0.05, 0.05); lon += rng.d(-0.05, 0.05)
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
            let path = POIRanking.RoutePath(coords: coords)
            for qi in 0..<12 {
                // Mostly NEAR-route queries (exercise the grid fast path, like a
                // real corridor POI); a couple FAR ones exercise the linear
                // fallback. Both must match brute force.
                let q: CLLocationCoordinate2D
                if qi < 9 {
                    let base = coords[rng.i(0, coords.count)]
                    q = CLLocationCoordinate2D(latitude: base.latitude + rng.d(-0.03, 0.03),
                                               longitude: base.longitude + rng.d(-0.03, 0.03))
                } else {
                    q = CLLocationCoordinate2D(latitude: rng.d(19, 61), longitude: rng.d(-121, -69))
                }
                // brute-force reference (lowest index on strict-less, like the old scan)
                var bi = 0; var bd = CLLocationDistance.greatestFiniteMagnitude
                for (idx, c) in coords.enumerated() {
                    let dd = POIRanking.meters(c, q); if dd < bd { bd = dd; bi = idx }
                }
                let got = path.nearest(to: q)
                XCTAssertEqual(got?.index, bi, "grid nearest index must match brute force")
                XCTAssertEqual(got!.offRoute, bd, accuracy: 1e-9)
            }
        }
    }

    func testShowerTableGridEqualsBruteForce() {
        typealias Entry = ShowerAvailability.LocationTable.Entry
        var rng = Lcg(s: 0xD1B54A32D192ED03)
        for _ in 0..<25 {
            var entries: [Entry] = []
            let cLat = rng.d(25, 49)
            let cLon = rng.d(-120, -75)
            let count = rng.i(1, 60)
            for k in 0..<count {
                let elat = cLat + rng.d(-0.05, 0.05)
                let elon = cLon + rng.d(-0.05, 0.05)
                let sh: String? = (k % 2 == 0) ? "std" : nil
                entries.append(Entry(lat: elat, lon: elon, brand: "b\(k)", shower: sh))
            }
            let table = ShowerAvailability.LocationTable(entries: entries)
            for _ in 0..<12 {
                let qLat = cLat + rng.d(-0.06, 0.06)
                let qLon = cLon + rng.d(-0.06, 0.06)
                // brute-force reference: same box filter + nearest (first on tie).
                var best: Entry?
                var bd = Double.greatestFiniteMagnitude
                for e in entries {
                    guard abs(e.lat - qLat) < 0.01, abs(e.lon - qLon) < 0.01 else { continue }
                    let dLat = e.lat - qLat
                    let dLon = e.lon - qLon
                    let dd = dLat * dLat + dLon * dLon
                    if dd < bd { bd = dd; best = e }
                }
                let got = table.entry(nearLat: qLat, lon: qLon)
                XCTAssertEqual(got?.brand, best?.brand, "grid entry must match brute force")
            }
        }
    }

    func testBadgeClusteringGridEqualsBruteForce() {
        typealias Item = BadgeClustering.Item<Int>
        var rng = Lcg(s: 0xA5A5A5A5DEADBEEF)
        // Oracle: the original O(N²) linear greedy clustering + score-weighted
        // centroid. The grid path must reproduce this BIT-for-BIT (both iterate
        // the same sorted order and fold each group in the same append order).
        func oracle(_ items: [Item], _ minSep: CLLocationDistance) -> [Item] {
            var seeds: [Item] = []
            var members: [[Item]] = []
            for item in items.sorted(by: { $0.score > $1.score }) {
                if let si = seeds.firstIndex(where: { s in
                    s.kind == item.kind
                        && POIRanking.meters(s.coordinate, item.coordinate) < minSep
                }) {
                    members[si].append(item)
                } else {
                    seeds.append(item); members.append([item])
                }
            }
            return zip(seeds, members).map { seed, group in
                let w = group.reduce(0.0) { $0 + max($1.score, 1e-4) }
                let lat = group.reduce(0.0) { $0 + $1.coordinate.latitude * max($1.score, 1e-4) } / w
                let lon = group.reduce(0.0) { $0 + $1.coordinate.longitude * max($1.score, 1e-4) } / w
                return Item(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            kind: seed.kind, score: seed.score)
            }
        }
        for _ in 0..<30 {
            // N spans the linear→grid threshold (64); tight cluster centers so
            // seeds genuinely merge (the case where firstIndex order matters).
            let n = rng.i(2, 400)
            let nCenters = rng.i(1, 8)
            var centers: [(Double, Double)] = []
            for _ in 0..<nCenters { centers.append((rng.d(22, 60), rng.d(-124, -70))) }
            var items: [Item] = []
            for _ in 0..<n {
                let c = centers[rng.i(0, centers.count)]
                items.append(Item(
                    coordinate: CLLocationCoordinate2D(latitude: c.0 + rng.d(-0.8, 0.8),
                                                       longitude: c.1 + rng.d(-0.8, 0.8)),
                    kind: rng.i(0, 4), score: rng.d(0, 100)))
            }
            for minSep in [3_000.0, 25_000.0, 120_000.0] {
                let got = BadgeClustering.cluster(items, minSeparationMeters: minSep)
                let want = oracle(items, minSep)
                XCTAssertEqual(got.count, want.count, "cluster count must match brute force")
                for (g, w) in zip(got, want) {
                    XCTAssertEqual(g.coordinate.latitude, w.coordinate.latitude,
                                   "centroid lat must be bit-identical")
                    XCTAssertEqual(g.coordinate.longitude, w.coordinate.longitude,
                                   "centroid lon must be bit-identical")
                    XCTAssertEqual(g.kind, w.kind)
                    XCTAssertEqual(g.score, w.score)
                }
            }
        }
    }

    func testRiskFieldSelectZipsGridEqualsBruteForce() {
        typealias Entry = RiskFieldService.ZipEntry
        var rng = Lcg(s: 0x1234_5678_9ABC_DEF0)
        // Oracle: the original O(E) full-entry filter + score-sort + prefix.
        func oracle(_ entries: [Entry], _ latMin: Double, _ latMax: Double,
                    _ lonMin: Double, _ lonMax: Double, _ fi: Int, _ limit: Int) -> [Entry] {
            entries.lazy
                .filter {
                    $0.centroid.latitude >= latMin && $0.centroid.latitude <= latMax
                        && $0.centroid.longitude >= lonMin && $0.centroid.longitude <= lonMax
                        && $0.ring != nil
                }
                .sorted { a, b in
                    (fi < a.scores.count ? a.scores[fi] : 0) > (fi < b.scores.count ? b.scores[fi] : 0)
                }
                .prefix(limit).map { $0 }
        }
        for _ in 0..<25 {
            let n = rng.i(1, 500)
            let cLat = rng.d(25, 55), cLon = rng.d(-120, -75)
            var entries: [Entry] = []
            for k in 0..<n {
                let lat = cLat + rng.d(-4, 4), lon = cLon + rng.d(-6, 6)
                // Scores from a tiny set so ties are common → stable-sort parity.
                let score = Double(rng.i(0, 5)) / 4.0
                let ring: [CLLocationCoordinate2D]? = (k % 4 == 0) ? nil
                    : [CLLocationCoordinate2D(latitude: lat, longitude: lon)]
                entries.append(Entry(zip: "z\(k)",
                                     centroid: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                     scores: [score], summary: nil, ring: ring))
            }
            let grid = RiskFieldService.buildGrid(entries)
            // Tight viewports (grid path), a whole-planet box (full-scan fallback),
            // and an off-map box (empty result) — all must match brute force.
            let boxes: [(Double, Double, Double, Double)] = [
                (cLat - 1, cLat + 1, cLon - 1.5, cLon + 1.5),
                (cLat - 0.3, cLat + 0.3, cLon - 0.3, cLon + 0.3),
                (-90, 90, -180, 180),
                (80, 85, 100, 120),
            ]
            for (latMin, latMax, lonMin, lonMax) in boxes {
                for limit in [5, 50, 10_000] {
                    let got = RiskFieldService.selectZips(
                        entries: entries, grid: grid,
                        latMin: latMin, latMax: latMax, lonMin: lonMin, lonMax: lonMax,
                        fi: 0, limit: limit)
                    let want = oracle(entries, latMin, latMax, lonMin, lonMax, 0, limit)
                    XCTAssertEqual(got.map { $0.zip }, want.map { $0.zip },
                                   "selectZips must match brute force (same set, same order)")
                }
            }
        }
    }
}
