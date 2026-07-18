// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The per-ZIP climate typing that replaces 1-D latitude bands for temperature
/// normalization — and its accuracy payoff (heat is dangerous relative to the
/// LOCAL climate, not an absolute number).
final class ClimateProfilesTests: XCTestCase {
    private func type(_ lat: Double, _ lon: Double, _ elev: Double? = nil)
        -> ClimateProfiles.ClimateType {
        ClimateProfiles.classify(latitude: lat, longitude: lon, elevationMeters: elev)
    }

    // Same-latitude pairs latitude bands call identical now differ correctly.
    func testSameLatitudePairsDiffer() {
        XCTAssertEqual(type(45.5, -122.7), .marineWestCoast)         // Portland OR
        XCTAssertEqual(type(44.98, -93.27), .humidContinentalCool)  // Minneapolis
        XCTAssertNotEqual(type(45.5, -122.7), type(44.98, -93.27))
    }

    // Known cities land in the right climate.
    func testKnownCities() {
        XCTAssertEqual(type(33.45, -112.07), .hotDesert)            // Phoenix
        XCTAssertEqual(type(47.61, -122.33), .marineWestCoast)      // Seattle
        XCTAssertEqual(type(34.05, -118.24), .mediterranean)       // Los Angeles
        XCTAssertEqual(type(25.76, -80.19), .tropical)             // Miami
        XCTAssertEqual(type(33.75, -84.39), .humidSubtropical)     // Atlanta
        XCTAssertEqual(type(41.88, -87.63), .humidContinentalWarm) // Chicago
        XCTAssertEqual(type(39.74, -104.99, 1609), .coldSteppe)    // Denver (BSk, semi-arid)
        XCTAssertEqual(type(39.10, -106.40, 3000), .highland)      // high Rockies (>2000 m)
    }

    // The whole point: 95 °F is a real risk in marine Seattle, ~none in Phoenix.
    func testHeatIsRelativeToClimate() {
        let seattle = ClimateProfiles.profile(latitude: 47.61, longitude: -122.33)
        let phoenix = ClimateProfiles.profile(latitude: 33.45, longitude: -112.07)
        func heat(_ p: LatitudeBands.Profile) -> Double {
            RiskEquations.temperatureRisk(
                tempF: 95, comfortLowF: p.comfortLowF, comfortHighF: p.comfortHighF,
                recordLowF: p.recordLowF, recordHighF: p.recordHighF)
        }
        XCTAssertGreaterThan(heat(seattle), 0.3, "95°F is anomalous for marine Seattle")
        XCTAssertLessThan(heat(phoenix), heat(seattle), "95°F is unremarkable in the desert")
    }

    // Every envelope is physically ordered.
    func testEnvelopesOrdered() {
        for t in ClimateProfiles.ClimateType.allCases {
            let p = t.profile
            XCTAssertLessThan(p.comfortLowF, p.comfortHighF, "\(t)")
            XCTAssertLessThan(p.recordLowF, p.comfortLowF, "\(t)")
            XCTAssertGreaterThan(p.recordHighF, p.comfortHighF, "\(t)")
        }
    }

    // Seasonal norms: winter ≠ summer for continental climates; the gate flags
    // only beyond-normal deviations — 62°F in a Minneapolis January is beyond
    // normal, 80°F in its July is not; ordinary wind never draws, a gale does.
    func testSeasonalNormalGates() {
        let mplsJan = ClimateProfiles.seasonalNorms(week: 0, latitude: 44.98, longitude: -93.27)
        let mplsJul = ClimateProfiles.seasonalNorms(week: 26, latitude: 44.98, longitude: -93.27)
        XCTAssertLessThan(mplsJan.weekHighF, mplsJul.weekHighF - 30,
                          "continental winter and summer norms must differ strongly")
        // 62°F in January: > 28 + 12 → beyond normal. 80°F in July: normal.
        XCTAssertTrue(ClimateProfiles.temperatureBeyondNormal(tempF: 62, norms: mplsJan))
        XCTAssertFalse(ClimateProfiles.temperatureBeyondNormal(tempF: 80, norms: mplsJul))
        XCTAssertFalse(ClimateProfiles.temperatureBeyondNormal(tempF: 20, norms: mplsJan),
                       "20°F is a NORMAL Minneapolis January day — no notice")
        XCTAssertTrue(ClimateProfiles.temperatureBeyondNormal(tempF: -5, norms: mplsJan))
        // Wind: mean 10 σ 4.5 → gate at 19 mph. 15 mph ordinary; 30 mph draws.
        XCTAssertFalse(ClimateProfiles.windBeyondNormal(windMph: 15, norms: mplsJan))
        XCTAssertTrue(ClimateProfiles.windBeyondNormal(windMph: 30, norms: mplsJan))
        // Plains steppe tolerates more wind before it's noteworthy.
        let denver = ClimateProfiles.seasonalNorms(week: 12, latitude: 39.74, longitude: -104.99)
        XCTAssertFalse(ClimateProfiles.windBeyondNormal(windMph: 18, norms: denver))
    }

    // Precise per-ZIP normals override the computed type once loaded on-demand.
    func testPreciseOverride() {
        let (lat, lon) = (40.0, -83.0)
        let before = ClimateProfiles.profile(latitude: lat, longitude: lon).comfortHighF
        let custom = LatitudeBands.Profile(band: 0, comfortLowF: 1, comfortHighF: 2,
                                           recordLowF: -1, recordHighF: 3)
        ClimateProfiles.loadPrecise([(lat, lon, custom)], home: nil)
        XCTAssertEqual(ClimateProfiles.profile(latitude: lat, longitude: lon).comfortHighF, 2)
        XCTAssertNotEqual(before, 2)
    }
}
