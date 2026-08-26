// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
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

    // MARK: FRB1 — the binary risk bundle (bundle-frb.rs is the writer)

    /// Hand-assemble an FRB1 shard (2 families, 2 zips, one summary, one
    /// ring), mirroring the Rust writer's layout byte for byte, and verify
    /// the parser reconstructs exactly the entries the JSON path would have
    /// produced — plus refusal on corruption and truncation.
    func testFRB1ParseRoundTripAndCorruptionRefusal() {
        var payload = Data()
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func f64(_ v: Double) -> Data { withUnsafeBytes(of: v.bitPattern.littleEndian) { Data($0) } }

        let generated = "2026-07-04T11:39:45Z"
        payload.append(contentsOf: generated.utf8)
        for fam in ["wind", "fire"] {
            payload.append(UInt8(fam.utf8.count))
            payload.append(contentsOf: fam.utf8)
        }
        payload.append(contentsOf: "01001".utf8)
        payload.append(contentsOf: "99999".utf8)
        payload.append(f64(-72.6258)); payload.append(f64(42.0624))   // centroid 1 (lon,lat)
        payload.append(f64(-100.5)); payload.append(f64(40.25))       // centroid 2
        payload.append(f64(0.125)); payload.append(f64(0.5))          // scores z1
        payload.append(f64(0)); payload.append(f64(0.043))            // scores z2
        payload.append(le16(5)); payload.append(contentsOf: "windy".utf8)  // summary z1
        payload.append(le16(0))                                       // summary z2: none
        payload.append(le16(0))                                       // ring z1: none
        payload.append(le16(3))                                       // ring z2: 3 pts
        for (lon, lat) in [(-100.0, 40.0), (-100.1, 40.1), (-100.2, 40.0)] {
            payload.append(f64(lon)); payload.append(f64(lat))
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in payload { hash ^= UInt64(b); hash = hash &* 0x0000_0100_0000_01b3 }

        var shard = Data("FRB1".utf8)
        shard.append(le32(1))                       // version
        shard.append(le32(2))                       // nFams
        shard.append(le32(2))                       // nZips
        shard.append(le32(UInt32(generated.utf8.count)))
        shard.append(le64(hash))
        shard.append(payload)

        guard let (entries, fams, gen) = RiskFieldService.parseFRB1(shard) else {
            return XCTFail("valid FRB1 refused")
        }
        XCTAssertEqual(gen, generated)
        XCTAssertEqual(fams, ["wind", "fire"])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].zip, "01001")
        XCTAssertEqual(entries[0].centroid.latitude, 42.0624)
        XCTAssertEqual(entries[0].centroid.longitude, -72.6258)
        XCTAssertEqual(entries[0].scores, [0.125, 0.5])
        XCTAssertEqual(entries[0].summary, "windy")
        XCTAssertNil(entries[0].ring)
        XCTAssertEqual(entries[1].zip, "99999")
        XCTAssertEqual(entries[1].scores, [0, 0.043])
        XCTAssertNil(entries[1].summary)
        XCTAssertEqual(entries[1].ring?.count, 3)
        XCTAssertEqual(entries[1].ring?[1].latitude, 40.1)
        XCTAssertEqual(entries[1].ring?[1].longitude, -100.1)

        // Corruption: one flipped payload byte fails the hash.
        var corrupt = shard
        corrupt[40] ^= 0xFF
        XCTAssertNil(RiskFieldService.parseFRB1(corrupt))
        // Truncation: refused (bounds guards, then the trailing-garbage check).
        XCTAssertNil(RiskFieldService.parseFRB1(shard.prefix(shard.count - 5)))
        // Wrong magic: refused.
        var badMagic = shard
        badMagic.replaceSubrange(0..<4, with: "XXXX".utf8)
        XCTAssertNil(RiskFieldService.parseFRB1(badMagic))
    }
}

/// The bulk launch rescore: whatever its internals (the zip map replaced a
/// per-zip binary search; a multi-core variant was measured and rejected),
/// it must produce exactly the scores of the brute-force serial loop — and
/// the O(1) zip map must agree with the binary search it replaced.
final class HarmonicRescoreTests: XCTestCase {

    /// FLHH fixture with `n` sorted zips × 2 families, deterministic coeffs.
    private func bulkFixture(nZips: Int) -> Data {
        var d = Data("FLHH".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(1)
        u32(UInt32(nZips))
        u32(2)
        for fam in ["winter", "heat"] {
            d.append(UInt8(fam.utf8.count))
            d.append(contentsOf: fam.utf8)
        }
        for z in 0..<nZips { d.append(contentsOf: String(format: "%05d", z).utf8) }
        for z in 0..<nZips {
            for f in 0..<2 {
                let coeffs: [Float] = [
                    0.1 + Float(z % 7) * 0.03, 0.05 * Float(f + 1),
                    -0.02, 0.01, Float(z % 3) * 0.005,
                ]
                for c in coeffs {
                    withUnsafeBytes(of: c.bitPattern.littleEndian) { d.append(contentsOf: $0) }
                }
            }
        }
        return d
    }

    func testZipIndexMapMatchesBinarySearch() throws {
        let table = try XCTUnwrap(HarmonicClimatology(data: bulkFixture(nZips: 200)))
        let map = table.zipIndexMap()
        for z in 0..<200 {
            let zip = String(format: "%05d", z)
            XCTAssertEqual(map[zip], table.zipIndex(zip))
        }
        XCTAssertNil(map["99999"])
        XCTAssertNil(table.zipIndex("99999"))
    }

    func testParallelRescoreMatchesSerial() throws {
        let table = try XCTUnwrap(HarmonicClimatology(data: bulkFixture(nZips: 500)))
        let trig = HarmonicClimatology.WeekTrig(week: 10)
        let famIdx = [(bundle: 0, harmonic: 0), (bundle: 1, harmonic: 1)]
        let ring = [CLLocationCoordinate2D(latitude: 43, longitude: -89),
                    .init(latitude: 43.1, longitude: -89), .init(latitude: 43, longitude: -88.9)]
        // 600 entries: every 5th carries a ring (R-engine entry — must be
        // untouched), every 7th references a zip the table doesn't know
        // (skipped), the rest are national entries due a rescore.
        let base = (0..<600).map { i in
            RiskFieldService.ZipEntry(
                zip: i % 7 == 0 ? "abcde" : String(format: "%05d", i % 500),
                centroid: CLLocationCoordinate2D(latitude: 40, longitude: -90),
                scores: [0.9, 0.9],
                summary: nil,
                ring: i % 5 == 0 ? ring : nil)
        }

        // Serial oracle — the loop shape harmonicRescore replaced.
        var expected = base
        var expectedCount = 0
        for e in 0..<expected.count where expected[e].ring == nil {
            guard let zi = table.zipIndex(expected[e].zip) else { continue }
            var scores = expected[e].scores
            for (bi, hi) in famIdx where bi < scores.count {
                scores[bi] = table.score(zipIndex: zi, familyIndex: hi, trig: trig)
            }
            expected[e] = RiskFieldService.ZipEntry(
                zip: expected[e].zip, centroid: expected[e].centroid,
                scores: scores, summary: expected[e].summary, ring: nil)
            expectedCount += 1
        }

        var got = base
        let gotCount = RiskFieldService.harmonicRescore(
            entries: &got, table: table, trig: trig, famIdx: famIdx)

        XCTAssertEqual(gotCount, expectedCount)
        XCTAssertEqual(got.count, expected.count)
        for (g, e) in zip(got, expected) {
            XCTAssertEqual(g.zip, e.zip)
            XCTAssertEqual(g.scores, e.scores)   // exact — same eval, same order
            XCTAssertEqual(g.ring == nil, e.ring == nil)
        }
        // Ringed entries kept their pre-rescore scores untouched.
        XCTAssertEqual(got[5].scores, [0.9, 0.9])
    }
}
