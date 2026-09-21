import CoreLocation
import Foundation
// Frozen oracle: every output below comes from the ORIGINAL TruckerRadio.relayChannels(fromDirectory:bundled:) at the
// commit that made it a pure static, before its facade switch, linked against the Rust bridge for the facades the
// file already calls. Text is "t:" + UTF-8 with bytes outside 0x20...0x7E, and the backslash, as \xx; doubles are
// IEEE-754 bit patterns in hex; nil is "-"; lists are "L<n>:" + rows joined with U+001E, a row's fields with U+001F.

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
let FS = "\u{1F}", RS = "\u{1E}"
func rows(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: RS) }
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
var rng = SM(s: 0x52454C4159534352)   // "RELAYSCR"

typealias Channel = TruckerRadio.Channel
func channelOut(_ c: Channel) -> String {
    [ht(c.name), ht(c.detail), ht(c.url), hdo(c.latitude), hdo(c.longitude)].joined(separator: FS)
}

// ------------------------------------------------------------------ the pieces of a directory page
let states = ["AL", "AK", "WI", "IL", "MN", "TX", "CA", "NY", "FL", "WA", "PR", "DC"]
let cities = ["Mobile", "Madison", "Dixon", "Anchorage", "Saint Paul", "Austin", "San José", "Sa\u{301}n Jose",
              "New York", "Miami", "Seattle", "San Juan"]
let calls = ["KEC61", "KZZ55", "WXJ83", "KEC 61", "K\u{C9}C61", "KE\u{301}C61", "WNG 522", "KIH-23", "", " ", "KZZ55 "]
func goodURL() -> String {
    "https://radio.weatherusa.net/NWR/" + rng.pick(["K", "W"]) + String(rng.below(900) + 100) + rng.pick([".mp3", "", "/live", "?q=1"])
}
let urlVariants: [() -> String] = [
    { goodURL() },
    { goodURL() },
    { goodURL() },
    { "http://radio.weatherusa.net/NWR/" + String(rng.below(900)) },
    { "https://radio.weatherusa.net/other/" + String(rng.below(900)) },
    { "HTTPS://RADIO.WEATHERUSA.NET/NWR/" + String(rng.below(900)) },
    { "https://radio.weatherusa.net/NWR" },
    { "https://radio.weatherusa.net/NWR/\u{301}x" },
    { "https://radio.weatherusa.net/NWR/a>b" + String(rng.below(9)) },
    { "https://radio.weatherusa.net/NWR/" + String(rng.below(900)) + "\u{0}z" },
]
func label() -> String {
    switch rng.below(12) {
    case 0: return ""
    case 1: return "   "
    case 2: return "\n\t" + rng.pick(states) + "-" + rng.pick(cities) + ": " + rng.pick(calls) + "  \r\n"
    case 3: return rng.pick(states) + "-" + rng.pick(cities)
    case 4: return "\u{A0}" + rng.pick(states) + "-" + rng.pick(cities) + ": " + rng.pick(calls) + "\u{2003}"
    case 5: return rng.pick(cities) + "::" + rng.pick(calls)
    case 6: return rng.pick(cities) + ":"
    case 7: return ":"
    default: return rng.pick(states) + "-" + rng.pick(cities) + ": " + rng.pick(calls)
    }
}
func option() -> String {
    let url = rng.pick(urlVariants)()
    let close = rng.chance(15) ? "" : (rng.chance(20) ? "\"\u{301}" : "\"")
    let attrs = rng.pick(["", " selected", " data-x=\"1\"", " class=\"r\"", " >"])
    let gt = rng.chance(20) ? "" : ">"
    let end = rng.chance(20) ? "" : rng.pick(["</option>", "</OPTION>", "<br>", "< /option>"])
    return "<option value=\"" + url + close + attrs + gt + label() + end
}
func page(options n: Int, duplicates: Bool) -> String {
    var parts: [String] = [rng.pick(["<html><body><select>", "", "junk <option value=x>", "<option value=\"\u{301}"])]
    var made: [String] = []
    for _ in 0..<n {
        let o = (duplicates && !made.isEmpty && rng.chance(4)) ? rng.pick(made) : option()
        made.append(o)
        parts.append(o)
        if rng.chance(6) { parts.append(rng.pick(["\n", " ", "<!-- -->", "<option value='single'>x", "\r\n"])) }
    }
    parts.append(rng.pick(["</select></body></html>", "", "<option value=\""]))
    return parts.joined()
}

// ------------------------------------------------------------------ bundled station lists
func bundledList() -> [Channel] {
    (0..<rng.below(14)).map { _ in
        let name: String
        switch rng.below(8) {
        case 0: name = rng.pick(cities)
        case 1: name = rng.pick(cities) + ":"
        case 2: name = "::"
        case 3: name = rng.pick(cities) + ": " + rng.pick(calls) + ": " + rng.pick(calls)
        default: name = "NOAA WX " + rng.pick(states) + "-" + rng.pick(cities) + ": " + rng.pick(calls)
        }
        let la: Double? = rng.chance(4) ? nil : (rng.chance(10) ? rng.pick([.nan, -0.0, .infinity]) : rng.range(20, 65))
        let lo: Double? = rng.chance(4) ? nil : (rng.chance(10) ? rng.pick([.nan, 0, -.infinity]) : rng.range(-160, -65))
        return Channel(name: name, detail: "bundled", url: rng.chance(3) ? "" : goodURL(), latitude: la, longitude: lo)
    }
}

// ------------------------------------------------------------------ records
var pages: [String] = ["", "<option value=\"", String(repeating: "<option value=\"https://radio.weatherusa.net/NWR/K1\">WI-A: K1</option>", count: 12)]
for k in 0..<1_200 {
    let n = k < 100 ? rng.pick([9, 10, 11]) : (k < 200 ? 30 + rng.below(40) : rng.below(26))
    pages.append(page(options: n, duplicates: rng.chance(3)))
}
MainActor.assumeIsolated {
    for html in pages {
        let bundled = bundledList()
        let result = TruckerRadio.relayChannels(fromDirectory: html, bundled: bundled)
        emit("rs-relays", ht(html), rows(bundled.map(channelOut)), result.map { rows($0.map(channelOut)) } ?? "-")
    }
}

try! out.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
