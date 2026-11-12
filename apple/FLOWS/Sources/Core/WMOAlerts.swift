// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import FlowsBridge
import Foundation

/// WMO Alert Hub — official national CAP alerts for the countries NWS/ECCC
/// don't cover: Mexico + Central America + the Caribbean. The hub republishes
/// each national met service's authoritative warnings (the same feed the paid
/// aggregators use). The per-country RSS is an index (event/severity/expiry
/// inline, geometry only in each item's linked CAP file), so we filter to
/// unexpired items, fetch a bounded set of their CAP files for the polygon,
/// then keep the ones that actually contain the driver's point.
///
/// Pure parsing here (pinned by FLOWSTests); WeatherAlertService does the I/O.
/// The rules run in Rust (`flows_core::wmo_alerts`); the diacritic folding
/// stays here, with Foundation's own tables.
enum WMOAlertParsing {

    /// The hub feed code for a point, or nil if outside every covered country.
    /// Each covered country is a coarse national box, checked most-specific
    /// first so a point in Belize, Costa Rica and the rest isn't swallowed by
    /// Mexico's broad box. Mexico's box also takes in Guatemala, El Salvador
    /// and northern Honduras, where its feed has no shapes; the small boxes
    /// take in the neighbours too (Venezuela's Paria tip sits in Trinidad's),
    /// and a neighbour read from the wrong country's list is "no alerts",
    /// complete. Rules in `flows_core::wmo_alerts`.
    static func feedCode(for c: CLLocationCoordinate2D) -> String? {
        let code = flows_wmo_feed_code(c.latitude, c.longitude).text
        return code.isEmpty ? nil : code
    }

    /// Whether a point in Mexico's box lies past its southern border: the
    /// Suchiate and the highlands, the 16.07°N parallel, the Usumacinta, the
    /// 91°W meridian and 17.82°N, as steps. Slivers by the border err to
    /// the south — "unknown" fails safe where "no alerts" does not. One cut
    /// at 91.4°W left Quetzaltenango, San Marcos and Huehuetenango on
    /// Mexico's feed.
    static func southOfMexico(_ c: CLLocationCoordinate2D) -> Bool {
        flows_wmo_south_of_mexico(c.latitude, c.longitude)
    }

    enum BelizeSide { case belize, mexico, unsure }

    /// Which side of Belize's borders a point in its box is on. Guatemala
    /// lies south of the Sarstoon and west of the 89.15°W line; Mexico north
    /// of the Hondo (drawn here as one straight line from La Unión to
    /// Chetumal Bay) and on the Xcalak coast. Within a tenth of a degree of
    /// the river the answer is "unsure": unknown fails safe, the wrong
    /// country's "no alerts" does not.
    static func besideBelize(_ c: CLLocationCoordinate2D) -> BelizeSide {
        switch flows_wmo_beside_belize(c.latitude, c.longitude) {
        case 0: return .belize
        case 1: return .mexico
        default: return .unsure
        }
    }

    /// A point in Costa Rica's box that may be Nicaragua (north of the San
    /// Juan and the line to Salinas Bay) or Panama (east of the Sixaola and
    /// the ridge down to Punta Burica). Wide on purpose.
    static func besideCostaRica(_ c: CLLocationCoordinate2D) -> Bool {
        flows_wmo_beside_costa_rica(c.latitude, c.longitude)
    }

    /// Each service's own list of alerts. The WMO hub's per-country lists
    /// (`severeweather.wmo.int/v2/cap-alerts/<code>/rss.xml`) answer "not
    /// found" (seen 2026-11-10), which left all seven countries unchecked;
    /// these are the addresses the hub's own source table gives. Panama and
    /// the Dominican Republic publish none there: nil, so unknown.
    static func indexURL(code: String) -> URL? {
        let address: String
        switch code {
        case "mx-smn-es": address = "https://smn.conagua.gob.mx/tools/PHP/feedsmn/cap.php"
        case "bz-nms-en": address = "https://cap-sources.s3.amazonaws.com/bz-nms-en/rss.xml"
        case "cr-imn-es": address = "https://cap-sources.s3.amazonaws.com/cr-imn-es/rss.xml"
        case "jm-jms-en": address = "https://alert.metservice.gov.jm/capfeed.php"
        case "tt-ttms-en": address = "https://metproducts.gov.tt/ttms/public/api/feed?type=rss"
        default: return nil
        }
        return URL(string: address)
    }

    struct RSSItem {
        let link: String
        let event: String
        let severity: String
        let expires: String
        /// When the list says the item was published (RSS `pubDate`, Atom
        /// `updated`), as written.
        var published = ""
    }

    /// Flat scan of the RSS `<item>` blocks (event/severity/expires inline;
    /// the `<link>` points at the full CAP file with the geometry), then the
    /// Atom `<entry>` blocks (Mexico, Jamaica), whose link is an attribute:
    /// `<link ... href="...">`. Any link: a list that names its alert files
    /// some other way than ".xml" lost every alert, and read "no alerts". A
    /// link that is not an alert file fails to parse as one: unknown.
    static func parseRSSItems(_ xml: String) -> [RSSItem] {
        let v = flows_wmo_rss_items(xml).map { $0.text }
        guard v.count % 5 == 0 else { return [] }
        return stride(from: 0, to: v.count, by: 5).map { i in
            RSSItem(
                link: v[i], event: v[i + 1], severity: v[i + 2], expires: v[i + 3],
                published: v[i + 4])
        }
    }

    /// A service's own name for an alert, in the words the risk rules read.
    /// Those rules know the US names only: "Aviso de Ciclón Tropical",
    /// severe, added nothing to a route's risk, and neither did "Hot Spell".
    /// A name the rules already place is kept as written. Severe and extreme
    /// alerts take the warning name (it can reach Red); the rest take the
    /// advisory or watch name (a predictor, capped). Sea-state notices and
    /// names nothing here knows stay as written, unscored.
    ///
    /// A rain notice is not a flood until it passes a threshold (owner,
    /// 2026-11-11): the service rates it severe or extreme, or its text
    /// names heavy rain (`namesHeavyRain`: 50 mm or more, Mexico's "muy
    /// fuertes" class and up). Below that it is a "Rain Advisory": the same
    /// capped rain predictor as before, under its own name and icon. A
    /// notice that names the flood itself ("inundaciones", "crecida") is a
    /// flood at any level.
    static func eventInRiskWords(
        _ event: String, severity: String,
        detail: String? = nil
    ) -> String {
        flows_wmo_event_in_risk_words(
            event, fold(event), severity, fold(event + " " + (detail ?? ""))
        ).text
    }

    /// The diacritic and case folding the risk-word rules read: it stays in
    /// Swift, with Foundation's own tables.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// The least rain, in millimetres, that makes a rain notice a flood
    /// notice. Mexico's weather service sorts a day's rain into "fuertes"
    /// (25 to 50 mm), "muy fuertes" (50 to 75), "intensas" (75 to 150),
    /// "torrenciales" (150 to 250) and "extraordinarias" (over 250); 50 mm in
    /// a day is also where most services begin to call rain heavy.
    static let floodRainMillimetres = 50.0

    /// Whether a notice's own words put its rain at the flood threshold: an
    /// amount of `floodRainMillimetres` or more (the low end of a range such
    /// as "75 a 150 mm" is the one read), or one of the class names that
    /// start there. "Fuertes" alone (25 to 50 mm) is below it.
    ///
    /// The class has to be said of the rain. "Lluvias fuertes y vientos muy
    /// fuertes" is 25 to 50 mm with strong wind: the bare words used to make
    /// that a flood notice. Up to four words may sit between ("lluvias
    /// puntuales intensas", "lluvias de fuertes a muy fuertes"), none of them
    /// the wind or the sea, and no comma. "Sin lluvias intensas" says there is
    /// none: only that one plain "sin" right before the phrase is read as a
    /// no. "75 a 150 mm", "50-75 mm", "de 150 mm": the first figure of each.
    static func namesHeavyRain(_ text: String) -> Bool {
        flows_wmo_names_heavy_rain(fold(text))
    }

    struct ParsedCAP {
        let event: String
        let severity: String
        /// EVERY <polygon> in the CAP, one ring each — an alert can span
        /// disjoint areas (<area> blocks / multiple polygons per area), and a
        /// driver inside the second ring is just as warned as one in the first.
        let polygons: [[CLLocationCoordinate2D]]
        /// First ring, for callers that only need one (tests, previews).
        var polygon: [CLLocationCoordinate2D] { polygons.first ?? [] }
        let areaDesc: String?
        let expires: String?
        let effective: String?
        let web: String?
        let description: String?
        /// A real alert in force: not a test or an exercise, not a
        /// cancellation, not an "all clear". Those came through as live
        /// alerts at their stated severity until they expired.
        var isLive = true
        /// The message's own name, and the names of the earlier messages it
        /// replaces (an update or a cancellation lists them).
        var identifier: String?
        var references: [String] = []
    }

    /// CAP `<polygon>` is space-separated `lat,lon` pairs (note: lat FIRST,
    /// unlike GeoJSON).
    ///
    /// Any white space parts the pairs (a Windows line end is one Character
    /// that is not "\n"), and a ring with a pair that cannot be read is no
    /// ring: a wrong shape can miss the driver.
    static func polygonCoords(_ raw: String) -> [CLLocationCoordinate2D] {
        coordinates(Array(flows_wmo_polygon(raw))[...])
    }

    private static func coordinates(_ flat: ArraySlice<Double>) -> [CLLocationCoordinate2D] {
        guard flat.count % 2 == 0 else { return [] }
        return stride(from: flat.startIndex, to: flat.endIndex, by: 2).map {
            CLLocationCoordinate2D(latitude: flat[$0], longitude: flat[$0 + 1])
        }
    }

    /// A CAP file, or nil when it is not an alert file at all (an error
    /// page, a web page). Tags read with or without the `cap:` prefix
    /// (Belize). EVERY `<polygon>` is a ring, and one with fewer than three
    /// vertices is dropped (un-locatable), so an alert with only garbled
    /// rings has no polygons and the caller's emptiness check rejects it.
    /// Not live: a test or an exercise, a cancellation, an "all clear".
    /// References are the second part of each "sender,identifier,sent".
    static func parseCAP(_ raw: String) -> ParsedCAP? {
        let v = flows_wmo_cap(raw).map { $0.text }
        guard v.count >= 10, v[0] == "1" else { return nil }
        let flags = Array(v[3])
        guard flags.count == 7 else { return nil }
        func optional(_ i: Int) -> String? { flags[i] == "1" ? v[4 + i] : nil }
        return ParsedCAP(
            event: v[1],
            severity: v[2],
            polygons: rings(raw),
            areaDesc: optional(0),
            expires: optional(1),
            effective: optional(2),
            web: optional(3),
            description: optional(4),
            isLive: flags[6] == "1",
            identifier: optional(5),
            references: Array(v[10...]))
    }

    /// The rings of a CAP file: `[count, lengths..., lat, lon, ...]`.
    private static func rings(_ raw: String) -> [[CLLocationCoordinate2D]] {
        let v = Array(flows_wmo_cap_rings(raw))
        guard let first = v.first, let n = Int(exactly: first), n >= 0, v.count > n else { return [] }
        var at = 1 + n
        var out: [[CLLocationCoordinate2D]] = []
        for k in 0..<n {
            guard let len = Int(exactly: v[1 + k]), len >= 0, at + 2 * len <= v.count else { return [] }
            out.append(coordinates(v[at..<(at + 2 * len)]))
            at += 2 * len
        }
        return out
    }
}
