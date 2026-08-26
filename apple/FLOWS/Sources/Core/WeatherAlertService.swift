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
    /// `onProgress` (optional) is called after each fetch batch with the
    /// fraction of corridor cells resolved and the provisional per-sample
    /// view (`provisionalSamples`) — on a slow cellular link the card can
    /// color the corridor as cells land instead of spinning until the last
    /// one. Progress is display-only; the returned score (and its `complete`
    /// contract) is unchanged.
    func corridorRisk(
        at samples: [CLLocationCoordinate2D],
        arrivalOffsets: [TimeInterval]? = nil,
        onProgress: (@MainActor (Double, [RiskSample?]) -> Void)? = nil
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
        var fetchFailures = 0
        // STATE-LEVEL PASS first: cells resolve from per-state alert lists
        // plus a client-side spatial join — 1-5 requests where the loop
        // below used to pay one per cell (~129 on a 950-mile plan).
        // Anything the state path can't answer completely (off-table cells,
        // a failed state fetch, an unplaceable zone alert) lands in
        // `pointCells` and rides the original per-point oracle unchanged.
        var pointCells = fresh
        if !fresh.isEmpty {
            let (resolved, remaining) = await resolveViaStates(fresh)
            for (key, hits) in resolved { cellAlerts[key] = hits }
            pointCells = remaining
            if let onProgress, !resolved.isEmpty {
                let attempted = Double(cellAlerts.count + fetchFailures)
                onProgress(
                    min(attempted / Double(max(cells.count, 1)), 1),
                    Self.provisionalSamples(
                        samples: samples, cellAlerts: cellAlerts,
                        arrivalOffsets: arrivalOffsets, now: now))
            }
        }
        let maxInFlight = AdaptiveTuning.shared.maxInFlight
        var idx = 0
        while idx < pointCells.count {
            let batch = Array(pointCells[idx..<min(idx + maxInFlight, pointCells.count)])
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
            if let onProgress {
                // Failed cells count as ATTEMPTED for the progress fraction
                // (the pass over them is done) but stay nil in the samples —
                // a failure is "unknown", never "clear".
                let attempted = Double(cellAlerts.count + fetchFailures)
                onProgress(
                    min(attempted / Double(max(cells.count, 1)), 1),
                    Self.provisionalSamples(
                        samples: samples, cellAlerts: cellAlerts,
                        arrivalOffsets: arrivalOffsets, now: now))
            }
        }
        // Per-sample local risk: the worst alert in the sample's cell that
        // will STILL BE ACTIVE when the driver arrives there. Same mapping as
        // the provisional view; a cell with no data (failed fetch) scores 0
        // here and is reported through `complete: false` instead.
        let riskSamples = zip(
            samples,
            Self.provisionalSamples(samples: samples, cellAlerts: cellAlerts,
                                    arrivalOffsets: arrivalOffsets, now: now)
        ).map { pt, s in s ?? RiskSample(coordinate: pt, risk: 0) }
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

        let polygons: [AlertPolygon] = unique.flatMap { h -> [AlertPolygon] in
            var rings = (h.polygon?.count ?? 0) >= 3 ? [h.polygon!] : []
            rings += h.extraRings.filter { $0.count >= 3 }
            return rings.map { AlertPolygon(coordinates: $0, severity: h.severityScore, event: h.event) }
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
    /// adjacent 40 km corridor samples. Internal (not private) so the tests
    /// can key `provisionalSamples` fixtures the way the scorer does.
    nonisolated static func cellKey(_ pt: CLLocationCoordinate2D) -> String {
        "\(Int((pt.latitude * 4).rounded()))|\(Int((pt.longitude * 4).rounded()))"
    }

    /// Per-sample view of a PARTIALLY fetched corridor: samples whose cell
    /// has landed carry their worst-active-alert risk, cells still in flight
    /// (or failed) stay nil. Pure — the corridor scorer uses it for both the
    /// mid-fetch progress callbacks and (with nils zero-filled) the final
    /// sample list, so the two can never disagree.
    nonisolated static func provisionalSamples(
        samples: [CLLocationCoordinate2D],
        cellAlerts: [String: [NWSAlert]],
        arrivalOffsets: [TimeInterval]?,
        now: Date
    ) -> [RiskSample?] {
        samples.enumerated().map { i, pt in
            guard let hits = cellAlerts[Self.cellKey(pt)] else { return nil }
            let offset: TimeInterval = {
                guard let arrivalOffsets, i < arrivalOffsets.count else { return 0 }
                return arrivalOffsets[i]
            }()
            let active = hits.filter {
                RiskTiming.isActive(expires: $0.expires, arrivalOffset: offset, now: now)
            }
            let worst = active.max { $0.severityScore < $1.severityScore }
            return RiskSample(
                coordinate: pt,
                risk: worst?.severityScore ?? 0,
                worstEvent: worst?.event,
                alertID: worst?.id)
        }
    }

    // MARK: state-level cell resolution (client-side spatial join)

    /// Two-letter codes of every state whose rough bbox contains the point —
    /// the states whose alert lists could cover a cell. Bboxes overlap at
    /// borders, so border cells list several states (good: that is exactly
    /// where a neighboring state's polygon can reach across). Empty for
    /// points off the table (Canada/Mexico/offshore) — those cells ride the
    /// per-point path with its foreign-feed chain.
    nonisolated static func statesContaining(_ pt: CLLocationCoordinate2D) -> [String] {
        LiveHazardFeedFetcher.stateBBoxes.compactMap { code, b in
            (pt.latitude >= b.s && pt.latitude <= b.n
             && pt.longitude >= b.w && pt.longitude <= b.e) ? code : nil
        }
    }

    /// Marine REGION lists a cell near the water must also union — state
    /// lists carry land zones only, but the per-point oracle includes marine
    /// zones, and route samples DO sit over water on long bridges
    /// (Chesapeake, Mackinac, the Keys), where a gale warning is exactly the
    /// high-profile-vehicle hazard FLOWS warns about. Verified live: the
    /// parity harness's only mismatches were offshore cells whose marine
    /// alerts area= queries never carry. Generous rough boxes — an extra
    /// region is one cached request.
    /// Source keys carry a "marine:" prefix so a marine REGION code can
    /// never collide with a state code ("AL" is both Alabama and Alaska
    /// waters); the fetcher maps the prefix to the `region=` query.
    nonisolated static func marineRegionsContaining(_ pt: CLLocationCoordinate2D) -> [String] {
        var out: [String] = []
        if pt.longitude <= -115, (30...50).contains(pt.latitude) { out.append("marine:PA") }
        if pt.longitude >= -83, (24...46).contains(pt.latitude) { out.append("marine:AT") }
        if pt.latitude <= 31.5, (-98...(-80)).contains(pt.longitude) { out.append("marine:GM") }
        if (40.5...49.5).contains(pt.latitude), (-93...(-75.5)).contains(pt.longitude) {
            out.append("marine:GL")
        }
        return out
    }

    /// Bbox pre-reject, then ray-cast — most alerts are nowhere near a cell.
    nonisolated private static func ringContains(
        _ p: CLLocationCoordinate2D, _ ring: [CLLocationCoordinate2D]
    ) -> Bool {
        guard ring.count >= 3 else { return false }
        var minLat = ring[0].latitude, maxLat = minLat
        var minLon = ring[0].longitude, maxLon = minLon
        for c in ring {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        guard p.latitude >= minLat, p.latitude <= maxLat,
              p.longitude >= minLon, p.longitude <= maxLon else { return false }
        return HazardFeedScores.pointInPolygon(p, ring)
    }

    /// The client-side replacement for the server's per-point spatial join:
    /// which of a state's alerts cover this point. Polygon alerts match by
    /// ring containment (the polygon IS the affected area — more precise
    /// than the zones it also lists); zone-referenced alerts (geometry:
    /// null) match if any of their zones' rings contain the point. An alert
    /// whose zones are absent from `zoneRings` cannot match — the RESOLVER
    /// guarantees every needed zone geometry is present before this runs,
    /// falling back to per-point queries otherwise.
    nonisolated static func alertsCovering(
        _ point: CLLocationCoordinate2D,
        alerts: [NWSAlert],
        zoneRings: [String: [[CLLocationCoordinate2D]]]
    ) -> [NWSAlert] {
        alerts.filter { a in
            var rings = (a.polygon?.count ?? 0) >= 3 ? [a.polygon!] : []
            rings += a.extraRings.filter { $0.count >= 3 }
            if !rings.isEmpty {
                return rings.contains { ringContains(point, $0) }
            }
            return a.affectedZones.contains { z in
                (zoneRings[z] ?? []).contains { ringContains(point, $0) }
            }
        }
    }

    /// Join every cell against the union of state alerts — nonisolated so
    /// the ring tests run off the main actor.
    nonisolated private static func joinCells(
        _ cells: [(String, CLLocationCoordinate2D)],
        alerts: [NWSAlert],
        zoneRings: [String: [[CLLocationCoordinate2D]]]
    ) async -> [String: [NWSAlert]] {
        var out: [String: [NWSAlert]] = [:]
        for (key, pt) in cells {
            out[key] = alertsCovering(pt, alerts: alerts, zoneRings: zoneRings)
        }
        return out
    }

    /// Outbreak guard: past this many distinct zone geometries the state
    /// path stops being cheaper than per-point queries — bail out to the
    /// oracle rather than fan out. Zone shapes are static and cache for a
    /// day (plus the disk URLCache across launches), so this burst is paid
    /// once per region, not per plan — the live harness measured an active
    /// state (CA, 32 alerts) needing 114, so the cap sits above that.
    private static let zoneFetchCap = 160

    /// Resolve fresh cells via per-STATE alert lists + the client-side join.
    /// Returns the resolved cell→alerts map (already written to the cell
    /// cache) plus the cells that must ride the per-point path instead:
    /// off-table cells, cells touching a state whose fetch failed, and — if
    /// any needed zone geometry is unavailable — every cell this pass would
    /// have judged, because an unplaceable alert must not silently vanish
    /// from the corridor. Failure can only ever mean "fall back to the
    /// per-point oracle", never "fewer alerts".
    private func resolveViaStates(
        _ fresh: [(String, CLLocationCoordinate2D)]
    ) async -> (resolved: [String: [NWSAlert]], pointFallback: [(String, CLLocationCoordinate2D)]) {
        var fallback: [(String, CLLocationCoordinate2D)] = []
        var candidates: [(String, CLLocationCoordinate2D, [String])] = []
        var stateSet = Set<String>()
        for (key, pt) in fresh {
            let states = Self.statesContaining(pt)
            if states.isEmpty {
                fallback.append((key, pt))
            } else {
                // Cells near water require their marine region lists too —
                // treated exactly like states: a failed source sends the
                // cell to the per-point oracle.
                let sources = states + Self.marineRegionsContaining(pt)
                candidates.append((key, pt, sources))
                stateSet.formUnion(sources)
            }
        }
        guard !candidates.isEmpty else { return ([:], fallback) }

        var stateAlerts: [String: [NWSAlert]] = [:]
        var failedStates = Set<String>()
        await withTaskGroup(of: (String, [NWSAlert]?).self) { group in
            for st in stateSet {
                group.addTask { (st, await StateAlertCache.shared.alerts(area: st)) }
            }
            for await (st, alerts) in group {
                if let alerts { stateAlerts[st] = alerts } else { failedStates.insert(st) }
            }
        }
        var joinable: [(String, CLLocationCoordinate2D)] = []
        for (key, pt, states) in candidates {
            if states.contains(where: failedStates.contains) {
                fallback.append((key, pt))
            } else {
                joinable.append((key, pt))
            }
        }
        guard !joinable.isEmpty else { return ([:], fallback) }

        // Union of the successful states' alerts, deduped by id (a
        // cross-border alert appears in both states' lists).
        var seen = Set<String>()
        var union: [NWSAlert] = []
        for st in stateAlerts.keys.sorted() {
            for a in stateAlerts[st] ?? [] where seen.insert(a.id).inserted {
                union.append(a)
            }
        }
        // Zone geometries for the alerts that ship with no polygon at all.
        let zoneURLs = Set(union
            .filter { ($0.polygon?.count ?? 0) < 3 && !$0.extraRings.contains { $0.count >= 3 } }
            .flatMap(\.affectedZones))
        guard zoneURLs.count <= Self.zoneFetchCap else { return ([:], fallback + joinable) }
        var zoneRings: [String: [[CLLocationCoordinate2D]]] = [:]
        var zoneFailed = false
        await withTaskGroup(of: (String, [[CLLocationCoordinate2D]]?).self) { group in
            for z in zoneURLs {
                group.addTask { (z, await ZoneGeometryCache.shared.rings(zoneURL: z)) }
            }
            for await (z, rings) in group {
                if let rings { zoneRings[z] = rings } else { zoneFailed = true }
            }
        }
        if zoneFailed { return ([:], fallback + joinable) }

        let resolved = await Self.joinCells(joinable, alerts: union, zoneRings: zoneRings)
        for (key, hits) in resolved { await cache.put(key, hits) }
        return (resolved, fallback)
    }

    // MARK: geocode-time prefetch

    private var prefetchTask: Task<Void, Never>?

    /// Warm the alert-cell cache the moment BOTH endpoints are known — before
    /// MKDirections has returned a single polyline — along the straight line
    /// between them. By the time the real corridors arrive, their cells that
    /// the line crossed are already cached (180 s TTL comfortably covers the
    /// route-planning gap), and in-flight prefetches are joined, not repeated
    /// (AlertZoneCache coalescing). Distance-gated inside `prefetchCells` —
    /// see there for why long trips must NOT prefetch.
    func prefetchCorridor(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) {
        let points = Self.prefetchCells(from: from, to: to)
        guard !points.isEmpty else { return }
        prefetchTask?.cancel()
        prefetchTask = Task {
            await RequestGate.shared.withPlanningBurst {
                // Same resolution path scoring uses: state-level lists cover
                // most cells in 1-2 requests; the rest ride per-point.
                var fresh: [(String, CLLocationCoordinate2D)] = []
                for pt in points {
                    let key = Self.cellKey(pt)
                    if await self.cache.get(key) == nil { fresh.append((key, pt)) }
                }
                guard !fresh.isEmpty, !Task.isCancelled else { return }
                let (_, fallback) = await self.resolveViaStates(fresh)
                await withTaskGroup(of: Void.self) { group in
                    for (key, pt) in fallback {
                        group.addTask {
                            // A superseded prefetch (new destination typed)
                            // stops starting cells; ones already fetching run
                            // out in the cache actor's coalesced tasks and
                            // stay useful.
                            guard !Task.isCancelled else { return }
                            _ = await self.cache.fetch(key) {
                                await self.activeAlerts(at: pt)
                            }
                        }
                    }
                }
            }
        }
    }

    /// One representative point per 0.25° cell along the straight line
    /// between two endpoints — the only corridor guess available before
    /// route geometry exists. Distance-gated: measured against real
    /// MKDirections corridors, roads track the straight line well on short
    /// and medium trips (~50% of route cells prewarmed at ≤150 mi) but
    /// barely at all cross-country (4–6% at 950 mi), where prefetching the
    /// line would spend NWS requests on cells no route crosses — so beyond
    /// `maxCells` of line this returns [] and the plan proceeds unprimed.
    nonisolated static func prefetchCells(
        from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
        maxCells: Int = 16
    ) -> [CLLocationCoordinate2D] {
        let a = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let b = CLLocation(latitude: to.latitude, longitude: to.longitude)
        // ~20 km steps: finer than the cell size so a diagonal line doesn't
        // step over cells it crosses.
        let steps = max(Int(b.distance(from: a) / 20_000), 1)
        var seen = Set<String>()
        var out: [CLLocationCoordinate2D] = []
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let pt = CLLocationCoordinate2D(
                latitude: from.latitude + (to.latitude - from.latitude) * f,
                longitude: from.longitude + (to.longitude - from.longitude) * f)
            if seen.insert(cellKey(pt)).inserted { out.append(pt) }
        }
        return out.count <= maxCells ? out : []
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
        let polyline = route.route.polyline
        let spacing = 40_000.0
        // A hydrated route's riskSamples sit on the same 40 km boundaries —
        // reuse them rather than re-walking the whole polyline.
        let allSamples = route.riskSamples.isEmpty
            ? RouteService.samplePoints(of: polyline, everyMeters: spacing)
            : route.riskSamples.map(\.coordinate)
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
                // Offsets are time-to-reach from the VEHICLE, not the window
                // start: windowed[i] is at (lo+i)*spacing along the route while
                // the vehicle is at w.along. Measuring from windowed[0]
                // overstated every offset by up to a full lookahead (~25 min),
                // discounting alerts that expire in that window as if the
                // driver arrived far later than they will.
                let base = lo <= hi ? Double(lo) * spacing : 0
                let offsets = (0..<windowed.count).map {
                    max(0, (base + Double($0) * spacing - w.along) * secondsPerMeter)
                }
                let score = await self.corridorRisk(at: windowed, arrivalOffsets: offsets)
                // A leg swap cancels this task, but the awaited cell fetches
                // run in the cache actor's own coalescing tasks and complete
                // anyway — without this guard the OLD corridor's score lands
                // on the NEW leg (stale headlines, wrong escalation baseline).
                guard !Task.isCancelled else { return }
                // Incomplete score (a cell fetch failed): keep the previous
                // headlines — "couldn't check" must never blank a live HUD
                // alert banner as if the corridor cleared.
                if score.complete { self.activeHeadlines = score.headlines }
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
        /// Remaining rings of a MultiPolygon alert (disjoint warned areas —
        /// split tornado polygons, island coastal warnings). Display-only:
        /// scoring is point-queried, but the map must tint EVERY warned area.
        var extraRings: [[CLLocationCoordinate2D]] = []
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
        /// NWS zone URLs this alert covers (properties.affectedZones) —
        /// the containable area for alerts the feed ships with
        /// `geometry: null`. Empty for non-NWS providers.
        var affectedZones: [String] = []
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
        // nil = the RSS index fetch itself failed (unknown), NOT an all-clear —
        // propagate it so the corridor's `complete` flag stays false and GO
        // can't unlock on a false "no alerts" during a WMO-region blip.
        guard let all = await WMOAlertCache.shared.alerts(code: code) else { return nil }
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
            let rings = Self.allRings(of: feature["geometry"] as? [String: Any])
            return NWSAlert(
                id: id, event: event, headline: headline, severityScore: score,
                polygon: rings.first,
                extraRings: Array(rings.dropFirst()),
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
        return .alerts(Self.parseAlertFeatures(features))
    }

    /// One parser for every api.weather.gov alert list — the per-point
    /// query and the per-state query return the same feature shape.
    nonisolated static func parseAlertFeatures(_ features: [[String: Any]]) -> [NWSAlert] {
        features.compactMap { feature in
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
            let rings = Self.allRings(of: feature["geometry"] as? [String: Any])
            return NWSAlert(
                id: id,
                event: (props["event"] as? String) ?? headline,
                headline: headline,
                severityScore: score,
                polygon: rings.first,
                extraRings: Array(rings.dropFirst()),
                expires: expires,
                onset: onset,
                sourceURL: source,
                detail: detail,
                affectedZones: (props["affectedZones"] as? [String]) ?? [])
        }
    }

    /// Extract every drawable outer ring from GeoJSON Polygon/MultiPolygon
    /// (one per part — a MultiPolygon's later parts are warned areas too),
    /// each decimated to <= `maxPoints` (alert rings can carry thousands;
    /// the map fill doesn't need them at 150). Zone-geometry CONTAINMENT
    /// callers pass a higher cap — a county ring decimated for display gets
    /// fuzzy near its boundary, which is exactly where a corridor cell test
    /// must not be.
    nonisolated static func allRings(
        of geometry: [String: Any]?, maxPoints: Int = 150
    ) -> [[CLLocationCoordinate2D]] {
        guard let geometry, let type = geometry["type"] as? String else { return [] }
        let raws: [[[Double]]]
        switch type {
        case "Polygon":
            raws = (geometry["coordinates"] as? [[[Double]]])?.first.map { [$0] } ?? []
        case "MultiPolygon":
            raws = (geometry["coordinates"] as? [[[[Double]]]])?.compactMap(\.first) ?? []
        default:
            raws = []
        }
        return raws.compactMap { raw in
            var pts = raw
            guard pts.count >= 3 else { return nil }
            if pts.count > maxPoints {
                let step = pts.count / maxPoints + 1
                pts = stride(from: 0, to: pts.count, by: step).map { pts[$0] }
            }
            let ring = pts.compactMap { c in
                c.count >= 2 ? CLLocationCoordinate2D(latitude: c[1], longitude: c[0]) : nil
            }
            return ring.count >= 3 ? ring : nil
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
        // Cells only ever accumulated: a cross-country drive with the 4-min
        // corridor watch plus viewport sweeps touches thousands of cells, and
        // during active weather each carries full alert geometry (rings up to
        // 150 points) — tens of MB by the end of a long day on a 2 GB device.
        // 300 live cells comfortably covers a whole plan's corridor plus the
        // viewport; beyond that the stalest half goes.
        if store.count > 300 { CacheEviction.dropOldestHalf(&store) { $0.fetched } }
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

/// Per-STATE active-alert lists (/alerts/active?area=XX): one fetch covers
/// every corridor cell in that state, where the per-point design paid one
/// query per 0.25° cell (~129 on a 950-mile plan). Same freshness as the
/// cell cache (180 s × device multiplier), coalesced, failures NOT cached —
/// a failed state falls the affected cells back to per-point queries, so a
/// blip can never read as "no alerts statewide".
actor StateAlertCache {
    static let shared = StateAlertCache()
    private var store: [String: (fetched: Date, alerts: [WeatherAlertService.NWSAlert])] = [:]
    private var inFlight: [String: Task<[WeatherAlertService.NWSAlert]?, Never>] = [:]

    func alerts(area: String) async -> [WeatherAlertService.NWSAlert]? {
        if let hit = store[area],
           Date().timeIntervalSince(hit.fetched) < AdaptiveTuning.shared.ttl(180) {
            return hit.alerts
        }
        if let running = inFlight[area] { return await running.value }
        let task = Task<[WeatherAlertService.NWSAlert]?, Never> { await Self.fetch(area: area) }
        inFlight[area] = task
        let out = await task.value
        inFlight[area] = nil
        if let out {
            store[area] = (Date(), out)
            if store.count > 60 { CacheEviction.dropOldestHalf(&store) { $0.fetched } }
        }
        return out
    }

    private static func fetch(area: String) async -> [WeatherAlertService.NWSAlert]? {
        // "marine:XX" sources query via `region=`; states via `area=`.
        let isMarine = area.hasPrefix("marine:")
        let param = isMarine ? "region" : "area"
        let code = isMarine ? String(area.dropFirst("marine:".count)) : area
        guard let url = URL(string: "https://api.weather.gov/alerts/active?\(param)=\(code)"),
              let (data, resp) = try? await ThrottledNet.fetch(url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]]
        else { return nil }
        return WeatherAlertService.parseAlertFeatures(features)
    }
}

/// NWS zone geometries (forecast/county/fire zone outlines) for the alerts
/// the feed ships with `geometry: null`. Zone shapes are effectively static,
/// so they cache for a day (and persist in the protocol URLCache across
/// launches); rings keep up to 1,500 points for faithful containment.
/// Failures are not cached.
actor ZoneGeometryCache {
    static let shared = ZoneGeometryCache()
    private var store: [String: (fetched: Date, rings: [[CLLocationCoordinate2D]])] = [:]
    private var inFlight: [String: Task<[[CLLocationCoordinate2D]]?, Never>] = [:]

    func rings(zoneURL: String) async -> [[CLLocationCoordinate2D]]? {
        if let hit = store[zoneURL], Date().timeIntervalSince(hit.fetched) < 86_400 {
            return hit.rings
        }
        if let running = inFlight[zoneURL] { return await running.value }
        let task = Task<[[CLLocationCoordinate2D]]?, Never> { await Self.fetch(zoneURL: zoneURL) }
        inFlight[zoneURL] = task
        let out = await task.value
        inFlight[zoneURL] = nil
        if let out {
            store[zoneURL] = (Date(), out)
            if store.count > 240 { CacheEviction.dropOldestHalf(&store) { $0.fetched } }
        }
        return out
    }

    private static func fetch(zoneURL: String) async -> [[CLLocationCoordinate2D]]? {
        guard let url = URL(string: zoneURL),
              url.host == "api.weather.gov",   // zone refs come from alert payloads
              let (data, resp) = try? await ThrottledNet.fetch(url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let rings = WeatherAlertService.allRings(
            of: json["geometry"] as? [String: Any], maxPoints: 1_500)
        return rings.isEmpty ? nil : rings
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
    private var inFlight: [String: Task<[WeatherAlertService.NWSAlert]?, Never>] = [:]

    // ISO8601DateFormatter is thread-safe (post-iOS 10) so the concurrent CAP
    // tasks can share it; the RFC822 parser is used only in the serial filter.
    private static let capDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let rfc822: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"; return f
    }()

    /// nil = the RSS index fetch/parse failed (unknown); [] = a genuine
    /// all-clear. Failures are NOT cached — the next call retries — so a
    /// blip can't pin "no alerts" for the TTL and defeat the GO gate.
    func alerts(code: String) async -> [WeatherAlertService.NWSAlert]? {
        if let e = byCode[code], Date().timeIntervalSince(e.fetched) < AdaptiveTuning.shared.ttl(600) { return e.alerts }
        if let t = inFlight[code] { return await t.value }
        let task = Task<[WeatherAlertService.NWSAlert]?, Never> {
            await Self.fetch(code: code)
        }
        inFlight[code] = task
        let result = await task.value
        if let result { byCode[code] = Entry(fetched: Date(), alerts: result) }
        inFlight[code] = nil
        return result
    }

    private static func fetch(
        code: String
    ) async -> [WeatherAlertService.NWSAlert]? {
        guard let rss = WMOAlertParsing.rssURL(code: code),
              let (data, resp) = try? await ThrottledNet.fetch(rss),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8) else { return nil }
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
        await withTaskGroup(of: [WeatherAlertService.NWSAlert].self) { group in
            for item in items {
                group.addTask {
                    guard let u = URL(string: item.link),
                          let (d, r) = try? await ThrottledNet.fetch(u),
                          (r as? HTTPURLResponse)?.statusCode == 200,
                          let capXML = String(data: d, encoding: .utf8),
                          let cap = WMOAlertParsing.parseCAP(capXML),
                          !cap.polygons.isEmpty else { return [] }
                    // One NWSAlert per ring, SAME id: a multi-area alert warns
                    // every ring it covers, while corridor coverage still
                    // groups the rings as one alert (dedupe is by id).
                    return cap.polygons.map { ring in
                        WeatherAlertService.NWSAlert(
                            id: item.link,
                            event: cap.event,
                            headline: cap.event + (cap.areaDesc.map { " — \($0)" } ?? ""),
                            severityScore: WeatherAlertService.severityScore(cap.severity),
                            polygon: ring,
                            expires: cap.expires.flatMap { capDate.date(from: $0) },
                            onset: cap.effective.flatMap { capDate.date(from: $0) },
                            sourceURL: cap.web.flatMap(URL.init(string:)) ?? URL(string: item.link),
                            detail: cap.description)
                    }
                }
            }
            for await hits in group { out.append(contentsOf: hits) }
        }
        return out
    }
}
