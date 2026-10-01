// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Built-in facts about national chains — cost tiers, brand sites, gym
/// showers, paid-parking operators — plus name-based shelter typing. Fills
/// POI rows when no live ratings provider (Google Places / Yelp) key is
/// configured: a brand fact beats an empty "$" column, and the table works
/// offline. A provider answer always wins; this only fills gaps.
///
/// The tables and the matching live in rust/flows-core (places_text.rs),
/// called through rust/flows-bridge. Matching is case-insensitive on
/// standalone word runs, longest match wins: "Hilton Garden Inn" hits
/// "hilton garden inn" (not the shorter "hilton"); "Hiltonia Cafe" hits
/// nothing. Swift's own text rules — a character is a grapheme cluster, and
/// two spellings compare as one when they are canonically equivalent — are
/// reproduced in Rust and pinned to the original by
/// rust/flows-bridge/tests/fixtures/swift_places_text_oracle.tsv.
enum BrandKnowledge {

    /// The spoken-request matcher (Siri add-a-stop): true when the asked-for
    /// words appear contiguously, as standalone words, inside the place's
    /// name — "Starbucks" in "Starbucks Coffee", never "Star" in "Starbucks".
    static func askedName(_ asked: String, matches name: String) -> Bool {
        flows_places_text_asked_name_matches(asked, name)
    }

    /// Cost tier 1…5 ("$"…"$$$$$") for a known national brand; nil when the
    /// name matches no brand as a standalone word run.
    static func costTier(name: String) -> Int? {
        let tier = flows_places_text_cost_tier(name)
        return tier == 0 ? nil : Int(tier)
    }

    /// The brand's own site — hotel chains only, for the row's link slot.
    static func website(name: String) -> URL? {
        let site = flows_places_text_website(name).text
        return site.isEmpty ? nil : URL(string: site)
    }

    /// true = the chain provides showers; false = it does not; nil = brand
    /// unknown (say nothing rather than guess).
    static func gymHasShowers(name: String) -> Bool? {
        tri(flows_places_text_gym_has_showers(name))
    }

    /// true = costs money, false = free, nil = the name says neither.
    /// An explicit "free" wins over structure words — a lot named "Free
    /// Parking Garage" is advertising the price.
    static func parkingFee(name: String) -> Bool? {
        tri(flows_places_text_parking_fee(name))
    }

    /// Shelter type in plain words — from the result name first, the search
    /// query second. Anything else is the general case: a public building
    /// pressed into service is an "Emergency shelter".
    static func shelterType(name: String, query: String = "") -> String {
        let code = Int(flows_places_text_shelter_type(name, query))
        return shelterTypeNames.indices.contains(code) ? shelterTypeNames[code] : shelterTypeNames[4]
    }

    /// Private listings the shelter queries surface but a driver under a
    /// warning cannot use: animal/pet shelters and service offices.
    static func isShelterNoise(name: String) -> Bool {
        flows_places_text_is_shelter_noise(name)
    }

    /// The bridge's three-valued answer: -1 unknown, 0 no, 1 yes.
    private static func tri(_ v: Int32) -> Bool? { v < 0 ? nil : v == 1 }

    /// Shelter types by the bridge's code, the general case last.
    private static let shelterTypeNames = [
        "Storm shelter", "Flood shelter", "Cooling center", "Warming center", "Emergency shelter",
    ]
}

extension RustStringRef {
    /// The string, with the empty case answered here. An empty Rust string
    /// crosses with no storage behind it, and Foundation's decoder answers nil
    /// for that rather than "" — so every facade reads Rust text through this.
    var text: String { len() == 0 ? "" : as_str().toString() }
}

/// How a chain's name is written and the colours of its sign, for the stop
/// list's brand tile: the chain's initials in its own colours, never its
/// logo — logos are trademarked artwork FLOWS has no licence to copy, and a
/// coloured monogram tells the brands apart at a glance just the same. A
/// stop of no known brand gets a plain placeholder tile.
enum BrandMark {
    struct RGB: Equatable {
        let r: Double, g: Double, b: Double
        init(_ hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }
    }

    struct Mark: Equatable {
        /// The brand as it writes its own name ("BP", "CITGO", "Kwik Trip").
        let name: String
        /// What the tile says.
        let initials: String
        let background: RGB
        let ink: RGB
        /// What a gallon usually costs at this brand against the others, 1
        /// (warehouse clubs, discounters) to 5 — for a fuel row with no live
        /// price to compare. nil for a brand that sells no fuel.
        let fuelTier: Int?
    }

    /// Known chains, matched at the start of a name, longest key first.
    private static let marks: [(key: String, mark: Mark)] = [
        ("bp", Mark(name: "BP", initials: "BP", background: RGB(0x009B3A), ink: RGB(0xFFE600), fuelTier: 4)),
        ("shell", Mark(name: "Shell", initials: "S", background: RGB(0xFBCE07), ink: RGB(0xDD1D21), fuelTier: 4)),
        ("exxon", Mark(name: "Exxon", initials: "E", background: RGB(0xED1B2D), ink: RGB(0xFFFFFF), fuelTier: 4)),
        ("mobil", Mark(name: "Mobil", initials: "M", background: RGB(0x0A4595), ink: RGB(0xFFFFFF), fuelTier: 4)),
        ("chevron", Mark(name: "Chevron", initials: "C", background: RGB(0x0054A4), ink: RGB(0xFFFFFF), fuelTier: 4)),
        ("texaco", Mark(name: "Texaco", initials: "T", background: RGB(0xE51937), ink: RGB(0xFFFFFF), fuelTier: 4)),
        ("marathon", Mark(name: "Marathon", initials: "M", background: RGB(0xE31837), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("speedway", Mark(name: "Speedway", initials: "S", background: RGB(0xE21E26), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("citgo", Mark(name: "CITGO", initials: "C", background: RGB(0xD71920), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("sunoco", Mark(name: "Sunoco", initials: "S", background: RGB(0x003DA5), ink: RGB(0xFFD100), fuelTier: 3)),
        ("phillips 66", Mark(name: "Phillips 66", initials: "66", background: RGB(0xED1C24), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("76", Mark(name: "76", initials: "76", background: RGB(0xF58220), ink: RGB(0x003DA5), fuelTier: 4)),
        ("conoco", Mark(name: "Conoco", initials: "C", background: RGB(0xE31B23), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("valero", Mark(name: "Valero", initials: "V", background: RGB(0x0072BC), ink: RGB(0xFFD200), fuelTier: 3)),
        ("arco", Mark(name: "ARCO", initials: "A", background: RGB(0x0060A9), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("sinclair", Mark(name: "Sinclair", initials: "S", background: RGB(0x00843D), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("casey's", Mark(name: "Casey's", initials: "C", background: RGB(0xD71921), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("caseys", Mark(name: "Casey's", initials: "C", background: RGB(0xD71921), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("kwik trip", Mark(name: "Kwik Trip", initials: "KT", background: RGB(0xD2202F), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("kwik star", Mark(name: "Kwik Star", initials: "KS", background: RGB(0xD2202F), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("holiday", Mark(name: "Holiday", initials: "H", background: RGB(0x00529B), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("quiktrip", Mark(name: "QuikTrip", initials: "QT", background: RGB(0xDA291C), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("wawa", Mark(name: "Wawa", initials: "W", background: RGB(0xDA291C), ink: RGB(0xFFD100), fuelTier: 2)),
        ("sheetz", Mark(name: "Sheetz", initials: "S", background: RGB(0xDA291C), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("circle k", Mark(name: "Circle K", initials: "K", background: RGB(0xEE2E24), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("kum & go", Mark(name: "Kum & Go", initials: "KG", background: RGB(0x00843D), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("love's", Mark(name: "Love's", initials: "L", background: RGB(0xE31837), ink: RGB(0xFFD200), fuelTier: 3)),
        ("loves", Mark(name: "Love's", initials: "L", background: RGB(0xE31837), ink: RGB(0xFFD200), fuelTier: 3)),
        ("pilot", Mark(name: "Pilot", initials: "P", background: RGB(0xE21836), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("flying j", Mark(name: "Flying J", initials: "FJ", background: RGB(0xE21836), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("travelcenters of america", Mark(name: "TA", initials: "TA", background: RGB(0x003B71), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("ta ", Mark(name: "TA", initials: "TA", background: RGB(0x003B71), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("petro", Mark(name: "Petro", initials: "P", background: RGB(0x00467F), ink: RGB(0xFFFFFF), fuelTier: 3)),
        ("murphy usa", Mark(name: "Murphy USA", initials: "M", background: RGB(0x003DA5), ink: RGB(0xFFFFFF), fuelTier: 1)),
        ("costco", Mark(name: "Costco", initials: "C", background: RGB(0xE31837), ink: RGB(0xFFFFFF), fuelTier: 1)),
        ("sam's club", Mark(name: "Sam's Club", initials: "S", background: RGB(0x0067A0), ink: RGB(0xFFFFFF), fuelTier: 1)),
        ("bj's", Mark(name: "BJ's", initials: "BJ", background: RGB(0xD71920), ink: RGB(0xFFFFFF), fuelTier: 1)),
        ("kroger", Mark(name: "Kroger", initials: "K", background: RGB(0x0F4C98), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("meijer", Mark(name: "Meijer", initials: "M", background: RGB(0xE31837), ink: RGB(0xFFFFFF), fuelTier: 2)),
        ("starbucks", Mark(name: "Starbucks", initials: "S", background: RGB(0x00704A), ink: RGB(0xFFFFFF), fuelTier: nil)),
        ("mcdonald's", Mark(name: "McDonald's", initials: "M", background: RGB(0xDA291C), ink: RGB(0xFFC72C), fuelTier: nil)),
        ("mcdonalds", Mark(name: "McDonald's", initials: "M", background: RGB(0xDA291C), ink: RGB(0xFFC72C), fuelTier: nil)),
        ("dunkin", Mark(name: "Dunkin'", initials: "D", background: RGB(0xFF671F), ink: RGB(0xFFFFFF), fuelTier: nil)),
        ("subway", Mark(name: "Subway", initials: "S", background: RGB(0x008C15), ink: RGB(0xFFC20E), fuelTier: nil)),
        ("taco bell", Mark(name: "Taco Bell", initials: "TB", background: RGB(0x702082), ink: RGB(0xFFFFFF), fuelTier: nil)),
        ("wendy's", Mark(name: "Wendy's", initials: "W", background: RGB(0xE2203D), ink: RGB(0xFFFFFF), fuelTier: nil)),
        ("burger king", Mark(name: "Burger King", initials: "BK", background: RGB(0xD62300), ink: RGB(0xF5EBDC), fuelTier: nil)),
        ("culver's", Mark(name: "Culver's", initials: "C", background: RGB(0x005696), ink: RGB(0xFFFFFF), fuelTier: nil)),
        ("chick-fil-a", Mark(name: "Chick-fil-A", initials: "C", background: RGB(0xE51636), ink: RGB(0xFFFFFF), fuelTier: nil)),
    ].sorted { $0.key.count > $1.key.count }

    /// The known chain a place's name starts with, nil for any other.
    static func mark(for name: String) -> Mark? { match(name)?.mark }

    /// The name as the chain writes it: the map gives some in lower case
    /// ("bp") — the brand's own spelling replaces that leading word.
    static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let (key, mark) = match(trimmed) else { return name }
        return mark.name + trimmed.dropFirst(key.count)
    }

    /// The chain and the key that named it: the key must start the name as
    /// a whole word — "bp" names "bp", "bp Gas" and "BP #2231", never
    /// "Bpm Cafe".
    private static func match(_ name: String) -> (key: String, mark: Mark)? {
        prefixMatch(name, in: marks).map { ($0.key, $0.value) }
    }

    /// The first entry (tables are sorted longest key first) whose key
    /// starts the name as a whole word.
    private static func prefixMatch<T>(_ name: String,
                                       in table: [(key: String, mark: T)]) -> (key: String, value: T)? {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        for entry in table {
            let key = entry.key.trimmingCharacters(in: .whitespaces)
            guard lower.hasPrefix(key) else { continue }
            let rest = lower.dropFirst(key.count)
            if rest.isEmpty || !(rest.first?.isLetter ?? false) { return (key, entry.mark) }
        }
        return nil
    }

    /// The major chains whose official logo the stop list shows (owner,
    /// 2026-10-01), by the brand's own web domain — what the logo service
    /// (BrandLogos, Brandfetch) looks a logo up by. Local businesses are not
    /// here: they get their own initials (LocalMarks). Matched like `marks`.
    private static let logoDomains: [(key: String, mark: String)] = [
        // Fuel
        ("bp", "bp.com"), ("shell", "shell.us"), ("exxon", "exxon.com"),
        ("mobil", "mobil.com"), ("chevron", "chevron.com"), ("texaco", "texaco.com"),
        ("marathon", "marathonbrand.com"), ("speedway", "speedway.com"),
        ("citgo", "citgo.com"), ("sunoco", "sunoco.com"),
        ("phillips 66", "phillips66gas.com"), ("76", "76.com"), ("conoco", "conoco.com"),
        ("valero", "valero.com"), ("arco", "arco.com"), ("sinclair", "sinclairoil.com"),
        ("casey's", "caseys.com"), ("caseys", "caseys.com"),
        ("kwik trip", "kwiktrip.com"), ("kwik star", "kwiktrip.com"),
        ("holiday", "holidaystationstores.com"), ("quiktrip", "quiktrip.com"),
        ("wawa", "wawa.com"), ("sheetz", "sheetz.com"), ("circle k", "circlek.com"),
        ("kum & go", "kumandgo.com"), ("love's", "loves.com"), ("loves", "loves.com"),
        ("pilot", "pilotflyingj.com"), ("flying j", "pilotflyingj.com"),
        ("travelcenters of america", "ta-petro.com"), ("ta ", "ta-petro.com"),
        ("petro", "ta-petro.com"), ("murphy usa", "murphyusa.com"),
        ("buc-ee's", "buc-ees.com"), ("7-eleven", "7-eleven.com"),
        // Charging
        ("tesla", "tesla.com"), ("electrify america", "electrifyamerica.com"),
        ("chargepoint", "chargepoint.com"), ("evgo", "evgo.com"),
        // Food and coffee
        ("starbucks", "starbucks.com"), ("mcdonald's", "mcdonalds.com"),
        ("mcdonalds", "mcdonalds.com"), ("dunkin", "dunkindonuts.com"),
        ("subway", "subway.com"), ("taco bell", "tacobell.com"), ("wendy's", "wendys.com"),
        ("burger king", "bk.com"), ("culver's", "culvers.com"), ("chick-fil-a", "chick-fil-a.com"),
        ("kfc", "kfc.com"), ("pizza hut", "pizzahut.com"), ("domino's", "dominos.com"),
        ("papa john's", "papajohns.com"), ("little caesars", "littlecaesars.com"),
        ("arby's", "arbys.com"), ("sonic", "sonicdrivein.com"), ("dairy queen", "dairyqueen.com"),
        ("jimmy john's", "jimmyjohns.com"), ("jersey mike's", "jerseymikes.com"),
        ("panda express", "pandaexpress.com"), ("five guys", "fiveguys.com"),
        ("popeyes", "popeyes.com"), ("chipotle", "chipotle.com"), ("panera", "panerabread.com"),
        ("qdoba", "qdoba.com"), ("whataburger", "whataburger.com"), ("in-n-out", "in-n-out.com"),
        ("tim hortons", "timhortons.com"), ("krispy kreme", "krispykreme.com"),
        ("raising cane's", "raisingcanes.com"), ("wingstop", "wingstop.com"),
        ("hardee's", "hardees.com"), ("carl's jr", "carlsjr.com"), ("jack in the box", "jackinthebox.com"),
        ("steak 'n shake", "steaknshake.com"), ("waffle house", "wafflehouse.com"),
        ("denny's", "dennys.com"), ("ihop", "ihop.com"), ("cracker barrel", "crackerbarrel.com"),
        ("applebee's", "applebees.com"), ("olive garden", "olivegarden.com"),
        ("buffalo wild wings", "buffalowildwings.com"), ("bob evans", "bobevans.com"),
        ("noodles & company", "noodles.com"), ("firehouse subs", "firehousesubs.com"),
        ("zaxby's", "zaxbys.com"), ("caribou coffee", "cariboucoffee.com"),
        // Stores
        ("walmart", "walmart.com"), ("target", "target.com"), ("costco", "costco.com"),
        ("sam's club", "samsclub.com"), ("bj's", "bjs.com"), ("the home depot", "homedepot.com"),
        ("home depot", "homedepot.com"), ("lowe's", "lowes.com"), ("menards", "menards.com"),
        ("best buy", "bestbuy.com"), ("cvs", "cvs.com"), ("walgreens", "walgreens.com"),
        ("rite aid", "riteaid.com"), ("dollar general", "dollargeneral.com"),
        ("family dollar", "familydollar.com"), ("dollar tree", "dollartree.com"),
        ("aldi", "aldi.us"), ("trader joe's", "traderjoes.com"),
        ("whole foods", "wholefoodsmarket.com"), ("hy-vee", "hy-vee.com"),
        ("publix", "publix.com"), ("safeway", "safeway.com"), ("kroger", "kroger.com"),
        ("meijer", "meijer.com"), ("kohl's", "kohls.com"), ("tj maxx", "tjmaxx.com"),
        ("marshalls", "marshalls.com"), ("ross dress for less", "rossstores.com"), ("petsmart", "petsmart.com"),
        ("petco", "petco.com"), ("autozone", "autozone.com"), ("o'reilly", "oreillyauto.com"),
        ("advance auto parts", "advanceautoparts.com"), ("napa auto parts", "napaonline.com"),
        ("tractor supply", "tractorsupply.com"), ("harbor freight", "harborfreight.com"),
        ("gamestop", "gamestop.com"), ("staples", "staples.com"), ("office depot", "officedepot.com"),
        ("ulta", "ulta.com"), ("dick's sporting goods", "dickssportinggoods.com"),
        ("cabela's", "cabelas.com"), ("bass pro", "basspro.com"), ("ikea", "ikea.com"),
        ("macy's", "macys.com"), ("jcpenney", "jcpenney.com"), ("michaels", "michaels.com"),
        ("hobby lobby", "hobbylobby.com"),
        // Hotels
        ("marriott", "marriott.com"), ("courtyard by marriott", "marriott.com"), ("hilton", "hilton.com"),
        ("hampton inn", "hilton.com"), ("holiday inn", "ihg.com"), ("hyatt", "hyatt.com"),
        ("best western", "bestwestern.com"), ("comfort inn", "choicehotels.com"),
        ("comfort suites", "choicehotels.com"), ("quality inn", "choicehotels.com"),
        ("super 8", "wyndhamhotels.com"), ("days inn", "wyndhamhotels.com"),
        ("la quinta", "wyndhamhotels.com"), ("ramada", "wyndhamhotels.com"),
        ("motel 6", "motel6.com"), ("red roof", "redroof.com"),
    ].sorted { $0.key.count > $1.key.count }

    /// The official web domain of the major chain a place's name starts
    /// with — the logo lookup's key — nil for a local business.
    static func logoDomain(for name: String) -> String? {
        prefixMatch(name, in: logoDomains)?.value
    }

    /// The Brandfetch client ID the app ships with (Info.plist
    /// FLOWSBrandfetchClientID, the owner's free developer account) — empty
    /// until set, and then no logo is asked for: every tile keeps its
    /// initials.
    static var logoClientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "FLOWSBrandfetchClientID") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// A chain's official logo, square, from Brandfetch's free Logo API —
    /// loaded straight into the tile, never saved (its terms forbid keeping
    /// copies). "fallback/404" makes an unknown brand fail, so the initials
    /// stay rather than a stand-in letter of theirs.
    static func logoURL(for name: String, clientID: String = logoClientID,
                        pixels: Int = 96) -> URL? {
        guard !clientID.isEmpty, let domain = logoDomain(for: name),
              let id = clientID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "https://cdn.brandfetch.io/domain/\(domain)/w/\(pixels)/h/\(pixels)"
                   + "/fallback/404/type/icon?c=\(id)")
    }

    /// Price tiers 1–5 by where each live price sits between the cheapest
    /// and dearest in the list — nil for a row without a live price, and for
    /// all of them when the prices don't differ.
    static func comparativeTiers(_ prices: [Double?]) -> [Int?] {
        let known = prices.compactMap { $0 }
        guard let lo = known.min(), let hi = known.max(), hi - lo >= 0.01 else {
            return prices.map { _ in nil }
        }
        return prices.map { p in p.map { 1 + Int((($0 - lo) / (hi - lo) * 4).rounded()) } }
    }
}

/// Tiles for local businesses (owner, 2026-10-01): a coloured background with
/// two contrasting initials, chosen so no two places in the same list share
/// both. The initials come from the name's first two words; the colour from
/// the name itself, moved on to the next free one when a neighbour in the
/// list already holds that pair.
enum LocalMarks {
    struct Mark: Equatable {
        let initials: String
        let background: BrandMark.RGB
        let ink: BrandMark.RGB
    }

    /// Twelve backgrounds far enough apart to tell at a glance, each with the
    /// ink that reads on it.
    static let palette: [(background: BrandMark.RGB, ink: BrandMark.RGB)] = [
        (BrandMark.RGB(0xC62828), BrandMark.RGB(0xFFFFFF)),   // red
        (BrandMark.RGB(0x1565C0), BrandMark.RGB(0xFFFFFF)),   // blue
        (BrandMark.RGB(0x2E7D32), BrandMark.RGB(0xFFFFFF)),   // green
        (BrandMark.RGB(0x6A1B9A), BrandMark.RGB(0xFFFFFF)),   // purple
        (BrandMark.RGB(0xE65100), BrandMark.RGB(0xFFFFFF)),   // orange
        (BrandMark.RGB(0x00838F), BrandMark.RGB(0xFFFFFF)),   // teal
        (BrandMark.RGB(0x4E342E), BrandMark.RGB(0xFFFFFF)),   // brown
        (BrandMark.RGB(0xAD1457), BrandMark.RGB(0xFFFFFF)),   // pink
        (BrandMark.RGB(0x283593), BrandMark.RGB(0xFFFFFF)),   // indigo
        (BrandMark.RGB(0xF9A825), BrandMark.RGB(0x1A1A1A)),   // amber
        (BrandMark.RGB(0x558B2F), BrandMark.RGB(0xFFFFFF)),   // olive
        (BrandMark.RGB(0x37474F), BrandMark.RGB(0xFFFFFF)),   // slate
    ]

    /// Words that don't name a place: "The Corner Cafe" is "CC".
    private static let skipped: Set<String> = ["the", "a", "an", "and", "&", "of",
                                               "at", "on", "in", "de", "la", "el", "le"]

    /// Initials to try, best first: the first letters of the first two words,
    /// then of the first and last words, then the first two letters of the
    /// first word.
    static func initialCandidates(_ name: String) -> [String] {
        let words = name
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
        let named = words.filter { !skipped.contains($0.lowercased()) }
        let use = named.isEmpty ? words : named
        guard let first = use.first else { return ["?"] }
        func letter(_ w: String) -> String { String(w.prefix(1)).uppercased() }
        var out: [String] = []
        if use.count >= 2 { out.append(letter(first) + letter(use[1])) }
        if use.count >= 3, let last = use.last { out.append(letter(first) + letter(last)) }
        if first.count >= 2 { out.append(String(first.prefix(2)).uppercased()) }
        if out.isEmpty { out.append(letter(first)) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// The same number for the same name on every launch (Swift's own hash
    /// is reseeded each run): djb2 over the lowercased UTF-8.
    static func stableHash(_ name: String) -> Int {
        var h: UInt64 = 5381
        for byte in name.lowercased().utf8 { h = (h &* 33) &+ UInt64(byte) }
        return Int(h % UInt64(Int.max))
    }

    /// One mark per name, in list order: no two share initials AND colour.
    static func assign(_ names: [String]) -> [Mark] {
        var used = Set<String>()
        return names.map { name in
            let candidates = initialCandidates(name)
            let start = stableHash(name) % palette.count
            var chosen: (initials: String, color: Int)?
            search: for initials in candidates {
                for step in 0..<palette.count {
                    let color = (start + step) % palette.count
                    if !used.contains("\(initials)|\(color)") {
                        chosen = (initials, color)
                        break search
                    }
                }
            }
            let pick = chosen ?? (candidates[0], start)
            used.insert("\(pick.initials)|\(pick.color)")
            return Mark(initials: pick.initials, background: palette[pick.color].background,
                        ink: palette[pick.color].ink)
        }
    }
}
