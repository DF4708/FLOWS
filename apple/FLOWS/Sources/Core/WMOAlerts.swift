// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
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
enum WMOAlertParsing {

    /// Country → hub feed code, checked most-specific first so a point in
    /// Belize/CR/etc. isn't swallowed by Mexico's broad box. Coordinates are
    /// coarse national bounding boxes (only the covered countries).
    private static let feeds: [(code: String, minLat: Double, maxLat: Double,
                                minLon: Double, maxLon: Double)] = [
        ("bz-nms-en", 15.8, 18.5, -89.3, -87.3),   // Belize
        ("cr-imn-es", 8.0, 11.3, -86.0, -82.5),     // Costa Rica
        ("pa-imhpa-es", 7.0, 9.7, -83.1, -77.1),    // Panama
        ("do-indomet-es", 17.5, 20.1, -72.1, -68.3),// Dominican Republic
        ("jm-jms-en", 17.6, 18.7, -78.5, -76.1),    // Jamaica
        ("tt-ttms-en", 10.0, 11.4, -62.1, -60.8),   // Trinidad & Tobago
        ("mx-smn-es", 14.3, 32.8, -118.5, -86.7),   // Mexico (regional catch-all)
    ]

    /// The hub feed code for a point, or nil if outside every covered country.
    static func feedCode(for c: CLLocationCoordinate2D) -> String? {
        for f in feeds where c.latitude >= f.minLat && c.latitude <= f.maxLat
            && c.longitude >= f.minLon && c.longitude <= f.maxLon {
            // Mexico's box also takes in Guatemala, El Salvador and northern
            // Honduras, where its feed has no shapes: Guatemala City read
            // "no alerts", complete, when it is a place no covered feed
            // answers for.
            if f.code == "mx-smn-es", southOfMexico(c) { continue }
            // The small boxes take in the neighbours too, and a neighbour
            // read from the wrong country's list is "no alerts", complete.
            if f.code == "bz-nms-en" {
                switch besideBelize(c) {
                case .mexico: continue          // on to Mexico's own list
                case .unsure: return nil
                case .belize: break
                }
            }
            // Venezuela's Paria tip sits in Trinidad's box.
            if f.code == "tt-ttms-en", c.latitude > 10.45, c.longitude < -61.8 { return nil }
            if f.code == "cr-imn-es", besideCostaRica(c) { return nil }
            return f.code
        }
        return nil
    }

    /// Whether a point in Mexico's box lies past its southern border: the
    /// Suchiate and the highlands, the 16.07°N parallel, the Usumacinta, the
    /// 91°W meridian and 17.82°N, as steps. Slivers by the border err to
    /// the south — "unknown" fails safe where "no alerts" does not. One cut
    /// at 91.4°W left Quetzaltenango, San Marcos and Huehuetenango on
    /// Mexico's feed.
    static func southOfMexico(_ c: CLLocationCoordinate2D) -> Bool {
        let (lat, lon) = (c.latitude, c.longitude)
        if lat < 15.2 { return lon > -92.25 }
        if lat < 16.07 { return lon > -92.0 }
        if lat < 16.5 { return lon > -90.6 }
        if lat < 17.82 { return lon > -91.0 }
        return false
    }

    enum BelizeSide { case belize, mexico, unsure }

    /// Which side of Belize's borders a point in its box is on. Guatemala
    /// lies south of the Sarstoon and west of the 89.15°W line; Mexico north
    /// of the Hondo (drawn here as one straight line from La Unión to
    /// Chetumal Bay) and on the Xcalak coast. Within a tenth of a degree of
    /// the river the answer is "unsure": unknown fails safe, the wrong
    /// country's "no alerts" does not.
    static func besideBelize(_ c: CLLocationCoordinate2D) -> BelizeSide {
        let (lat, lon) = (c.latitude, c.longitude)
        if lat < 15.9 || lon < -89.15 { return .unsure }          // Guatemala, Honduras
        if lon < -88.88 { return lat > 17.8 ? .unsure : .belize } // Petén corner, Mexico above
        if lon > -88.1 { return lat > 18.2 ? .mexico : .belize }  // Xcalak coast
        if lon > -88.3 { return lat > 18.45 ? .unsure : .belize } // Chetumal Bay
        let river = 17.90 + 1.07 * (lon + 88.88)
        if lat > river + 0.1 { return .mexico }
        return lat > river - 0.1 ? .unsure : .belize
    }

    /// A point in Costa Rica's box that may be Nicaragua (north of the San
    /// Juan and the line to Salinas Bay) or Panama (east of the Sixaola and
    /// the ridge down to Punta Burica). Wide on purpose.
    static func besideCostaRica(_ c: CLLocationCoordinate2D) -> Bool {
        let (lat, lon) = (c.latitude, c.longitude)
        if lat > (lon < -85.0 ? 11.0 : 10.7) { return true }
        return lon > -83.1 && lat < 9.7
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
        let link: String; let event: String; let severity: String; let expires: String
        /// When the list says the item was published (RSS `pubDate`, Atom
        /// `updated`), as written.
        var published = ""
    }

    /// Flat scan of the RSS `<item>` blocks (event/severity/expires inline;
    /// the `<link>` points at the full CAP file with the geometry).
    static func parseRSSItems(_ xml: String) -> [RSSItem] {
        parseItems(xml, open: "<item>", close: "</item>")
            + parseItems(xml, open: "<entry>", close: "</entry>")
    }

    /// RSS `<item>` blocks, or Atom `<entry>` blocks (Mexico, Jamaica), whose
    /// link is an attribute: `<link ... href="...">`.
    private static func parseItems(_ xml: String, open: String, close: String) -> [RSSItem] {
        var out: [RSSItem] = []
        var search = xml[xml.startIndex...]
        while let open = search.range(of: open),
              let close = search.range(of: close, range: open.upperBound..<search.endIndex) {
            let body = String(search[open.upperBound..<close.lowerBound])
            func tag(_ name: String) -> String? {
                guard let s = body.range(of: "<\(name)>"),
                      let e = body.range(of: "</\(name)>", range: s.upperBound..<body.endIndex)
                else { return nil }
                return String(body[s.upperBound..<e.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var link = tag("link")
            if link == nil, let l = body.range(of: "<link "),
               let h = body.range(of: "href=\"", range: l.upperBound..<body.endIndex),
               let q = body.range(of: "\"", range: h.upperBound..<body.endIndex) {
                link = String(body[h.upperBound..<q.lowerBound])
            }
            // Any link: a list that names its alert files some other way
            // than ".xml" lost every alert, and read "no alerts". A link
            // that is not an alert file fails to parse as one: unknown.
            if let link, !link.isEmpty {
                out.append(RSSItem(link: link,
                                   event: tag("cap:event") ?? tag("title") ?? "Weather alert",
                                   severity: tag("cap:severity") ?? "Moderate",
                                   expires: tag("cap:expires") ?? "",
                                   published: tag("pubDate") ?? tag("updated") ?? ""))
            }
            search = search[close.upperBound...]
        }
        return out
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
    static func eventInRiskWords(_ event: String, severity: String,
                                 detail: String? = nil) -> String {
        guard !event.isEmpty, RiskEquations.alertFamily(event) == nil else { return event }
        let e = event.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        func has(_ words: [String]) -> Bool { words.contains { e.contains($0) } }
        let strong = ["severe", "extreme"].contains(severity.lowercased())
        if has(["ciclon", "huracan", "tormenta tropical", "depresion tropical", "tropical"]) {
            return strong ? "Tropical Storm Warning" : "Tropical Storm Watch"
        }
        if has(["small craft", "seas", "marine", "oleaje", "mar de fondo", "marejada", "surf"]) {
            return event
        }
        if has(["inunda", "riverine", "crecida", "desbordamiento"]) {
            return strong ? "Flood Warning" : "Flood Advisory"
        }
        if has(["lluvia", "rain"]) {
            if strong { return "Flood Warning" }
            return namesHeavyRain(event + " " + (detail ?? "")) ? "Flood Advisory" : "Rain Advisory"
        }
        if has(["nevada", "nieve", "aguanieve"]) { return "Winter Weather Advisory" }
        if has(["frente frio", "frio", "helada"]) { return "Cold Weather Advisory" }
        if has(["calor", "hot spell", "hot weather"]) { return "Heat Advisory" }
        if has(["viento", "gust"]) { return "Wind Advisory" }
        if has(["tormenta", "electrica", "granizo", "adverse weather"]) {
            return strong ? "Severe Thunderstorm Warning" : "Severe Thunderstorm Watch"
        }
        if has(["niebla", "neblina"]) { return "Dense Fog Advisory" }
        return event
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
    static func namesHeavyRain(_ text: String) -> Bool {
        let t = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        if ["muy fuerte", "intensa", "torrencial", "extraordinaria",
            "very heavy rain", "torrential", "extreme rain"].contains(where: t.contains) {
            return true
        }
        // "75 a 150 mm", "50-75 mm", "de 150 mm": the first figure of each.
        let pattern = #"(\d+(?:[.,]\d+)?)(?:\s*(?:a|to|-|–)\s*\d+(?:[.,]\d+)?)?\s*(?:mm|milimetros|millimeters|millimetres)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let whole = NSRange(t.startIndex..., in: t)
        return regex.matches(in: t, range: whole).contains { match in
            guard let r = Range(match.range(at: 1), in: t),
                  let amount = Double(t[r].replacingOccurrences(of: ",", with: "."))
            else { return false }
            return amount >= floodRainMillimetres
        }
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
    static func polygonCoords(_ raw: String) -> [CLLocationCoordinate2D] {
        // Any white space parts the pairs. A Windows line end is one
        // Character that is not "\n": two pairs joined by it failed to parse
        // and were dropped, leaving a ring of the wrong shape. And a ring
        // with a pair that cannot be read is no ring: a wrong shape can miss
        // the driver.
        var ring: [CLLocationCoordinate2D] = []
        for pair in raw.split(whereSeparator: \.isWhitespace) {
            let xy = pair.split(separator: ",")
            guard xy.count == 2, let lat = Double(xy[0]), let lon = Double(xy[1]) else { return [] }
            ring.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        return ring
    }

    static func parseCAP(_ raw: String) -> ParsedCAP? {
        // Some services write every tag with a prefix (`<cap:polygon>`,
        // Belize): read plain, their alerts had no shape and were dropped.
        let xml = raw.replacingOccurrences(of: "<cap:", with: "<")
            .replacingOccurrences(of: "</cap:", with: "</")
        // Not an alert file at all (an error page, a web page): unreadable.
        guard xml.contains("<alert") else { return nil }
        func tag(_ name: String) -> String? {
            guard let s = xml.range(of: "<\(name)>"),
                  let e = xml.range(of: "</\(name)>", range: s.upperBound..<xml.endIndex)
            else { return nil }
            return String(xml[s.upperBound..<e.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // ALL <polygon> occurrences, not just the first — CAP allows several
        // <area> blocks each with polygons, and services like SMN emit them
        // for warnings spanning disjoint regions. A ring needs ≥3 vertices to
        // enclose area; garbled sub-3-point rings are dropped (un-locatable),
        // so an alert with only garbled rings ends up with no polygons and the
        // caller's emptiness check rejects it.
        var rings: [[CLLocationCoordinate2D]] = []
        var search = xml[xml.startIndex...]
        while let s = search.range(of: "<polygon>"),
              let e = search.range(of: "</polygon>", range: s.upperBound..<search.endIndex) {
            let ring = polygonCoords(String(search[s.upperBound..<e.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines))
            if ring.count >= 3 { rings.append(ring) }
            search = search[e.upperBound...]
        }
        let status = tag("status")?.lowercased()
        let live = (status == nil || status == "actual")
            && tag("msgType")?.lowercased() != "cancel"
            && tag("responseType")?.lowercased() != "allclear"
        return ParsedCAP(
            event: tag("event") ?? "Weather alert",
            severity: tag("severity") ?? "Moderate",
            polygons: rings,
            areaDesc: tag("areaDesc"),
            expires: tag("expires"),
            effective: tag("effective") ?? tag("onset"),
            web: tag("web"),
            description: tag("description").map { String($0.prefix(280)) },
            isLive: live,
            identifier: tag("identifier"),
            // "sender,identifier,sent" triples, parted by white space.
            references: (tag("references") ?? "").split(whereSeparator: \.isWhitespace)
                .compactMap { ref in
                    let parts = ref.split(separator: ",")
                    return parts.count >= 2 ? String(parts[1]) : nil
                })
    }
}
