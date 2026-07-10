// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

// route_bench — times each phase of FLOWS route planning from the CLI.
//
//   swiftc -O -o /tmp/route_bench apple/tools/route_bench.swift \
//       -framework MapKit -framework CoreLocation
//   /tmp/route_bench 30809 53203
//
// Phases: geocode both endpoints → MKDirections (alternates + traffic) →
// corridor weather scoring, twice:
//   OLD: sequential NWS query per 40 km sample (the shipped algorithm),
//        measured on the first route only to stay polite to api.weather.gov;
//   NEW: 0.5° grid dedupe + shared cache + ≤6 concurrent, all routes.

import CoreLocation
import Foundation
import MapKit

let session: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.httpAdditionalHeaders = [
        "User-Agent": "FLOWS (davidfoster4708@gmail.com)",
        "Accept": "application/geo+json",
    ]
    cfg.timeoutIntervalForRequest = 8
    return URLSession(configuration: cfg)
}()

func now() -> Double { CFAbsoluteTimeGetCurrent() }

func geocode(_ query: String) async throws -> CLLocationCoordinate2D {
    let pms = try await CLGeocoder().geocodeAddressString(query + ", USA")
    guard let c = pms.first?.location?.coordinate else {
        throw NSError(domain: "bench", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "geocode failed: \(query)"])
    }
    return c
}

func samplePoints(_ polyline: MKPolyline, everyMeters: CLLocationDistance) -> [CLLocationCoordinate2D] {
    let n = polyline.pointCount
    guard n > 0 else { return [] }
    var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
    polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
    var out = [coords[0]]
    var since: CLLocationDistance = 0
    for i in 1..<n {
        let a = CLLocation(latitude: coords[i-1].latitude, longitude: coords[i-1].longitude)
        let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
        since += b.distance(from: a)
        if since >= everyMeters { out.append(coords[i]); since = 0 }
    }
    if let last = coords.last { out.append(last) }
    return out
}

struct AlertHit { let id: String; let severity: Double }

func fetchAlerts(_ pt: CLLocationCoordinate2D) async -> [AlertHit] {
    let url = URL(string: String(format: "https://api.weather.gov/alerts/active?point=%.4f,%.4f",
                                 pt.latitude, pt.longitude))!
    guard let (data, resp) = try? await session.data(from: url),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let features = json["features"] as? [[String: Any]] else { return [] }
    return features.compactMap { f in
        guard let props = f["properties"] as? [String: Any],
              let id = (props["id"] as? String) ?? (f["id"] as? String) else { return nil }
        let sev = (props["severity"] as? String) ?? "Unknown"
        let score: Double = switch sev {
        case "Extreme": 0.95
        case "Severe": 0.88
        case "Moderate": 0.72
        case "Minor": 0.45
        default: 0.30
        }
        return AlertHit(id: id, severity: score)
    }
}

// OLD algorithm: strictly sequential, every sample queried.
func scoreSequential(_ samples: [CLLocationCoordinate2D]) async -> (risk: Double, queries: Int) {
    var maxSev = 0.0
    var seen = Set<String>()
    for pt in samples {
        for hit in await fetchAlerts(pt) where !seen.contains(hit.id) {
            seen.insert(hit.id)
            maxSev = max(maxSev, hit.severity)
        }
    }
    return (maxSev, samples.count)
}

// NEW algorithm: grid dedupe + shared cache + capped concurrency.
actor AlertCache {
    var store: [String: [AlertHit]] = [:]
    func get(_ k: String) -> [AlertHit]? { store[k] }
    func put(_ k: String, _ v: [AlertHit]) { store[k] = v }
}

func scoreConcurrent(_ samples: [CLLocationCoordinate2D], cache: AlertCache,
                     maxInFlight: Int = 6) async -> (risk: Double, queries: Int) {
    // One representative sample per 0.25° grid cell (~28 km): with 40 km
    // sampling this almost never merges two same-route samples (no accuracy
    // loss) — the dedupe win comes from alternates sharing corridor cells.
    // (0.5° was measured to drop a Severe alert on the 30809→53203 corridor.)
    var cells: [String: CLLocationCoordinate2D] = [:]
    for pt in samples {
        let key = "\(Int((pt.latitude * 4).rounded()))|\(Int((pt.longitude * 4).rounded()))"
        if cells[key] == nil { cells[key] = pt }
    }
    var fresh: [(String, CLLocationCoordinate2D)] = []
    var hits: [AlertHit] = []
    for (key, pt) in cells {
        if let cached = await cache.get(key) { hits.append(contentsOf: cached) }
        else { fresh.append((key, pt)) }
    }
    var queries = 0
    var idx = 0
    while idx < fresh.count {
        let batch = Array(fresh[idx..<min(idx + maxInFlight, fresh.count)])
        idx += batch.count
        queries += batch.count
        await withTaskGroup(of: (String, [AlertHit]).self) { group in
            for (key, pt) in batch {
                group.addTask { (key, await fetchAlerts(pt)) }
            }
            for await (key, got) in group {
                await cache.put(key, got)
                hits.append(contentsOf: got)
            }
        }
    }
    var seen = Set<String>()
    var maxSev = 0.0
    for h in hits where !seen.contains(h.id) {
        seen.insert(h.id)
        maxSev = max(maxSev, h.severity)
    }
    return (maxSev, queries)
}

@main
struct Bench {
    static func main() async {
        let args = CommandLine.arguments
        let src = args.count > 1 ? args[1] : "30809"
        let dst = args.count > 2 ? args[2] : "53203"
        do {
            var t = now()
            let a = try await geocode(src)
            let tGeo1 = now() - t
            t = now()
            let b = try await geocode(dst)
            let tGeo2 = now() - t
            print(String(format: "geocode %@: %.2fs   geocode %@: %.2fs", src, tGeo1, dst, tGeo2))

            t = now()
            let req = MKDirections.Request()
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
            req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
            req.transportType = .automobile
            req.requestsAlternateRoutes = true
            req.departureDate = Date()
            let resp = try await MKDirections(request: req).calculate()
            let tDir = now() - t
            print(String(format: "MKDirections: %.2fs  (%d routes; best %.0f min, %.0f mi)",
                         tDir, resp.routes.count,
                         resp.routes[0].expectedTravelTime / 60,
                         resp.routes[0].distance / 1609.344))

            let sampleSets = resp.routes.map { samplePoints($0.polyline, everyMeters: 40_000) }

            // OLD: first route only (sequential; extrapolate to all routes).
            // Skippable on re-runs (BENCH_SKIP_OLD=1) to stay polite to NWS.
            var tOld = 0.0
            var old = (risk: -1.0, queries: 0)
            if ProcessInfo.processInfo.environment["BENCH_SKIP_OLD"] == nil {
                t = now()
                old = await scoreSequential(sampleSets[0])
                tOld = now() - t
                print(String(format: "OLD scoring (route 1 of %d): %.2fs  (%d sequential queries, risk %.2f)",
                             resp.routes.count, tOld, old.queries, old.risk))
                print(String(format: "OLD extrapolated all routes: %.2fs", tOld * Double(resp.routes.count)))
            }

            // NEW: all routes, shared cache.
            t = now()
            let cache = AlertCache()
            var newRisks: [Double] = []
            var newQueries = 0
            for samples in sampleSets {
                let r = await scoreConcurrent(samples, cache: cache)
                newRisks.append(r.risk)
                newQueries += r.queries
            }
            let tNew = now() - t
            print(String(format: "NEW scoring (ALL %d routes): %.2fs  (%d network queries total, risks %@)",
                         resp.routes.count, tNew, newQueries,
                         newRisks.map { String(format: "%.2f", $0) }.joined(separator: ",")))
            print(String(format: "route-1 risk agreement: old %.2f vs new %.2f", old.risk, newRisks[0]))
            print(String(format: "\nperceived latency  OLD (routes blocked on scoring): %.2fs",
                         tGeo1 + tGeo2 + tDir + tOld * Double(resp.routes.count)))
            print(String(format: "perceived latency  NEW (routes shown after directions): %.2fs  + badges %.2fs async",
                         tGeo1 + tGeo2 + tDir, tNew))
        } catch {
            print("BENCH FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
}
