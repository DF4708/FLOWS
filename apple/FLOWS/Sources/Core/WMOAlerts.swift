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
            return f.code
        }
        return nil
    }

    static func rssURL(code: String) -> URL? {
        URL(string: "https://severeweather.wmo.int/v2/cap-alerts/\(code)/rss.xml")
    }

    struct RSSItem { let link: String; let event: String; let severity: String; let expires: String }

    /// Flat scan of the RSS `<item>` blocks (event/severity/expires inline;
    /// the `<link>` points at the full CAP file with the geometry).
    static func parseRSSItems(_ xml: String) -> [RSSItem] {
        var out: [RSSItem] = []
        var search = xml[xml.startIndex...]
        while let open = search.range(of: "<item>"),
              let close = search.range(of: "</item>", range: open.upperBound..<search.endIndex) {
            let body = String(search[open.upperBound..<close.lowerBound])
            func tag(_ name: String) -> String? {
                guard let s = body.range(of: "<\(name)>"),
                      let e = body.range(of: "</\(name)>", range: s.upperBound..<body.endIndex)
                else { return nil }
                return String(body[s.upperBound..<e.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let link = tag("link"), link.hasSuffix(".xml") {
                out.append(RSSItem(link: link,
                                   event: tag("cap:event") ?? tag("title") ?? "Weather alert",
                                   severity: tag("cap:severity") ?? "Moderate",
                                   expires: tag("cap:expires") ?? ""))
            }
            search = search[close.upperBound...]
        }
        return out
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
    }

    /// CAP `<polygon>` is space-separated `lat,lon` pairs (note: lat FIRST,
    /// unlike GeoJSON).
    static func polygonCoords(_ raw: String) -> [CLLocationCoordinate2D] {
        raw.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { pair in
            let xy = pair.split(separator: ",")
            guard xy.count == 2, let lat = Double(xy[0]), let lon = Double(xy[1]) else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    static func parseCAP(_ xml: String) -> ParsedCAP? {
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
        return ParsedCAP(
            event: tag("event") ?? "Weather alert",
            severity: tag("severity") ?? "Moderate",
            polygons: rings,
            areaDesc: tag("areaDesc"),
            expires: tag("expires"),
            effective: tag("effective") ?? tag("onset"),
            web: tag("web"),
            description: tag("description").map { String($0.prefix(280)) })
    }
}
