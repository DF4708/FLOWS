// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import FlowsBridge
import Foundation

/// Plain-words facts for the tourist stop card: what a place is, what it
/// costs to get in, and which hours line applies today. The rules run in
/// Rust (flows-core `tourist_info`, pinned by a frozen oracle of this file's
/// original Swift); Swift keeps the words, the bundled table and the name's
/// clean-up, whose diacritic folding is Foundation's own.
enum TouristInfo {
    /// National-park entry fees (NPS posted rates, per 7-day pass), bundled
    /// as nps_entry_fees.json. Keys are lowercase park names; notes are the
    /// exact plain-words line the card shows.
    struct FeeTable {
        let notes: [String: String]
        /// The keys in the order they cross to Rust, which answers an index.
        let keys: [String]
        let column: RustTextColumn

        init(notes: [String: String]) {
            self.notes = notes
            keys = Array(notes.keys)
            column = RustTextColumn(keys)
        }

        static func loadBundled() -> FeeTable {
            guard
                let url = Bundle.main.url(
                    forResource: "nps_entry_fees",
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

    static let parkDefault = "Free at most park spots. Big parks often charge for each car."
    static let siteDefault = "Free at most sites like this. Some charge a small fee."
    static let pricesVary = "Prices vary — check before you go."

    /// The card's "Cost to get in" line.
    ///   * National parks: the posted fee from the table ("$35 for each car" /
    ///     "Free to enter"), longest key wins so Glacier Bay never reads as
    ///     Glacier. Parks not in the table get the honest NPS default.
    ///   * Other national sites (monuments, memorials, seashores…): most are
    ///     free, some charge — say so.
    ///   * Everything else (museums, zoos, theme parks): prices vary.
    static func feeNote(name: String?, table: FeeTable) -> String {
        let n = normalized(name ?? "")
        let code = table.column.with { joined, lens, _ in
            flows_tourist_fee(n, joined, lens, Int64(table.keys.count))
        }
        switch code {
        case -1: return parkDefault
        case -2: return siteDefault
        case 0..<Int64(table.keys.count): return table.notes[table.keys[Int(code)]] ?? pricesVary
        default: return pricesVary
        }
    }

    /// The card header's words, in `tourist_info::Kind`'s order.
    static let kindWords = [
        "National park", "Museum", "Theme park", "Zoo", "Aquarium", "Park", "Landmark", "State park",
        "Monument", "Cave", "Waterfall", "Beach", "Trail", "Garden", "Place worth a stop",
    ]

    /// Plain-words kind for the card header. `categoryRaw` is the MapKit
    /// point-of-interest raw value when the result carries one; the name
    /// keywords cover offline-shard results that don't.
    static func plainKind(name: String?, categoryRaw: String?) -> String {
        let k = flows_tourist_kind(normalized(name ?? ""), categoryRaw ?? "", categoryRaw != nil)
        return kindWords.indices.contains(Int(k)) ? kindWords[Int(k)] : "Place worth a stop"
    }

    /// Google's hours lines come Monday-first; Calendar weekdays come
    /// 1 = Sunday. Map one to the other so "today" picks the right line.
    static func mondayFirstIndex(weekday: Int) -> Int {
        Int(flows_tourist_monday_first_index(Int64(weekday)))
    }
}
