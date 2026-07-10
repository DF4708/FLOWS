// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// The FLHH harmonic-climatology reader: format parse, binary zip search, and
/// week reconstruction identical to the Rust writer's `harmonic_eval`.
final class HarmonicClimatologyTests: XCTestCase {

    /// Build a tiny FLHH fixture: 2 zips × 2 families.
    private func fixture(coeffs: [[Float]]) -> Data {
        var d = Data("FLHH".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(1)                       // version
        u32(2)                       // nZips
        u32(2)                       // nFamilies
        for fam in ["winter", "heat"] {
            d.append(UInt8(fam.utf8.count))
            d.append(contentsOf: fam.utf8)
        }
        d.append(contentsOf: "53703".utf8)   // sorted zip index
        d.append(contentsOf: "85004".utf8)
        for zipFam in coeffs {               // 4 blocks of 5 f32 (zip-major)
            for c in zipFam {
                withUnsafeBytes(of: c.bitPattern.littleEndian) { d.append(contentsOf: $0) }
            }
        }
        return d
    }

    func testParseAndReconstruction() {
        // Madison winter: mean 0.3, strong annual cosine (peaks at week 0).
        // Phoenix heat: mean 0.3, NEGATIVE annual cosine (peaks mid-year).
        let madisonWinter: [Float] = [0.3, 0.25, 0, 0, 0]
        let madisonHeat: [Float] = [0.05, 0, 0, 0, 0]
        let phoenixWinter: [Float] = [0.02, 0, 0, 0, 0]
        let phoenixHeat: [Float] = [0.3, -0.25, 0, 0, 0]
        let table = HarmonicClimatology(data: fixture(
            coeffs: [madisonWinter, madisonHeat, phoenixWinter, phoenixHeat]))
        XCTAssertNotNil(table)
        guard let t = table else { return }
        XCTAssertEqual(t.families, ["winter", "heat"])
        // Week 0 (midwinter): Madison winter = 0.3 + 0.25·cos(0) = 0.55.
        XCTAssertEqual(t.score(zip: "53703", family: "winter", week: 0) ?? 0,
                       0.55, accuracy: 1e-6)
        // Week 26 (midsummer): Madison winter = 0.3 − 0.25 = 0.05.
        XCTAssertEqual(t.score(zip: "53703", family: "winter", week: 26) ?? 0,
                       0.05, accuracy: 1e-6)
        // Phoenix heat peaks midsummer: 0.3 + 0.25 = 0.55; near-zero winter.
        XCTAssertEqual(t.score(zip: "85004", family: "heat", week: 26) ?? 0,
                       0.55, accuracy: 1e-6)
        XCTAssertEqual(t.score(zip: "85004", family: "heat", week: 0) ?? 0,
                       0.05, accuracy: 1e-6)
        // Unknown zip / family → nil, never a trap.
        XCTAssertNil(t.score(zip: "99999", family: "winter", week: 0))
        XCTAssertNil(t.score(zip: "53703", family: "volcanic", week: 0))
    }

    func testClampAndCorruption() {
        // Coefficients that exceed the cap clamp to 0.6; negatives clamp to 0.
        let hot: [Float] = [0.5, 0.5, 0, 0, 0]      // week 0 → 1.0 → clamps 0.6
        let cold: [Float] = [-0.5, 0, 0, 0, 0]      // → clamps 0
        let filler: [Float] = [0, 0, 0, 0, 0]
        let t = HarmonicClimatology(data: fixture(coeffs: [hot, cold, filler, filler]))
        XCTAssertEqual(t?.score(zip: "53703", family: "winter", week: 0) ?? -1,
                       0.6, accuracy: 1e-6)
        XCTAssertEqual(t?.score(zip: "53703", family: "heat", week: 0) ?? -1,
                       0, accuracy: 1e-6)
        // Truncated body / wrong magic → nil.
        var good = fixture(coeffs: [hot, cold, filler, filler])
        XCTAssertNil(HarmonicClimatology(data: good.prefix(good.count - 7)))
        good.replaceSubrange(0..<4, with: "XXXX".utf8)
        XCTAssertNil(HarmonicClimatology(data: good))
    }
}
