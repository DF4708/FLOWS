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
/// data/runtime_cache/app_risk_bundle.json; bundle-frb.rs packs it as FRB1.
/// This service loads that bundle so the app renders the SAME numbers the
/// web map shows:
///   * the family-filtered ZIP choropleth overlay,
///   * the continuous risk field that colors route segments physically
///     (the web app's roads inherit ZIP risk the same way),
///   * per-ZIP hazard descriptions for the route summary text.
/// When no bundle is present (fresh machine, iOS before a serving endpoint
/// exists) everything degrades to the alert-only behavior.
///
/// The field itself — the FRB1 reader, the 0.2° grid, the nearest-centroid
/// lookup, the viewport selection and the week-correct rescore — lives in
/// rust/flows-core (risk_field.rs) as one opaque type this service holds
/// through rust/flows-bridge (`RiskField` below). This class keeps the file
/// reads, the JSON fallback, the published state and the render memo.
/// Pinned to the original by
/// rust/flows-bridge/tests/fixtures/swift_risk_field_oracle.tsv.
@MainActor
final class RiskFieldService: ObservableObject {
    struct ZipEntry: Identifiable {
        /// The entry's index in the loaded bundle, so a ZIP keeps one identity
        /// across viewport changes and the map's ForEach updates only the
        /// polygons that changed. (A fresh UUID per selection tore down and
        /// re-added every polygon on each camera settle.) Entries decoded from
        /// JSON before the field indexes them carry -1; they are never drawn.
        var id: Int = -1
        let zip: String
        let centroid: CLLocationCoordinate2D
        let scores: [Double]           // aligned with `families`
        let summary: String?           // risk_type_summary_text
        let ring: [CLLocationCoordinate2D]?
    }

    @Published private(set) var loaded = false
    @Published private(set) var families: [String] = []
    @Published private(set) var generatedUTC: String?

    /// The bundle's build stamp ("2026-07-04T11:39:45Z") as Settings shows
    /// it — "July 4, 2026" — or nil when it does not parse. The raw stamp
    /// read like a timestamp on live data.
    nonisolated static func builtDate(_ generatedUTC: String, locale: Locale = .current,
                                      timeZone: TimeZone = .current) -> String? {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: generatedUTC) else { return nil }
        let out = DateFormatter()
        out.locale = locale
        out.timeZone = timeZone
        out.dateStyle = .long
        out.timeStyle = .none
        return out.string(from: date)
    }

    /// The loaded field; nil until `load()` has parsed a bundle.
    private var field: RiskField?

    init() {
        riskLog.info("init — scheduling load")
        Task { await load() }
    }

    // MARK: lookups (all O(neighborhood), backed by the grid index in Rust)

    func familyIndex(_ family: String) -> Int? {
        field?.familyIndex(family)
    }

    /// The aligned score row at a coordinate = nearest ZIP centroid within
    /// ~30 km (matches the web app's ZIP-resolution field; nil beyond it).
    /// ONE nearest-entry resolution serves every family at the point — route
    /// scoring reads 13 family scores per corridor sample. Index the row with
    /// `familyIndex(_:)`.
    func scoreRow(at coord: CLLocationCoordinate2D) -> [Double]? {
        guard let field, let i = field.nearest(coord) else { return nil }
        return field.scores(at: i)
    }

    /// Hazard summary text of the ZIP under a coordinate.
    func summary(at coord: CLLocationCoordinate2D) -> String? {
        guard let field, let i = field.nearest(coord) else { return nil }
        return field.summary(at: i)
    }

    /// ZIP entries whose centroid falls inside `region`, worst-score-first
    /// for the given family, capped — the choropleth overlay's working set.
    /// Memoized: mapLayer asks for the same working set at least twice per
    /// render (choropleth + weather shapes), and the map re-renders on every
    /// model tick.
    private var zipsMemo: [ZipsMemoKey: [ZipEntry]] = [:]

    /// Hashable memo key with 3-decimal bucketing of the viewport.
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
        guard let field, let fi = field.familyIndex(family) else { return [] }
        let key = ZipsMemoKey(family: family, limit: limit, region: region)
        if let hit = zipsMemo[key] { return hit }
        let out = field.select(
            latMin: region.center.latitude - region.span.latitudeDelta / 2,
            latMax: region.center.latitude + region.span.latitudeDelta / 2,
            lonMin: region.center.longitude - region.span.longitudeDelta / 2,
            lonMax: region.center.longitude + region.span.longitudeDelta / 2,
            family: fi, limit: limit
        ).map { field.entry($0) }
        if zipsMemo.count > 8 { zipsMemo.removeAll() }   // camera moved on: tiny cache
        zipsMemo[key] = out
        return out
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

    /// The FRB1 binary risk bundle, parsed in Rust (see bundle-frb.rs for the
    /// format contract). Corrupt shards are refused, never repaired — same
    /// discipline as FPS1/FLHH.
    nonisolated static func parseFRB1(_ data: Data) -> RiskField? {
        RiskField(frb1: data)
    }

    private func load() async {
        riskLog.info("load started; candidates: \(Self.candidatePaths().joined(separator: " | "))")
        let parsed: RiskField? = await Task.detached(priority: .utility) {
            let sp = flowsSignposter.beginInterval("bundle-parse")
            defer { flowsSignposter.endInterval("bundle-parse", sp) }
            for path in Self.candidatePaths() {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                           options: .mappedIfSafe) else { continue }
                if path.hasSuffix(".frb1") {
                    if let field = RiskField(frb1: data) { return field }
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
                // A bundle the field refuses is skipped like an unreadable
                // file: the next candidate still gets its turn.
                if let field = RiskField(generated: raw.generated_utc, families: raw.families, entries: entries) {
                    return field
                }
            }
            return nil
        }.value

        guard let field = parsed else {
            riskLog.error("LOAD FAILED — no candidate parsed")
            return
        }
        riskLog.info("loaded \(field.count) zips, \(field.families.count) families")
        // WEEK-CORRECT seasonal priors: the bundle's national scores are frozen
        // at export week; when the 20-year harmonic table is present, rebuild
        // each NATIONAL entry's covered families for the CURRENT week from its
        // Fourier coefficients. R-engine entries are the ones with polygon
        // rings — those carry live-engine scores and are never touched.
        // The rescore (33k zips × families) stays OFF the main actor.
        await Task.detached(priority: .utility) {
            let sp = flowsSignposter.beginInterval("rescore+grid")
            defer { flowsSignposter.endInterval("rescore+grid", sp) }
            if let table = HarmonicClimatology.loadBundled() {
                let week = SeasonalRiskModel.week()
                let rebuilt = field.harmonicRescore(table: table, week: week)
                riskLog.info("harmonic climatology: \(rebuilt) national zips rescored for week \(week)")
            }
        }.value
        self.field = field
        families = field.families
        generatedUTC = field.generated
        zipsMemo = [:]
        loaded = true
    }
}

/// A ZIP's risk summary in plain words. The bundle's trainers wrote lines like
/// "Seasonal baseline: elevated convective risk (climatology)", and the
/// shipped bundle still carries them; they read as "Storms are common here in
/// some seasons." Any other text is shown as written. The rule is Rust's
/// (rust/flows-core risk_summary.rs), the same one the trainers now write
/// with, so an old bundle and a rebuilt one read alike.
enum RiskSummaryText {
    /// The line to show, or nil when there is none to show (an empty text,
    /// or one the rule could not read — never the old line as written).
    static func plain(_ text: String) -> String? {
        let line = flows_risk_summary_plain(text).text
        return line.isEmpty ? nil : line
    }
}

/// The Rust field behind `RiskFieldService`: one opaque handle, parsed once
/// and read in place. Nothing mutates it after `load()` finishes its rescore,
/// so it moves between the loading task and the main actor as a value would.
final class RiskField: @unchecked Sendable {
    let handle: FlowsRiskField

    init(handle: FlowsRiskField) { self.handle = handle }

    /// The FRB1 shard; nil for a corrupt one. An empty buffer never crosses.
    convenience init?(frb1 data: Data) {
        guard !data.isEmpty,
              let parsed = data.withUnsafeBytes({ raw -> FlowsRiskField? in
                  flows_risk_field_parse_frb1(raw.bindMemory(to: UInt8.self))
              })
        else { return nil }
        self.init(handle: parsed)
    }

    /// From entries already decoded (the JSON path, and the tests). Columns
    /// cross as parallel lists, names and summaries as one joined text plus each
    /// text's length (RustTextColumn) and a presence flag beside each optional; a column that would be empty carries
    /// one placeholder the counts ignore, because swift-bridge must never see an
    /// empty buffer. Rings cross as the entry carries them (the JSON path has
    /// already dropped rings under three points).
    convenience init?(generated: String, families: [String], entries: [RiskFieldService.ZipEntry]) {
        let familyColumn = RustTextColumn(families)
        guard !entries.isEmpty else {
            self.init(handle: familyColumn.with { joined, lens, _ in
                flows_risk_field_empty(generated, joined, lens, Int64(families.count))
            })
            return
        }
        var lats: [Double] = [], lons: [Double] = [], scores: [Double] = [], ringPoints: [Double] = []
        var scoreCounts: [Int64] = [], hasSummary: [Int64] = [], ringCounts: [Int64] = [], hasRing: [Int64] = []
        var zips: [String] = [], summaries: [String] = []
        for e in entries {
            zips.append(e.zip)
            lats.append(e.centroid.latitude)
            lons.append(e.centroid.longitude)
            scoreCounts.append(Int64(e.scores.count))
            scores.append(contentsOf: e.scores)
            hasSummary.append(e.summary == nil ? 0 : 1)
            summaries.append(e.summary ?? "")
            ringCounts.append(Int64(e.ring?.count ?? 0))
            hasRing.append(e.ring == nil ? 0 : 1)
            for p in e.ring ?? [] { ringPoints.append(p.latitude); ringPoints.append(p.longitude) }
        }
        if scores.isEmpty { scores = [0] }
        if ringPoints.isEmpty { ringPoints = [0] }
        let zipColumn = RustTextColumn(zips), summaryColumn = RustTextColumn(summaries)
        let handle: FlowsRiskField? = familyColumn.with { fj, fl, _ in zipColumn.with { zj, zl, _ in
          summaryColumn.with { sj, sl, _ in lats.withUnsafeBufferPointer { la in
            lons.withUnsafeBufferPointer { lo in
                scoreCounts.withUnsafeBufferPointer { sc in
                    scores.withUnsafeBufferPointer { s in
                        hasSummary.withUnsafeBufferPointer { hs in
                            ringCounts.withUnsafeBufferPointer { rc in
                                hasRing.withUnsafeBufferPointer { hr in
                                    ringPoints.withUnsafeBufferPointer { rp in
                                        flows_risk_field_from_columns(
                                            generated, fj, fl, Int64(families.count), zj, zl,
                                            la, lo, sc, s, sj, sl, hs, rc, hr, rp)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        } } }
        guard let handle else { return nil }
        self.init(handle: handle)
    }

    var generated: String { handle.generated().text }
    var families: [String] { handle.families().map { $0.text } }
    var count: Int { Int(handle.count()) }

    func familyIndex(_ family: String) -> Int? {
        let i = handle.family_index(family)
        return i < 0 ? nil : Int(i)
    }

    /// The nearest entry within the field's reach (~30 km); nil beyond it.
    func nearest(_ c: CLLocationCoordinate2D) -> Int? {
        let i = handle.nearest(c.latitude, c.longitude)
        return i < 0 ? nil : Int(i)
    }

    func scores(at index: Int) -> [Double] { Array(handle.scores(Int64(index))) }

    /// The entry's summary as a driver reads it (RiskSummaryText): every
    /// reader of the field's text — the route card, the map's tap card, the
    /// entries — goes through here.
    func summary(at index: Int) -> String? {
        guard handle.has_summary(Int64(index)) else { return nil }
        return RiskSummaryText.plain(handle.summary(Int64(index)).text)
    }

    func entry(_ index: Int) -> RiskFieldService.ZipEntry {
        let i = Int64(index)
        var ring: [CLLocationCoordinate2D]?
        if handle.has_ring(i) {
            let flat = Array(handle.ring(i))
            ring = stride(from: 0, to: flat.count - 1, by: 2).map {
                CLLocationCoordinate2D(latitude: flat[$0], longitude: flat[$0 + 1])
            }
        }
        return RiskFieldService.ZipEntry(
            id: index,
            zip: handle.zip(i).text,
            centroid: CLLocationCoordinate2D(latitude: handle.latitude(i), longitude: handle.longitude(i)),
            scores: scores(at: index), summary: summary(at: index), ring: ring)
    }

    /// Every entry, in bundle order (the tests and the JSON round trip).
    var entries: [RiskFieldService.ZipEntry] { (0..<count).map(entry) }

    /// The viewport working set: ringed entries inside the box, worst score
    /// first for the family, the first `limit` of them.
    func select(latMin: Double, latMax: Double, lonMin: Double, lonMax: Double,
                family: Int, limit: Int) -> [Int] {
        Array(handle.select(latMin, latMax, lonMin, lonMax, Int64(family), Int64(limit))).map { Int($0) }
    }

    /// The week-correct rescore of every national (ring-less) entry whose ZIP
    /// the table knows; the count of rebuilt entries.
    func harmonicRescore(table: HarmonicClimatology, week: Int) -> Int {
        Int(handle.harmonic_rescore(table.handle, Int64(week)))
    }
}
