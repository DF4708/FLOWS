// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// Gates for the Swift side's pure functions — the same discipline the R
/// side gets from tests/ and the Rust side from cargo. These compile the
/// sources under test directly (no app host).
final class CoreTests: XCTestCase {

    // MARK: risk band cuts — must mirror R/risk_constants.R + rust risk.rs

    func testRiskBandCutsMatchTheRConstants() {
        XCTAssertEqual(FlowsCore.riskBand(score: 0.0), .clear)
        XCTAssertEqual(FlowsCore.riskBand(score: 0.3979), .clear)
        XCTAssertEqual(FlowsCore.riskBand(score: 0.3980), .green)   // GREEN_MIN inclusive
        XCTAssertEqual(FlowsCore.riskBand(score: 0.6989), .green)
        XCTAssertEqual(FlowsCore.riskBand(score: 0.6990), .yellow)  // YELLOW_MIN inclusive
        XCTAssertEqual(FlowsCore.riskBand(score: 0.8751), .yellow)  // RED_MIN inclusive (risk.rs ..=)
        XCTAssertEqual(FlowsCore.riskBand(score: 0.8752), .red)
        XCTAssertEqual(FlowsCore.riskBand(score: .nan), .clear)
        XCTAssertEqual(FlowsCore.riskBand(score: .infinity), .clear)
    }

    // MARK: polyline decoder fallback — must match the Rust/R twins

    func testGoogleSpecReferenceVectorDecodesExactly() {
        let out = FlowsCore.decodePolylineSwift(Array("_p~iF~ps|U_ulLnnqC_mqNvxq`@".utf8))
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].lon.bitPattern, (-120.2).bitPattern)
        XCTAssertEqual(out[0].lat.bitPattern, (38.5).bitPattern)
        XCTAssertEqual(out[2].lon.bitPattern, (-126.453).bitPattern)
        XCTAssertEqual(out[2].lat.bitPattern, (43.252).bitPattern)
    }

    func testMalformedOverlongVarintStopsWithoutTrap() {
        // The R decoder's old bit-31 overflow case: must be finite, no crash.
        let enc = String(repeating: "~", count: 6) + "^" + String(repeating: "~", count: 6) + "^"
        let out = FlowsCore.decodePolylineSwift(Array(enc.utf8))
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].lon.isFinite && out[0].lat.isFinite)
        // > 10 chunks = malformed -> decoding stops, prior pairs kept.
        let overlong = Array((String(repeating: "~", count: 15) + "^").utf8)
        XCTAssertTrue(FlowsCore.decodePolylineSwift(overlong).isEmpty)
    }

    func testTruncatedTrailingVarintIsDropped() {
        let full = "_p~iF~ps|U"
        let out = FlowsCore.decodePolylineSwift(Array(full.dropLast().utf8))
        XCTAssertTrue(out.isEmpty)   // dangling lat without lon
    }
}

/// The decoder is Swift-native and is pinned to the PUBLISHED spec vector,
/// not to a second implementation of the same algorithm.
///
/// It used to be pinned to the Rust FFI decoder — two implementations agreeing
/// with each other, which proves they share an algorithm but not that the
/// algorithm is right. The Rust boundary is gone (flows-core is
/// `forbid(unsafe_code)`, and a C-ABI export cannot live in such a crate), so
/// the oracle is now the Google encoded-polyline specification's own worked
/// example and its documented coordinates — an independent oracle, per 6.3.
final class PolylineDecoderTests: XCTestCase {
    func testTheSpecReferenceVectorDecodesToItsPublishedCoordinates() {
        // The example from the Google encoded-polyline format specification,
        // whose decoded value is published with it.
        let got = FlowsCore.decodePolyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        let want: [(lon: Double, lat: Double)] = [
            (-120.2, 38.5), (-120.95, 40.7), (-126.453, 43.252),
        ]
        XCTAssertEqual(got.count, want.count)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.lat, w.lat, accuracy: 1e-9)
            XCTAssertEqual(g.lon, w.lon, accuracy: 1e-9)
        }
    }

    func testTheTwoEntryPointsAgree() {
        // decodePolyline is a thin wrapper over decodePolylineSwift; keep them
        // from drifting apart.
        for enc in ["_p~iF~ps|U_ulLnnqC_mqNvxq`@", "u{~vFvyys@fS]", ""] {
            let a = FlowsCore.decodePolyline(enc)
            let b = FlowsCore.decodePolylineSwift(Array(enc.utf8))
            XCTAssertEqual(a.count, b.count, "point count for \(enc)")
            for (x, y) in zip(a, b) {
                XCTAssertEqual(x.lon.bitPattern, y.lon.bitPattern)
                XCTAssertEqual(x.lat.bitPattern, y.lat.bitPattern)
            }
        }
    }

    func testMalformedInputIsDroppedNotGuessed() {
        // A varint longer than the 10-chunk guard, and a dangling lat with no
        // lon, must both yield nothing rather than a plausible coordinate.
        XCTAssertTrue(FlowsCore.decodePolyline(String(repeating: "\u{7e}", count: 24)).isEmpty)
        XCTAssertTrue(FlowsCore.decodePolyline("_p~iF").isEmpty)
    }
}
