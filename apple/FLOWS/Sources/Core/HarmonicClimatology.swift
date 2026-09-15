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
///
/// The file is parsed and held in rust/flows-core (climate.rs) and scored
/// there; this struct is a handle, created through rust/flows-bridge, and the
/// table is never copied out. Loading the file stays here. Pinned to the
/// Swift this replaced by rust/flows-bridge/tests/fixtures/swift_climate_oracle.tsv.
struct HarmonicClimatology {
    private let table: FlowsHarmonicTable
    let families: [String]
    static let scoreMax = flows_climate_score_max()

    /// Parse the FLHH binary; nil on any structural mismatch (never traps).
    init?(data: Data) {
        // An empty buffer never crosses; an empty file is not a table anyway.
        guard !data.isEmpty,
              let parsed = data.withUnsafeBytes({ raw -> FlowsHarmonicTable? in
                  flows_climate_parse_flhh(raw.bindMemory(to: UInt8.self))
              })
        else { return nil }
        table = parsed
        families = parsed.families().map { $0.as_str().toString() }
    }

    /// Reconstructed score for a ZIP + family at a week-of-year (0…51).
    /// nil when the ZIP or family isn't in the table.
    func score(zip: String, family: String, week: Int) -> Double? {
        let r = table.score_named(zip, family, Int64(week))
        return r.is_some == 1 ? r.value : nil
    }

    func zipIndex(_ zip: String) -> Int? {
        let i = table.zip_index(zip)
        return i >= 0 ? Int(i) : nil
    }

    /// O(1) zip → row map for BULK consumers: the 33k-zip launch rescore did
    /// a `zipIndex` binary search per zip where one build of this map plus a
    /// hash per zip does. Point lookups should keep using `zipIndex`.
    func zipIndexMap() -> [String: Int] {
        var map: [String: Int] = [:]
        for (i, z) in table.zips().enumerated() {
            let key = z.as_str().toString()
            if map[key] == nil { map[key] = i }
        }
        return map
    }

    /// The four trig factors for a week, computed once. `score` needs only
    /// these; hoisting them out of a bulk rescore (33k zips x families, one
    /// fixed week) deletes ~10^5-10^6 redundant libm calls.
    struct WeekTrig {
        let cosT, sinT, cos2T, sin2T: Double
        init(week: Int) {
            let t = flows_climate_week_trig(Int64(week))
            cosT = t.cos_t; sinT = t.sin_t; cos2T = t.cos_2t; sin2T = t.sin_2t
        }
    }

    /// The score for a row and family with the week's trig factors. A row or
    /// family past the table answers NaN, where the Swift this replaced crashed.
    func score(zipIndex zi: Int, familyIndex fi: Int, trig: WeekTrig) -> Double {
        table.score_row(Int64(zi), Int64(fi), trig.cosT, trig.sinT, trig.cos2T, trig.sin2T)
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
