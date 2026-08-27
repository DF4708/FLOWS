// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// NWS gridpoint forecast conditions at a coordinate — the inputs the R
/// engine's forecast equations take. Fetched live from api.weather.gov
/// (two-step: /points → forecast/hourly), cached per ~11 km cell for 30 min.
/// This is what makes the FLOWS risk field CONUS-wide on-device instead of
/// Wisconsin-export-only: same equations (RiskEquations), NWS inputs
/// anywhere the NWS covers. (Canada/Mexico corridors would need Environment
/// Canada / SMN feeds — noted in docs.)
struct ForecastConditions: Sendable {
    var temperatureF: Double?
    var windMph: Double?
    /// The direction the wind blows FROM, in degrees — what turns a wind
    /// speed into a head- or tailwind once the vehicle's heading is known.
    var windFromDegrees: Double?
    var popPercent: Double?
    /// Quantitative precipitation forecast for the coming hours, INCHES —
    /// how much water falls, not just how likely (drives the relative-
    /// elevation flood amplifier). nil where the provider doesn't report it.
    var qpfInches: Double?

    /// The R forecast composite (exact equations) against the location's
    /// LATITUDE-BAND profile — the same normalization the R server applies
    /// per WI band, extended continent-wide (LatitudeBands): what counts as
    /// anomalous heat in a Manitoba band is unremarkable in a Sonora band.
    /// Elevation can shift the effective band by at most ±1 (contiguous rule).
    func forecastScore(latitude: Double, longitude: Double, elevationMeters: Double?) -> Double {
        let band = ClimateProfiles.profile(
            latitude: latitude, longitude: longitude, elevationMeters: elevationMeters)
        let t = temperatureF.map {
            RiskEquations.temperatureRisk(
                tempF: $0, comfortLowF: band.comfortLowF, comfortHighF: band.comfortHighF,
                recordLowF: band.recordLowF, recordHighF: band.recordHighF)
        } ?? 0
        let w = windMph.map {
            RiskEquations.piecewiseScore($0, low: band.windLow, medium: band.windMedium, high: band.windHigh)
        } ?? 0
        let p = popPercent.map {
            RiskEquations.piecewiseScore($0, low: band.popLow, medium: band.popMedium, high: band.popHigh)
        } ?? 0
        return RiskEquations.forecastComposite(temp: t, wind: w, pop: p)
    }

    /// Forecast → PREDICTOR family scores (the secondary side of the realized
    /// risk model): wind, heat, cold, precipitation probability, and the
    /// forecast winter/convective potential — all against the location's
    /// latitude-band profile. Shared by the map viewport and the route scorer
    /// so both decompose a forecast into the same predictor families before
    /// `RiskEquations.realizedRisk` combines them. Contains NO realized
    /// primaries — those come from live gauges/perimeters/outlooks/alerts.
    func predictorFamilies(latitude: Double, longitude: Double, elevationMeters: Double?) -> [String: Double] {
        let band = ClimateProfiles.profile(
            latitude: latitude, longitude: longitude, elevationMeters: elevationMeters)
        let t = temperatureF.map {
            RiskEquations.temperatureRisk(
                tempF: $0, comfortLowF: band.comfortLowF, comfortHighF: band.comfortHighF,
                recordLowF: band.recordLowF, recordHighF: band.recordHighF)
        } ?? 0
        let w = windMph.map(RiskEquations.windRisk(mph:)) ?? 0
        let p = popPercent.map(RiskEquations.popRisk(pct:)) ?? 0
        let temp = temperatureF ?? 70
        var out: [String: Double] = ["wind": w, "precip": p]
        out["heat"] = temp > band.comfortHighF ? t : 0
        out["cold"] = temp < band.comfortLowF ? t : 0
        out["winter"] = temp <= 34 ? min(1, 0.2 * w + 0.8 * p) : 0
        out["convective"] = temp > 60 ? min(1, 0.6 * p + 0.4 * w) : p * 0.3
        return out
    }

}

actor NWSForecastFetcher {
    static let shared = NWSForecastFetcher()

    private struct Entry {
        let conditions: ForecastConditions
        let fetched: Date
    }

    private var cache: [String: Entry] = [:]
    private let ttl: TimeInterval = 1800   // forecasts change hourly-ish
    /// Coalesce concurrent misses: a viewport sweep fans out up to 36 grid
    /// points and at metro zoom many round into the same 0.1° cell — without
    /// this, every one of them runs its own full provider chain (2 NWS
    /// requests each) through the actor's reentrancy window.
    private var inFlight: [String: Task<ForecastConditions?, Never>] = [:]

    private func key(_ c: CLLocationCoordinate2D) -> String {
        "\(Int((c.latitude * 10).rounded()))|\(Int((c.longitude * 10).rounded()))"
    }

    /// Current forecast conditions via the NORTH AMERICAN provider chain:
    ///   1. NWS (US + territories — hourly gridpoints)
    ///   2. Apple WeatherKit (all of NA — activates when the app is built
    ///      with a paid developer team + the WeatherKit entitlement; the
    ///      hook returns nil under ad-hoc/local signing)
    ///   3. Open-Meteo hourly forecast (GLOBAL, keyless, already the app's
    ///      air-quality and elevation provider) — the working REDUNDANCY
    ///      for an NWS forecast outage, and full-fidelity coverage
    ///      (temp/wind/PoP/QPF) for Canada and Mexico ahead of the
    ///      observation-only regional feeds
    ///   4. ECCC GeoMet SWOB real-time observations (Canada)
    ///   5. SMN/CONAGUA municipal forecasts (Mexico)
    /// Each provider fails harmlessly to the next; nil only when nobody
    /// covers the point. A non-primary provider serving is journaled
    /// (throttled) so degraded runs are visible in the field.
    func conditions(at c: CLLocationCoordinate2D) async -> ForecastConditions? {
        let k = key(c)
        if let e = cache[k], Date().timeIntervalSince(e.fetched) < AdaptiveTuning.shared.ttl(ttl) {
            return e.conditions
        }
        if let running = inFlight[k] { return await running.value }
        let task = Task<ForecastConditions?, Never> {
            if let nws = await self.nwsConditions(at: c) { return nws }
            if let apple = await self.appleWeatherKitConditions(at: c) { return apple }
            if let om = await self.openMeteoConditions(at: c) {
                FlowsDiag.logThrottled(
                    key: "forecast.open-meteo", .info, "forecast",
                    "Open-Meteo serving conditions (NWS unavailable or off-region)")
                return om
            }
            if let eccc = await self.ecccConditions(at: c) { return eccc }
            if let smn = await self.smnConditions(at: c) { return smn }
            return nil
        }
        inFlight[k] = task
        let out = await task.value
        inFlight[k] = nil
        // Failures are NOT cached — nil stays uncached so the next sweep
        // retries instead of pinning "no forecast" for the TTL.
        if let out {
            cache[k] = Entry(conditions: out, fetched: Date())
            // Session-monotonic otherwise: every viewport sweep adds up to 36
            // cells and stale entries were skipped but never removed.
            if cache.count > 400 { CacheEviction.dropOldestHalf(&cache) { $0.fetched } }
        }
        return out
    }

    // MARK: provider 1 — NWS (US)

    /// 0.1°-cell → hourly-forecast URL. The /points grid metadata is
    /// effectively static — a coordinate's NWS grid square never moves, and
    /// the server itself marks the response fresh for hours — yet every
    /// conditions() refresh paid a full round trip for it before fetching
    /// the forecast, DOUBLING the NWS request count of the forecast path.
    /// One resolution per cell per day now; failures are not cached.
    private var gridURLCache: [String: (fetched: Date, url: URL)] = [:]

    private func hourlyForecastURL(at c: CLLocationCoordinate2D) async -> URL? {
        let k = key(c)
        if let hit = gridURLCache[k], Date().timeIntervalSince(hit.fetched) < 86_400 {
            return hit.url
        }
        guard let pointURL = URL(string: String(
            format: "https://api.weather.gov/points/%.4f,%.4f", c.latitude, c.longitude)),
            let (pd, pr) = try? await ThrottledNet.fetch(pointURL),
            (pr as? HTTPURLResponse)?.statusCode == 200,
            let pjson = try? JSONSerialization.jsonObject(with: pd) as? [String: Any],
            let props = pjson["properties"] as? [String: Any],
            let hourlyURLString = props["forecastHourly"] as? String,
            let hourlyURL = URL(string: hourlyURLString)
        else { return nil }
        gridURLCache[k] = (Date(), hourlyURL)
        if gridURLCache.count > 400 { CacheEviction.dropOldestHalf(&gridURLCache) { $0.fetched } }
        return hourlyURL
    }

    private func nwsConditions(at c: CLLocationCoordinate2D) async -> ForecastConditions? {
        guard let hourlyURL = await hourlyForecastURL(at: c),
            let (hd, hr) = try? await ThrottledNet.fetch(hourlyURL),
            (hr as? HTTPURLResponse)?.statusCode == 200,
            let hjson = try? JSONSerialization.jsonObject(with: hd) as? [String: Any],
            let hprops = hjson["properties"] as? [String: Any],
            let periods = hprops["periods"] as? [[String: Any]],
            let now = periods.first
        else { return nil }

        var out = ForecastConditions()
        if let t = now["temperature"] as? Double {
            let unit = (now["temperatureUnit"] as? String) ?? "F"
            out.temperatureF = unit == "C" ? t * 9 / 5 + 32 : t
        }
        if let ws = now["windSpeed"] as? String {
            // "15 mph" / "10 to 20 mph" — take the max stated.
            let nums = ws.split(whereSeparator: { !"0123456789".contains($0) })
                .compactMap { Double($0) }
            out.windMph = nums.max()
            // NWS gives the direction as a compass word in the same forecast
            // ("NW", "SSE") — turn it into the degrees the drag math wants.
            out.windFromDegrees = Self.degrees(fromCompass: now["windDirection"] as? String)
        }
        if let popDict = now["probabilityOfPrecipitation"] as? [String: Any] {
            out.popPercent = popDict["value"] as? Double
        }
        // QPF: sum the next ~6 hourly amounts — "how much water is coming",
        // the flood amplifier's input. NWS reports wmoUnit:mm; convert to in.
        var qpfMM = 0.0
        var sawQPF = false
        for period in periods.prefix(6) {
            guard let qp = period["quantitativePrecipitation"] as? [String: Any],
                  let v = qp["value"] as? Double else { continue }
            sawQPF = true
            let unit = (qp["unitCode"] as? String) ?? "wmoUnit:mm"
            qpfMM += unit.hasSuffix(":in") ? v * 25.4 : v
        }
        if sawQPF { out.qpfInches = qpfMM / 25.4 }
        return out
    }

    // MARK: provider 2 — Apple WeatherKit (entitlement-gated hook)

    /// WeatherKit covers all of North America with Apple's own weather data,
    /// but requires a paid Apple Developer team + the
    /// com.apple.developer.weatherkit entitlement, which ad-hoc/local
    /// signing cannot carry. When the app is provisioned for it, implement
    /// with `WeatherService.weather(for:)` here — the chain lights up with
    /// no other changes.
    private func appleWeatherKitConditions(at c: CLLocationCoordinate2D) async -> ForecastConditions? {
        nil
    }

    // MARK: provider 3 — Open-Meteo hourly forecast (global redundancy)

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func openMeteoConditions(at c: CLLocationCoordinate2D) async -> ForecastConditions? {
        let url = String(
            format: "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
                + "&hourly=temperature_2m,wind_speed_10m,precipitation_probability,precipitation"
                + "&forecast_days=1&temperature_unit=fahrenheit&wind_speed_unit=mph"
                + "&precipitation_unit=inch&timezone=GMT",
            c.latitude, c.longitude)
        guard let u = URL(string: url),
              let (data, resp) = try? await ThrottledNet.fetch(u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Self.parseOpenMeteoConditions(
            json, hourUTC: Self.utcCalendar.component(.hour, from: Date()))
    }

    /// Pure Open-Meteo hourly → ForecastConditions mapping (units already
    /// requested app-native: °F, mph, %, inches; series starts at 00:00 UTC
    /// so the current-hour index is the UTC hour). QPF sums the coming 6
    /// hourly amounts — the same window the NWS path uses.
    nonisolated static func parseOpenMeteoConditions(
        _ json: [String: Any], hourUTC: Int
    ) -> ForecastConditions? {
        guard let hourly = json["hourly"] as? [String: Any] else { return nil }
        func series(_ name: String) -> [Double]? {
            // Arrays can carry NSNull for missing hours — map those to nan
            // so indexing stays aligned, then filter at use.
            (hourly[name] as? [Any])?.map { ($0 as? Double) ?? .nan }
        }
        guard let temps = series("temperature_2m"), !temps.isEmpty else { return nil }
        let idx = min(max(hourUTC, 0), temps.count - 1)
        var out = ForecastConditions()
        if temps[idx].isFinite { out.temperatureF = temps[idx] }
        if let winds = series("wind_speed_10m"), idx < winds.count, winds[idx].isFinite {
            out.windMph = winds[idx]
        }
        if let pops = series("precipitation_probability"), idx < pops.count, pops[idx].isFinite {
            out.popPercent = pops[idx]
        }
        if let qpf = series("precipitation"), idx < qpf.count {
            let coming = qpf[idx..<min(idx + 6, qpf.count)].filter(\.isFinite)
            if !coming.isEmpty { out.qpfInches = coming.reduce(0, +) }
        }
        return out.temperatureF == nil && out.windMph == nil ? nil : out
    }

    // MARK: provider 4 — ECCC GeoMet SWOB (Canada)

    private func ecccConditions(at c: CLLocationCoordinate2D) async -> ForecastConditions? {
        let url = String(
            format: "https://api.weather.gc.ca/collections/swob-realtime/items"
                + "?bbox=%.3f,%.3f,%.3f,%.3f&limit=20&f=json",
            c.longitude - 0.4, c.latitude - 0.4, c.longitude + 0.4, c.latitude + 0.4)
        guard let u = URL(string: url),
              let (d, r) = try? await ThrottledNet.fetch(u),
              (r as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let features = json["features"] as? [[String: Any]], !features.isEmpty
        else { return nil }
        for feature in features {
            guard let props = feature["properties"] as? [String: Any],
                  let tempF = IntlWeatherParsing.ecccAirTempF(props) else { continue }
            var out = ForecastConditions()
            out.temperatureF = tempF
            out.windMph = IntlWeatherParsing.ecccWindMph(props)
            out.popPercent = nil   // SWOB is observations; PoP needs forecast layers
            return out
        }
        return nil
    }

    // MARK: provider 4 — SMN/CONAGUA municipios (Mexico)

    private var smnRows: [IntlWeatherParsing.SMNRow] = []
    private var smnFetched = Date.distantPast
    private var smnRefresh: Task<[IntlWeatherParsing.SMNRow], Never>?

    // Grid index over the ~2,000 municipios so the nearest-neighbor lookup is
    // O(1) per corridor sample instead of a full linear scan. Cell = 0.7° ≥ the
    // 0.55°/cos search radius, so any municipio within the cutoff sits in the
    // query cell's 3×3 neighborhood (the CONUS path already has such an index;
    // the Mexico path did not).
    private struct SMNCell: Hashable { let x: Int; let y: Int }
    private static let smnCellDeg = 0.7
    private var smnGrid: [SMNCell: [Int]] = [:]
    private static func smnCell(_ lat: Double, _ lon: Double) -> SMNCell {
        SMNCell(x: Int((lon / smnCellDeg).rounded(.down)),
                y: Int((lat / smnCellDeg).rounded(.down)))
    }

    /// Fetch/refresh the national SMN table exactly once, no matter how many
    /// corridor samples ask concurrently. Review finding: actor reentrancy at
    /// the `await session.data` suspension let every Mexico sample in a task
    /// group see the stale timestamp and download the 340 KB file in parallel
    /// (a 15-way stampede per scoring pass) — and a failed fetch retried
    /// immediately on every call. The shared in-flight Task collapses the
    /// stampede; a failure stamps a 10-minute backoff instead of 3 hours of
    /// hammering.
    private func smnEnsureRows() async {
        guard Date().timeIntervalSince(smnFetched) > 3 * 3600 else { return }
        if smnRefresh == nil {
            smnRefresh = Task {
                guard let u = URL(string: "https://smn.conagua.gob.mx/tools/GUI/webservices/?method=1"),
                      let (d, r) = try? await ThrottledNet.fetch(u),
                      (r as? HTTPURLResponse)?.statusCode == 200,
                      let plain = IntlWeatherParsing.gunzip(d) ?? Optional(d),
                      let array = try? JSONSerialization.jsonObject(with: plain) as? [[String: Any]]
                else { return [] }
                return array.compactMap(IntlWeatherParsing.smnRow)
            }
        }
        let task = smnRefresh!
        let rows = await task.value
        // First resumer applies the result; the timestamp guard keeps later
        // resumers (and callers racing the cleanup) from re-applying.
        if Date().timeIntervalSince(smnFetched) > 3 * 3600 {
            if rows.isEmpty {
                smnFetched = Date().addingTimeInterval(-(3 * 3600) + 600)
            } else {
                smnRows = rows
                var g: [SMNCell: [Int]] = [:]
                for (i, row) in rows.enumerated() {
                    g[Self.smnCell(row.lat, row.lon), default: []].append(i)
                }
                smnGrid = g
                smnFetched = Date()
            }
            smnRefresh = nil
        }
    }

    private func smnConditions(at c: CLLocationCoordinate2D) async -> ForecastConditions? {
        // Rough Mexico envelope so US/CA misses don't trigger a 340 KB fetch.
        guard c.latitude > 13, c.latitude < 33.5, c.longitude > -119, c.longitude < -85
        else { return nil }
        await smnEnsureRows()
        // Nearest municipio within ~60 km — grid-indexed (query cell's 3×3). Any
        // municipio within the 0.55° cutoff is at most one 0.7° cell away, so this
        // finds the same nearest as a full scan.
        let c0 = Self.smnCell(c.latitude, c.longitude)
        let cosLat = cos(c.latitude * .pi / 180)
        var best: (IntlWeatherParsing.SMNRow, Double)?
        for dy in -1...1 {
            for dx in -1...1 {
                guard let idxs = smnGrid[SMNCell(x: c0.x + dx, y: c0.y + dy)] else { continue }
                for i in idxs {
                    let row = smnRows[i]
                    let dLat = row.lat - c.latitude
                    let dLon = (row.lon - c.longitude) * cosLat
                    let d2 = dLat * dLat + dLon * dLon
                    if best == nil || d2 < best!.1 { best = (row, d2) }
                }
            }
        }
        guard let (row, d2) = best, d2 < 0.55 * 0.55 else { return nil }
        return IntlWeatherParsing.conditions(from: row)
    }

    /// NWS publishes wind direction as a compass word ("NW", "SSE"). The
    /// drag math needs degrees, and the 16-point table is the same one the
    /// banner compass reads from.
    nonisolated static func degrees(fromCompass word: String?) -> Double? {
        guard let word = word?.trimmingCharacters(in: .whitespaces).uppercased(),
              !word.isEmpty,
              let idx = CompassReading.points.firstIndex(of: word) else { return nil }
        return Double(idx) * 22.5
    }
}
