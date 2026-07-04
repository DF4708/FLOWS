// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Bridge to the Rust compute core (rust/flows-core), which carries the hot
/// loops: the AArch64-assembly polyline decoder, risk banding, and the CH
/// router. Mirrors the R side's optional-dylib pattern (R/rust_core.R):
///   - dev builds dlopen libflows_core.dylib when present;
///   - device/App Store builds static-link libflows_core.a, where the same
///     symbols resolve at link time;
///   - if neither is available, pure-Swift fallbacks keep the app functional
///     (slower, but identical results).
enum FlowsCore {
    // C ABI: int64_t flows_polyline_decode(const uint8_t*, size_t, double*, size_t)
    private typealias PolylineDecodeFn = @convention(c) (
        UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<Double>?, Int
    ) -> Int64

    private static let polylineDecodeFn: PolylineDecodeFn? = {
        // Same ownership guard the R loader applies: only accept a library we
        // own that nobody else can write (see R/rust_core.R).
        for path in candidateLibraryPaths() {
            var st = stat()
            guard stat(path, &st) == 0,
                  st.st_uid == getuid(),
                  (st.st_mode & 0o022) == 0,
                  let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL),
                  let sym = dlsym(handle, "flows_polyline_decode")
            else { continue }
            return unsafeBitCast(sym, to: PolylineDecodeFn.self)
        }
        // Static-linked builds: the symbol is already in the binary.
        if let sym = dlsym(dlopen(nil, RTLD_NOW), "flows_polyline_decode") {
            return unsafeBitCast(sym, to: PolylineDecodeFn.self)
        }
        return nil
    }()

    private static func candidateLibraryPaths() -> [String] {
        #if os(macOS)
        let repo = ProcessInfo.processInfo.environment["FLOWS_REPO"]
            ?? "\(NSHomeDirectory())/Documents/Coding_Files/FLOWS"
        return [
            Bundle.main.privateFrameworksPath.map { "\($0)/libflows_core.dylib" },
            "\(repo)/rust/target/release/libflows_core.dylib",
        ].compactMap { $0 }
        #else
        return []   // iOS: static link only
        #endif
    }

    /// True when the Rust core (asm hot loops) is live rather than fallback.
    static var rustCoreLoaded: Bool { polylineDecodeFn != nil }

    /// Decode a Google encoded polyline into (lon, lat) pairs.
    /// Rust/asm when available; the Swift fallback implements the identical
    /// overflow-safe algorithm (64-bit accumulate, MAX_CHUNKS guard) so both
    /// paths are value-identical.
    static func decodePolyline(_ encoded: String) -> [(lon: Double, lat: Double)] {
        let bytes = Array(encoded.utf8)
        if let f = polylineDecodeFn {
            let cap = bytes.count / 2 + 1
            var buf = [Double](repeating: 0, count: 2 * cap)
            let n = bytes.withUnsafeBufferPointer { bp in
                buf.withUnsafeMutableBufferPointer { op in
                    f(bp.baseAddress, bytes.count, op.baseAddress, cap)
                }
            }
            guard n > 0 else { return [] }
            return (0..<Int(n)).map { (lon: buf[2 * $0], lat: buf[2 * $0 + 1]) }
        }
        return decodePolylineSwift(bytes)
    }

    /// Pure-Swift fallback — same algorithm as rust/flows-core/src/polyline.rs.
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
