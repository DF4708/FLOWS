import Foundation

// Frozen oracle: every output below comes from the ORIGINAL Swift `IntlWeatherParsing` (InternationalWeather.swift),
// compiled with the test target's own Core sources at the base commit. Doubles are IEEE-754 bit patterns in hex,
// text is its UTF-8 in hex, nil is "-".
//
// Kinds: c value, celsiusToF, kmhToMph, msToMph | at props, ecccAirTempF | w props, ecccWindMph | wp the same, for every two
// wind keys side by side | smn tmax, tmin, wind, pop, temperatureF, windMph, popPercent.
//
// A props field lists the dictionary as the original saw it, entries joined by ",", each
// key/nfc/number/text: the key, its NFC spelling (`precomposedStringWithCanonicalMapping`), the value read as
// a number the original's way (`as? Double`, else a `String` through `Double(_:)`), and the value as text when
// it is a `String`. Entries are in UTF-8 byte order of their keys, so the record does not depend on the
// dictionary's own order.

func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func th(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }
func opt(_ d: Double?) -> String { d.map(hx) ?? "-" }

struct SM {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
    mutating func chance(_ n: Int) -> Bool { below(n) == 0 }
}

let SP: [Double] = [
    .nan, .infinity, -.infinity, 0, -0.0, 1e300, -1e300, .leastNonzeroMagnitude, .greatestFiniteMagnitude, -1, 2,
]

// Anemometer keys as SWOB stations name them, with near misses: case, the exclusions ("-uom", "-qa", "flag" are
// case-sensitive), "10m" in other places, combining marks that join a letter of "wnd_spd", composed and
// decomposed spellings (canonically equal keys are one key), and letters that change length when lowercased.
let WIND_KEYS: [String] = [
    "wnd_spd", "avg_wnd_spd_10m_pst1hr", "avg_wnd_spd_10m_pst10mts", "max_wnd_spd_10m_pst1hr",
    "avg_wnd_spd_pcpn_gag_pst10mts", "max_wnd_spd_pcpn_gag_pst10mts", "wnd_spd_10m", "WND_SPD_10M", "Wnd_Spd",
    "wnd_spd_10M", "10m_wnd_spd", "a_wnd_spd", "z_wnd_spd_10m", "wnd_spd_10m-qa", "wnd_spd-QA", "wnd_spd_qa",
    "wnd_spd-flag", "wnd_spd_flag", "wnd_spd_FLAG", "wnd_spd-Uom", "wnd_spdx", "wnd_sp", "wnd spd", "wnd_dir",
    "avg_wnd_dir_10m_pst1hr", "wnd_spd_\u{E9}", "wnd_spd_e\u{301}", "wnd_spd\u{301}", "w\u{301}nd_spd",
    "WND_SPD_\u{130}", "\u{130}_WND_SPD", "wnd_spd_\u{F6}z", "wnd_spd_o\u{308}", "wnd_spd_o\u{308}z",
    "wnd_spd_\u{AC00}", "wnd_spd_\u{1100}\u{1161}", "\u{FF57}\u{FF4E}\u{FF44}_spd", "wnd_spd_1\u{FF10}m",
    "wnd_spd_10m\u{301}", "wnd_spd_\u{212B}", "wnd_spd_\u{C5}", "WND_SPD_\u{212A}", "wnd_spd_k", "",
    "x10mwnd_spd", "wnd_spd_10m_10m", "WND_SPD", "wNd_sPd_10m",
]
// The pair records add keys whose "10m" a mark or a joiner splits and NFC leaves split (no letter "m" composes
// with a diaeresis), so a byte search finds "10m" where Swift does not.
let PAIR_KEYS: [String] =
    WIND_KEYS + ["wnd_spd_10m\u{308}", "wnd_spd_10m\u{200D}x", "wnd_spd_10m\u{1F3FB}", "a_10m\u{308}_wnd_spd"]
let TEMP_KEYS: [String] = [
    "air_temp", "air_temp_1", "avg_air_temp_pst1hr", "air_temp_2", "AIR_TEMP", "air_temp ", "Air_temp",
    "max_air_temp_pst1hr", "air_temp\u{301}", "dwpt_temp", "",
]
let UNITS: [String] = [
    "km/h", "KM/H", "Km/H", "m/s", "M/S", "knots", "kts", "", "m/sec", "km/h m/s", "m/ s", "\u{FF4D}/s",
    "m\u{301}/s", "mph", "M/s", "kmh", " m/s ",
]
let NUMBER_TEXTS: [String] = [
    "0", "12", "12.5", "-3", " 12", "12 ", "1e2", "0x1p3", "nan", "-nan", "inf", "-inf", "infinity", "abc", "",
    "1_000", "\u{661}\u{662}", "+4", ".5", "5.", "-0", "1e400", "-1e400", "4.9e-324", "007", "1,5", "MSNG",
]

@main
@MainActor
enum Oracle {
    static var rng = SM(s: 0x494E_544C_5745_4154)  // "INTLWEAT"
    static var out = ""
    static func emit(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }
    static func special(_ v: Double, _ n: Int = 10) -> Double { rng.chance(n) ? rng.pick(SP) : v }

    /// A value as JSONSerialization hands it over, or something it could not.
    static func value(_ around: Double) -> Any {
        switch rng.below(10) {
        case 0, 1, 2: return NSNumber(value: special(around))
        case 3, 4: return rng.chance(3) ? rng.pick(NUMBER_TEXTS) : String(special(around))
        case 5: return NSNumber(value: Int(around.rounded()))
        case 6: return NSNumber(value: rng.chance(2))
        case 7: return rng.pick([NSNumber(value: 9_007_199_254_740_993 as Int64), NSNumber(value: Int64.max)])
        case 8: return NSNull()
        default: return rng.chance(2) ? [around] as [Any] : around
        }
    }

    static func props(keys: [String], around: () -> Double) -> [String: Any] {
        var p: [String: Any] = [:]
        let n = rng.chance(10) ? 0 : 1 + rng.below(7)
        for _ in 0..<n {
            let k = rng.pick(keys)
            p[k] = value(around())
            if rng.chance(2) {
                // The key's unit, sometimes in another spelling of the key, sometimes not a String.
                let uk = rng.chance(6) ? rng.pick(keys) + "-uom" : k + "-uom"
                p[uk] = rng.chance(8) ? NSNumber(value: 1) : rng.pick(UNITS) as Any
            }
        }
        return p
    }

    static func number(_ v: Any?) -> Double? { (v as? Double) ?? (v as? String).flatMap(Double.init) }

    static func listed(_ p: [String: Any]) -> String {
        p.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }.map { k in
            let v = p[k]
            let text = (v as? String).map(th) ?? "-"
            return "\(th(k))/\(th(k.precomposedStringWithCanonicalMapping))/\(opt(number(v)))/\(text)"
        }.joined(separator: ",")
    }

    static func conversion() {
        let v = special(rng.unit() * 240 - 80, 6)
        emit([
            "c", hx(v), hx(IntlWeatherParsing.celsiusToF(v)), hx(IntlWeatherParsing.kmhToMph(v)),
            hx(IntlWeatherParsing.msToMph(v)),
        ])
    }

    static func airTemp() {
        let p = props(keys: TEMP_KEYS) { rng.unit() * 90 - 45 }
        emit(["at", listed(p), opt(IntlWeatherParsing.ecccAirTempF(p))])
    }

    static func wind() {
        let p = props(keys: WIND_KEYS) { rng.chance(5) ? -(rng.unit() * 10) : rng.unit() * 140 }
        emit(["w", listed(p), opt(IntlWeatherParsing.ecccWindMph(p))])
    }

    /// Every two of `PAIR_KEYS` side by side, each with a speed: pins which one speaks first for every pair, the
    /// pairs whose order hangs on a combining mark, a width or a case included. Canonically equal keys are one
    /// key, so such a pair holds one field.
    ///
    /// Swift's own `<` gives some pairs no order at all (neither is less and they are not equal; for one,
    /// "wnd_spd_o\u{308}" and "wnd_spd_\u{F6}z"), so the original's answer for them follows the dictionary's
    /// order, which changes from run to run. Those pairs are left out and counted on stderr.
    static func windPairs() {
        var unordered = 0
        for i in PAIR_KEYS.indices {
            for j in (i + 1)..<PAIR_KEYS.count {
                let (a, b) = (PAIR_KEYS[i], PAIR_KEYS[j])
                if !(a < b) && !(b < a) && a != b {
                    unordered += 1
                    continue
                }
                var p: [String: Any] = [:]
                p[a] = 10.0
                p[b] = 20.0
                emit(["wp", listed(p), opt(IntlWeatherParsing.ecccWindMph(p))])
            }
        }
        FileHandle.standardError.write(Data("wind pairs with no order in Swift: \(unordered)\n".utf8))
    }

    static func smn() {
        func maybe(_ v: @autoclosure () -> Double) -> Double? { rng.chance(4) ? nil : special(v(), 8) }
        let row = IntlWeatherParsing.SMNRow(
            lat: rng.unit() * 20 + 13, lon: -(rng.unit() * 34 + 85), tmaxC: maybe(rng.unit() * 60 - 10),
            tminC: maybe(rng.unit() * 50 - 20), windKmh: maybe(rng.unit() * 120), popPct: maybe(rng.unit() * 100))
        let c = IntlWeatherParsing.conditions(from: row)
        emit([
            "smn", opt(row.tmaxC), opt(row.tminC), opt(row.windKmh), opt(row.popPct), opt(c.temperatureF),
            opt(c.windMph), opt(c.popPercent),
        ])
    }

    static func main() {
        for _ in 0..<300 { conversion() }
        for _ in 0..<600 { airTemp() }
        for _ in 0..<1600 { wind() }
        windPairs()
        for _ in 0..<400 { smn() }
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/stdout"
        FileManager.default.createFile(atPath: path, contents: Data(out.utf8))
    }
}
