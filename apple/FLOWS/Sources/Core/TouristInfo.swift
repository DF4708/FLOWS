// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Plain-words facts for the tourist stop card: what a place is, what it
/// costs to get in, and which hours line applies today. Pure and pinned by
/// FLOWSTests; the bundled NPS fee table plugs in at load time.
enum TouristInfo {
    /// National-park entry fees (NPS posted rates, per 7-day pass), bundled
    /// as nps_entry_fees.json. Keys are lowercase park names; notes are the
    /// exact plain-words line the card shows.
    struct FeeTable {
        let notes: [String: String]

        static func loadBundled() -> FeeTable {
            guard let url = Bundle.main.url(forResource: "nps_entry_fees",
                                            withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
            else { return FeeTable(notes: [:]) }
            var m: [String: String] = [:]
            for row in rows {
                guard let park = row["park"], let note = row["note"] else { continue }
                m[park] = note
            }
            return FeeTable(notes: m)
        }
    }

    /// Fold the messy parts of place names (Haleakalā, Wrangell–St. Elias)
    /// so table keys match what MKLocalSearch returns.
    static func normalized(_ name: String) -> String {
        name.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            .lowercased()
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
    }

    /// The card's "Cost to get in" line.
    ///   * National parks: the posted fee from the table ("$35 for each car" /
    ///     "Free to enter"), longest key wins so Glacier Bay never reads as
    ///     Glacier. Parks not in the table get the honest NPS default.
    ///   * Other national sites (monuments, memorials, seashores…): most are
    ///     free, some charge — say so.
    ///   * Everything else (museums, zoos, theme parks): prices vary.
    static func feeNote(name: String?, table: FeeTable) -> String {
        let n = normalized(name ?? "")
        if n.contains("national park") {
            let hit = table.notes
                .filter { n.contains($0.key) }
                .max { $0.key.count < $1.key.count }
            return hit?.value
                ?? "Free at most park spots. Big parks often charge for each car."
        }
        for site in ["national monument", "national memorial", "national historic",
                     "national historical", "national seashore", "national lakeshore",
                     "national recreation", "national battlefield", "national preserve"]
        where n.contains(site) {
            return "Free at most sites like this. Some charge a small fee."
        }
        return "Prices vary — check before you go."
    }

    /// Plain-words kind for the card header. `categoryRaw` is the MapKit
    /// point-of-interest raw value when the result carries one; the name
    /// keywords cover offline-shard results that don't.
    static func plainKind(name: String?, categoryRaw: String?) -> String {
        switch categoryRaw {
        case "MKPOICategoryNationalPark": return "National park"
        case "MKPOICategoryMuseum": return "Museum"
        case "MKPOICategoryAmusementPark": return "Theme park"
        case "MKPOICategoryZoo": return "Zoo"
        case "MKPOICategoryAquarium": return "Aquarium"
        case "MKPOICategoryPark": return "Park"
        case "MKPOICategoryLandmark": return "Landmark"
        default: break
        }
        let n = normalized(name ?? "")
        if n.contains("national park") { return "National park" }
        if n.contains("state park") { return "State park" }
        if n.contains("museum") { return "Museum" }
        if n.contains("zoo") { return "Zoo" }
        if n.contains("aquarium") { return "Aquarium" }
        if n.contains("monument") || n.contains("memorial") { return "Monument" }
        if n.contains("cave") || n.contains("cavern") { return "Cave" }
        if n.contains("falls") { return "Waterfall" }
        if n.contains("beach") { return "Beach" }
        if n.contains("trail") { return "Trail" }
        if n.contains("garden") { return "Garden" }
        if n.contains("park") { return "Park" }
        return "Place worth a stop"
    }

    /// Google's hours lines come Monday-first; Calendar weekdays come
    /// 1 = Sunday. Map one to the other so "today" picks the right line.
    static func mondayFirstIndex(weekday: Int) -> Int {
        ((weekday + 5) % 7)
    }
}
