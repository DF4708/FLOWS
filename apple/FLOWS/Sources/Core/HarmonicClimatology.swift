// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Reader for `history_harmonic.bin` — the 20-year NOAA Storm Events
/// climatology compressed to 5 Fourier coefficients per ZIP × family
/// (rust/flows-train history-baseline, format "FLHH"). ~5.5 MB carries the
/// whole CONUS, and reconstructing any week's score on demand means the app's
/// seasonal priors stay WEEK-CORRECT year-round — no weekly bundle re-export.
///
/// Layout (little-endian):
///   "FLHH" | u32 version=1 | u32 nZips | u32 nFamilies
///   per family: u8 nameLen + UTF-8 name
///   zip index: nZips × 5 ASCII bytes, sorted ascending
///   data: nZips × nFamilies × 5 f32 = mean, a1, b1, a2, b2
/// score(w) = clamp(mean + a1·cos t + b1·sin t + a2·cos 2t + b2·sin 2t, 0, 0.6)
/// with t = 2πw/52 — identical math to the Rust `harmonic_eval`.
struct HarmonicClimatology {
    let families: [String]
    private let zips: [String]          // sorted, 5-char
    private let coeffs: [Float]         // nZips × nFamilies × 5
    private let nFamilies: Int

    static let scoreMax = 0.6

    /// Parse the FLHH binary; nil on any structural mismatch (never traps).
    init?(data: Data) {
        var off = 0
        func read(_ n: Int) -> Data? {
            guard off + n <= data.count else { return nil }
            defer { off += n }
            return data.subdata(in: off..<(off + n))
        }
        func u32() -> Int? {
            read(4).map { $0.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) } }
        }
        guard let magic = read(4), magic == Data("FLHH".utf8),
              let version = u32(), version == 1,
              let nZips = u32(), nZips > 0, nZips < 100_000,
              let nFams = u32(), nFams > 0, nFams <= 32 else { return nil }
        var fams: [String] = []
        for _ in 0..<nFams {
            guard let lenB = read(1), let name = read(Int(lenB[0])),
                  let s = String(data: name, encoding: .utf8) else { return nil }
            fams.append(s)
        }
        var zipList: [String] = []
        zipList.reserveCapacity(nZips)
        for _ in 0..<nZips {
            guard let z = read(5), let s = String(data: z, encoding: .utf8) else { return nil }
            zipList.append(s)
        }
        let want = nZips * nFams * 5 * 4
        guard let body = read(want), off == data.count else { return nil }
        var c = [Float](repeating: 0, count: nZips * nFams * 5)
        body.withUnsafeBytes { raw in
            for i in 0..<c.count {
                c[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: Float.self)
            }
        }
        families = fams
        zips = zipList
        coeffs = c
        nFamilies = nFams
    }

    /// Reconstructed score for a ZIP + family at a week-of-year (0…51).
    /// nil when the ZIP or family isn't in the table.
    func score(zip: String, family: String, week: Int) -> Double? {
        guard let fi = families.firstIndex(of: family),
              let zi = zipIndex(zip) else { return nil }
        return score(zipIndex: zi, familyIndex: fi, week: week)
    }

    func zipIndex(_ zip: String) -> Int? {
        var lo = 0, hi = zips.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if zips[mid] == zip { return mid }
            if zips[mid] < zip { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    func score(zipIndex zi: Int, familyIndex fi: Int, week: Int) -> Double {
        let base = (zi * nFamilies + fi) * 5
        let t = 2 * Double.pi * Double(((week % 52) + 52) % 52) / 52
        let v = Double(coeffs[base])
            + Double(coeffs[base + 1]) * cos(t)
            + Double(coeffs[base + 2]) * sin(t)
            + Double(coeffs[base + 3]) * cos(2 * t)
            + Double(coeffs[base + 4]) * sin(2 * t)
        return min(max(v, 0), Self.scoreMax)
    }

    /// Load from the same candidate roots the risk bundle uses.
    static func loadBundled() -> HarmonicClimatology? {
        #if os(macOS)
        let repo = ProcessInfo.processInfo.environment["FLOWS_REPO"]
            ?? "\(NSHomeDirectory())/Documents/Coding_Files/FLOWS"
        let candidates = [
            Bundle.main.path(forResource: "history_harmonic", ofType: "bin"),
            "\(repo)/data/runtime_cache/history_harmonic.bin",
            "/Users/Shared/flows/repo/data/runtime_cache/history_harmonic.bin",
        ].compactMap { $0 }
        #else
        let candidates = [Bundle.main.path(forResource: "history_harmonic", ofType: "bin")]
            .compactMap { $0 }
        #endif
        for path in candidates {
            if let data = FileManager.default.contents(atPath: path),
               let table = HarmonicClimatology(data: data) {
                return table
            }
        }
        return nil
    }
}
