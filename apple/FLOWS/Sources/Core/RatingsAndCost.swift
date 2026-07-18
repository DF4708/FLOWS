// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Review stars (1–5) and cost "$" tiers (1–5) for POIs.
///
/// The $ SCALE, anchored to income as specified: tier 1 is affordable on a
/// US minimum-wage dining-out budget (BLS consumer expenditure puts the
/// lowest-quintile food-away-from-home spend near ~$5–8/meal); tier 5 is
/// only justifiable in the top 1–3% of incomes. Encoded as average
/// per-person check breakpoints (pure, pinned by FLOWSTests):
///   $      ≤ $12   — minimum-wage affordable
///   $$     ≤ $30   — median-income casual
///   $$$    ≤ $60   — upper-middle occasion
///   $$$$   ≤ $120  — high income
///   $$$$$  > $120  — top 1–3% territory
/// Live per-business data plugs in via the Yelp Fusion key (free tier,
/// Settings → Data sources): Yelp's $–$$$$ maps into tiers 1–4/5.
enum RatingsAndCost {
    /// COUNTRY-SPECIFIC cost profiles, switched automatically by GPS.
    /// Each anchors tier 1 to that country's minimum-wage dining-out budget
    /// and tier 5 to its top-percentile spending, in LOCAL currency:
    ///   * US — federal/effective minimum wage + BLS food-away-from-home
    ///     (lowest quintile ≈ $8–12/meal): $12/$30/$60/$120 USD.
    ///   * Canada — federal minimum C$17.30 (2024), after-tax ~C$14.6/h +
    ///     StatCan household food-away spending: C$16/C$40/C$80/C$160.
    ///   * Mexico — general minimum MX$248.93/day (2024, CONASAMI) +
    ///     ENIGH/CONEVAL food shares (comida corrida ≈ MX$70–90):
    ///     MX$90/MX$250/MX$600/MX$1500.
    enum Country: String, CaseIterable {
        case us, canada, mexico

        var currencySymbol: String {
            switch self {
            case .us: return "US$"
            case .canada: return "C$"
            case .mexico: return "MX$"
            }
        }

        var checkBreakpoints: [Double] {
            switch self {
            case .us: return [12, 30, 60, 120]
            case .canada: return [16, 40, 80, 160]
            case .mexico: return [90, 250, 600, 1500]
            }
        }

        /// GPS → country (rough NA boxes; the app refines with reverse
        /// geocoding when available, this pure fallback is tested).
        static func forCoordinate(latitude: Double, longitude: Double) -> Country {
            // The US–MX border is NOT a flat parallel: CA ~32.5, AZ/NM ~31.3–31.8,
            // then the Rio Grande runs DIAGONALLY from El Paso (31.8, −106.4)
            // to Brownsville (25.9, −97.1). The old flat 32.72 cut classified
            // Houston, San Antonio, Tucson, and San Diego as Mexico (MX$ tiers
            // + CRE fuel feed for US stations).
            func isMexico() -> Bool {
                guard longitude > -118, longitude < -86 else { return false }
                if latitude < 25.9 { return true }                       // south of Brownsville
                if longitude < -114.7 { return latitude < 32.5 }         // Baja/CA line
                if longitude < -106.4 { return latitude < 31.3 }         // AZ/NM line
                if longitude < -97.1 {                                    // Rio Grande diagonal
                    let borderLat = 31.75 - 0.63 * (longitude + 106.4)
                    return latitude < borderLat
                }
                return false                                              // Gulf side
            }
            if isMexico() { return .mexico }
            if latitude > 49 { return .canada }
            // Eastern Canada dips below 49 (Quebec/Maritimes)…
            if latitude > 44.8 && longitude > -83.6 && longitude < -52 { return .canada }
            // …and the southern-Ontario peninsula (Toronto/Hamilton) dips
            // to ~43.2 between Lakes Huron and Ontario — the strip north of
            // Rochester/Buffalo latitudes within those longitudes is Canada.
            if latitude > 43.4 && longitude > -81.8 && longitude < -76.3 { return .canada }
            return .us
        }
    }

    /// Average per-person check (local currency) → 1…5 tier for a country.
    static func costTier(averageCheck: Double, country: Country = .us) -> Int {
        for (i, edge) in country.checkBreakpoints.enumerated() where averageCheck <= edge {
            return i + 1
        }
        return 5
    }

    /// Back-compat US entry point (tests + Yelp path).
    static func costTier(averageCheckUSD: Double) -> Int {
        costTier(averageCheck: averageCheckUSD, country: .us)
    }

    /// Yelp "price" string ("$"…"$$$$") → tier; Yelp's top band spans our
    /// 4 and 5, splitting on rating-weighted prestige (4.5★+ $$$$ reads
    /// as luxury).
    static func costTier(yelpPrice: String, rating: Double?) -> Int {
        let count = yelpPrice.filter { $0 == "$" }.count
        switch count {
        case ..<1: return 1
        case 1, 2, 3: return count
        default: return (rating ?? 0) >= 4.5 ? 5 : 4
        }
    }

    /// Star color ramp: plain yellow at 1★ → rich gold at 5★ (the shimmer
    /// animation rides on top in the view layer).
    /// Returned as (red, green, blue) 0…1 for platform-free testing.
    static func starColor(stars: Double) -> (r: Double, g: Double, b: Double) {
        let t = min(max((stars - 1) / 4, 0), 1)
        // yellow (1.0, 0.85, 0.25) → gold (0.95, 0.65, 0.05)
        return (1.0 - 0.05 * t, 0.85 - 0.20 * t, 0.25 - 0.20 * t)
    }

    /// "$" color ramp: dark green at 1 → light green at 5.
    static func dollarColor(tier: Int) -> (r: Double, g: Double, b: Double) {
        let t = min(max(Double(tier - 1) / 4, 0), 1)
        // dark green (0.05, 0.35, 0.12) → light green (0.45, 0.85, 0.45)
        return (0.05 + 0.40 * t, 0.35 + 0.50 * t, 0.12 + 0.33 * t)
    }
}

/// Optional Yelp Fusion source (free key: https://www.yelp.com/developers —
/// create an app, paste the API key into Settings → Data sources). Supplies
/// rating + price for hotels/food; absent a key, the UI simply omits
/// stars/$ rather than inventing them.
actor YelpLink {
    static let shared = YelpLink()

    /// Set from Settings (persisted by AppModel).
    var apiKey: String = ""
    func setKey(_ key: String) { apiKey = key }

    struct BusinessInfo {
        let rating: Double?      // 0–5
        let price: String?       // "$"…"$$$$"
        var isOpenNow: Bool? = nil
    }

    private var cache: [String: BusinessInfo] = [:]

    func info(name: String, latitude: Double, longitude: Double) async -> BusinessInfo? {
        guard !apiKey.isEmpty else { return nil }
        let key = "\(name)|\(Int(latitude * 500))|\(Int(longitude * 500))"
        if let hit = cache[key] { return hit }
        // .urlQueryAllowed leaves & = + literal, truncating the term param
        // for names like "Dave & Buster's" — use a strict component set.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        let term = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        guard let url = URL(string: "https://api.yelp.com/v3/businesses/search?term=\(term)"
                            + "&latitude=\(latitude)&longitude=\(longitude)&limit=1") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await ThrottledNet.fetch(request),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let businesses = json["businesses"] as? [[String: Any]],
              let first = businesses.first else { return nil }
        let hoursBlock = (first["business_hours"] as? [[String: Any]])?.first
        let info = BusinessInfo(rating: first["rating"] as? Double,
                                price: first["price"] as? String,
                                isOpenNow: hoursBlock?["is_open_now"] as? Bool)
        cache[key] = info
        if cache.count > 300 { cache = [:] }
        return info
    }
}

/// Google Places API (New) as an ALTERNATE ratings source — Yelp Fusion moved
/// to paid plans, while Places carries a real free monthly quota per SKU
/// (thousands of Text Search calls/month), plenty for per-search live lookups.
/// Same optional-key model as Yelp: no key → provider skipped. Results are
/// fetched live per search and cached ONLY in memory for the session —
/// Google's terms prohibit persisting/redistributing Places content, so
/// nothing is stored or shipped.
actor GooglePlacesLink {
    static let shared = GooglePlacesLink()

    var apiKey: String = ""
    func setKey(_ key: String) { apiKey = key }

    private var cache: [String: YelpLink.BusinessInfo] = [:]

    /// Text Search (New), field-masked to exactly what the rows display:
    /// rating, price level, open-now. Location-biased to the placemark.
    func info(name: String, latitude: Double, longitude: Double)
        async -> YelpLink.BusinessInfo? {
        guard !apiKey.isEmpty else { return nil }
        let key = "\(name)|\(Int(latitude * 500))|\(Int(longitude * 500))"
        if let hit = cache[key] { return hit }
        guard let url = URL(string: "https://places.googleapis.com/v1/places:searchText")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "places.rating,places.priceLevel,places.currentOpeningHours.openNow",
            forHTTPHeaderField: "X-Goog-FieldMask")
        let body: [String: Any] = [
            "textQuery": name,
            "pageSize": 1,
            "locationBias": ["circle": [
                "center": ["latitude": latitude, "longitude": longitude],
                "radius": 5_000.0,
            ]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await ThrottledNet.fetch(request),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let places = json["places"] as? [[String: Any]],
              let first = places.first else { return nil }
        // PRICE_LEVEL_* → the "$"…"$$$$" string the cost-tier mapper expects.
        let price: String? = (first["priceLevel"] as? String).flatMap {
            switch $0 {
            case "PRICE_LEVEL_INEXPENSIVE": return "$"
            case "PRICE_LEVEL_MODERATE": return "$$"
            case "PRICE_LEVEL_EXPENSIVE": return "$$$"
            case "PRICE_LEVEL_VERY_EXPENSIVE": return "$$$$"
            default: return nil
            }
        }
        let openNow = (first["currentOpeningHours"] as? [String: Any])?["openNow"] as? Bool
        let info = YelpLink.BusinessInfo(rating: first["rating"] as? Double,
                                         price: price, isOpenNow: openNow)
        cache[key] = info
        if cache.count > 300 { cache = [:] }
        return info
    }
}

/// One ratings front door: Google Places first (bigger free quota), Yelp as
/// the fallback — whichever the user has keyed. POI code asks HERE, not a
/// specific provider.
enum RatingsProvider {
    static func info(name: String, latitude: Double, longitude: Double)
        async -> YelpLink.BusinessInfo? {
        if let g = await GooglePlacesLink.shared.info(
            name: name, latitude: latitude, longitude: longitude) {
            return g
        }
        return await YelpLink.shared.info(
            name: name, latitude: latitude, longitude: longitude)
    }
}

/// Trucker shower availability by BRAND — the documented industry standard
/// per chain (Love's, Pilot/Flying J, TA/Petro all provide showers at
/// effectively every travel-center location; Buc-ee's famously does not).
/// Name-matched per result; "assume yes at Love's unless disproven" is
/// exactly the .standard tier. Pure table, pinned by FLOWSTests.
enum ShowerAvailability: String {
    case standard = "Showers (brand standard)"
    case likely = "Showers likely"
    case none = "No showers"
    case disproven = "No showers (reported)"
    case unknown = ""

    /// Per-LOCATION table: 1,505 major-brand truck stops (OSM pull, bundled
    /// as truckstop_showers.json) + the driver's own "no showers here"
    /// reports (persisted). Explicit data beats the brand default — exactly
    /// "assume Love's has them unless disproven".
    struct LocationTable {
        struct Entry: Codable {
            let lat: Double
            let lon: Double
            let brand: String
            var shower: String?
        }
        let entries: [Entry]

        // Grid index at the same 0.01° resolution as the lookup box, so
        // `entry(nearLat:lon:)` is O(1) instead of O(entries) — the ~1,505-row
        // table was scanned in full on every shower lookup during POI ranking.
        private struct Cell: Hashable { let x: Int; let y: Int }
        private static let cellDeg = 0.01
        private let grid: [Cell: [Int]]

        private static func cell(_ lat: Double, _ lon: Double) -> Cell {
            Cell(x: Int((lon / cellDeg).rounded(.down)),
                 y: Int((lat / cellDeg).rounded(.down)))
        }

        init(entries: [Entry]) {
            self.entries = entries
            var g: [Cell: [Int]] = [:]
            for (i, e) in entries.enumerated() {
                g[Self.cell(e.lat, e.lon), default: []].append(i)
            }
            self.grid = g
        }

        static func loadBundled() -> LocationTable {
            guard let url = Bundle.main.url(forResource: "truckstop_showers",
                                            withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let parsed = try? JSONDecoder().decode([Entry].self, from: data)
            else { return LocationTable(entries: []) }
            return LocationTable(entries: parsed)
        }

        /// Nearest table entry within the ±0.01° box of a stop. Any entry inside
        /// that box is at most one cell away, so a 3×3 neighborhood scan is exact
        /// — same box filter, same nearest, same lowest-index tie-break as before.
        func entry(nearLat lat: Double, lon: Double) -> Entry? {
            let c0 = Self.cell(lat, lon)
            var bestIdx = -1
            var bestD = Double.greatestFiniteMagnitude
            for dy in -1...1 {
                for dx in -1...1 {
                    guard let idxs = grid[Cell(x: c0.x + dx, y: c0.y + dy)] else { continue }
                    for i in idxs {
                        let e = entries[i]
                        guard abs(e.lat - lat) < 0.01, abs(e.lon - lon) < 0.01 else { continue }
                        let d = (e.lat - lat) * (e.lat - lat) + (e.lon - lon) * (e.lon - lon)
                        if d < bestD || (d == bestD && (bestIdx < 0 || i < bestIdx)) {
                            bestD = d
                            bestIdx = i
                        }
                    }
                }
            }
            return bestIdx >= 0 ? entries[bestIdx] : nil
        }
    }

    /// VERIFIED per-location shower data scraped from the chain's own store
    /// pages, keyed by (state, city) — bundled as pilot_city_showers.json.
    /// The POI result's placemark supplies the same key at lookup time.
    struct CityTable {
        private let map: [String: Int]   // "wi|madison" → shower count

        /// Pilot/Flying J (back-compat default resource).
        static func loadBundled() -> CityTable { loadBundled(resource: "pilot_city_showers") }

        /// Load one brand's verified city→showers scrape. Per-brand tables stay
        /// SEPARATE so a Love's result never matches a Pilot city key.
        static func loadBundled(resource: String) -> CityTable {
            guard let url = Bundle.main.url(forResource: resource,
                                            withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return CityTable(map: [:]) }
            var m: [String: Int] = [:]
            for row in rows {
                guard let state = row["state"] as? String,
                      let city = row["city"] as? String,
                      let showers = row["showers"] as? Int else { continue }
                m["\(state.lowercased())|\(city.lowercased())"] = showers
            }
            return CityTable(map: m)
        }

        init(map: [String: Int]) { self.map = map }

        /// nil = city not in the scrape; 0 = verified no showers; n = count.
        func showers(state: String?, city: String?) -> Int? {
            guard let state, let city else { return nil }
            return map["\(state.lowercased())|\(city.lowercased().replacingOccurrences(of: " ", with: "-"))"]
                ?? map["\(state.lowercased())|\(city.lowercased())"]
        }
    }

    private static let disprovedKey = "flows.showersDisproved"

    /// Location key for driver reports (≈100 m grid).
    static func locationKey(lat: Double, lon: Double) -> String {
        "\(Int((lat * 1000).rounded()))|\(Int((lon * 1000).rounded()))"
    }

    static func disprove(lat: Double, lon: Double) {
        var set = Set(UserDefaults.standard.stringArray(forKey: disprovedKey) ?? [])
        set.insert(locationKey(lat: lat, lon: lon))
        UserDefaults.standard.set(Array(set), forKey: disprovedKey)
    }

    static func isDisproved(lat: Double, lon: Double) -> Bool {
        (UserDefaults.standard.stringArray(forKey: disprovedKey) ?? [])
            .contains(locationKey(lat: lat, lon: lon))
    }

    /// Full resolution ladder: driver report → explicit table tag → brand.
    static func forStop(
        named name: String?, lat: Double? = nil, lon: Double? = nil,
        table: LocationTable? = nil
    ) -> ShowerAvailability {
        if let lat, let lon {
            if isDisproved(lat: lat, lon: lon) { return .disproven }
            if let entry = table?.entry(nearLat: lat, lon: lon),
               let tag = entry.shower {
                return tag == "no" ? .none : .standard
            }
        }
        return forStop(named: name)
    }

    static func forStop(named name: String?) -> ShowerAvailability {
        let lower = (name ?? "").lowercased()
        // Chains where showers are the brand standard at travel centers.
        for brand in ["love's", "loves travel", "pilot", "flying j",
                      "ta travel", "travelcenters of america", "petro stopping",
                      "sapp bros"] where lower.contains(brand) {
            return .standard
        }
        for brand in ["kwik trip", "road ranger", "ambest", "roady"]
        where lower.contains(brand) {
            return .likely
        }
        for brand in ["buc-ee", "bucee", "casey's", "caseys", "speedway",
                      "circle k", "7-eleven", "kum & go", "quiktrip", "wawa",
                      "sheetz"] where lower.contains(brand) {
            return .none
        }
        return .unknown
    }
}
