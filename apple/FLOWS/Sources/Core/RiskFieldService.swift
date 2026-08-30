// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation
import MapKit
import os

private let riskLog = Logger(subsystem: "com.flows.app", category: "riskfield")

/// The R engine's ZIP-level risk field, on-device.
///
/// scripts/export_app_risk_bundle.R dumps the warmed snapshot's per-ZIP
/// family scores (the web Map Filter's 11 primary maps), normalized
/// environmental score, hazard summary text, and simplified polygons to
/// data/runtime_cache/app_risk_bundle.json. This service loads that bundle so
/// the app renders the SAME numbers the web map shows:
///   * the family-filtered ZIP choropleth overlay,
///   * the continuous risk field that colors route segments physically
///     (the web app's roads inherit ZIP risk the same way),
///   * per-ZIP hazard descriptions for the route summary text.
/// When no bundle is present (fresh machine, iOS before a serving endpoint
/// exists) everything degrades to the alert-only behavior.
@MainActor
final class RiskFieldService: ObservableObject {
    struct ZipEntry: Identifiable {
        let id = UUID()
        let zip: String
        let centroid: CLLocationCoordinate2D
        let scores: [Double]           // aligned with `families`
        let summary: String?           // risk_type_summary_text
        let ring: [CLLocationCoordinate2D]?
    }

    @Published private(set) var loaded = false
    @Published private(set) var families: [String] = []
    @Published private(set) var generatedUTC: String?

    private var entries: [ZipEntry] = []
    private var grid: [Int: [Int]] = [:]   // 0.2° cell -> entry indices
    /// families → index, O(1) — familyIndex used to linear-scan ~15 Strings
    /// and route scoring asks it 13× per corridor sample.
    private var familyIdx: [String: Int] = [:]
    /// Structure-of-arrays centroid mirror of `entries`: the nearest-entry
    /// scan touches ONLY these two flat Double arrays instead of
    /// materializing a 4-refcount ZipEntry per candidate.
    private var centroidLats: [Double] = []
    private var centroidLons: [Double] = []

    init() {
        riskLog.info("init — scheduling load")
        Task { await load() }
    }

    // MARK: lookups (all O(neighborhood), backed by the grid index)

    func familyIndex(_ family: String) -> Int? {
        familyIdx[family]
    }

    /// The aligned score row at a coordinate = nearest ZIP centroid within
    /// ~30 km (matches the web app's ZIP-resolution field; nil beyond it).
    /// ONE nearest-entry resolution serves every family at the point — route
    /// scoring reads 13 family scores per corridor sample, and the old
    /// per-family score() accessor redid the same neighborhood scan for each.
    /// Index the row with `familyIndex(_:)`.
    func scoreRow(at coord: CLLocationCoordinate2D) -> [Double]? {
        nearestEntry(to: coord)?.scores
    }

    /// Hazard summary text of the ZIP under a coordinate.
    func summary(at coord: CLLocationCoordinate2D) -> String? {
        nearestEntry(to: coord)?.summary
    }

    /// ZIP entries whose centroid falls inside `region`, worst-score-first
    /// for the given family, capped — the choropleth overlay's working set.
    /// Memoized: mapLayer asks for the same working set at least twice per
    /// render (choropleth + weather shapes), and the map re-renders on every
    /// model tick — each miss was a full filter+sort of every entry
    /// (near-miss from review).
    private var zipsMemo: [ZipsMemoKey: [ZipEntry]] = [:]

    /// Hashable memo key with the same 3-decimal bucketing the old
    /// `String(format: "%.3f…")` key had — minus the NSString formatting trip
    /// this per-render path paid on every probe.
    private struct ZipsMemoKey: Hashable {
        let family: String
        let limit: Int
        let cLat: Int, cLon: Int, dLat: Int, dLon: Int

        init(family: String, limit: Int, region: MKCoordinateRegion) {
            self.family = family
            self.limit = limit
            func q(_ v: Double) -> Int { Int((v * 1000).rounded()) }
            cLat = q(region.center.latitude)
            cLon = q(region.center.longitude)
            dLat = q(region.span.latitudeDelta)
            dLon = q(region.span.longitudeDelta)
        }
    }

    func zips(in region: MKCoordinateRegion, family: String, limit: Int) -> [ZipEntry] {
        guard let fi = familyIndex(family) else { return [] }
        let key = ZipsMemoKey(family: family, limit: limit, region: region)
        if let hit = zipsMemo[key] { return hit }
        let out = Self.selectZips(
            entries: entries, grid: grid,
            latMin: region.center.latitude - region.span.latitudeDelta / 2,
            latMax: region.center.latitude + region.span.latitudeDelta / 2,
            lonMin: region.center.longitude - region.span.longitudeDelta / 2,
            lonMax: region.center.longitude + region.span.longitudeDelta / 2,
            fi: fi, limit: limit)
        if zipsMemo.count > 8 { zipsMemo.removeAll() }   // camera moved on: tiny cache
        zipsMemo[key] = out
        return out
    }

    private func nearestEntry(to coord: CLLocationCoordinate2D) -> ZipEntry? {
        var best: (idx: Int, d2: Double)?
        let (cy, cx) = Self.cell(coord)
        // Loop-invariant: the longitude cosine depends on the QUERY point, not
        // the candidate — hoist it out of the ~90-entry neighbourhood scan.
        // Same value, computed once → byte-identical.
        let cosLat = cos(coord.latitude * .pi / 180)
        // The 0.27° cutoff is applied to COS-SCALED longitude, so the RAW
        // longitude reach it needs is 0.27/cosLat degrees — which exceeds the
        // ±0.4° that ±2 cells of 0.2° give above ~47.5°N. A fixed ±2 window
        // silently missed ZIPs in Alaska/high-latitude Canada. Widen the
        // longitude half-window with latitude; ±2 for latitude is enough
        // (0.27/0.2 ≈ 1.35). Clamped so a near-pole query can't blow up.
        let dyMax = 2
        let dxMax = min(6, max(2, Int((0.27 / max(cosLat, 0.15) / 0.2).rounded(.up))))
        for dy in -dyMax...dyMax {
            for dx in -dxMax...dxMax {
                for idx in grid[Self.cellKey(cy + dy, cx + dx)] ?? [] {
                    // SoA centroid arrays: unmanaged Doubles only — reading
                    // entries[idx] here materialized a ZipEntry (4 refcounted
                    // fields) per candidate just to compare two numbers.
                    let dLat = centroidLats[idx] - coord.latitude
                    let dLon = (centroidLons[idx] - coord.longitude) * cosLat
                    let d2 = dLat * dLat + dLon * dLon
                    if best == nil || d2 < best!.d2 { best = (idx, d2) }
                }
            }
        }
        // ~30 km cap (0.27° squared) — beyond the field, report nothing.
        guard let best, best.d2 < 0.27 * 0.27 else { return nil }
        return entries[best.idx]
    }

    // MARK: loading

    private struct RawBundle: Decodable {
        let generated_utc: String
        let families: [String]
        let zips: [RawZip]
    }

    private struct RawZip: Decodable {
        let z: String
        let c: [Double]
        let s: [Double]
        let t: String?
        let p: [[Double]]?
    }

    /// FRB1 binary bundle first (zero JSON parse cost on the launch path —
    /// rust/flows-train/src/bin/bundle-frb.rs writes it with bit-exact
    /// doubles), JSON as the dev/legacy fallback.
    nonisolated private static func candidatePaths() -> [String] {
        #if os(macOS)
        let repo = ProcessInfo.processInfo.environment["FLOWS_REPO"]
            ?? "\(NSHomeDirectory())/Documents/Coding_Files/FLOWS"
        return [
            Bundle.main.path(forResource: "app_risk_bundle", ofType: "frb1"),
            "\(repo)/data/runtime_cache/app_risk_bundle.frb1",
            "/Users/Shared/flows/repo/data/runtime_cache/app_risk_bundle.frb1",
            Bundle.main.path(forResource: "app_risk_bundle", ofType: "json"),
            "\(repo)/data/runtime_cache/app_risk_bundle.json",
            "/Users/Shared/flows/repo/data/runtime_cache/app_risk_bundle.json",
        ].compactMap { $0 }
        #else
        return [
            Bundle.main.path(forResource: "app_risk_bundle", ofType: "frb1"),
            Bundle.main.path(forResource: "app_risk_bundle", ofType: "json"),
        ].compactMap { $0 }
        #endif
    }

    /// Parse the FRB1 binary risk bundle (see bundle-frb.rs for the format
    /// contract: 28-byte header with fnv1a-64 over the payload, then
    /// generated_utc, length-prefixed family names, 5-char zip index,
    /// centroid f64 pairs, row-major f64 scores, length-prefixed summaries,
    /// and optional rings). Corrupt shards are refused, never repaired —
    /// same discipline as FPS1/FLHH.
    nonisolated static func parseFRB1(_ data: Data)
        -> (entries: [ZipEntry], families: [String], generated: String)? {
        guard data.count > 28, data.prefix(4) == Data("FRB1".utf8) else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer)
            -> ([ZipEntry], [String], String)? in
            func u32(_ at: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
            guard u32(4) == 1 else { return nil }
            let nFams = u32(8), nZips = u32(12), genLen = u32(16)
            let storedHash = raw.loadUnaligned(fromByteOffset: 20, as: UInt64.self)
            guard nFams > 0, nZips >= 0, genLen >= 0 else { return nil }
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for i in 28..<data.count {
                hash ^= UInt64(raw[i])
                hash = hash &* 0x0000_0100_0000_01b3
            }
            guard hash == storedHash else { return nil }

            var off = 28
            func take(_ n: Int) -> Bool { // bounds guard before each section
                guard off + n <= data.count else { return false }
                return true
            }
            guard take(genLen) else { return nil }
            let generated = String(decoding: raw[off..<off + genLen], as: UTF8.self)
            off += genLen

            var families: [String] = []; families.reserveCapacity(nFams)
            for _ in 0..<nFams {
                guard take(1) else { return nil }
                let len = Int(raw[off]); off += 1
                guard take(len) else { return nil }
                families.append(String(decoding: raw[off..<off + len], as: UTF8.self))
                off += len
            }

            guard take(nZips * 5) else { return nil }
            var zipCodes: [String] = []; zipCodes.reserveCapacity(nZips)
            for i in 0..<nZips {
                zipCodes.append(String(decoding: raw[off + i * 5..<off + i * 5 + 5],
                                       as: UTF8.self))
            }
            off += nZips * 5

            guard take(nZips * 16) else { return nil }
            let centroidBase = off
            off += nZips * 16
            guard take(nZips * nFams * 8) else { return nil }
            let scoreBase = off
            off += nZips * nFams * 8

            var summaries: [String?] = []; summaries.reserveCapacity(nZips)
            for _ in 0..<nZips {
                guard take(2) else { return nil }
                let len = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
                off += 2
                guard take(len) else { return nil }
                summaries.append(len == 0 ? nil
                    : String(decoding: raw[off..<off + len], as: UTF8.self))
                off += len
            }

            var rings: [[CLLocationCoordinate2D]?] = []; rings.reserveCapacity(nZips)
            for _ in 0..<nZips {
                guard take(2) else { return nil }
                let npts = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
                off += 2
                guard take(npts * 16) else { return nil }
                if npts >= 3 {
                    var ring: [CLLocationCoordinate2D] = []; ring.reserveCapacity(npts)
                    for p in 0..<npts {
                        let lon = raw.loadUnaligned(fromByteOffset: off + p * 16, as: Double.self)
                        let lat = raw.loadUnaligned(fromByteOffset: off + p * 16 + 8, as: Double.self)
                        ring.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    }
                    rings.append(ring)
                } else {
                    rings.append(nil)
                }
                off += npts * 16
            }
            guard off == data.count else { return nil }   // no trailing garbage

            var entries: [ZipEntry] = []; entries.reserveCapacity(nZips)
            for i in 0..<nZips {
                let lon = raw.loadUnaligned(fromByteOffset: centroidBase + i * 16, as: Double.self)
                let lat = raw.loadUnaligned(fromByteOffset: centroidBase + i * 16 + 8, as: Double.self)
                var scores: [Double] = []; scores.reserveCapacity(nFams)
                for f in 0..<nFams {
                    scores.append(raw.loadUnaligned(
                        fromByteOffset: scoreBase + (i * nFams + f) * 8, as: Double.self))
                }
                entries.append(ZipEntry(
                    zip: zipCodes[i],
                    centroid: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    scores: scores, summary: summaries[i], ring: rings[i]))
            }
            return (entries, families, generated)
        }
    }

    private func load() async {
        riskLog.info("load started; candidates: \(Self.candidatePaths().joined(separator: " | "))")
        let parsed: ([ZipEntry], [String], String)? = await Task.detached(priority: .utility) {
            let sp = flowsSignposter.beginInterval("bundle-parse")
            defer { flowsSignposter.endInterval("bundle-parse", sp) }
            for path in Self.candidatePaths() {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                           options: .mappedIfSafe) else { continue }
                if path.hasSuffix(".frb1") {
                    if let (entries, fams, generated) = Self.parseFRB1(data) {
                        return (entries, fams, generated)
                    }
                    continue
                }
                guard let raw = try? JSONDecoder().decode(RawBundle.self, from: data)
                else { continue }
                let entries = raw.zips.compactMap { z -> ZipEntry? in
                    guard z.c.count >= 2 else { return nil }
                    let ring = z.p.map { pts in
                        pts.compactMap { p -> CLLocationCoordinate2D? in
                            p.count >= 2 ? CLLocationCoordinate2D(latitude: p[1], longitude: p[0]) : nil
                        }
                    }
                    return ZipEntry(
                        zip: z.z,
                        centroid: CLLocationCoordinate2D(latitude: z.c[1], longitude: z.c[0]),
                        scores: z.s,
                        summary: z.t,
                        ring: (ring?.count ?? 0) >= 3 ? ring : nil)
                }
                return (entries, raw.families, raw.generated_utc)
            }
            return nil
        }.value

        guard let (loadedEntries, fams, generated) = parsed else {
            riskLog.error("LOAD FAILED — no candidate parsed")
            return
        }
        riskLog.info("loaded \(loadedEntries.count) zips, \(fams.count) families")
        // WEEK-CORRECT seasonal priors: the bundle's national scores are frozen
        // at export week; when the 20-year harmonic table is present, rebuild
        // each NATIONAL entry's covered families for the CURRENT week from its
        // Fourier coefficients. R-engine entries are the ones with polygon
        // rings — those carry live-engine scores and are never touched.
        // The rescore (33k zips × families) and the grid build stay OFF the
        // main actor — inline they blocked launch for seconds, eating the
        // user's first keystrokes and focus clicks in the planner.
        let (final, builtGrid) = await Task.detached(
            priority: .utility
        ) { () -> ([ZipEntry], [Int: [Int]]) in
            let sp = flowsSignposter.beginInterval("rescore+grid")
            defer { flowsSignposter.endInterval("rescore+grid", sp) }
            var final = loadedEntries
            if let table = HarmonicClimatology.loadBundled() {
                let week = SeasonalRiskModel.week()
                // One trig evaluation for the whole rescore: `week` is fixed
                // for every zip x family below, so the four sin/cos factors
                // are loop-invariant (~10^5-10^6 identical libm calls saved,
                // bit-identical results).
                let trig = HarmonicClimatology.WeekTrig(week: week)
                let famIdx: [(bundle: Int, harmonic: Int)] = fams.enumerated().compactMap {
                    (i, name) in table.families.firstIndex(of: name).map { (i, $0) }
                }
                let rebuilt = Self.harmonicRescore(
                    entries: &final, table: table, trig: trig, famIdx: famIdx)
                riskLog.info("harmonic climatology: \(rebuilt) national zips rescored for week \(week)")
            }
            return (final, Self.buildGrid(final))
        }.value
        entries = final
        centroidLats = final.map(\.centroid.latitude)
        centroidLons = final.map(\.centroid.longitude)
        families = fams
        familyIdx = Dictionary(uniqueKeysWithValues: fams.enumerated().map { ($1, $0) })
        generatedUTC = generated
        zipsMemo = [:]
        grid = builtGrid
        loaded = true
    }

    /// The week-correct rescore of every national (ring-less) entry.
    /// DELIBERATELY SERIAL — measured before shipping, on the real
    /// 33,613-zip × 8-family table (M-series): per-zip binary search 10.3 ms,
    /// O(1) zip map 8.2 ms, zip map + concurrentPerform chunks 10.3 ms — the
    /// chunk-buffer/merge overhead eats the whole multi-core gain at this
    /// size, and a 2-core A10 would only lose more. So the one real win is
    /// the zip map, and the loop stays a plain pass. Runs inside load()'s
    /// detached utility task, never on the main actor. Factored out so the
    /// equivalence test pins it against a brute-force binary-search rescore.
    nonisolated static func harmonicRescore(
        entries: inout [ZipEntry], table: HarmonicClimatology,
        trig: HarmonicClimatology.WeekTrig, famIdx: [(bundle: Int, harmonic: Int)]
    ) -> Int {
        let zipRow = table.zipIndexMap()
        var rebuilt = 0
        for e in 0..<entries.count where entries[e].ring == nil {
            guard let zi = zipRow[entries[e].zip] else { continue }
            var scores = entries[e].scores
            for (bi, hi) in famIdx where bi < scores.count {
                scores[bi] = table.score(zipIndex: zi, familyIndex: hi, trig: trig)
            }
            entries[e] = ZipEntry(zip: entries[e].zip, centroid: entries[e].centroid,
                                  scores: scores, summary: entries[e].summary,
                                  ring: nil)
            rebuilt += 1
        }
        return rebuilt
    }

    nonisolated private static func cell(_ c: CLLocationCoordinate2D) -> (Int, Int) {
        (Int((c.latitude * 5).rounded(.down)), Int((c.longitude * 5).rounded(.down)))
    }

    nonisolated private static func cellKey(_ y: Int, _ x: Int) -> Int {
        y &* 100_000 &+ x
    }

    /// The 0.2° cell → entry-index map. Factored out of `load()` so the region
    /// query and its equivalence test build the index the same way.
    nonisolated static func buildGrid(_ entries: [ZipEntry]) -> [Int: [Int]] {
        var grid: [Int: [Int]] = [:]
        for (i, e) in entries.enumerated() {
            let (cy, cx) = cell(e.centroid)
            grid[cellKey(cy, cx), default: []].append(i)
        }
        return grid
    }

    /// Region working-set selection — the choropleth's per-viewport query,
    /// factored out as a pure function so it is unit-tested for byte-identity
    /// against the brute-force filter+sort+prefix. Grid-indexed: only the cells
    /// overlapping the lat/lon box are visited, so a viewport query costs
    /// O(cells + C·log C) in its C candidates instead of scanning every ZIP in
    /// the continent (the old `entries.lazy.filter`, O(E) on each memo miss —
    /// and misses recur on every camera move while panning).
    ///
    /// Two rails keep it never worse than the old full scan: a non-finite/zero
    /// box, out-of-range cell bounds, or a box so large the cell walk would
    /// exceed the entry count (whole-continent zoom) all fall back to scanning
    /// all indices. Candidate indices are re-sorted ascending before the score
    /// sort, so — because `Array.sort` is stable — equal-score ties break in
    /// original array order, exactly as `entries.lazy.filter` did. Result is
    /// byte-identical to the previous implementation.
    nonisolated static func selectZips(
        entries: [ZipEntry], grid: [Int: [Int]],
        latMin: Double, latMax: Double, lonMin: Double, lonMax: Double,
        fi: Int, limit: Int
    ) -> [ZipEntry] {
        let cyMinD = (latMin * 5).rounded(.down), cyMaxD = (latMax * 5).rounded(.down)
        let cxMinD = (lonMin * 5).rounded(.down), cxMaxD = (lonMax * 5).rounded(.down)
        let cellCount = (cyMaxD - cyMinD + 1) * (cxMaxD - cxMinD + 1)
        var idxs: [Int]
        if cellCount.isFinite, cellCount > 0, cellCount <= Double(entries.count),
           cyMinD >= -1e7, cyMaxD <= 1e7, cxMinD >= -1e7, cxMaxD <= 1e7 {
            idxs = []
            let cyHi = Int(cyMaxD), cxLo = Int(cxMinD), cxHi = Int(cxMaxD)
            var cy = Int(cyMinD)
            while cy <= cyHi {
                var cx = cxLo
                while cx <= cxHi {
                    if let ids = grid[cellKey(cy, cx)] { idxs.append(contentsOf: ids) }
                    cx += 1
                }
                cy += 1
            }
            idxs.sort()
        } else {
            idxs = Array(entries.indices)
        }
        // Sort INDICES, not entries: moving whole ZipEntry values through a
        // sort meant retain/release on 4 managed fields per swap. Candidate
        // order (ascending) plus the stable sort preserves the documented
        // equal-score tie-break; entries materialize only for the ≤limit
        // survivors.
        var kept: [Int] = []
        kept.reserveCapacity(idxs.count)
        for i in idxs {
            let c = entries[i].centroid
            guard c.latitude >= latMin, c.latitude <= latMax,
                  c.longitude >= lonMin, c.longitude <= lonMax,
                  entries[i].ring != nil else { continue }
            kept.append(i)
        }
        func score(_ i: Int) -> Double {
            fi < entries[i].scores.count ? entries[i].scores[fi] : 0
        }
        let ranked = kept.sorted { score($0) > score($1) }
        return ranked.prefix(limit).map { entries[$0] }
    }
}
