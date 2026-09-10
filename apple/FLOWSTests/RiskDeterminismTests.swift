// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest
@testable import FLOWS

/// The risk combine must give the SAME BITS on every launch and on both
/// sides of the language line.
///
/// Floating-point multiplication is not associative, and a Swift Dictionary
/// iterates in an order seeded per process — so a noisy-OR that walked the
/// dictionary could put the same route a last bit either side of a band cut
/// on two different days. `realizedRisk` now walks the fixed, name-sorted
/// family lists instead, which is the order rust/flows-core uses. These six
/// inputs are pinned bit-for-bit HERE and in
/// rust/flows-core/src/families.rs (`cross_language_fixture_is_bit_exact`):
/// if either implementation drifts from the other by one bit, its own suite
/// fails. After a deliberate model change, run the Rust test with
/// `--nocapture`, and update both files together.
final class RiskDeterminismTests: XCTestCase {

    private let fixture: [(name: String, families: [String: Double], bits: UInt64)] = [
        ("flood_in_rain", ["qpf_flood": 0.7, "precip": 0.9, "wind": 0.6], 0x3feb_0790_1739_d869),
        ("fire_in_weather", ["fire": 0.85, "wind": 0.95, "heat": 0.9], 0x3fee_b030_4973_e758),
        ("mixed_with_ignored",
         ["closure": 0.3, "heat": 0.2, "wind": 0.4, "qpf_flood": 0.7, "environmental": 0.9],
         0x3feb_3128_0d87_9f69),
        ("all_predictors_maxed",
         Dictionary(uniqueKeysWithValues: RiskEquations.secondaryOrder.map { ($0, 1.0) }),
         0x3fe9_9999_9999_999a),
        ("two_primaries", ["seismic": 0.5, "fire": 0.5], 0x3fe8_0000_0000_0000),
        ("ten_terms_unsaturated",
         ["wind": 0.13, "cold": 0.07, "air": 0.11, "radiation": 0.09, "avalanche": 0.12,
          "convective": 0.08, "winter": 0.06, "precip": 0.15, "heat": 0.05, "fire": 0.2],
         0x3fdd_4910_b178_ba6a),
    ]

    func testRealizedRiskMatchesTheRustPortBitForBit() {
        for c in fixture {
            let got = RiskEquations.realizedRisk(c.families)
            XCTAssertEqual(got.bitPattern, c.bits,
                           "\(c.name): Swift \(got) (0x\(String(got.bitPattern, radix: 16))) "
                           + "differs from the Rust port — one side has drifted")
        }
    }

    func testRealizedRiskDoesNotDependOnInsertionOrder() {
        // Build the same family map from different insertion sequences. The
        // dictionaries may iterate differently; the result must not.
        let base: [(String, Double)] = [("qpf_flood", 0.7), ("precip", 0.9), ("wind", 0.6),
                                        ("heat", 0.3), ("fire", 0.1)]
        let forward = Dictionary(uniqueKeysWithValues: base)
        let backward = Dictionary(uniqueKeysWithValues: base.reversed())
        var rotated: [String: Double] = [:]
        for (k, v) in base.dropFirst(2) + base.prefix(2) { rotated[k] = v }
        let want = RiskEquations.realizedRisk(forward).bitPattern
        XCTAssertEqual(RiskEquations.realizedRisk(backward).bitPattern, want)
        XCTAssertEqual(RiskEquations.realizedRisk(rotated).bitPattern, want)
    }

    func testTheFamilyOrdersAreSortedAndMatchTheSets() {
        // The binary-searchable, name-sorted lists are the source of truth;
        // the sets are derived. If someone appends to a list out of order the
        // Swift and Rust products silently stop agreeing — so pin it.
        XCTAssertEqual(RiskEquations.primaryOrder, RiskEquations.primaryOrder.sorted())
        XCTAssertEqual(RiskEquations.secondaryOrder, RiskEquations.secondaryOrder.sorted())
        XCTAssertEqual(Set(RiskEquations.primaryOrder), RiskEquations.primaryFamilies)
        XCTAssertEqual(Set(RiskEquations.secondaryOrder), RiskEquations.secondaryFamilies)
        XCTAssertTrue(RiskEquations.primaryFamilies.isDisjoint(with: RiskEquations.secondaryFamilies))
    }

    func testDominantFamilyBreaksExactTiesByName() {
        // Two hazards at the same weighted score: the lower name wins, on
        // every launch, regardless of how the dictionary iterates.
        XCTAssertEqual(HazardRanking.dominantFamily(["winter": 0.7, "convective": 0.7]), "convective")
        XCTAssertEqual(HazardRanking.dominantFamily(["convective": 0.7, "winter": 0.7]), "convective")
        // The acute nudge still decides a tie between an acute and a dial reading …
        XCTAssertEqual(HazardRanking.dominantFamily(["fire": 0.6, "convective": 0.6]), "fire")
        // … and still cannot beat a materially worse hazard.
        XCTAssertEqual(HazardRanking.dominantFamily(["fire": 0.6, "convective": 0.7]), "convective")
        XCTAssertNil(HazardRanking.dominantFamily(["fire": .nan]))
    }

    func testPeakFamilyIsAPlainMaxWithNameTies() {
        XCTAssertEqual(RiskEquations.peakFamily(["fire": 0.6, "convective": 0.6], floor: 0.4), "convective")
        XCTAssertEqual(RiskEquations.peakFamily(["fire": 0.6, "convective": 0.7], floor: 0.4), "convective")
        XCTAssertNil(RiskEquations.peakFamily(["wind": 0.2], floor: 0.4))
        XCTAssertNil(RiskEquations.peakFamily(["wind": .nan], floor: 0))
    }
}
