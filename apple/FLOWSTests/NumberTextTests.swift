// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// The app writes numbers with `.fixed`, `.padded` and `.general` instead of
/// `String(format:)`. These hold the new text to what printf writes.
final class NumberTextTests: XCTestCase {
    func testFixedWritesWhatPrintfWrites() {
        let values: [Double] = [
            0, -0.0, 0.05, 0.15, 0.25, 0.5, 1.5, 2.5, 9.95, 9.949, 10, 99.5, 99.95, 1234.5678,
            -0.04, -0.05, -1.005, 1e-9, 123456789.125, 0.1 + 0.2, 72.449999, 1e15,
        ]
        for value in values {
            for places in 0...6 {
                XCTAssertEqual(
                    value.fixed(places), String(format: "%.\(places)f", value),
                    "\(value) at \(places) places")
            }
        }
        // A swept range, so a rounding rule that differs somewhere shows up.
        var x = -50.0
        while x < 250 {
            XCTAssertEqual(x.fixed(1), String(format: "%.1f", x), "\(x)")
            XCTAssertEqual(x.fixed(0), String(format: "%.0f", x), "\(x)")
            x += 0.0125
        }
    }

    func testFixedNamesWhatIsNotANumber() {
        XCTAssertEqual(Double.nan.fixed(1), String(format: "%.1f", Double.nan))
        XCTAssertEqual(Double.infinity.fixed(1), String(format: "%.1f", Double.infinity))
        XCTAssertEqual((-Double.infinity).fixed(1), String(format: "%.1f", -Double.infinity))
    }

    func testPaddedWritesWhatPrintfWrites() {
        for value in [0, 5, 9, 10, 59, 100, 12345, -3, -42] {
            for width in 1...5 {
                XCTAssertEqual(
                    value.padded(width), String(format: "%0\(width)d", value),
                    "\(value) at width \(width)")
            }
        }
        XCTAssertEqual(UInt8(7).padded(2), "07")
    }

    func testGeneralWritesWhatPrintfWrites() {
        for value in [0, 0.5, 1, 1.5, 2.25, 3, 4, 12, 24.5, 100, 0.0001, 123456, 1e6, 1.5e-5] {
            XCTAssertEqual(value.general, String(format: "%g", value), "\(value)")
        }
    }
}
