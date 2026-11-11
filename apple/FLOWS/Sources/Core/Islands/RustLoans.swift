// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//  The one place a Swift value is handed to the Rust bridge as raw memory,
//  and the one place Rust text is read back.
//
//  swift-bridge 0.1.59 has three rules its generated code does not check:
//
//  1. An empty buffer must not cross with no address behind it. Rust builds
//     a slice from the address and the count, and a slice from a null
//     address is undefined even at count zero. `lent` and `lentBytes` give
//     an empty loan a real address, so every loan made here is sound.
//  2. Text going to Rust must be a Swift `String`. A `String` is always
//     valid UTF-8, which is what the generated code assumes; the compiler
//     holds this, since bridge text parameters accept nothing else that
//     hand-written code makes.
//  3. Text coming back empty has no storage behind it, and the generated
//     `toString()` force-unwraps Foundation's nil for that. `text` answers
//     the empty case first.
//
//  rust/flows-bridge/tests/swift_unsafe_islands.rs fails on a buffer loan or
//  a `toString()` anywhere outside this folder.

import Foundation

/// An array's storage, lent to Rust for the length of one call.
typealias RustLoan<Element> = UnsafeBufferPointer<Element>

enum RustLoans {
    /// Run `body` with a loan Rust may safely turn into a slice.
    ///
    /// PROMISE: the loan is valid for `body` only and is never kept; an
    /// empty loan points at real, aligned stack space with a count of zero,
    /// so nothing is ever read through it.
    @inline(__always)
    static func sound<Element, R>(
        _ loan: UnsafeBufferPointer<Element>,
        _ body: (RustLoan<Element>) throws -> R
    ) rethrows -> R {
        if loan.baseAddress != nil { return try body(loan) }
        return try withUnsafeTemporaryAllocation(of: Element.self, capacity: 1) { spare in
            try body(UnsafeBufferPointer(start: spare.baseAddress, count: 0))
        }
    }

    /// `count` slots holding `start`, set by index, then lent once. Stack
    /// storage: this serves the per-sample hot path.
    ///
    /// PROMISE: every slot is written before the loan, a `set` outside
    /// `0..<count` is dropped rather than written, and the storage does not
    /// outlive the call.
    @inline(__always)
    static func slots<R>(
        _ count: Int, startingAt start: Double,
        fill: ((Int, Double) -> Void) -> Void,
        _ body: (RustLoan<Double>) -> R
    ) -> R {
        withUnsafeTemporaryAllocation(of: Double.self, capacity: max(count, 1)) { buf in
            buf.initialize(repeating: start)
            fill { index, value in
                if index >= 0 && index < count { buf[index] = value }
            }
            return body(UnsafeBufferPointer(start: buf.baseAddress, count: max(count, 0)))
        }
    }
}

extension Array {
    /// Lend this array to Rust for one call (rule 1 above).
    @inline(__always)
    func lent<R>(_ body: (RustLoan<Element>) throws -> R) rethrows -> R {
        try withUnsafeBufferPointer { try RustLoans.sound($0, body) }
    }
}

extension Data {
    /// Lend these bytes to Rust for one call (rule 1 above).
    func lentBytes<R>(_ body: (RustLoan<UInt8>) throws -> R) rethrows -> R {
        try withUnsafeBytes { raw in try RustLoans.sound(raw.bindMemory(to: UInt8.self), body) }
    }
}

extension RustStringRef {
    /// The string, with the empty case answered here (rule 3 above): every
    /// facade reads Rust text through this.
    var text: String { len() == 0 ? "" : as_str().toString() }
}
