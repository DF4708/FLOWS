// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// The continental band system: inside Wisconsin it must reproduce the R
/// server's rows EXACTLY (vectors computed by assign_lat_band + the profile
/// CSV in R); beyond, the user-specified extension rules hold — same pitch,
/// −1°F/band gradient, elevation shifts clamped to ±1 (contiguous rule).
final class LatitudeBandsTests: XCTestCase {

    /// R-computed: (lat, band, comfort_low, comfort_high, record_low, record_high).
    private let rVectors: [(Double, Int, Double, Double, Double, Double)] = [
        (42.6000000000, 1, 60, 76, -28, 108),
        (43.0700000000, 2, 59, 75, -29, 107),
        (44.5000000000, 5, 56, 72, -32, 104),
        (45.9000000000, 8, 53, 69, -35, 101),
        (46.9000000000, 10, 51, 67, -37, 99),
        (42.3129850010, 1, 60, 76, -28, 108),
        (47.0806210000, 10, 51, 67, -37, 99),
    ]

    func testWisconsinBandsMatchTheRServerExactly() {
        for (lat, band, cl, ch, rl, rh) in rVectors {
            let p = LatitudeBands.profile(latitude: lat)
            XCTAssertEqual(p.band, band, "band at lat \(lat)")
            XCTAssertEqual(p.comfortLowF, cl)
            XCTAssertEqual(p.comfortHighF, ch)
            XCTAssertEqual(p.recordLowF, rl)
            XCTAssertEqual(p.recordHighF, rh)
        }
    }

    func testOneWisconsinNorthIsBandsElevenThroughTwenty() {
        // "If there's 10 across Wisconsin and we went one Wisconsin up in
        // distance there would be 20 bands."
        let wiHeight = LatitudeBands.northAnchor - LatitudeBands.southAnchor
        let justNorth = LatitudeBands.northAnchor + 0.01
        let oneWisconsinUp = LatitudeBands.northAnchor + wiHeight
        XCTAssertEqual(LatitudeBands.profile(latitude: justNorth).band, 11)
        XCTAssertEqual(LatitudeBands.profile(latitude: oneWisconsinUp).band, 20)
        // Gradient continues: band 20 comfort_low = 60 − 19 = 41.
        XCTAssertEqual(LatitudeBands.profile(latitude: oneWisconsinUp).comfortLowF, 41)
    }

    func testSouthernExtensionWarms() {
        // One band south of WI: comfort_low = 60 − (0−1) = 61.
        let justSouth = LatitudeBands.southAnchor - 0.01
        let p = LatitudeBands.profile(latitude: justSouth)
        XCTAssertEqual(p.band, 0)
        XCTAssertEqual(p.comfortLowF, 61)
    }

    func testContinentalSpanIsManyBands() {
        let southMost = LatitudeBands.profile(latitude: 14.0).band
        let northMost = LatitudeBands.profile(latitude: 70.0).band
        XCTAssertLessThan(southMost, -50)
        XCTAssertGreaterThan(northMost, 50)
        XCTAssertGreaterThan(northMost - southMost, 100)   // ~119 bands
    }

    func testElevationShiftIsClampedToOneBand() {
        // The contiguous rule: Denver's ~1600 m would raw-shift ~15 bands —
        // it must move exactly ONE band toward the pole.
        let base = LatitudeBands.profile(latitude: 39.74).band
        let denver = LatitudeBands.profile(latitude: 39.74, elevationMeters: 1609)
        XCTAssertEqual(denver.band, base + 1)
        // Below-reference terrain shifts at most one band the other way.
        let belowSea = LatitudeBands.profile(latitude: 36.0, elevationMeters: -80)
        XCTAssertEqual(belowSea.band, LatitudeBands.profile(latitude: 36.0).band - 1)
        // Near-reference elevation: no shift.
        XCTAssertEqual(LatitudeBands.profile(latitude: 43.0, elevationMeters: 310).band,
                       LatitudeBands.profile(latitude: 43.0).band)
    }

    func testPhysicalClampsBoundTheLongExtrapolation() {
        let tropics = LatitudeBands.profile(latitude: 14.5)
        XCTAssertLessThanOrEqual(tropics.comfortLowF, 72)
        XCTAssertLessThanOrEqual(tropics.recordHighF, 125)
        let arctic = LatitudeBands.profile(latitude: 69.5)
        XCTAssertGreaterThanOrEqual(arctic.recordLowF, -80)
        XCTAssertGreaterThan(arctic.comfortHighF, arctic.comfortLowF)
    }
}
