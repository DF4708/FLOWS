import Foundation

// Frozen oracle: every output below comes from the ORIGINAL Swift `TouristInfo` (TouristInfo.swift), compiled with
// the test target's own Core sources at the base commit. Text is its UTF-8 in hex, nil is "-".
//
// Kinds: t id, keys, notes (a fee table, its entries in UTF-8 byte order of their keys, each list joined by ",") |
// f table id, name, normalized(name), feeNote | k name, categoryRaw, normalized(name), plainKind |
// d weekday, mondayFirstIndex.
//
// A fee record is left out when the name is a national park's and two of the longest keys it holds are the same
// length: the original's pick between them followed the dictionary's order, which changes from run to run. The
// count of such records goes to stderr.

func th(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }
func optText(_ s: String?) -> String { s.map(th) ?? "-" }

struct SM {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
    mutating func chance(_ n: Int) -> Bool { below(n) == 0 }
}

// Keys beyond the bundled table's: empty and blank keys, keys that hold other keys, case, canonically equal
// spellings (one dictionary key), marks, joiners, emoji, Hangul, and letters that change when lowercased.
let ODD_KEYS: [String] = [
    "", " ", "park", "national park", "national", "glacier", "glacier bay", "bay", "zion", "zion ", "e\u{301}",
    "\u{E9}", "-", "st. elias", "wrangell-st. elias", "wrangell\u{2013}st. elias", "Glacier", "glacier\u{200D}",
    "\u{1F3DE}", "\u{AC00}", "ss", "\u{DF}", "i\u{307}", "\u{FB01}", "fi", "k", "\u{212A}", "olympic", "redwood",
    "arches", "acadia", "big", "big bend", "bend", "a", "aa", "n", "national park ", "\u{1F1FA}\u{1F1F8}",
    "haleakala", "haleakal\u{101}", "great smoky mountains", "smoky", "yellowstone", "stone", "grand canyon",
    "canyon", "kings canyon", "\u{0915}\u{094D}", "x\u{308}", "\u{FF5A}\u{FF49}\u{FF4F}\u{FF4E}",
]

// Words a place name is built from: park names come from the tables; these are the rest.
let WORDS: [String] = [
    "National Park", "National Park and Preserve", "national park", "NATIONAL PARK", "National  Park",
    "Nationalpark", "National\u{A0}Park", "Nati\u{F6}nal Park", "Nat\u{131}onal Park", "National Pa\u{301}rk",
    "National Monument", "National Memorial", "National Historic Site", "National Historical Park",
    "National Seashore", "National Lakeshore", "National Recreation Area", "National Battlefield",
    "National Preserve", "National Monument and Preserve", "State Park", "State  Park", "Museum", "MUSEUM",
    "Mus\u{E9}um", "\u{FF2D}\u{FF55}\u{FF53}\u{FF45}\u{FF55}\u{FF4D}", "Zoo", "Zo\u{F6}", "Z\u{200D}oo", "Aquarium",
    "Cave", "Caverns", "Cavern", "Falls", "Beach", "Trail", "Trails", "Garden", "Gardens", "Park", "P\u{E1}rk",
    "Memorial", "Monument", "Mall", "Cafe", "Caf\u{E9}", "Ruby", "Mystery Spot", "the", "of", "&", "\u{2014}",
    "\u{2013}", "-", "St.", "Big", "Old", "\u{130}stanbul", "Stra\u{DF}e", "\u{FB01}sh", "\u{1F3DE}\u{FE0F}",
    "\u{1F44D}\u{1F3FD}", "\u{1F1FA}\u{1F1F8}", "\u{AC00}", "\u{0915}\u{094D}\u{0937}", "e\u{301}", "\u{2126}",
    "\u{212B}ngstr\u{F6}m", "\u{212A}elvin", "Na\u{308}tional", "zoological", "parkway", "falls\u{301}", "",
]

// Scalars dropped into names at random places.
let STRAY: [UInt32] = [
    0x301, 0x308, 0x304, 0x323, 0x200D, 0xFE0F, 0x1F3FB, 0x2013, 0x2014, 0x20, 0x2D, 0xA0, 0x130, 0x131, 0xDF,
    0x212A, 0x212B, 0x3099, 0x94D, 0xE9, 0xC5, 0x41, 0x7A, 0xAC00, 0x1161, 0x1F1FA,
]

let CATEGORIES: [String] = [
    "MKPOICategoryNationalPark", "MKPOICategoryMuseum", "MKPOICategoryAmusementPark", "MKPOICategoryZoo",
    "MKPOICategoryAquarium", "MKPOICategoryPark", "MKPOICategoryLandmark", "MKPOICategoryCafe",
    "MKPOICategoryBeach", "MKPOICategoryCampground", "mkpoicategorypark", "MKPOICategoryPark ",
    "MKPOICategoryPa\u{301}rk", "MKPOICategoryPark\u{301}", "", "MKPOICategory", "National park",
    "MKPOICategoryNationalMonument", "M\u{212A}POICategoryPark", "M\u{212A}POICategoryNationalPark",
]

@main
@MainActor
enum Oracle {
    static var rng = SM(s: 0x544F_5552_4953_5449)  // "TOURISTI"
    static var out = ""
    static var ties = 0
    static func emit(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }

    static func bytesBefore(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

    static func table(_ id: Int, _ m: [String: String]) -> TouristInfo.FeeTable {
        let keys = m.keys.sorted(by: bytesBefore)
        emit(["t", "\(id)", keys.map(th).joined(separator: ","), keys.map { th(m[$0]!) }.joined(separator: ",")])
        return TouristInfo.FeeTable(notes: m)
    }

    /// A park name as a search might spell it: case, marks, long dashes.
    static func respell(_ key: String) -> String {
        var s = key
        switch rng.below(4) {
        case 0: s = s.capitalized
        case 1: s = s.uppercased()
        default: break
        }
        if rng.chance(3) { s = s.replacingOccurrences(of: "a", with: rng.pick(["\u{101}", "a\u{304}", "\u{E1}", "a"])) }
        if rng.chance(3) { s = s.replacingOccurrences(of: "-", with: rng.pick(["\u{2013}", "\u{2014}", " - ", ""])) }
        if rng.chance(4) { s = s.replacingOccurrences(of: " ", with: rng.pick(["", "  ", "\u{A0}", "-"])) }
        return s
    }

    static func name(_ parks: [String], park: Bool = false) -> String? {
        if rng.chance(40) { return nil }
        var parts: [String] = []
        for _ in 0..<(1 + rng.below(4)) {
            parts.append(rng.chance(2) && !parks.isEmpty ? respell(rng.pick(parks)) : rng.pick(WORDS))
        }
        if park { parts.append(rng.pick(["National Park", "national park", "NATIONAL PARK", "National Park and Preserve", "Nati\u{F6}nal Park"])) }
        var s = parts.joined(separator: rng.pick([" ", " ", " ", "", "-", "\u{2013}"]))
        if rng.chance(5) {
            var v = Array(s.unicodeScalars)
            v.insert(Unicode.Scalar(rng.pick(STRAY))!, at: rng.below(v.count + 1))
            var view = String.UnicodeScalarView()
            view.append(contentsOf: v)
            s = String(view)
        }
        return s
    }

    static func feeRecord(_ id: Int, _ t: TouristInfo.FeeTable, _ name: String?) {
        let n = TouristInfo.normalized(name ?? "")
        if n.contains("national park") {
            let hits = t.notes.keys.filter { n.contains($0) }
            if let top = hits.map(\.count).max(), hits.filter({ $0.count == top }).count > 1 {
                ties += 1
                return
            }
        }
        emit(["f", "\(id)", optText(name), th(n), th(TouristInfo.feeNote(name: name, table: t))])
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3, let data = FileManager.default.contents(atPath: args[2]),
            let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else {
            FileHandle.standardError.write(Data("usage: oracle out.tsv nps_entry_fees.json\n".utf8))
            exit(2)
        }
        // The bundled table, read as `loadBundled` reads it.
        var bundled: [String: String] = [:]
        for row in rows {
            guard let park = row["park"], let note = row["note"] else { continue }
            bundled[park] = note
        }
        let parkNames = bundled.keys.sorted(by: bytesBefore)

        var tables: [(Int, TouristInfo.FeeTable, [String])] = []
        tables.append((0, table(0, bundled), parkNames))
        let unitTable = [
            "yellowstone": "$35 for each car", "glacier": "$35 for each car", "glacier bay": "Free to enter",
            "great smoky mountains": "Free to enter (parking tags cost extra)",
        ]
        tables.append((1, table(1, unitTable), unitTable.keys.sorted(by: bytesBefore)))
        var odd: [String: String] = [:]
        for (i, k) in ODD_KEYS.enumerated() { odd[k] = "odd \(i)" }
        tables.append((2, table(2, odd), ODD_KEYS))
        tables.append((3, table(3, [:]), parkNames))
        let pool = parkNames + ODD_KEYS
        for id in 4..<14 {
            var m: [String: String] = [:]
            for j in 0..<(1 + rng.below(12)) { m[rng.pick(pool)] = "t\(id) n\(j)" }
            tables.append((id, table(id, m), m.keys.sorted(by: bytesBefore)))
        }

        // Fee lines: the unit test's names, then built names against every table.
        for (id, t, _) in tables.prefix(4) {
            for nm in [
                "Yellowstone National Park", "Great Smoky Mountains National Park", "Glacier Bay National Park",
                "Glacier National Park", "Imaginary National Park", "Devils Tower National Monument",
                "City Science Museum", "Haleakal\u{101} National Park", "Wrangell\u{2013}St. Elias National Park",
                "", "National Park",
            ] { feeRecord(id, t, nm) }
            feeRecord(id, t, nil)
        }
        for i in 0..<4000 {
            let (id, t, keys) = i % 3 == 0 ? tables[0] : tables[rng.below(tables.count)]
            feeRecord(id, t, name(rng.chance(3) ? parkNames : keys, park: !rng.chance(3)))
        }

        // Kinds.
        for _ in 0..<2500 {
            let nm = name(parkNames)
            let cat: String? = rng.chance(2) ? nil : rng.pick(CATEGORIES)
            emit([
                "k", optText(nm), optText(cat), th(TouristInfo.normalized(nm ?? "")),
                th(TouristInfo.plainKind(name: nm, categoryRaw: cat)),
            ])
        }
        // Each name word with a scalar glued to its end that folding may keep, so a word that ends inside a
        // bigger Character is pinned.
        for w in [
            "national park", "state park", "museum", "zoo", "aquarium", "monument", "memorial", "cave", "cavern",
            "falls", "beach", "trail", "garden", "park",
        ] {
            for g in ["\u{200D}", "\u{FE0F}", "\u{1F3FB}", "\u{301}", "\u{94D}", "\u{20DD}"] {
                for nm in [w + g, "x" + w + g + "y"] {
                    emit(["k", th(nm), "-", th(TouristInfo.normalized(nm)), th(TouristInfo.plainKind(name: nm, categoryRaw: nil))])
                }
            }
        }

        // Weekdays: the calendar's, around them, and the extremes Swift's `+ 5` does not trap on.
        var days = Array(-30...30)
        days += [Int.min, Int.min + 1, Int.min + 6, Int.max - 5, Int.max - 6, Int.max - 12, 1 << 40, -(1 << 40)]
        for d in days { emit(["d", "\(d)", "\(TouristInfo.mondayFirstIndex(weekday: d))"]) }

        FileHandle.standardError.write(Data("fee records left out (tied keys): \(ties)\n".utf8))
        FileManager.default.createFile(atPath: args[1], contents: Data(out.utf8))
    }
}
