// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
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
///
/// The country boxes, the tier edges and the shower ladder are computed in
/// rust/flows-core (places_text.rs) and called through rust/flows-bridge;
/// countries and shower answers cross as codes in declaration order. Pinned
/// to the original Swift by
/// rust/flows-bridge/tests/fixtures/swift_places_text_oracle.tsv.
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

        /// ISO code the Radio Browser directory keys stations by.
        var radioBrowserCode: String {
            switch self {
            case .us: return "US"
            case .canada: return "CA"
            case .mexico: return "MX"
            }
        }

        var currencySymbol: String {
            switch self {
            case .us: return "US$"
            case .canada: return "C$"
            case .mexico: return "MX$"
            }
        }

        var checkBreakpoints: [Double] { Array(flows_places_text_check_breakpoints(rustCode)) }

        /// The bridge's code: the `allCases` position.
        var rustCode: UInt8 {
            switch self {
            case .us: return 0
            case .canada: return 1
            case .mexico: return 2
            }
        }
        init(rustCode: UInt8) {
            switch rustCode {
            case 1: self = .canada
            case 2: self = .mexico
            default: self = .us
            }
        }

        /// GPS → country (rough NA boxes; the app refines with reverse
        /// geocoding when available, this pure fallback is tested). The US–MX
        /// border is three line segments and the Rio Grande diagonal, not a
        /// flat parallel, so Houston, San Antonio, Tucson and San Diego stay US.
        static func forCoordinate(latitude: Double, longitude: Double) -> Country {
            Country(rustCode: flows_places_text_country_for_coordinate(latitude, longitude))
        }
    }

    /// Average per-person check (local currency) → 1…5 tier for a country.
    static func costTier(averageCheck: Double, country: Country = .us) -> Int {
        Int(flows_places_text_cost_tier_for_check(averageCheck, country.rustCode))
    }

    /// Back-compat US entry point (tests + Yelp path).
    static func costTier(averageCheckUSD: Double) -> Int {
        costTier(averageCheck: averageCheckUSD, country: .us)
    }

    /// Typical US nightly rate for a hotel's cost tier — the "no blank
    /// data" fallback when no live nightly exists for a property. Clearly an
    /// estimate (the UI labels it "est."); a live rate always replaces it.
    /// Unknown tier reads as the mid-market median.
    static func estimatedNightly(costTier: Int?) -> Double {
        flows_places_text_estimated_nightly(Int64(costTier ?? 0), costTier != nil)
    }

    /// Yelp "price" string ("$"…"$$$$") → tier; Yelp's top band spans our
    /// 4 and 5, splitting on rating-weighted prestige (4.5★+ $$$$ reads
    /// as luxury).
    static func costTier(yelpPrice: String, rating: Double?) -> Int {
        Int(flows_places_text_yelp_cost_tier(yelpPrice, rating ?? 0, rating != nil))
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
        /// Weekly hours lines, Monday first ("Monday: 9:00 AM – 5:00 PM") —
        /// Google supplies them; Yelp's search response doesn't, so nil there.
        var hours: [String]? = nil
        /// The business page, when the provider requires linking to it
        /// (Yelp's display terms do; Google's are met by the credit line).
        var url: URL? = nil
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
                                isOpenNow: hoursBlock?["is_open_now"] as? Bool,
                                url: (first["url"] as? String).flatMap(URL.init))
        cache[key] = info
        if cache.count > 300 { CacheEviction.dropHalf(&cache) }
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
            "places.rating,places.priceLevel,places.currentOpeningHours.openNow,"
                + "places.regularOpeningHours.weekdayDescriptions",
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
        let hours = (first["regularOpeningHours"] as? [String: Any])?["weekdayDescriptions"]
            as? [String]
        let info = YelpLink.BusinessInfo(rating: first["rating"] as? Double,
                                         price: price, isOpenNow: openNow,
                                         hours: hours)
        cache[key] = info
        if cache.count > 300 { CacheEviction.dropHalf(&cache) }
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

    /// Who supplied the rating currently on screen, or nil when no provider
    /// is configured and the app shows only its own data.
    ///
    /// Google's Places terms require their content to be credited wherever
    /// it appears. FLOWS draws on an Apple map, so the credit has to travel
    /// with the stars rather than live in a Google map's own chrome. This
    /// mirrors the same key ladder `info(name:latitude:longitude:)` uses —
    /// read straight from defaults so a SwiftUI body can call it.
    @MainActor static var creditLine: String? {
        let d = UserDefaults.standard
        if !(d.string(forKey: "flows.googlePlacesKey") ?? "").isEmpty {
            return "Powered by Google"
        }
        if !(d.string(forKey: "flows.yelpKey") ?? "").isEmpty {
            return "Ratings by Yelp"
        }
        return nil
    }
}

/// Trucker shower availability by BRAND — the documented industry standard
/// per chain (Love's, Pilot/Flying J, TA/Petro all provide showers at
/// effectively every travel-center location; Buc-ee's famously does not).
/// Name-matched per result; "assume yes at Love's unless disproven" is
/// exactly the .standard tier. Pure table, pinned by FLOWSTests.
enum ShowerAvailability: String {
    case standard = "Showers"
    case likely = "Showers likely"
    case none = "No showers"
    case disproven = "No showers (reported)"
    case unknown = ""

    /// The bridge's code, in declaration order; anything else is unknown.
    init(rustCode: UInt8) {
        switch rustCode {
        case 0: self = .standard
        case 1: self = .likely
        case 2: self = .none
        case 3: self = .disproven
        default: self = .unknown
        }
    }

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

        // The entries' coordinates as parallel lists, so the nearest-entry
        // lookup crosses to Rust without copying the rows.
        private let lats: [Double]
        private let lons: [Double]

        init(entries: [Entry]) {
            self.entries = entries
            self.lats = entries.map(\.lat)
            self.lons = entries.map(\.lon)
        }

        static func loadBundled() -> LocationTable {
            guard let url = Bundle.main.url(forResource: "truckstop_showers",
                                            withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let parsed = try? JSONDecoder().decode([Entry].self, from: data)
            else { return LocationTable(entries: []) }
            return LocationTable(entries: parsed)
        }

        /// Nearest table entry within the ±0.01° box of a stop, ties to the
        /// lowest index, found in Rust through the same 0.01° grid the original
        /// kept (an empty table never crosses). nil for a stop that cannot be
        /// placed.
        func entry(nearLat lat: Double, lon: Double) -> Entry? {
            guard !entries.isEmpty else { return nil }
            let index = lats.withUnsafeBufferPointer { la in
                lons.withUnsafeBufferPointer { lo in
                    flows_places_text_shower_table_entry(la, lo, lat, lon)
                }
            }
            return index >= 0 && Int(index) < entries.count ? entries[Int(index)] : nil
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
                m["\(lowercased(state))|\(lowercased(city))"] = showers
            }
            return CityTable(map: m)
        }

        init(map: [String: Int]) { self.map = map }

        /// Swift's `lowercased()`, computed in Rust so the keys the loader
        /// writes and the keys the lookup builds agree letter for letter.
        private static func lowercased(_ s: String) -> String {
            flows_places_text_lowercased(s).text
        }

        /// nil = city not in the scrape; 0 = verified no showers; n = count.
        /// The two keys tried (spaces as hyphens, then as spelled) are built
        /// in Rust; the dictionary itself is this store's.
        func showers(state: String?, city: String?) -> Int? {
            guard let state, let city else { return nil }
            let keys = flows_places_text_city_keys(state, city)
            guard keys.len() == 2 else { return nil }
            return map[keys[0].text] ?? map[keys[1].text]
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
    /// The store's reads (the report, the table entry) happen here; the
    /// decision is Rust's.
    static func forStop(
        named name: String?, lat: Double? = nil, lon: Double? = nil,
        table: LocationTable? = nil
    ) -> ShowerAvailability {
        var disproved = false
        var tag: String?
        if let lat, let lon {
            disproved = isDisproved(lat: lat, lon: lon)
            tag = table?.entry(nearLat: lat, lon: lon)?.shower
        }
        return ShowerAvailability(rustCode: flows_places_text_shower_ladder(
            name ?? "", name != nil, lat != nil && lon != nil, disproved, tag ?? "", tag != nil))
    }

    /// The brand default by name: chains where showers are the standard at
    /// travel centers, chains where they are likely, and formats that
    /// famously omit them.
    static func forStop(named name: String?) -> ShowerAvailability {
        ShowerAvailability(rustCode: flows_places_text_shower_for_name(name ?? "", name != nil))
    }
}
