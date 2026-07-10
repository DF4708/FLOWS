// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

// na_coverage_check — validates the app's data paths across all US states,
// DC, Puerto Rico, Canada, and Mexico.
//
//   swiftc -O -parse-as-library -o /tmp/na_check \
//       apple/tools/na_coverage_check.swift \
//       -framework MapKit -framework CoreLocation
//   /tmp/na_check
//
// Per location: NWS hourly forecast (temperature/wind/PoP), NWS active-alert
// endpoint, USGS EPQS elevation (sampled subset). Plus cross-border
// MKDirections routing checks. Prints a per-location line and a summary
// matrix. Rate-limited to ~4 concurrent requests; total runtime a few min.

import CoreLocation
import Foundation
import MapKit

struct Spot {
    let name: String
    let country: String
    let lat: Double
    let lon: Double
}

let usSpots: [Spot] = [
    .init(name: "AL Birmingham", country: "US", lat: 33.52, lon: -86.80),
    .init(name: "AK Anchorage", country: "US", lat: 61.22, lon: -149.90),
    .init(name: "AZ Phoenix", country: "US", lat: 33.45, lon: -112.07),
    .init(name: "AR Little Rock", country: "US", lat: 34.75, lon: -92.29),
    .init(name: "CA Los Angeles", country: "US", lat: 34.05, lon: -118.24),
    .init(name: "CO Denver", country: "US", lat: 39.74, lon: -104.99),
    .init(name: "CT Hartford", country: "US", lat: 41.76, lon: -72.67),
    .init(name: "DE Wilmington", country: "US", lat: 39.75, lon: -75.55),
    .init(name: "FL Miami", country: "US", lat: 25.76, lon: -80.19),
    .init(name: "GA Atlanta", country: "US", lat: 33.75, lon: -84.39),
    .init(name: "HI Honolulu", country: "US", lat: 21.31, lon: -157.86),
    .init(name: "ID Boise", country: "US", lat: 43.62, lon: -116.20),
    .init(name: "IL Chicago", country: "US", lat: 41.88, lon: -87.63),
    .init(name: "IN Indianapolis", country: "US", lat: 39.77, lon: -86.16),
    .init(name: "IA Des Moines", country: "US", lat: 41.59, lon: -93.62),
    .init(name: "KS Wichita", country: "US", lat: 37.69, lon: -97.34),
    .init(name: "KY Louisville", country: "US", lat: 38.25, lon: -85.76),
    .init(name: "LA New Orleans", country: "US", lat: 29.95, lon: -90.07),
    .init(name: "ME Portland", country: "US", lat: 43.66, lon: -70.26),
    .init(name: "MD Baltimore", country: "US", lat: 39.29, lon: -76.61),
    .init(name: "MA Boston", country: "US", lat: 42.36, lon: -71.06),
    .init(name: "MI Detroit", country: "US", lat: 42.33, lon: -83.05),
    .init(name: "MN Minneapolis", country: "US", lat: 44.98, lon: -93.27),
    .init(name: "MS Jackson", country: "US", lat: 32.30, lon: -90.18),
    .init(name: "MO Kansas City", country: "US", lat: 39.10, lon: -94.58),
    .init(name: "MT Billings", country: "US", lat: 45.78, lon: -108.50),
    .init(name: "NE Omaha", country: "US", lat: 41.26, lon: -95.93),
    .init(name: "NV Las Vegas", country: "US", lat: 36.17, lon: -115.14),
    .init(name: "NH Manchester", country: "US", lat: 42.99, lon: -71.45),
    .init(name: "NJ Newark", country: "US", lat: 40.74, lon: -74.17),
    .init(name: "NM Albuquerque", country: "US", lat: 35.08, lon: -106.65),
    .init(name: "NY New York", country: "US", lat: 40.71, lon: -74.01),
    .init(name: "NC Charlotte", country: "US", lat: 35.23, lon: -80.84),
    .init(name: "ND Fargo", country: "US", lat: 46.88, lon: -96.79),
    .init(name: "OH Columbus", country: "US", lat: 39.96, lon: -83.00),
    .init(name: "OK Oklahoma City", country: "US", lat: 35.47, lon: -97.52),
    .init(name: "OR Portland", country: "US", lat: 45.52, lon: -122.68),
    .init(name: "PA Philadelphia", country: "US", lat: 39.95, lon: -75.17),
    .init(name: "RI Providence", country: "US", lat: 41.82, lon: -71.41),
    .init(name: "SC Charleston", country: "US", lat: 32.78, lon: -79.93),
    .init(name: "SD Sioux Falls", country: "US", lat: 43.55, lon: -96.73),
    .init(name: "TN Nashville", country: "US", lat: 36.16, lon: -86.78),
    .init(name: "TX Houston", country: "US", lat: 29.76, lon: -95.37),
    .init(name: "UT Salt Lake City", country: "US", lat: 40.76, lon: -111.89),
    .init(name: "VT Burlington", country: "US", lat: 44.48, lon: -73.21),
    .init(name: "VA Richmond", country: "US", lat: 37.54, lon: -77.44),
    .init(name: "WA Seattle", country: "US", lat: 47.61, lon: -122.33),
    .init(name: "WV Charleston", country: "US", lat: 38.35, lon: -81.63),
    .init(name: "WI Milwaukee", country: "US", lat: 43.04, lon: -87.91),
    .init(name: "WY Cheyenne", country: "US", lat: 41.14, lon: -104.82),
    .init(name: "DC Washington", country: "US", lat: 38.91, lon: -77.04),
    .init(name: "PR San Juan", country: "US", lat: 18.47, lon: -66.11),
]

let caSpots: [Spot] = [
    .init(name: "ON Toronto", country: "CA", lat: 43.65, lon: -79.38),
    .init(name: "BC Vancouver", country: "CA", lat: 49.28, lon: -123.12),
    .init(name: "AB Calgary", country: "CA", lat: 51.05, lon: -114.07),
    .init(name: "QC Montreal", country: "CA", lat: 45.50, lon: -73.57),
    .init(name: "MB Winnipeg", country: "CA", lat: 49.90, lon: -97.14),
]

let mxSpots: [Spot] = [
    .init(name: "CDMX Mexico City", country: "MX", lat: 19.43, lon: -99.13),
    .init(name: "NL Monterrey", country: "MX", lat: 25.69, lon: -100.32),
    .init(name: "JAL Guadalajara", country: "MX", lat: 20.67, lon: -103.35),
    .init(name: "BC Tijuana", country: "MX", lat: 32.51, lon: -117.04),
    .init(name: "QR Cancun", country: "MX", lat: 21.16, lon: -86.85),
]

let session: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 10
    cfg.httpAdditionalHeaders = [
        "User-Agent": "FLOWS (davidfoster4708@gmail.com)",
        "Accept": "application/geo+json",
    ]
    return URLSession(configuration: cfg)
}()

func json(_ url: String) async -> [String: Any]? {
    guard let u = URL(string: url),
          let (d, r) = try? await session.data(from: u),
          (r as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
}

struct Result {
    let spot: Spot
    var forecast = false
    var forecastDetail = ""
    var alerts = false
    var elevation: Double?
}

func check(_ spot: Spot, sampleElevation: Bool) async -> Result {
    var out = Result(spot: spot)
    // NWS two-step
    if let p = await json(String(format: "https://api.weather.gov/points/%.4f,%.4f", spot.lat, spot.lon)),
       let props = p["properties"] as? [String: Any],
       let hourly = props["forecastHourly"] as? String,
       let h = await json(hourly),
       let hp = h["properties"] as? [String: Any],
       let periods = hp["periods"] as? [[String: Any]],
       let now = periods.first {
        out.forecast = true
        let t = (now["temperature"] as? Double).map { String(format: "%.0fF", $0) } ?? "?"
        let w = (now["windSpeed"] as? String) ?? "?"
        out.forecastDetail = "\(t) \(w)"
    }
    // NWS alerts endpoint reachability (any 200 counts, even zero alerts)
    if let a = await json(String(format: "https://api.weather.gov/alerts/active?point=%.4f,%.4f", spot.lat, spot.lon)),
       a["features"] != nil {
        out.alerts = true
    }
    if sampleElevation,
       let e = await json(String(format: "https://epqs.nationalmap.gov/v1/json?x=%.4f&y=%.4f&wkid=4326&units=Meters&includeDate=false", spot.lon, spot.lat)) {
        out.elevation = (e["value"] as? Double) ?? (e["value"] as? String).flatMap(Double.init)
    }
    return out
}

func routeCheck(_ name: String, from: (Double, Double), to: (Double, Double)) async -> String {
    let req = MKDirections.Request()
    req.source = MKMapItem(placemark: MKPlacemark(
        coordinate: CLLocationCoordinate2D(latitude: from.0, longitude: from.1)))
    req.destination = MKMapItem(placemark: MKPlacemark(
        coordinate: CLLocationCoordinate2D(latitude: to.0, longitude: to.1)))
    req.transportType = .automobile
    if let resp = try? await MKDirections(request: req).calculate(),
       let r = resp.routes.first {
        return String(format: "ROUTE %@: OK — %.0f mi, %.0f min", name,
                      r.distance / 1609.344, r.expectedTravelTime / 60)
    }
    return "ROUTE \(name): FAILED"
}

@main
struct Check {
    static func main() async {
        let all = usSpots + caSpots + mxSpots
        var results: [Result] = []
        // Concurrency 4, elevation sampled for every 5th US spot + all CA/MX.
        var idx = 0
        while idx < all.count {
            let batch = Array(all[idx..<min(idx + 4, all.count)])
            await withTaskGroup(of: Result.self) { group in
                for (j, spot) in batch.enumerated() {
                    let sampleElev = spot.country != "US" || (idx + j) % 5 == 0
                    group.addTask { await check(spot, sampleElevation: sampleElev) }
                }
                for await r in group { results.append(r) }
            }
            idx += batch.count
        }

        var okForecast: [String: Int] = [:], okAlerts: [String: Int] = [:], total: [String: Int] = [:]
        for r in results.sorted(by: { $0.spot.name < $1.spot.name }) {
            total[r.spot.country, default: 0] += 1
            if r.forecast { okForecast[r.spot.country, default: 0] += 1 }
            if r.alerts { okAlerts[r.spot.country, default: 0] += 1 }
            let elev = r.elevation.map { String(format: "elev %.0fm", $0) } ?? ""
            print("\(r.spot.country) \(r.spot.name): forecast=\(r.forecast ? "OK \(r.forecastDetail)" : "—") alerts=\(r.alerts ? "OK" : "—") \(elev)")
        }
        print("\nSUMMARY")
        for c in ["US", "CA", "MX"] {
            print("\(c): forecast \(okForecast[c] ?? 0)/\(total[c] ?? 0), alerts \(okAlerts[c] ?? 0)/\(total[c] ?? 0)")
        }

        print(await routeCheck("Seattle→Vancouver (US→CA)", from: (47.61, -122.33), to: (49.28, -123.12)))
        print(await routeCheck("Detroit→Toronto (US→CA)", from: (42.33, -83.05), to: (43.65, -79.38)))
        print(await routeCheck("San Diego→Tijuana (US→MX)", from: (32.72, -117.16), to: (32.51, -117.04)))
        print(await routeCheck("Monterrey→Houston (MX→US)", from: (25.69, -100.32), to: (29.76, -95.37)))
    }
}
