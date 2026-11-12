// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import FlowsBridge
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
        let flat = bytes.lent { flows_decode_polyline_lonlat($0) }
        let pairs = flat.len() / 2
        let all = Array(flat)
        return (0..<pairs).map { (lon: all[2 * $0], lat: all[2 * $0 + 1]) }
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

// MARK: - Number text
//
// The app writes no `String(format:)`: its arguments are C varargs, which
// the compiler cannot check against the format, so a wrong one reads the
// wrong memory. Text is built with string interpolation, and these give the
// two things interpolation lacks.

extension Double {
    /// This number with exactly `places` digits after the point, rounded
    /// the way `%.Nf` rounds (9.95 is "9.9"). Computed in Rust.
    func fixed(_ places: Int) -> String {
        flows_places_text_fixed(self, Int64(places)).text
    }

    /// This number the way `%g` writes it: 3.5 is "3.5" and 4 is "4".
    var general: String { flows_places_text_general(self).text }
}

extension BinaryInteger {
    /// This whole number with leading zeros up to `width` digits, the way
    /// `%02d` writes it: 5 is "05".
    func padded(_ width: Int) -> String {
        let digits = String(magnitude)
        let sign = self < 0 ? "-" : ""
        let zeros = max(width - digits.count - sign.count, 0)
        return sign + String(repeating: "0", count: zeros) + digits
    }
}
