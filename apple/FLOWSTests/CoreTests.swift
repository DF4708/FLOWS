// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
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

/// The Rust core (asm hot loops) must be STATICALLY LINKED and its FFI decoder
/// must be byte-for-byte identical to the pure-Swift fallback. This is the
/// architectural guard: "Rust for compute + asm hot loops, Swift for UI."
final class RustCoreLinkageTests: XCTestCase {
    func testRustCoreIsLinkedNotFallback() {
        XCTAssertTrue(FlowsCore.rustCoreLoaded,
                      "libflows_core must be static-linked so the app runs the "
                      + "Rust/asm polyline decoder, not the Swift fallback")
    }

    func testRustDecoderIsByteIdenticalToSwift() {
        // Google polyline spec reference vector + a couple of real shapes.
        let samples = [
            "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
            "u{~vFvyys@fS]",
            " khwithoutmeaningbutstillvalidchars",
        ]
        for enc in samples {
            let rust = FlowsCore.decodePolyline(enc)                    // Rust FFI (linked)
            let swift = FlowsCore.decodePolylineSwift(Array(enc.utf8))  // pure Swift
            XCTAssertEqual(rust.count, swift.count, "point count for \(enc)")
            for (r, s) in zip(rust, swift) {
                // BIT-identical, not just approximately equal.
                XCTAssertEqual(r.lon.bitPattern, s.lon.bitPattern, "lon bits for \(enc)")
                XCTAssertEqual(r.lat.bitPattern, s.lat.bitPattern, "lat bits for \(enc)")
            }
        }
    }

    func testRaptorTransitEngineRunsOnDevice() {
        // The RAPTOR engine executes end-to-end through the C ABI: the self-test
        // builds a 2-leg transfer timetable in Rust, plans it, and returns the
        // arrival time. Proves flows_transit_selftest is linked and the engine runs.
        XCTAssertEqual(FlowsCore.transitSelfTest(), 1500,
                       "the linked Rust RAPTOR engine must run through the C ABI")
        XCTAssertTrue(FlowsCore.transitEngineLoaded)
    }
}
