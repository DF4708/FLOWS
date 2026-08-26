// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
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
        // Zip index and coefficient body decode IN PLACE from the (mapped)
        // buffer: the per-zip subdata() built ~33k throwaway Data objects,
        // and the body subdata was a ~5 MB transient copy of data that is
        // immediately re-copied into `coeffs`.
        let zipsOff = off
        guard off + 5 * nZips <= data.count else { return nil }
        off += 5 * nZips
        var zipList: [String] = []
        zipList.reserveCapacity(nZips)
        let zipsOK = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<nZips {
                let start = zipsOff + i * 5
                guard let s = String(bytes: bytes[start..<(start + 5)], encoding: .utf8)
                else { return false }
                zipList.append(s)
            }
            return true
        }
        guard zipsOK else { return nil }
        let want = nZips * nFams * 5 * 4
        guard off + want == data.count else { return nil }
        let bodyOff = off
        var c = [Float](repeating: 0, count: nZips * nFams * 5)
        // One bulk copy instead of ~1.8M scalar unaligned loads: FLHH floats
        // are little-endian IEEE-754, same as every Apple target, so memcpy
        // (NEON-vectorized in libsystem) produces identical bytes.
        data.withUnsafeBytes { raw in
            c.withUnsafeMutableBytes { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(
                    rebasing: raw[bodyOff..<(bodyOff + want)]))
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

    /// O(1) zip → row map for BULK consumers: the 33k-zip launch rescore did
    /// a `zipIndex` binary search per zip — ~half a million Unicode String
    /// comparisons — where one build of this map plus a hash per zip does.
    /// Point lookups should keep using `zipIndex` (no map to build or hold).
    func zipIndexMap() -> [String: Int] {
        Dictionary(zips.enumerated().map { ($1, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// The four trig factors for a week, computed once. `score` needs only
    /// these; hoisting them out of a bulk rescore (33k zips x families, one
    /// fixed week) deletes ~10^5-10^6 redundant libm calls that all return
    /// the identical bits. Same calls, same argument, same doubles — the
    /// hoisted path is byte-identical to the per-call path by construction.
    struct WeekTrig {
        let cosT, sinT, cos2T, sin2T: Double
        init(week: Int) {
            let t = 2 * Double.pi * Double(((week % 52) + 52) % 52) / 52
            cosT = cos(t); sinT = sin(t); cos2T = cos(2 * t); sin2T = sin(2 * t)
        }
    }

    func score(zipIndex zi: Int, familyIndex fi: Int, trig: WeekTrig) -> Double {
        let base = (zi * nFamilies + fi) * 5
        let v = Double(coeffs[base])
            + Double(coeffs[base + 1]) * trig.cosT
            + Double(coeffs[base + 2]) * trig.sinT
            + Double(coeffs[base + 3]) * trig.cos2T
            + Double(coeffs[base + 4]) * trig.sin2T
        return min(max(v, 0), Self.scoreMax)
    }

    func score(zipIndex zi: Int, familyIndex fi: Int, week: Int) -> Double {
        score(zipIndex: zi, familyIndex: fi, trig: WeekTrig(week: week))
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
            // Mapped, not copied — FileManager.contents pulled the whole
            // ~5.5 MB table into memory before parsing began.
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                    options: .mappedIfSafe),
               let table = HarmonicClimatology(data: data) {
                return table
            }
        }
        return nil
    }
}
