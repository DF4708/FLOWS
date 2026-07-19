// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
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

    /// Same keys/order as the web PRIMARY_MAP_CHOICES (global.R).
    static let familyDisplayNames: [String: String] = [
        "environmental": "Normalized environmental risk",
        "wind": "Wind risk",
        "qpf_flood": "Flood risk",
        "winter": "Winter risk",
        "fire": "Fire risk",
        "convective": "Storm risk",
        "heat": "Heat risk",
        "cold": "Cold risk",
        "air": "Air / smoke risk",
        "radiation": "Radiation / UV risk",
        "seismic": "Seismic risk",
        // Live-feed acute families (scored from primary feeds, not the export).
        "tropical": "Tropical storm risk",
        "volcanic": "Volcanic risk",
        "avalanche": "Avalanche risk",
        "tsunami": "Tsunami risk",
    ]

    @Published private(set) var loaded = false
    @Published private(set) var families: [String] = []
    @Published private(set) var generatedUTC: String?

    private var entries: [ZipEntry] = []
    private var grid: [Int: [Int]] = [:]   // 0.2° cell -> entry indices

    init() {
        riskLog.info("init — scheduling load")
        Task { await load() }
    }

    // MARK: lookups (all O(neighborhood), backed by the grid index)

    func familyIndex(_ family: String) -> Int? {
        families.firstIndex(of: family)
    }

    /// Field score for a family at a coordinate = nearest ZIP centroid within
    /// ~30 km (matches the web app's ZIP-resolution field; 0 beyond it).
    func score(family: String, at coord: CLLocationCoordinate2D) -> Double {
        guard let fi = familyIndex(family), let e = nearestEntry(to: coord) else { return 0 }
        return fi < e.scores.count ? e.scores[fi] : 0
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
    private var zipsMemo: [String: [ZipEntry]] = [:]

    func zips(in region: MKCoordinateRegion, family: String, limit: Int) -> [ZipEntry] {
        guard let fi = familyIndex(family) else { return [] }
        let key = String(
            format: "%@|%d|%.3f|%.3f|%.3f|%.3f", family, limit,
            region.center.latitude, region.center.longitude,
            region.span.latitudeDelta, region.span.longitudeDelta)
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
        // 5×5 of 0.2° cells covers the full 0.27° cutoff (3×3 only reached
        // 0.2°, silently missing centroids in the 0.2–0.27° shell).
        for dy in -2...2 {
            for dx in -2...2 {
                for idx in grid[Self.cellKey(cy + dy, cx + dx)] ?? [] {
                    let e = entries[idx]
                    let dLat = e.centroid.latitude - coord.latitude
                    let dLon = (e.centroid.longitude - coord.longitude) * cosLat
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

    nonisolated private static func candidatePaths() -> [String] {
        #if os(macOS)
        let repo = ProcessInfo.processInfo.environment["FLOWS_REPO"]
            ?? "\(NSHomeDirectory())/Documents/Coding_Files/FLOWS"
        return [
            Bundle.main.path(forResource: "app_risk_bundle", ofType: "json"),
            "\(repo)/data/runtime_cache/app_risk_bundle.json",
            "/Users/Shared/flows/repo/data/runtime_cache/app_risk_bundle.json",
        ].compactMap { $0 }
        #else
        return [Bundle.main.path(forResource: "app_risk_bundle", ofType: "json")].compactMap { $0 }
        #endif
    }

    private func load() async {
        riskLog.info("load started; candidates: \(Self.candidatePaths().joined(separator: " | "))")
        let parsed: ([ZipEntry], [String], String)? = await Task.detached(priority: .utility) {
            let sp = flowsSignposter.beginInterval("bundle-parse")
            defer { flowsSignposter.endInterval("bundle-parse", sp) }
            for path in Self.candidatePaths() {
                guard let data = FileManager.default.contents(atPath: path),
                      let raw = try? JSONDecoder().decode(RawBundle.self, from: data)
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
                var rebuilt = 0
                for e in 0..<final.count where final[e].ring == nil {
                    guard let zi = table.zipIndex(final[e].zip) else { continue }
                    var scores = final[e].scores
                    for (bi, hi) in famIdx where bi < scores.count {
                        scores[bi] = table.score(zipIndex: zi, familyIndex: hi, trig: trig)
                    }
                    final[e] = ZipEntry(zip: final[e].zip, centroid: final[e].centroid,
                                        scores: scores, summary: final[e].summary,
                                        ring: nil)
                    rebuilt += 1
                }
                riskLog.info("harmonic climatology: \(rebuilt) national zips rescored for week \(week)")
            }
            return (final, Self.buildGrid(final))
        }.value
        entries = final
        families = fams
        generatedUTC = generated
        zipsMemo = [:]
        grid = builtGrid
        loaded = true
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
        let inBox: [ZipEntry] = idxs.compactMap { i in
            let e = entries[i]
            guard e.centroid.latitude >= latMin, e.centroid.latitude <= latMax,
                  e.centroid.longitude >= lonMin, e.centroid.longitude <= lonMax,
                  e.ring != nil else { return nil }
            return e
        }
        let ranked = inBox.sorted { a, b in
            let sa = fi < a.scores.count ? a.scores[fi] : 0
            let sb = fi < b.scores.count ? b.scores[fi] : 0
            return sa > sb
        }
        return Array(ranked.prefix(limit))
    }
}
