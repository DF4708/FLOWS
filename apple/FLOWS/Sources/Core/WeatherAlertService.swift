// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// NWS active-alert ingest, corridor-scoped.
///
/// The web app scores whole states of ZIPs; the app only ever asks about the
/// corridor it is planning or driving — a handful of api.weather.gov point
/// queries, deduplicated by alert zone. Severity folds into the same 0…1 risk
/// scale the rest of FLOWS uses (cuts in FlowsCore.riskBand).
@MainActor
final class WeatherAlertService: ObservableObject {
    @Published private(set) var activeHeadlines: [String] = []

    private var watchTask: Task<Void, Never>?
    private var seenAlertIDs = Set<String>()
    private let cache = AlertZoneCache()

    /// One NWS alert polygon, map-drawable — the corridor-scoped analog of
    /// the web app's ZIP risk choropleth.
    struct AlertPolygon: Identifiable {
        let id = UUID()
        let coordinates: [CLLocationCoordinate2D]
        let severity: Double
        let event: String
    }

    struct CorridorScore {
        /// Normalized corridor risk — the SAME noisy-OR shape as the web
        /// app's environmental normalization (R/families.R noisy_or_combine):
        /// risk = 1 − Π(1 − severityᵢ·coverageᵢ) over distinct alerts, where
        /// coverageᵢ is the fraction of corridor samples inside alert i.
        /// One severe alert across the whole corridor → red; the same alert
        /// clipping one corner → moderate; several moderate hazards stack up
        /// — exactly the web app's combination behavior, so the FLOWS band
        /// cuts apply unchanged.
        var risk: Double
        /// Worst single alert severity (the "max" the score used to be).
        var worstSeverity: Double
        /// Fraction of corridor samples inside any active alert.
        var coverage: Double
        var headlines: [String]
        /// Distinct event names, worst-first ("Flood Warning", …).
        var events: [String]
        /// Local risk at every input sample (cell-resolved) — powers the
        /// on-map risk-colored corridor and the per-route risk strips.
        var samples: [RiskSample]
        /// Actual alert geometries along the corridor, severity-tinted.
        var alertPolygons: [AlertPolygon]
        /// False when any cell fetch failed — callers must not present the
        /// corridor as confidently clear (and should retry).
        var complete: Bool = true
        /// Every distinct alert on the corridor, by id — samples carry the
        /// id of their worst alert, so the imminent-alert engine can join a
        /// risky sample back to its official summary + source link.
        var alertsByID: [String: NWSAlert] = [:]
    }

    /// One-shot corridor score for route ranking.
    ///
    /// Measured on 30809→53203 (961 mi, 3 alternates): the original
    /// one-query-per-sample sequential loop took ~55 s for all routes. This
    /// version reaches the same risk values (verified against the sequential
    /// oracle in apple/tools/route_bench.swift) in ~8 s for ALL routes:
    ///   - one query per 0.25° grid cell (~28 km — finer than the 40 km sample
    ///     spacing, so same-route samples almost never merge: no accuracy loss;
    ///     the dedupe win is alternates sharing corridor cells. 0.5° was tried
    ///     and measurably dropped a Severe alert);
    ///   - a TTL cache shared across routes and re-scores;
    ///   - at most `maxInFlight` NWS requests concurrently (polite to
    ///     api.weather.gov, still ~6x the sequential throughput).
    /// `arrivalOffsets[i]` = seconds until the driver reaches sample i.
    /// Time-aware: an alert that EXPIRES before the driver arrives at its
    /// stretch contributes nothing there — a 10 h route with a 1 h-remaining
    /// storm at the far end scores clear at that end (RiskTiming).
    func corridorRisk(
        at samples: [CLLocationCoordinate2D],
        arrivalOffsets: [TimeInterval]? = nil
    ) async -> CorridorScore {
        let now = Date()
        func offset(_ i: Int) -> TimeInterval {
            guard let arrivalOffsets, i < arrivalOffsets.count else { return 0 }
            return arrivalOffsets[i]
        }
        // One representative point per grid cell, first-sample-wins.
        var cells: [String: CLLocationCoordinate2D] = [:]
        for pt in samples {
            let key = Self.cellKey(pt)
            if cells[key] == nil { cells[key] = pt }
        }
        var cellAlerts: [String: [NWSAlert]] = [:]
        var fresh: [(String, CLLocationCoordinate2D)] = []
        for (key, pt) in cells {
            if let cached = await cache.get(key) {
                cellAlerts[key] = cached
            } else {
                fresh.append((key, pt))
            }
        }
        let maxInFlight = AdaptiveTuning.shared.maxInFlight
        var idx = 0
        var fetchFailures = 0
        while idx < fresh.count {
            let batch = Array(fresh[idx..<min(idx + maxInFlight, fresh.count)])
            idx += batch.count
            // Review finding: `?? []` here poisoned the cache — a transient
            // network failure was stored as "no alerts" for the TTL and the
            // route scored confidently clear. Failures are now distinguished,
            // NOT cached, and reported via `complete` so callers can retry.
            await withTaskGroup(of: (String, [NWSAlert]?).self) { group in
                for (key, pt) in batch {
                    // Coalesced through the cache actor: concurrent corridor
                    // scores (route alternates) join one fetch per cell
                    // instead of each running their own. Success is cached
                    // inside fetch(); failure returns nil uncached.
                    group.addTask {
                        (key, await self.cache.fetch(key) {
                            await self.activeAlerts(at: pt)
                        })
                    }
                }
                for await (key, got) in group {
                    if let got {
                        cellAlerts[key] = got
                    } else {
                        fetchFailures += 1
                    }
                }
            }
        }
        // Per-sample local risk: the worst alert in the sample's cell that
        // will STILL BE ACTIVE when the driver arrives there.
        let riskSamples = samples.enumerated().map { i, pt -> RiskSample in
            let hits = (cellAlerts[Self.cellKey(pt)] ?? [])
                .filter { RiskTiming.isActive(expires: $0.expires, arrivalOffset: offset(i), now: now) }
            let worst = hits.max { $0.severityScore < $1.severityScore }
            return RiskSample(
                coordinate: pt,
                risk: worst?.severityScore ?? 0,
                worstEvent: worst?.event,
                alertID: worst?.id)
        }
        // Per-alert corridor coverage: fraction of samples whose cell
        // contains that alert AND where it survives until arrival.
        var alertSampleCount: [String: Int] = [:]
        for (i, pt) in samples.enumerated() {
            for h in cellAlerts[Self.cellKey(pt)] ?? []
            where RiskTiming.isActive(expires: h.expires, arrivalOffset: offset(i), now: now) {
                alertSampleCount[h.id, default: 0] += 1
            }
        }
        // Distinct alerts, worst-first — dropping alerts the drive outlives
        // entirely (zero active coverage → no risk, no headline).
        var seen = Set<String>()
        var unique: [NWSAlert] = []
        for hits in cellAlerts.values {
            for h in hits where seen.insert(h.id).inserted
                && alertSampleCount[h.id, default: 0] > 0 { unique.append(h) }
        }
        unique.sort { $0.severityScore > $1.severityScore }

        // Noisy-OR normalization (mirror of R/families.R noisy_or_combine):
        // each alert contributes severity × corridor-coverage.
        let n = Double(max(samples.count, 1))
        var survival = 1.0
        for h in unique {
            let cov = Double(alertSampleCount[h.id] ?? 0) / n
            survival *= 1 - min(max(h.severityScore * cov, 0), 1)
        }
        let normalized = 1 - survival

        var eventSeen = Set<String>()
        let events = unique.compactMap { eventSeen.insert($0.event).inserted ? $0.event : nil }

        let polygons: [AlertPolygon] = unique.compactMap { h in
            guard let ring = h.polygon, ring.count >= 3 else { return nil }
            return AlertPolygon(coordinates: ring, severity: h.severityScore, event: h.event)
        }.prefix(40).map { $0 }   // was 12 — clipped visible weather on long routes

        return CorridorScore(
            risk: normalized,
            worstSeverity: unique.first?.severityScore ?? 0,
            coverage: riskSamples.isEmpty ? 0
                : Double(riskSamples.filter { $0.risk > 0 }.count) / Double(riskSamples.count),
            headlines: unique.map(\.headline),
            events: events,
            samples: riskSamples,
            alertPolygons: polygons,
            complete: fetchFailures == 0,
            alertsByID: Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0) }))
    }

    /// 0.25° cell key (~28 km): matches NWS zone scale without merging
    /// adjacent 40 km corridor samples.
    private static func cellKey(_ pt: CLLocationCoordinate2D) -> String {
        "\(Int((pt.latitude * 4).rounded()))|\(Int((pt.longitude * 4).rounded()))"
    }

    /// While navigating: re-check the corridor ahead every few minutes —
    /// turn-by-turn is time-sensitive, so the weather picture refreshes at a
    /// driving cadence, not the web app's whole-map cadence. Each re-score is
    /// delivered to `onUpdate` so the navigation layer can detect escalation
    /// and offer a reroute.
    /// Window provider: (alongMeters, lookaheadMeters, cadenceSeconds) —
    /// supplied by AppModel from live GPS progress + speed. Faster travel =
    /// alerts and predictions FURTHER OUT and refreshed MORE OFTEN; walking
    /// pace watches a few km at a relaxed cadence. Only the windowed slice of
    /// the corridor is processed — never the whole remaining route, never
    /// anything outside the route buffer.
    func beginCorridorWatch(
        along route: PlannedRoute,
        window: (@MainActor () -> (along: Double, lookahead: Double, cadence: Double))? = nil,
        onUpdate: (@MainActor (CorridorScore) -> Void)? = nil
    ) {
        watchTask?.cancel()
        seenAlertIDs.removeAll()
        let polyline = route.route.polyline
        let spacing = 40_000.0
        let allSamples = RouteService.samplePoints(of: polyline, everyMeters: spacing)
        // Route pace for time-aware scoring while driving: window sample i
        // is ~i*spacing ahead of the vehicle.
        let secondsPerMeter = route.eta / max(route.distanceMeters, 1)
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let w = window?() ?? (along: 0, lookahead: Double.greatestFiniteMagnitude,
                                      cadence: 240)
                // Sample i sits ~i*spacing along the route; slice the window.
                // Clamp in Double first — review finding: Int(4.5e303)
                // traps when lookahead is .greatestFiniteMagnitude.
                let maxIdx = Double(allSamples.count - 1)
                let lo = Int(min(max(w.along / spacing, 0), maxIdx))
                let hi = Int(min(max((w.along + w.lookahead) / spacing + 1, 0), maxIdx))
                let windowed = lo <= hi ? Array(allSamples[lo...hi]) : allSamples
                let offsets = (0..<windowed.count).map { Double($0) * spacing * secondsPerMeter }
                let score = await self.corridorRisk(at: windowed, arrivalOffsets: offsets)
                self.activeHeadlines = score.headlines
                onUpdate?(score)
                try? await Task.sleep(for: .seconds(max(w.cadence, 60) * AdaptiveTuning.shared.settings.ttlMultiplier))
            }
        }
    }

    func endCorridorWatch() {
        watchTask?.cancel()
        watchTask = nil
        activeHeadlines = []
    }

    // MARK: NWS fetch

    struct NWSAlert: Sendable {
        let id: String
        let event: String
        let headline: String
        let severityScore: Double
        /// Outer ring of the alert's polygon when the feed provides geometry
        /// (many alerts are zone-referenced with `geometry: null` — those
        /// still score, they just can't be drawn).
        let polygon: [CLLocationCoordinate2D]?
        /// When the alert expires (imminent-alert policy: expiry within ~2 h
        /// makes an upper-yellow risk "transient" → wait it out at a rest
        /// area instead of driving into it).
        var expires: Date? = nil
        /// When the incident BEGAN (onset/effective/sent) — the reach
        /// circle's clock starts here.
        var onset: Date? = nil
        /// The issuing agency's canonical record for THIS alert — tapping
        /// the on-screen warning opens it.
        var sourceURL: URL? = nil
        /// First lines of the official description (the on-screen summary).
        var detail: String? = nil
    }

    // ISO8601DateFormatter is thread-safe (Foundation guarantees it post-iOS
    // 10), so unsafe-nonisolated shared use across the concurrent fetchers is
    // correct; the Sendable checker just can't prove it.
    nonisolated(unsafe) private static let alertDateParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// nonisolated: touches only the immutable `session`, so TaskGroup children
    /// can fetch truly concurrently instead of hopping through the main actor.
    /// Chain: NWS (US) → ECCC GeoMet CAP alerts (Canada). Mexico's SMN
    /// publishes bulletins rather than a point-queryable alert API — SMN's
    /// forecast severity flows through the conditions provider instead.
    nonisolated private func activeAlerts(at point: CLLocationCoordinate2D) async -> [NWSAlert]? {
        // Fall through to a foreign feed ONLY when NWS reports the point is
        // OUTSIDE its coverage (HTTP 400/404): US → Canada → Mexico/Central-
        // America/Caribbean (WMO Alert Hub). On a TRANSIENT NWS failure
        // (5xx/timeout/network) for a point NWS does cover, return nil ("unknown")
        // rather than substituting Canadian/WMO alerts — otherwise a driver in the
        // northern US (lat > 41.5) could be shown another country's warnings, and
        // cached for the whole TTL, on a single api.weather.gov blip.
        switch await nwsAlerts(at: point) {
        case .alerts(let us): return us
        case .failed: return nil
        case .offRegion:
            if let ca = await ecccAlerts(at: point) { return ca }
            return await wmoAlerts(at: point)
        }
    }

    /// Outcome of an NWS point query — distinguishes "outside US coverage" (fall
    /// through to a foreign feed) from a "transient failure" (do NOT substitute).
    private enum NWSResult {
        case alerts([NWSAlert])
        case offRegion
        case failed
    }

    nonisolated private static let rfc822Parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    /// WMO Alert Hub national CAP alerts for Mexico + Central America + the
    /// Caribbean. The country's active alerts (with polygons) are fetched and
    /// cached ONCE per country by `WMOAlertCache`; here we just keep the ones
    /// whose polygon contains this point.
    nonisolated private func wmoAlerts(at point: CLLocationCoordinate2D) async -> [NWSAlert]? {
        guard let code = WMOAlertParsing.feedCode(for: point) else { return nil }
        let all = await WMOAlertCache.shared.alerts(code: code)
        return all.filter { alert in
            alert.polygon.map { HazardFeedScores.pointInPolygon(point, $0) } ?? false
        }
    }

    /// One severity→score table for every provider (review finding: NWS and
    /// ECCC each had a copy differing only in case — tuning one would skew
    /// cross-border ranking).
    nonisolated static func severityScore(_ severity: String) -> Double {
        switch severity.lowercased() {
        case "extreme": return 0.95
        case "severe": return 0.88
        case "moderate": return 0.72
        case "minor": return 0.45
        default: return 0.30
        }
    }

    nonisolated private func ecccAlerts(at point: CLLocationCoordinate2D) async -> [NWSAlert]? {
        // Rough Canada envelope: skip the fetch for clearly-US/MX points.
        guard point.latitude > 41.5 else { return nil }
        let url = String(
            format: "https://api.weather.gc.ca/collections/alerts/items"
                + "?bbox=%.3f,%.3f,%.3f,%.3f&f=json&limit=20",
            point.longitude - 0.5, point.latitude - 0.5,
            point.longitude + 0.5, point.latitude + 0.5)
        guard let u = URL(string: url),
              let (data, resp) = try? await ThrottledNet.fetch(u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]]
        else { return nil }
        return features.compactMap { feature in
            guard let props = feature["properties"] as? [String: Any] else { return nil }
            let event = (props["event"] as? String)
                ?? (props["alert_type"] as? String)
                ?? (props["headline"] as? String) ?? "Weather alert"
            let headline = (props["headline"] as? String)
                ?? (props["descrip_en"] as? String) ?? event
            let score = Self.severityScore((props["severity"] as? String) ?? "moderate")
            let id = (props["identifier"] as? String) ?? (feature["id"] as? String)
                ?? "\(event)-\(headline.hashValue)"
            let expires = (props["expires"] as? String).flatMap {
                Self.alertDateParser.date(from: $0)
            }
            let source = (props["url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://weather.gc.ca/warnings/index_e.html")
            let detail = (props["descrip_en"] as? String).map { String($0.prefix(280)) }
            return NWSAlert(
                id: id, event: event, headline: headline, severityScore: score,
                polygon: Self.outerRing(of: feature["geometry"] as? [String: Any]),
                expires: expires,
                sourceURL: source,
                detail: detail)
        }
    }

    nonisolated private func nwsAlerts(at point: CLLocationCoordinate2D) async -> NWSResult {
        let lat = String(format: "%.4f", point.latitude)
        let lon = String(format: "%.4f", point.longitude)
        guard let url = URL(string: "https://api.weather.gov/alerts/active?point=\(lat),\(lon)") else {
            return .failed
        }
        guard let (data, response) = try? await ThrottledNet.fetch(url) else { return .failed }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 400/404 = point is outside NWS coverage (off-US) → let the chain try a
        // foreign feed. Any other non-200 = transient failure → .failed.
        if status == 400 || status == 404 { return .offRegion }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]]
        else { return .failed }

        return .alerts(features.compactMap { feature in
            guard let props = feature["properties"] as? [String: Any],
                  let id = props["id"] as? String ?? feature["id"] as? String,
                  let headline = (props["headline"] as? String) ?? (props["event"] as? String)
            else { return nil }
            let score = Self.severityScore((props["severity"] as? String) ?? "Unknown")
            let expires = (props["expires"] as? String).flatMap {
                Self.alertDateParser.date(from: $0)
            }
            let onset = ["onset", "effective", "sent"]
                .compactMap { props[$0] as? String }
                .compactMap { Self.alertDateParser.date(from: $0) }
                .first
            // The api.weather.gov alert record IS the NWS's canonical source
            // for this alert (feature id is its URL).
            let source = (feature["id"] as? String).flatMap(URL.init(string:))
            let detail = (props["description"] as? String).map { String($0.prefix(280)) }
            return NWSAlert(
                id: id,
                event: (props["event"] as? String) ?? headline,
                headline: headline,
                severityScore: score,
                polygon: Self.outerRing(of: feature["geometry"] as? [String: Any]),
                expires: expires,
                onset: onset,
                sourceURL: source,
                detail: detail)
        })
    }

    /// Extract a drawable outer ring from GeoJSON Polygon/MultiPolygon,
    /// decimated to <= 150 points (alert rings can carry thousands; the map
    /// fill doesn't need them).
    nonisolated private static func outerRing(of geometry: [String: Any]?) -> [CLLocationCoordinate2D]? {
        guard let geometry, let type = geometry["type"] as? String else { return nil }
        let ring: [[Double]]?
        switch type {
        case "Polygon":
            ring = (geometry["coordinates"] as? [[[Double]]])?.first
        case "MultiPolygon":
            ring = (geometry["coordinates"] as? [[[[Double]]]])?.first?.first
        default:
            ring = nil
        }
        guard var pts = ring, pts.count >= 3 else { return nil }
        if pts.count > 150 {
            let step = pts.count / 150 + 1
            pts = stride(from: 0, to: pts.count, by: step).map { pts[$0] }
        }
        return pts.compactMap { c in
            c.count >= 2 ? CLLocationCoordinate2D(latitude: c[1], longitude: c[0]) : nil
        }
    }
}

/// Grid-cell → alerts cache with TTL. Alerts churn on a minutes scale; 180 s
/// keeps route re-plans and the 240 s corridor watch fresh while letting
/// alternates (which share most of their corridor) reuse each other's fetches.
actor AlertZoneCache {
    private struct Entry {
        let hits: [WeatherAlertService.NWSAlert]
        let fetched: Date
    }

    private var store: [String: Entry] = [:]
    private let ttl: TimeInterval = 180
    private var inFlight: [String: Task<[WeatherAlertService.NWSAlert]?, Never>] = [:]

    func get(_ key: String) -> [WeatherAlertService.NWSAlert]? {
        guard let e = store[key], Date().timeIntervalSince(e.fetched) < AdaptiveTuning.shared.ttl(ttl) else { return nil }
        return e.hits
    }

    func put(_ key: String, _ hits: [WeatherAlertService.NWSAlert]) {
        store[key] = Entry(hits: hits, fetched: Date())
    }

    /// Coalesced fetch-or-join: alternate routes score concurrently and share
    /// most of their corridor cells — without this, each alternate's miss on
    /// the same cell spawned its own NWS fetch through the actor's reentrancy
    /// window. At most one live fetch per cell; failures stay uncached (the
    /// poisoned-cache contract) so the retry pass gets a real attempt.
    func fetch(_ key: String,
               make: @escaping @Sendable () async -> [WeatherAlertService.NWSAlert]?)
        async -> [WeatherAlertService.NWSAlert]? {
        if let hit = get(key) { return hit }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await make() }
        inFlight[key] = task
        let out = await task.value
        inFlight[key] = nil
        if let out { put(key, out) }
        return out
    }
}

/// Country-level cache of WMO Alert Hub active alerts (Mexico + Central America
/// + Caribbean). The RSS index + per-alert CAP-file fetches happen ONCE per
/// country per TTL (not per corridor point); callers then filter by polygon.
/// 10-min TTL with in-flight coalescing, and the CAP fetches are bounded to the
/// 24 most-recent unexpired items so a corridor scoring can't fan out to
/// hundreds of requests.
actor WMOAlertCache {
    static let shared = WMOAlertCache()
    private struct Entry { let fetched: Date; let alerts: [WeatherAlertService.NWSAlert] }
    private var byCode: [String: Entry] = [:]
    private var inFlight: [String: Task<[WeatherAlertService.NWSAlert], Never>] = [:]

    // ISO8601DateFormatter is thread-safe (post-iOS 10) so the concurrent CAP
    // tasks can share it; the RFC822 parser is used only in the serial filter.
    private static let capDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let rfc822: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"; return f
    }()

    func alerts(code: String) async -> [WeatherAlertService.NWSAlert] {
        if let e = byCode[code], Date().timeIntervalSince(e.fetched) < AdaptiveTuning.shared.ttl(600) { return e.alerts }
        if let t = inFlight[code] { return await t.value }
        let task = Task<[WeatherAlertService.NWSAlert], Never> {
            await Self.fetch(code: code)
        }
        inFlight[code] = task
        let result = await task.value
        byCode[code] = Entry(fetched: Date(), alerts: result)
        inFlight[code] = nil
        return result
    }

    private static func fetch(
        code: String
    ) async -> [WeatherAlertService.NWSAlert] {
        guard let rss = WMOAlertParsing.rssURL(code: code),
              let (data, resp) = try? await ThrottledNet.fetch(rss),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8) else { return [] }
        let now = Date()
        let items = WMOAlertParsing.parseRSSItems(xml).filter { item in
            // CAP `cap:expires` is ISO8601 (2026-07-06T18:00:00-06:00), so try the
            // ISO8601 parser FIRST — the old code used only the RFC822 formatter,
            // which returned nil for every ISO8601 stamp and made this whole
            // filter a no-op that let expired alerts through. Fall back to RFC822
            // for any feed that uses a pubDate-style stamp; keep only when neither
            // parses (fail-open, so a real alert isn't dropped on a format quirk).
            guard let exp = capDate.date(from: item.expires)
                    ?? rfc822.date(from: item.expires) else { return true }
            return exp > now
        }.prefix(24)
        var out: [WeatherAlertService.NWSAlert] = []
        await withTaskGroup(of: WeatherAlertService.NWSAlert?.self) { group in
            for item in items {
                group.addTask {
                    guard let u = URL(string: item.link),
                          let (d, r) = try? await ThrottledNet.fetch(u),
                          (r as? HTTPURLResponse)?.statusCode == 200,
                          let capXML = String(data: d, encoding: .utf8),
                          let cap = WMOAlertParsing.parseCAP(capXML),
                          !cap.polygon.isEmpty else { return nil }
                    return WeatherAlertService.NWSAlert(
                        id: item.link,
                        event: cap.event,
                        headline: cap.event + (cap.areaDesc.map { " — \($0)" } ?? ""),
                        severityScore: WeatherAlertService.severityScore(cap.severity),
                        polygon: cap.polygon,
                        expires: cap.expires.flatMap { capDate.date(from: $0) },
                        onset: cap.effective.flatMap { capDate.date(from: $0) },
                        sourceURL: cap.web.flatMap(URL.init(string:)) ?? URL(string: item.link),
                        detail: cap.description)
                }
            }
            for await hit in group { if let hit { out.append(hit) } }
        }
        return out
    }
}
