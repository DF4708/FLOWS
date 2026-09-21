import CoreLocation
import Foundation
import MapKit
// Frozen oracle: every output below comes from the ORIGINAL CoordinateInput, RecentDestinations and
// DestinationSearch.blend (DestinationSearch.swift), TransitPlanning and RentalCars (TransitItinerary.swift) and
// TruckerRadio's static rules (TruckerRadio.swift) at c206b98, before their facade switch, linked against the Rust
// bridge for the facades those files already call. Doubles are IEEE-754 bit patterns in hex; a Date is its
// timeIntervalSinceReferenceDate; text is "t:" + UTF-8 with bytes outside 0x20...0x7E, and the backslash, as \xx; nil
// is "-"; lists are "L<n>:" + rows joined with U+001E, a row's fields joined with U+001F.

func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func ht(_ s: String) -> String {
    var o = "t:"
    for b in s.utf8 {
        if b >= 0x20, b <= 0x7E, b != 0x5C { o.unicodeScalars.append(Unicode.Scalar(b)) }
        else { o += "\\" + String(format: "%02x", b) }
    }
    return o
}
func hdo(_ d: Double?) -> String { d.map(hx) ?? "-" }
func hto(_ s: String?) -> String { s.map(ht) ?? "-" }
func b(_ v: Bool) -> String { v ? "1" : "0" }
let FS = "\u{1F}", RS = "\u{1E}"
func rows(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: RS) }
typealias C = CLLocationCoordinate2D
func at(_ t: Double) -> Date { Date(timeIntervalSinceReferenceDate: t) }
func tisr(_ d: Date) -> String { hx(d.timeIntervalSinceReferenceDate) }
var out = ""
func emit(_ f: String...) { out += f.joined(separator: "\t") + "\n" }

struct SM { var s: UInt64
  mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
  mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
  mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + unit() * (hi - lo) }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
  mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
  mutating func chance(_ n: Int) -> Bool { below(n) == 0 } }
var rng = SM(s: 0x5245434E54524944)   // "RECNTRID"
let SPECIAL: [Double] = [.nan, .infinity, -.infinity, -0.0, 0, .greatestFiniteMagnitude, .leastNonzeroMagnitude]
func dv(_ lo: Double, _ hi: Double, _ extra: [Double] = []) -> Double {
    if rng.chance(8) { return rng.pick(SPECIAL + extra) }
    if !extra.isEmpty, rng.chance(4) { return rng.pick(extra) }
    return rng.range(lo, hi)
}

// ===================================================================== CoordinateInput
var coordTexts: [String] = [
    "43.0731, -89.4012", "43.0731 -89.4012", "43.0731;-89.4012", "43.0731N 89.4012W", "N 43.0731 W 89.4012",
    "43.0731 N 89.4012 W", "89.4012W 43.0731N", "33.8688S 151.2093E", "  43.0731 , -89.4012  ",
    "Madison", "Madison WI", "43.0731", "1600 Pennsylvania Ave", "43.0731, -89.4012, 10", "91.0, -89.4",
    "43.0, -181.0", "43.0731N 89.4012N", "N43W 89.4", "", "  ",
    "90 180", "-90 -180", "90.0000001 0", "0 180.0000001", "nan 0", "0 inf", "inf inf", "0x1p3 4", "0X1p3 4",
    "1e2 3", "1e 3", "+43 +89", "43. .5", "4\u{0}3 5", "43°N 89°W", "43° N, 89° W", "n 43 w 89", "s43 e89",
    "ß43 89", "43ß 89", "N\u{301}43 89", "43 89\u{301}", "43\u{A0}89", "43\t89", "43\n89", "N N 43 89", "43 N N 89",
    "E 43 N 89", "43 E 89 E", "W43 S89", "٤٣ ٨٩", "４３ ８９", "1_000 2", "43,,,89", ";43;89;", "°43°89°",
    "NS 43 89", "N 43 89 W", "43 89 N", "N", "43 N", "ﬁ 43 89", "Ｎ43 89", "-0 -0", "-0.0N 0W", "nan(12) 1",
    "snan 1", "0x1.8p1 2", "1e400 1", "1e-400 1", "N-43 W-89", "S-43 E-89", "43N89W", "N 43 N", "W 43 89",
]
let numberTokens = ["43.0731", "-89.4012", "0", "-0", "90", "-90", "180", "-180", "90.0000001", "180.0000001",
                    "1e2", "1e-2", "nan", "inf", "-inf", "infinity", "0x1p3", ".5", "5.", "+7", "12_3", "٤", "１",
                    "1e", "--1", "4\u{301}", "12.5", "-45.25", "89.999", "179.5"]
let letterTokens = ["N", "S", "E", "W", "n", "s", "e", "w", "NE", "ß", "N\u{301}", "Ｎ", "ﬁ", "°", ";", ",", "x"]
let separators = [" ", ",", ", ", ";", "  ", "\t", "\u{A0}", "°", " \u{301}", "", " , "]
for _ in 0..<3_000 {
    var s = ""
    let n = rng.below(5)
    for i in 0..<n {
        if i > 0 { s += rng.pick(separators) }
        switch rng.below(4) {
        case 0: s += rng.pick(letterTokens)
        case 1: s += rng.pick(letterTokens) + rng.pick(numberTokens)
        case 2: s += rng.pick(numberTokens) + rng.pick(letterTokens)
        default: s += rng.pick(numberTokens)
        }
    }
    if rng.chance(10) { s = " " + s + " " }
    coordTexts.append(s)
}
for _ in 0..<600 {
    let lat = rng.range(-95, 95), lon = rng.range(-185, 185)
    let la = rng.chance(2) ? "\(lat)" : String(format: "%.4f", lat)
    let lo = rng.chance(2) ? "\(lon)" : String(format: "%.4f", lon)
    switch rng.below(5) {
    case 0: coordTexts.append("\(la), \(lo)")
    case 1: coordTexts.append("\(abs(lat))\(lat < 0 ? "S" : "N") \(abs(lon))\(lon < 0 ? "W" : "E")")
    case 2: coordTexts.append("\(lat < 0 ? "S" : "N") \(abs(lat)) \(lon < 0 ? "W" : "E") \(abs(lon))")
    case 3: coordTexts.append("\(abs(lon))\(lon < 0 ? "W" : "E") \(abs(lat))\(lat < 0 ? "S" : "N")")
    default: coordTexts.append("\(la);\(lo)")
    }
}
for t in coordTexts {
    let c = CoordinateInput.parse(t)
    emit("ci-parse", ht(t), c.map { hx($0.latitude) + "/" + hx($0.longitude) } ?? "-")
}

// ===================================================================== RecentDestinations
typealias Entry = RecentDestinations.Entry
func entryOut(_ e: Entry) -> String {
    [ht(e.name), hx(e.latitude), hx(e.longitude), tisr(e.lastUsed), String(e.uses)].joined(separator: FS)
}
let names: [String] = [
    "Madison", "madison", "MADISON", " Madison", "Madison ", "\tMadison", "Café", "Cafe\u{301}", "CAFÉ", "Straße",
    "STRASSE", "strasse", "İstanbul", "i\u{307}stanbul", "istanbul", "ǅemal", "ǆemal", "Ω Club", "\u{2126} Club",
    "Å Park", "\u{212B} Park", "Current Location", "current location", "CURRENT LOCATION", " current location ",
    "Current\u{A0}Location", "Current Location\n", "", " ", "\t", "Home", "Work", "Sun Prairie", "sun prairie",
    "ΟΔΟΣ", "οδος", "🏠 Home", "🇺🇸 Base", "e\u{301}\u{301}", "ﬁsh fry", "FISH FRY", "Fish Fry", "Kwik Trip #402",
    "Kwik Trip #403", "Mall of America", "\u{301}Start", "ma", "MA", "prairie",
]
emit("rd-consts", String(RecentDestinations.cap))
let ages: [Double] = [0, 3_600, 86_400, 86_400 * 13.9, 86_400 * 14, 86_400 * 30, 86_400 * 400, -86_400, 1e300]
func dateNear(_ now: Double) -> Double {
    if rng.chance(12) { return rng.pick(SPECIAL) }
    return now - rng.pick(ages) * (rng.chance(3) ? rng.unit() : 1)
}
let usesPool = [0, 1, 1, 2, 3, 5, 8, 20, 1000, -1, -7]
func someNow() -> Double { rng.chance(15) ? rng.pick(SPECIAL) : rng.range(7e8, 8e8) }
for _ in 0..<600 {
    let now = someNow()
    let uses = rng.chance(20) ? rng.pick([Int.max, Int.min]) : rng.pick(usesPool)
    let e = Entry(name: "x", latitude: 0, longitude: 0, lastUsed: at(dateNear(now)), uses: uses)
    emit("rd-score", String(uses), tisr(e.lastUsed), hx(now), hx(RecentDestinations.score(e, now: at(now))))
}
func randomEntry(_ now: Double) -> Entry {
    Entry(name: rng.pick(names), latitude: dv(-90, 90), longitude: dv(-180, 180),
          lastUsed: at(dateNear(now)), uses: rng.pick(usesPool))
}
for k in 0..<700 {
    let now = someNow()
    let n = k < 40 ? rng.pick([19, 20, 21, 25, 40]) : rng.below(8)
    let list = (0..<n).map { _ in randomEntry(now) }
    var new = randomEntry(now)
    new.uses = 1
    let merged = RecentDestinations.merged(list, adding: new, now: at(now))
    emit("rd-merged", rows(list.map(entryOut)), entryOut(new), hx(now), rows(merged.map(entryOut)))
}
let fragments = ["", " ", "ma", "MA", "Ma", "madison", "café", "cafe\u{301}", "CAFE", "str", "strasse", "ß", "i\u{307}",
                 "ist", "ω", "\u{2126}", "å", "home", " home ", "\thome", "o", "prairie", "#40", "🏠", "e\u{301}", "\u{301}",
                 "fish", "ﬁ", "current", "zz"]
MainActor.assumeIsolated {
    for k in 0..<60 {
        // SecureBehaviorStore is a stub: this directory is never read or written.
        let store = RecentDestinations(directory: URL(fileURLWithPath: "/nonexistent/flows-oracle"))
        var now = rng.range(7e8, 8e8)
        let steps = k < 10 ? 45 : 1 + rng.below(20)
        for s in 0..<steps {
            now += rng.pick([0, 60, 3_600, 86_400, 86_400 * 7, 86_400 * 30, -3_600])
            var name = rng.pick(names)
            if rng.chance(6) { name = rng.pick([" ", "\t", "\u{A0}", "\n"]) + name + rng.pick(["", " ", "\t"]) }
            let lat = dv(-90, 90), lon = dv(-180, 180)
            store.record(name: name, coordinate: C(latitude: lat, longitude: lon), now: at(now))
            let entries = (s % 5 == 4 || s == steps - 1) ? rows(store.entries.map(entryOut)) : "~"
            emit("rd-store", String(k), String(s), ht(name), hx(lat), hx(lon), hx(now), entries)
        }
        for _ in 0..<8 {
            let f = rng.pick(fragments)
            let limit = rng.pick([0, 1, 3, 3, 5, 25])
            emit("rd-match", String(k), ht(f), String(limit), rows(store.matching(f, limit: limit).map(entryOut)))
        }
    }
}

// ===================================================================== DestinationSearch.blend
typealias Sug = DestinationSearch.Suggestion
let titles = names + ["Publix Super Market", "publix super market", "160 Convention Center Dr",
                      "Map point 43.0731, -89.4012", "PUBLIX SUPER MARKET"]
let pinnedKinds: [Sug.Kind] = [.recent, .predicted, .coordinate, .completion]
for _ in 0..<900 {
    let pinned = (0..<rng.below(6)).map { _ in
        Sug(title: rng.pick(titles), subtitle: "Recent", kind: rng.pick(pinnedKinds)) }
    let completions = (0..<rng.below(9)).map { _ in Sug(title: rng.pick(titles), subtitle: "Augusta, GA") }
    let cap = rng.below(11)
    let blended = DestinationSearch.blend(pinned: pinned, completions: completions, cap: cap)
    let origin = blended.map { s -> String in
        if let i = pinned.firstIndex(where: { $0.id == s.id }) { return "p\(i)" }
        return "c\(completions.firstIndex(where: { $0.id == s.id })!)"
    }
    emit("ds-blend", rows(pinned.map { ht($0.title) }), rows(completions.map { ht($0.title) }), String(cap),
         rows(origin))
}

// ===================================================================== TransitPlanning
let modes = ["Amtrak", "Greyhound", "Rail", "Bus", "amtrak", "AMTRAK", "Amtrak ", " Rail", "", "Ferry",
             "Greyhound\u{200D}", "Rai\u{301}l", "Ｒａｉｌ", "Plane"]
for _ in 0..<700 {
    let mode = rng.pick(modes)
    let drive: Double? = rng.chance(4) ? nil : dv(0, 200_000, [0, -1, 1])
    let miles = dv(0, 3_000, [0, -5, 1])
    emit("tp-ride", ht(mode), hdo(drive), hx(miles), hx(TransitPlanning.rideMultiplier(mode)),
         hx(TransitPlanning.fallbackMPH(mode)),
         hx(TransitPlanning.rideDuration(mode: mode, driveSeconds: drive, miles: miles)))
}

// ===================================================================== RentalCars
emit("rc-consts", rows(RentalCars.brandOrder.map(ht)))
var rentalNames: [String?] = [
    nil, "", "Enterprise Rent-A-Car", "ENTERPRISE", "enterprise holdings", "Hertz", "Hertz Car Rental - Columbia Airport",
    "hertz", "Avis Car Rental", "AVIS Budget Group", "Budget", "National Car Rental", "Nationals Park Garage",
    "Alamo Rent A Car", "Sixt rent a car", "Thrifty", "Dollar Rent A Car", "Dollarama", "Zipcar", "Turo host",
    "U-Haul Moving", "UHaul", "U\u{2010}Haul", "Bob's Rent-a-Wreck", "Carol's Cars", "Enterprisé", "Enterprise\u{301}",
    "ＨＥＲＴＺ", "İHertz", "Kiss Rent a Car", "Avisha Motors", "ALAMO", "thrifty-dollar", "Budgetel Inn",
    "Sixty Six Rentals", "Café Cars", "Cafe\u{301} Cars", "CAFÉ CARS", "ß Rentals", "SS Rentals", "Car rental",
    "e\u{301}nterprise", "HERTZ\u{301}", "sixt\u{200D}", "zip car", "tu ro",
]
let brandPieces = ["enterprise", "hertz", "avis", "budget", "national", "alamo", "sixt", "thrifty", "dollar",
                   "zipcar", "turo", "u-haul", "rent", "car", "é", "\u{301}", "İ", "ß"]
for _ in 0..<400 {
    var s = ""
    for _ in 0..<(1 + rng.below(3)) {
        var piece = rng.pick(brandPieces)
        if rng.chance(3) { piece = piece.uppercased() }
        s += piece + rng.pick(["", " ", "-", "\u{301}"])
    }
    rentalNames.append(s)
}
for n in rentalNames {
    emit("rc-rank", hto(n), String(RentalCars.brandRank(name: n)),
         RentalCars.bookingURL(name: n).map { ht($0.absoluteString) } ?? "-")
}
typealias Office = RentalCars.Office
func officeOut(_ o: Office) -> String { ht(o.name) + FS + hx(o.miles) }
/// Swift's order is fixed only inside a brand group whose miles all order strictly; any other group comes out in
/// Dictionary order, which moves with the hash seed. Those groups are written sorted by name bytes, then miles bits,
/// and the record says so.
func canonical(_ picks: [Office]) -> (text: [String], tiedRanges: [Range<Int>]) {
    var text: [String] = []
    var tied: [Range<Int>] = []
    var i = 0
    while i < picks.count {
        let rank = RentalCars.brandRank(name: picks[i].name)
        var j = i
        while j < picks.count, RentalCars.brandRank(name: picks[j].name) == rank { j += 1 }
        let group = Array(picks[i..<j])
        var strict = true
        for x in 0..<group.count { for y in (x + 1)..<max(group.count, x + 1) where !(group[x].miles < group[y].miles) && !(group[y].miles < group[x].miles) { strict = false } }
        if strict {
            text += group.map(officeOut)
        } else {
            tied.append(i..<j)
            text += group.map(officeOut).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        }
        i = j
    }
    return (text, tied)
}
for k in 0..<900 {
    let n = rng.below(k < 60 ? 30 : 10)
    let offices = (0..<n).map { _ in
        Office(name: rng.pick(rentalNames.compactMap { $0 }),
               miles: rng.chance(6) ? rng.pick([.nan, 0, -0.0, 1, .infinity]) : Double(rng.below(20)) * 0.5,
               url: nil)
    }
    let limit = rng.pick([0, 1, 2, 3, 3, 3, 5, 50])
    let full = canonical(RentalCars.recommend(offices, limit: Int.max))
    let limited = RentalCars.recommend(offices, limit: limit)
    let cutsTie = full.tiedRanges.contains { $0.lowerBound < limited.count && limited.count < $0.upperBound }
    emit("rc-recommend", rows(offices.map(officeOut)), String(limit), rows(full.text),
         cutsTie ? "X\(limited.count)" : rows(canonical(limited).text))
}

// ===================================================================== TruckerRadio
MainActor.assumeIsolated {
    let guideNames = TruckerRadio.frequencyGuide.map(\.0)
    emit("tr-guide", rows(TruckerRadio.frequencyGuide.map { ht($0.0) + FS + ht($0.1) }))
    let radioNames = guideNames + [
        "CB 19", "CB 190 test", "CB 1", "cb 19 (27.185 MHz)", "CB 9\u{301}", "CB 9", "NOAA", "noaa",
        "NOAA WX IL-Dixon: KZZ55", "Highway Advisory", "Highway", "", "ＣＢ 19", "CB 17", "CB 170",
        "Highway Advisory 530/1610 kHz AM\u{301}", "\u{301}CB 19", "CB 1\u{301}9", "NOAA\u{301}", "Highway Advisor",
    ]
    for n in radioNames {
        emit("tr-purpose", ht(n), ht(TruckerRadio.shortPurpose(n)), hto(TruckerRadio.carBandLabel(n)))
    }
}
for i in -6...6 {
    for c in -3...8 {
        for s in [-25, -13, -7, -3, -1, 0, 1, 2, 3, 7, 13, 25] {
            emit("tr-advance", String(i), String(c), String(s), String(TruckerRadio.advance(index: i, count: c, by: s)))
        }
    }
}
var stationNames = [
    "AL-Mobile: KEC61", "NOAA WX AL-Mobile: KEC61", "NOAA WX IL-Dixon: KZZ55", "al-mobile", "ALA-Mobile", "A-L",
    "-AL", "AL\u{2010}Mobile", "", "NOAA WX ", "NOAA WX NOAA WX WI-Madison", "noaa wx WI-Madison", "e\u{301}x-Foo",
    "ΑΒ-Αθήνα", "ß1-x", "i\u{307}s-x", "WI-", "WI-Madison-East", "ZZ-Nowhere", "PR-San Juan", "DC-Washington",
    "NOAA WXWI-Madison", "🇺🇸-x", "W\u{301}I-x", "wi-madison", "Ｗ Ｉ-x", "XX-", "GU-Guam", "AK-Anchorage",
    "HI-Honolulu", "NOAA  WX WI-x", "ǅ-x", "ﬁ-x", "W-I-x", "WI -x", " WI-x",
]
stationNames += LiveHazardFeedFetcher.stateBBoxes.keys.sorted().map { $0 + "-Test" }
stationNames += LiveHazardFeedFetcher.stateBBoxes.keys.sorted().map { "NOAA WX " + $0.lowercased() + "-Test" }
let coordinatePairs: [(Double?, Double?)] = [(nil, nil), (43.1, nil), (nil, -89.4), (43.1, -89.4), (.nan, 1.0),
                                            (-0.0, .infinity)]
for name in stationNames {
    for (la, lo) in coordinatePairs {
        let channel = TruckerRadio.Channel(name: name, detail: "", url: "", latitude: la, longitude: lo)
        let p = TruckerRadio.position(of: channel)
        emit("tr-state", ht(name), hdo(la), hdo(lo), hto(TruckerRadio.stateCode(of: channel)),
             p.map { hx($0.coordinate.latitude) + "/" + hx($0.coordinate.longitude) + "/" + b($0.isExact) } ?? "-")
    }
}

try! out.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
