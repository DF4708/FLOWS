// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Swift-native compute the app used to reach into Rust for.
///
/// There is no longer a Rust boundary here. The library it called
/// (rust/flows-core) is safe Rust under `forbid(unsafe_code)`, and a C-ABI
/// export cannot exist in such a crate — `#[no_mangle]` is itself rejected
/// by that lint. Removing the boundary took away, on this side, a `dlsym`
/// whose result was `unsafeBitCast` into a function pointer, two
/// `withUnsafe*BufferPointer` scopes, and a copy of every decoded double out
/// of a scratch buffer; and on the Rust side, every raw pointer it had.
///
/// The measured cost of that safety is about 23 microseconds on a 10 KB
/// route polyline (Rust 1.16 ns/byte, Swift 4.73). flows-core remains the
/// reference implementation and still runs in the offline tooling. When the
/// RAPTOR transit engine goes live it needs a real bulk boundary; that comes
/// back through swift-bridge, which exports via `#[export_name]` and is
/// verified to compile under the crate's `forbid` — see
/// docs/RUST_SWIFT_MIGRATION.md.
enum FlowsCore {
    /// Decode a Google encoded polyline into (lon, lat) pairs.
    ///
    /// Swift-native, and deliberately so. This used to call through the C ABI
    /// into Rust, which cost an `unsafeBitCast` of a `dlsym` result, two
    /// `withUnsafe*BufferPointer` scopes, and a full copy of the decoded
    /// doubles out of a scratch buffer — to save about 23 microseconds on a
    /// 10 KB route polyline (measured: Rust 1.16 ns/byte, Swift 4.73). That
    /// is not a cost worth a raw pointer on either side of the boundary, and
    /// the two implementations were already value-identical by test.
    /// rust/flows-core/src/polyline.rs remains the reference and is still
    /// used by the offline tooling.
    static func decodePolyline(_ encoded: String) -> [(lon: Double, lat: Double)] {
        decodePolylineSwift(Array(encoded.utf8))
    }

    /// The decoder — same algorithm as rust/flows-core/src/polyline.rs.
    static func decodePolylineSwift(_ bytes: [UInt8]) -> [(lon: Double, lat: Double)] {
        var deltas: [Int64] = []
        var acc: UInt64 = 0, shift: UInt64 = 0, chunks = 0
        for raw in bytes {
            let b = Int32(raw) - 63
            chunks += 1
            if chunks > 10 { break }   // malformed varint: stop
            acc |= UInt64(UInt32(bitPattern: b & 0x1f)) << shift
            shift += 5
            if b < 0x20 {
                deltas.append(Int64(bitPattern: acc >> 1) ^ -(Int64(bitPattern: acc & 1)))
                acc = 0; shift = 0; chunks = 0
            }
        }
        var lat: Int64 = 0, lon: Int64 = 0
        var out: [(lon: Double, lat: Double)] = []
        out.reserveCapacity(deltas.count / 2)
        var i = 0
        while i + 1 < deltas.count {
            lat += deltas[i]
            lon += deltas[i + 1]
            out.append((lon: Double(lon) / 1e5, lat: Double(lat) / 1e5))
            i += 2
        }
        return out
    }

    /// FLOWS risk banding — same cuts as R/risk_constants.R + rust risk.rs.
    static let riskGreenMin = 0.3980
    static let riskYellowMin = 0.6990

    static func riskBand(score: Double) -> RiskBand {
        if !score.isFinite || score < riskGreenMin { return .clear }
        if score < riskYellowMin { return .green }
        if score <= 0.8751 { return .yellow }  // RISK_RED_MIN inclusive, as in risk.rs
        return .red
    }
}

enum RiskBand: String {
    case clear = "Clear"
    case green = "Green"
    case yellow = "Yellow"
    case red = "Red"
}
