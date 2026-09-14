// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Polyline decoding and risk banding, computed in rust/flows-core and called
/// through rust/flows-bridge. No arithmetic and no thresholds live here; the
/// band cuts are read from Rust, so Swift holds no copy of them.
enum FlowsCore {
    /// Decode a Google encoded polyline into (lon, lat) pairs.
    static func decodePolyline(_ encoded: String) -> [(lon: Double, lat: Double)] {
        decodePolyline(bytes: Array(encoded.utf8))
    }

    /// Decode polyline bytes into (lon, lat) pairs. Rust returns the pairs
    /// interleaved; this copies them out once.
    static func decodePolyline(bytes: [UInt8]) -> [(lon: Double, lat: Double)] {
        // An empty polyline has no points; nothing to send across.
        guard !bytes.isEmpty else { return [] }
        let flat = bytes.withUnsafeBufferPointer { flows_decode_polyline_lonlat($0) }
        let pairs = flat.len() / 2
        return withExtendedLifetime(flat) {
            let p = flat.as_ptr()
            return (0..<pairs).map { (lon: p[2 * $0], lat: p[2 * $0 + 1]) }
        }
    }

    static let riskGreenMin = flows_risk_green_min()
    static let riskYellowMin = flows_risk_yellow_min()

    static func riskBand(score: Double) -> RiskBand {
        switch flows_risk_band_code(score) {
        case 1: return .green
        case 2: return .yellow
        case 3: return .red
        default: return .clear
        }
    }
}

enum RiskBand: String {
    case clear = "Clear"
    case green = "Green"
    case yellow = "Yellow"
    case red = "Red"
}
