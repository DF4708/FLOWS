// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// The bridge facade's own rules (Core/Islands/RustLoans.swift).
final class RustLoansTests: XCTestCase {
    /// Rule 1: an empty loan still has a real address, so Rust never builds
    /// a slice from null.
    func testAnEmptyLoanHasAnAddress() {
        let doubles = [Double]().lent { ($0.baseAddress != nil, $0.count) }
        XCTAssertTrue(doubles.0)
        XCTAssertEqual(doubles.1, 0)
        let bytes = Data().lentBytes { ($0.baseAddress != nil, $0.count) }
        XCTAssertTrue(bytes.0)
        XCTAssertEqual(bytes.1, 0)
    }

    func testAFullLoanIsTheArrayItself() {
        let seen = [1.5, 2.5, 4].lent { Array($0) }
        XCTAssertEqual(seen, [1.5, 2.5, 4])
        XCTAssertEqual(Data([7, 8, 9]).lentBytes { Array($0) }, [7, 8, 9])
    }

    /// Slots start filled, take writes by index, and drop a write outside
    /// their range instead of writing past the end.
    func testSlotsAreFilledAndBounded() {
        let seen = RustLoans.slots(4, startingAt: -1, fill: { set in
            set(2, 9)
            set(4, 100)
            set(-1, 100)
        }) { Array($0) }
        XCTAssertEqual(seen, [-1, -1, 9, -1])
        XCTAssertEqual(RustLoans.slots(0, startingAt: 0, fill: { $0(0, 1) }) { $0.count }, 0)
    }

    /// Rule 3: empty Rust text reads as "", not a trap.
    func testEmptyRustTextReadsAsEmpty() {
        XCTAssertEqual("".intoRustString().text, "")
        XCTAssertEqual("Ünïcode".intoRustString().text, "Ünïcode")
    }
}
