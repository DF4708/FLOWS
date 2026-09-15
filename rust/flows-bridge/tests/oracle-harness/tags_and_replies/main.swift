import CoreLocation
import Foundation
// Frozen oracle: every output below comes from the ORIGINAL RouteAttributes, VehicleLink, VoiceReply (YesNoWords,
// VoiceCommands, VoicePick), BroadcastRadio and RadioBrowser before their facade switch, linked against the Rust bridge
// for the facades they already call (BrandKnowledge.askedName, POIRanking). Doubles are IEEE-754 bit patterns in hex;
// text is "t:" + UTF-8 with bytes outside 0x20...0x7E, and the backslash, as \xx; nil is "-"; lists are "N<n>:" +
// items joined by U+001E, an item's fields by U+001F; index lists are "L<n>:" + comma-joined.

func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func ht(_ s: String) -> String {
    var o = "t:"
    for b in s.utf8 {
        if b >= 0x20, b <= 0x7E, b != 0x5C { o.unicodeScalars.append(Unicode.Scalar(b)) }
        else { o += "\\" + String(format: "%02x", b) }
    }
    return o
}
func hto(_ s: String?) -> String { s.map(ht) ?? "-" }
func hdo(_ d: Double?) -> String { d.map(hx) ?? "-" }
func b(_ v: Bool) -> String { v ? "1" : "0" }
func bo(_ v: Bool?) -> String { v.map(b) ?? "-" }
let FS = "\u{1F}", RS = "\u{1E}"
func items(_ a: [String]) -> String { "N\(a.count):" + a.joined(separator: RS) }
func lst(_ a: [Int]) -> String { "L\(a.count):" + a.map(String.init).joined(separator: ",") }
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
var rng = SM(s: 0x574F524454414753)   // "WORDTAGS"
let SPECIAL: [Double] = [.nan, .infinity, -.infinity, -0.0, 0, .greatestFiniteMagnitude, .leastNonzeroMagnitude]
/// Two to four pool entries glued with a random joiner: odd spacing, punctuation and marks between real words.
func glue(_ pool: [String], _ joiners: [String] = ["", " ", "  ", ", ", "-", "\u{A0}", "\n", ".", "'"]) -> String {
    (0..<rng.pick([1, 2, 2, 3, 4])).map { _ in rng.pick(pool) }.joined(separator: rng.pick(joiners))
}
let marks = ["", "\u{301}", "\u{200D}", "\u{FE0F}", "\u{0}", "\u{2028}", "\u{3000}"]

// ===================================================================== Character.isLetter, over every scalar
// The spoken-reply splitter and the mirror check read `isLetter`, which the runtime answers from the Alphabetic
// property (numbers such as U+216B are letters too). Emitted as the ranges of scalars whose one-scalar Character is a
// letter, so the Rust table is generated from this record and checked against it.
do {
    var ranges: [String] = []
    var start: UInt32? = nil
    for v in UInt32(0)...0x10FFFF {
        let isLetter = Unicode.Scalar(v).map { Character($0).isLetter } ?? false
        if isLetter, start == nil { start = v }
        if !isLetter, let s = start { ranges.append(String(s, radix: 16) + "-" + String(v - 1, radix: 16)); start = nil }
    }
    if let s = start { ranges.append(String(s, radix: 16) + "-10ffff") }
    emit("u-letter", String(ranges.count), ranges.joined(separator: ","))
}

// ===================================================================== RouteAttributes
for k in 0..<500 {
    let n = rng.pick([0, 1, 2, 3, 5, 12])
    let elevations: [Double?] = (0..<n).map { _ in
        rng.chance(6) ? nil : (rng.chance(10) ? rng.pick(SPECIAL) : rng.range(-50, 3_000))
    }
    let spacing = k < 60 ? rng.pick(SPECIAL + [-1, 1, 1_200]) : rng.pick([1, 50, 1_200, rng.range(0.001, 5_000)])
    emit("ra-grade", "N\(n):" + elevations.map(hdo).joined(separator: ","), hx(spacing),
         hdo(RouteAttributes.maxGradePercent(elevations: elevations, spacingMeters: spacing)))
}
let clearancePool = ["4.1", "4.1 m", "13'6\"", "13 ft", "13 feet", "3,5 m", "default", "none", "unsigned", "", " 4 m ",
    "4.1m", "4.1 metres", "4.1meters", "4.1 metre", "4.1 meter", "13'", "13'6", "13' 6\"", "'6\"", "abc", "4.1 mm", "m",
    "4,1,2 m", "1e3", "0x10", "inf", "nan", " 13 FT", "13ft 6in", "\u{FF14}.\u{FF11}", "4.1\u{301} m", "13\u{2019}6\"",
    "13\u{2032}6\u{2033}", "4.1 m\n", "\t4.1", "- 4", "+4.5", ".5", "5.", "13'6\"\"", "13'x", "4.1\u{A0}m", "4.1 \u{2003}m",
    "DEFAULT", "None", "13'6 \"", "12'11\"", "14'", "4.115", "4.114", "3 metres", "10 FT", "10ft", "feet", "ft", "4 M",
    "13'-6\"", "13 ' 6", "13''", "1'2'3", "4.5 m ", "4.5m\u{301}", "ｍ", "4.5ｍ", "2.5 m.", "4 1/2 ft", "13.5'", "1,5", ","]
var clearances = clearancePool
for _ in 0..<300 { clearances.append(glue(clearancePool, ["", " ", "'", "\"", ",", "."]) + rng.pick(marks)) }
for t in clearances { emit("ra-clear", ht(t), hdo(RouteAttributes.clearanceMeters(fromOSM: t))) }
let weightPool = ["7.5", "7.5 t", "3,5", "10000 lbs", "5 st", "3500 kg", "10 tons", "10 ton", "2 tonnes", "2 tonne", "lb",
    "5lb", "t", "st", "7.5t", "default", "none", "", "12 short tons", "1e2 t", "abc", "44000lbs", "3.5 T", " 7.5 ", "est",
    "7,5,0", "\u{BD} t", "7.5\u{301} t", "unsigned", "10 TONS", "8.5 tonnes ", "80000 LBS", "36287 kg", "0", "-3 t",
    "3 lbs.", "3t\u{A0}", "\u{A0}3t", "40 st", "40st", "4.5 mt", "4.5 cwt", "NaN t", "inf lbs", "0x1p3 t", "3. t", ".5t",
    "20 ton ", "1,000 kg", "1.000,5 t", "7\u{FF0E}5", "ﬆ", "5 ﬆ"]
var weights = weightPool
for _ in 0..<300 { weights.append(glue(weightPool, ["", " ", ","]) + rng.pick(marks)) }
for t in weights { emit("ra-weight", ht(t), hdo(RouteAttributes.weightLimitLbs(fromOSM: t))) }
let zonePool = ["A", "AE", "AO", "VE", "V", "X", "x", " a", "ae", "", "D", "\u{130}", "\u{C5}A", "a\u{301}", "\u{FB00}",
    "\u{DF}", "\u{A0}A", "\nA", "\tVE", "0.2 PCT ANNUAL CHANCE FLOOD HAZARD", "AREA NOT INCLUDED", "OPEN WATER", "v", "\u{24B6}",
    "\u{FF21}", "A99", "AH", "VE ", "  x", "\u{3000}A", "\u{2003}v"]
var zones = zonePool
for _ in 0..<80 { zones.append(glue(zonePool, ["", " ", "\u{A0}"]) + rng.pick(marks)) }
for z in zones { emit("ra-flood", ht(z), b(RouteAttributes.isHighRiskFloodZone(z))) }
emit("ra-consts", hx(RouteAttributes.lowClearanceThresholdMeters), hx(RouteAttributes.weightLimitCapLbs))

// ===================================================================== VehicleLink
let tpmsNames: [String?] = [nil, "TPMS1_ABC123", "tpms2_x", "TPMS", "TPMS\u{301}1", "\u{FF34}\u{FF30}\u{FF2D}\u{FF33}1",
    "tpm\u{17F}1_A", "TPMS1\u{301}_A", "TPMSe\u{301}", "TPMS4", "TPMS\u{1F697}", "BR TPMS1", "", " TPMS3", "TPMS12_X",
    "tpms", "TPMSX", "TPMS\r\n", "TPMS\u{200D}9", "\u{130}TPMS"]
func hexBytes(_ d: Data?) -> String { d.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "-" }
let pressureRaws: [UInt32] = [0, 20_684, 20_685, 20_700, 1_378_946, 1_378_947, 1_379_000, 241_317, 700_000, UInt32.max, 1]
for k in 0..<700 {
    let name = rng.pick(tpmsNames)
    var data: Data? = nil
    if !rng.chance(12) {
        let count = rng.pick([0, 8, 12, 15, 16, 16, 16, 20, 24])
        var bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        if count >= 16 {
            let raw = k % 3 == 0 ? UInt32(truncatingIfNeeded: rng.next()) : rng.pick(pressureRaws)
            let t = Int32(truncatingIfNeeded: rng.chance(3) ? Int64(rng.below(8_000)) - 4_000 : Int64(bitPattern: rng.next()))
            withUnsafeBytes(of: raw.littleEndian) { for (i, v) in $0.enumerated() { bytes[8 + i] = v } }
            withUnsafeBytes(of: t.littleEndian) { for (i, v) in $0.enumerated() { bytes[12 + i] = v } }
        }
        data = Data(bytes)
    }
    let parsed = VehicleLink.parseTPMSAdvertisement(name: name, manufacturerData: data)
    emit("vl-tpms", hto(name), hexBytes(data),
         parsed.map { [ht($0.id), hx($0.psi), hx($0.celsius), hx(($0.psi * 10).rounded() / 10)].joined(separator: FS) } ?? "-")
}
let fuelPool = ["41 2F 80", "412F80", "41 2f 80\r>", "SEARCHING...\r41 2F FF\r\r>", "41 2F", "41 2F 8", "41 2F GG", "7F 01 12",
    "", "412F 80 00", "41 2F \u{FF18}0", "41 2F 8\u{301}0", "4\u{FF11}2F80", "41\u{A0}2F80", "412F412F12", "\u{DF}412F80",
    "\u{FB00}412F80", "41 2F 00", "41 2F ff", "NO DATA", "41 2F 1", ">", "41 2F 80 41 2F 40", "412F-1", "412F+1", "412F0x",
    "41 2F 8 0", "41\t2F80", "41 2F 80\u{0}", "41 2F 80\u{301}", "4 1 2 F 3 3", "412F\u{1F600}9", "BUS INIT: ...OK\r41 2F 2A",
    "41 2Ｆ 80", "41 2F 7F"]
var fuelLines = fuelPool
for _ in 0..<250 { fuelLines.append(glue(fuelPool, ["", " ", "\r", "\r\n"]) + rng.pick(marks)) }
for l in fuelLines { emit("vl-fuel", ht(l), hdo(VehicleLink.parseFuelReply(l))) }
let obdNames = ["OBDII", "obd2", "V-LINK", "vLinker MC+", "Veepeak OBDCheck", "ELM327 v1.5", "IOS-Vlink", "Car Stereo",
    "", "TPMS1_A", "\u{D3}BD", "O\u{301}BD", "OBD\u{301}", "Elm", "HELMET", "ELM\u{130}", "vl\u{130}nk", "VEEPEAK", "Kiwi 3",
    "\u{1F697} obd", "O B D"]
var adapters = obdNames
for _ in 0..<60 { adapters.append(glue(obdNames, ["", " ", "-"]) + rng.pick(marks)) }
for name in adapters {
    // Verbatim from VehicleLink.centralManager(_:didDiscover:advertisementData:rssi:) at the base commit.
    let lower = (Optional(name) ?? "").lowercased()
    let looks = lower.contains("obd") || lower.contains("vlink")
        || lower.contains("veepeak") || lower.contains("elm")
    emit("vl-obd", ht(name), b(looks))
}
emit("vl-consts", hx(VehicleLink.lowPressurePsi))

// ===================================================================== VoiceReply
let replyPool = ["yes", "Yes!", "yeah, no", "no thanks", "ok", "okay then", "go ahead", "take it", "please", "I don't know",
    "don't", "dont", "keep this route please", "not now", "never mind", "nevermind", "YES", "y\u{E9}s", "ye\u{301}s", "noah",
    "nope.", "sure thing", "affirmative", "negative", "stay", "stayed", "no-go", "yes-no", "\u{FF39}\u{FF45}\u{FF53}",
    "\u{130} yes", "go  ahead", "go\u{A0}ahead", "GO AHEAD", "take it easy", "don\u{2019}t", "can't", "o'k", "yes\nno", "",
    "   ", "ok\u{200D}", "ok\u{301}", "\u{FB01}ne", "YEAH", "yep yep", "yup", "do it", "nah", "cancel that", "never mind that",
    "N\u{D3}", "no\u{301}", "okay.", "ok?", "k", "okey", "sure", "unsure", "insure", "pleased", "weather", "NOAA radio",
    "the weather channel", "w\u{E9}ather", "WEATHER", "noa\u{301}a", "\u{FF2E}\u{FF2F}\u{FF21}\u{FF21}", "back", "go back",
    "start over", "different", "something else", "change it", "other food", "backup", "go  back", "Taco Bell", "taco bell please",
    "El Rays", "burger king", "fast food", "Mexican", "actually mexican", "the second one", "caf\u{E9} rio", "Cafe\u{301} Rio",
    "El Rays or Taco Bell", "McDonald's", "mcdonalds", "Chick-fil-A", "chick fil a", "italian", "Ital\u{301}ian", "rio"]
var replies = replyPool
for _ in 0..<500 { replies.append(glue(replyPool)) }
for r in replies {
    emit("yn", ht(r), bo(YesNoWords.interpret(r)), b(VoiceCommands.wantsWeatherRadio(r)))
}
emit("yn-words", items(YesNoWords.yesWords.map(ht)), items(YesNoWords.noWords.map(ht)), items(VoicePick.backWords.map(ht)))
let optionPool = ["Taco Bell", "El Rays", "McDonald's", "Burger King", "fast food", "Caf\u{E9} Rio", "Chick-fil-A", "", "a",
    "Rio", "Bell", "Mexican", "Italian", "Chinese", "Thai", "El", "The Diner", "diner", "Taco", "Ital\u{301}ian", "\u{1F32E}",
    "Kwik Trip", "Culver's", "Culvers", "Mc Donald's"]
func outcome(_ o: VoicePick.Outcome) -> String {
    switch o { case .picked(let i): return "p\(i)"; case .declined: return "d"; case .unclear: return "u" }
}
func placeOutcome(_ o: VoicePick.PlaceOutcome) -> String {
    switch o {
    case .picked(let i): return "p\(i)"; case .switchCuisine(let i): return "s\(i)"
    case .backToCuisine: return "b"; case .declined: return "d"; case .unclear: return "u"
    }
}
for _ in 0..<900 {
    let reply = rng.chance(3) ? rng.pick(replies) : glue(replyPool + optionPool)
    let options = (0..<rng.pick([0, 1, 2, 3, 4])).map { _ in rng.pick(optionPool) }
    emit("vp-choose", ht(reply), items(options.map(ht)), outcome(VoicePick.choose(reply: reply, options: options)))
    let cuisines = (0..<rng.pick([0, 1, 2, 3])).map { _ in rng.pick(optionPool) }
    emit("vp-place", ht(reply), items(options.map(ht)), items(cuisines.map(ht)),
         placeOutcome(VoicePick.placeReply(reply, places: options, cuisines: cuisines)))
}

// ===================================================================== BroadcastRadio
let kinds = BroadcastRadio.Kind.allCases
func kindCode(_ k: BroadcastRadio.Kind?) -> String { k.map { String(kinds.firstIndex(of: $0)!) } ?? "-" }
emit("br-kinds", items(kinds.map { ([$0.rawValue] + $0.tagWords).map(ht).joined(separator: FS) }),
     lst(BroadcastRadio.Kind.matchOrder.map { kinds.firstIndex(of: $0)! }))
let tagPool = ["Classic Rock", "christian rock", "sports talk", "News/Talk", "top 40,pop", "Hip-Hop", "R&B", "rnb",
    "Regional Mexican", "Espa\u{F1}ol", "espan\u{303}ol", "ESPA\u{D1}OL", "jazz,blues", "bluegrass", "", "  ", "electronic",
    "contemporary", "contempo", "classic hits", "80s", "doo-wop", "motown", "catholic", "religious", "religio", "symphony",
    "orchestra", "npr", "public radio", "information", "politics", "honky tonk", "western", "punk", "indie", "house", "chart",
    "\u{CD}NDIE", "\u{130}ndie", "SPORT", "sportswear", "passport", "rap", "trap", "therapy", "soul", "funk", "urban",
    "rhythm", "nostalgia", "adult hits", "hits", "dance", "worship", "gospel", "salsa", "ranchera", "tejano", "banda",
    "reggaeton", "latin", "baroque", "opera", "big band", "swing", "bebop", "americana", "metal", "grunge", "alternative",
    "top40", "current affairs", "classical", "country", "news", "talk", "pop", "oldies", "50s", "60s", "70s", "espanol",
    "hiphop", "hip hop", "r\u{26}b", "cla\u{301}ssical", "\u{FF52}\u{FF4F}\u{FF43}\u{FF4B}", "ro\u{200D}ck", "k-pop", "j-pop"]
var tagSets = tagPool
for _ in 0..<700 { tagSets.append(glue(tagPool, [",", ", ", " ", "", ";", "/"]) + rng.pick(marks)) }
for t in tagSets { emit("br-kind", ht(t), kindCode(BroadcastRadio.kind(forTags: t))) }
let dialPool = ["WAPL 105.7", "105.7 FM", "WTMJ 620", "620AM", "KQRS-FM 92.5", "1070 AM", "88.25", "107.25", "90.75",
    "87.5", "108.0", "108.1", "87.4", "530", "1700", "1701", "529", "2024 hits", "99.9.9", "1.0.1", "..", ".",
    "\u{669}\u{669}.\u{669}", "\u{FF11}\u{FF10}\u{FF15}.\u{FF17}", "105.7\u{301}", "105,7", "FM 101.1 & 1450 AM",
    "Z104.3", "99.5 - 1510", "0105.7", "1e2", "+99.1", "-98.1", "98.15", "98.05", "99.95", "107.95", "108.04", "87.45",
    "\u{BD}", "5\u{B2}", "88.", ".88", "088.1", "00620", "620.", "620.0", "1,070", "Hot 97", "KISS 108", "WNYC 820 & 93.9",
    "93.9FM820AM", "\u{1F4FB}101.5", "101.5\u{FE0F}", "101\u{2024}5", "1\u{0}01.5", "", "News 1130", "0.0", "1080.0",
    "96.3.", "96..3", "9.63", "106.9\u{200D}", "Radio 1", "3", "8888.8", "88.8888888888888888888"]
var dialNames = dialPool
for _ in 0..<400 { dialNames.append(glue(dialPool, [" ", "", "-", ".", "/"]) + rng.pick(marks)) }
for n in dialNames { emit("br-dial", ht(n), hto(BroadcastRadio.dialLabel(from: n))) }
typealias C = CLLocationCoordinate2D
let centers: [C] = [C(latitude: 43.07, longitude: -89.40), C(latitude: 40.71, longitude: -74.0), C(latitude: 61.2, longitude: -149.9)]
for k in 0..<500 {
    let c = rng.pick(centers)
    let n = k < 25 ? 70 : rng.pick([0, 1, 2, 3, 5, 9, 16])
    var stations: [BroadcastRadio.Station] = []
    for i in 0..<n {
        let located = !rng.chance(3)
        var lat: Double? = located ? c.latitude + rng.range(-2, 2) : nil
        var lon: Double? = located ? c.longitude + rng.range(-2, 2) : nil
        if rng.chance(8) { lat = rng.chance(2) ? .nan : nil }
        if rng.chance(8), !stations.isEmpty { let o = rng.pick(stations); lat = o.latitude; lon = o.longitude }
        let bitrate = rng.pick([0, 64, 128, 128, 320, -1, Int.max, Int.min])
        stations.append(BroadcastRadio.Station(id: "s\(i)", name: "S\(i)", url: "https://s\(i)", tags: "",
                                               latitude: lat, longitude: lon, bitrate: bitrate, kind: .pop))
    }
    let position: C? = rng.chance(5) ? nil : (rng.chance(12) ? C(latitude: .nan, longitude: 0) : c)
    let ranked = BroadcastRadio.ranked(stations, near: position)
    emit("br-ranked",
         items(stations.map { [hdo($0.latitude), hdo($0.longitude), String($0.bitrate)].joined(separator: FS) }),
         position.map { hx($0.latitude) + "/" + hx($0.longitude) } ?? "-",
         lst(ranked.map { Int($0.id.dropFirst())! }))
}

// ===================================================================== RadioBrowser
let hostPool = ["de1.api.radio-browser.info", "DE1.API.RADIO-BROWSER.INFO", "at1.api.radio-browser.info",
    "ru1.api.radio-browser.info", "de.api.radio-browser.info", "de1a.api.radio-browser.info", "d1.api.radio-browser.info",
    "deu1.api.radio-browser.info", "de\u{661}.api.radio-browser.info", "de1.api.radio-browser.info.evil.com",
    ".api.radio-browser.info", "api.radio-browser.info", "uk1.api.radio-browser.info", "gb2.api.radio-browser.info",
    "us1.api.radio-browser.info", "cn1.api.radio-browser.info", "d\u{E9}1.api.radio-browser.info",
    "de\u{301}1.api.radio-browser.info", "\u{FB01}1.api.radio-browser.info", "all.api.radio-browser.info",
    "nl1.api.radio-browser.info", "fi1.api.radio-browser.info", "se1.api.radio-browser.info", "", "de12.api.radio-browser.info",
    "de1\u{301}.api.radio-browser.info", "\u{130}e1.api.radio-browser.info", "DE1.api.radio-browser.INFO",
    "de-1.api.radio-browser.info", "de\u{FF11}.api.radio-browser.info", "ca\u{BD}.api.radio-browser.info",
    "no1.api.radio-browser.info", "dk9.api.radio-browser.info", "pl0.api.radio-browser.info", "cz1.api.radio-browser.info",
    "ch1.api.radio-browser.info", "be1.api.radio-browser.info", "ie1.api.radio-browser.info", "fr1.api.radio-browser.info",
    "ir1.api.radio-browser.info", "kp1.api.radio-browser.info", "de1.api.radio-browser.info\u{301}", "de1.api.radio\u{2010}browser.info"]
var hosts = hostPool
for _ in 0..<120 { hosts.append(rng.pick(["de", "at", "us", "ru", "c", "gbr", "\u{E9}s"]) + rng.pick(["", "1", "22", "a", "\u{661}"])
    + rng.pick([".api.radio-browser.info", ".api.radio-browser.inf", ".API.radio-browser.info", ".api.radio-browser.info."])) }
for h in hosts { emit("rb-mirror", ht(h), b(RadioBrowser.isAllowedMirror(h))) }
emit("rb-consts", String(RadioBrowser.nearbyRadiusMeters), items(RadioBrowser.commonGenres.map(ht)),
     items(RadioBrowser.allowedMirrorCountries.sorted().map(ht)))

let genreTagPool = ["country", " news ", "talk", "", " ", "classic rock,,pop", "\u{A0}jazz\u{A0}", "hip hop\n", "a,b,c,d",
    ",,,", "r&b", "caf\u{E9}", "e\u{301},x", "\u{3000}", "\u{201A}", "one\u{2028}two", ", ,", "x,\u{301}y"]
var genreTags = genreTagPool
for _ in 0..<250 { genreTags.append(glue(genreTagPool, [",", ", ", " ,", ""])) }
for t in genreTags { emit("rb-genre", ht(t), ht(RadioBrowser.genreWords(fromTags: t))) }

let codes = ["AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "DC", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY",
    "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR",
    "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY"]
var codeInputs = codes + codes.map { $0.lowercased() }
codeInputs += ["", "XX", "PR", "GU", "\u{131}d", "\u{130}D", "Wi", "w\u{130}", "C\u{301}A", "CA ", " CA", "\u{FF23}\u{FF21}",
               "\u{DF}", "AL\u{0}", "N\u{200D}Y", "Texas", "tx\n", "\u{1F1FA}\u{1F1F8}", "Ca", "cA"]
for c in codeInputs { emit("rb-state", ht(c), hto(RadioBrowser.stateName(c))) }

func stationOut(_ s: RadioBrowser.Station) -> String {
    [ht(s.name), ht(s.url), ht(s.genre), String(s.votes), hdo(s.latitude), hdo(s.longitude)].joined(separator: FS)
}
let stationNames = ["WAPL", "wapl", "WAPL ", "Caf\u{E9} FM", "Cafe\u{301} FM", "KQRS", "", " ", "\u{130}NDIE", "i\u{307}ndie",
    "\u{DF} Radio", "SS RADIO", "ss radio", "Jazz 88", "jazz 88"]
let urls = ["https://a", "https://b", "http://a", "https://A", "https://a\u{301}", "https://\u{E1}", "", "ftp://c",
    "HTTPS://d", "https://e", " https://f"]
for k in 0..<500 {
    func hits() -> [RadioBrowser.Station]? {
        if rng.chance(5) { return nil }
        return (0..<rng.pick([0, 1, 2, 4, 7])).map { _ in
            RadioBrowser.Station(name: rng.pick(stationNames), url: rng.pick(urls), genre: "", votes: 0)
        }
    }
    var names = hits(), tags = hits()
    // Give every station a unique genre so its position in the combined list can be read back.
    var tagIndex = 0
    names = names.map { $0.map { var s = $0; s.genre0(&tagIndex); return s } }
    tags = tags.map { $0.map { var s = $0; s.genre0(&tagIndex); return s } }
    let combined = (names ?? []) + (tags ?? [])
    let merged = RadioBrowser.merged(nameHits: names, tagHits: tags)
    emit("rb-merged", names.map { items($0.map { ht($0.name) + FS + ht($0.url) }) } ?? "-",
         tags.map { items($0.map { ht($0.name) + FS + ht($0.url) }) } ?? "-",
         merged.map { m in lst(m.map { s in combined.firstIndex { $0.genre == s.genre }! }) } ?? "-")
    _ = k
}
extension RadioBrowser.Station {
    fileprivate mutating func genre0(_ counter: inout Int) {
        self = RadioBrowser.Station(name: name, url: url, genre: "g\(counter)", votes: votes, latitude: latitude, longitude: longitude)
        counter += 1
    }
}

// Station rows as the directory's JSON: the fields each row carries as parseStations reads them, and what it keeps.
let nameValues: [Any] = ["WAPL", " WAPL ", "\nKQRS\t", "", "  ", "Caf\u{E9}", "Cafe\u{301}", "wapl", 42, NSNull(), "\u{3000}Jazz\u{2028}",
                         "\u{DF}", "SS", "\u{0}x"]
let urlValues: [Any] = ["https://a", "https://b", "http://c", "HTTPS://d", "https://a\u{301}", "https://\u{E1}", "", 7, NSNull(),
                        " https://e", "https://"]
let tagValues: [Any] = ["country,news", "", "a, b ,c,d", 3, NSNull(), " , ,pop", "caf\u{E9},x"]
let voteValues: [Any] = [0, 12, -3, 3.5, "9", true, NSNull(), Int.max, 1e30]
let coordValues: [Any] = [43.07, -89.4, 0, "43", NSNull(), 1, true, 1e308]
for _ in 0..<400 {
    var rows: [[String: Any]] = []
    for _ in 0..<rng.pick([0, 1, 2, 3, 6, 12]) {
        var row: [String: Any] = [:]
        if !rng.chance(8) { row["name"] = rng.pick(nameValues) }
        if !rng.chance(8) { row["url_resolved"] = rng.pick(urlValues) }
        if !rng.chance(4) { row["tags"] = rng.pick(tagValues) }
        if !rng.chance(4) { row["votes"] = rng.pick(voteValues) }
        if !rng.chance(3) { row["geo_lat"] = rng.pick(coordValues) }
        if !rng.chance(3) { row["geo_long"] = rng.pick(coordValues) }
        rows.append(row)
    }
    let data = try! JSONSerialization.data(withJSONObject: rows)
    let parsedRows = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    // The fields as parseStations reads each row (verbatim casts from the base commit), before its rules run.
    let fields = parsedRows.map { row -> String in
        [hto(row["name"] as? String), hto(row["url_resolved"] as? String), ht(row["tags"] as? String ?? ""),
         String(row["votes"] as? Int ?? 0), hdo(row["geo_lat"] as? Double), hdo(row["geo_long"] as? Double)].joined(separator: FS)
    }
    emit("rb-rows", items(fields), items(RadioBrowser.parseStations(data).map(stationOut)))
}
for _ in 0..<150 {
    let rows: [[String: Any]] = (0..<rng.pick([0, 1, 2, 4, 8])).map { _ in
        rng.chance(6) ? [:] : ["name": rng.pick(["de1.api.radio-browser.info", "at1.api.radio-browser.info", "", 5, NSNull(),
                                                 "caf\u{E9}", "cafe\u{301}", "nl1.api.radio-browser.info"] as [Any])]
    }
    let data = try! JSONSerialization.data(withJSONObject: rows)
    let parsedRows = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    emit("rb-servers", items(parsedRows.map { hto($0["name"] as? String) }), items(RadioBrowser.parseServers(data).map(ht)))
}

for k in 0..<300 {
    let c = rng.pick(centers)
    let n = k < 15 ? 70 : rng.pick([0, 1, 2, 3, 6, 12])
    var found: [RadioBrowser.Station] = []
    for _ in 0..<n {
        let lat: Double? = rng.chance(3) ? nil : (rng.chance(10) ? .nan : c.latitude + rng.range(-2, 2))
        let lon: Double? = lat == nil ? nil : c.longitude + rng.range(-2, 2)
        found.append(RadioBrowser.Station(name: rng.pick(stationNames), url: "https://s\(rng.below(max(n, 1) + 2))",
                                          genre: rng.pick(tagPool), votes: rng.pick([0, 5, 5, 90, -1]),
                                          latitude: lat, longitude: lon))
    }
    let position = rng.chance(12) ? C(latitude: .nan, longitude: 0) : c
    let ranked = RadioBrowser.rankedNearest(found, near: position)
    emit("rb-ranked", items(found.map(stationOut)), hx(position.latitude) + "/" + hx(position.longitude),
         lst(ranked.map { r in found.firstIndex { $0.id == r.id }! }))
}

if CommandLine.arguments.count > 1 {
    FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: out.data(using: .utf8)!)
} else {
    FileHandle.standardOutput.write(out.data(using: .utf8)!)
}
