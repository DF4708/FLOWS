import CoreLocation
import Foundation
// Frozen oracle: every output below comes from the ORIGINAL ForecastConditions.forecastScore and
// .predictorFamilies (NWSForecastService.swift), compiled with the ORIGINAL ClimateProfiles and
// LatitudeBands and the RiskEquations facade over the Rust equations it already called — the
// first harness linked against libflows_bridge.a. Doubles are IEEE-754 bit patterns in hex;
// nil is "-"; lists are "L<n>:" + comma-joined items. The predictor dictionary is read by its
// six fixed keys, never iterated.

func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func opt(_ d: Double?) -> String { d.map(hx) ?? "-" }
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
var out = ""
func emit(_ f: String...) { out += f.joined(separator: "\t") + "\n" }

struct SM { var s: UInt64
  mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
  mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
  mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
  mutating func chance(_ n: Int) -> Bool { below(n) == 0 } }
var rng = SM(s: 0x464F5245434153)   // "FORECAS"

let FAMS = ["wind", "precip", "heat", "cold", "winter", "convective"]
func record(_ c: ForecastConditions, _ lat: Double, _ lon: Double, _ elev: Double?) {
    let inputs = [opt(c.temperatureF), opt(c.windMph), opt(c.popPercent), hx(lat), hx(lon), opt(elev)]
    emit("fc-score", inputs.joined(separator: "\t"), hx(c.forecastScore(latitude: lat, longitude: lon, elevationMeters: elev)))
    let fam = c.predictorFamilies(latitude: lat, longitude: lon, elevationMeters: elev)
    emit("fc-fam", inputs.joined(separator: "\t"), lst(FAMS.map { opt(fam[$0]) }))
}

let SP: [Double] = [.nan, -Double.nan, .infinity, -.infinity, 0, -0.0, .leastNonzeroMagnitude, .greatestFiniteMagnitude, -1e300, 1e300, -1]
// Temperatures straddle every rule edge: 34 and 60 exactly and one ulp either side, typical comfort edges.
let temps: [Double?] = [nil, 34, (34.0).nextUp, (34.0).nextDown, 60, (60.0).nextUp, (60.0).nextDown, 70, -40, 0, 32, 45, 50, 55, 65, 72, 78, 80, 85, 90, 95, 100, 110, 120, 130]
let winds: [Double?] = [nil, 0, 5, 14.9, 15, 15.1, 20, 28, 30, 44.9, 45, 60, 100, -5]
let pops: [Double?] = [nil, 0, 10, 24.9, 25, 30, 50, 60, 70, 74.9, 75, 90, 100, 120]
// Finite, in-range coordinates only: the original's latitude bands and its precise-cell key take Int(…) and trap otherwise.
let places: [(Double, Double)] = [(43.07, -89.4), (47.61, -122.33), (33.45, -112.07), (25.76, -80.19), (61.22, -149.9), (71.29, -156.79),
  (19.43, -99.13), (45.5, -73.57), (0.0, 0.0), (-33.9, 151.2), (89.9, -179.9), (-89.9, 179.9), (39.74, -104.99), (36.17, -115.14)]
let elevs: [Double?] = [nil, 0, 1609, 2240, 5000, -80, .nan, .infinity, -.infinity, 1e300]

// The grid of edges: every temperature against a few winds and rains at a few places.
for (i, t) in temps.enumerated() {
    for w in [winds[0], winds[4], winds[9]] {
        for p in [pops[0], pops[4], pops[10]] {
            let (lat, lon) = places[i % places.count]
            record(ForecastConditions(temperatureF: t, windMph: w, windFromDegrees: nil, popPercent: p, qpfInches: nil), lat, lon, elevs[i % elevs.count])
        }
    }
}
// Specials in every slot.
for s in SP {
    for (lat, lon) in [places[0], places[6]] {
        record(ForecastConditions(temperatureF: s, windMph: 20, windFromDegrees: nil, popPercent: 50, qpfInches: nil), lat, lon, nil)
        record(ForecastConditions(temperatureF: 70, windMph: s, windFromDegrees: nil, popPercent: 50, qpfInches: nil), lat, lon, nil)
        record(ForecastConditions(temperatureF: 20, windMph: 20, windFromDegrees: nil, popPercent: s, qpfInches: nil), lat, lon, nil)
        // The original's precise-cell lookup takes Int(lon / 0.1): only a longitude that fits traps nothing.
        if s.isFinite, abs(s) < 1e6 {
            record(ForecastConditions(temperatureF: 90, windMph: 30, windFromDegrees: nil, popPercent: 80, qpfInches: nil), lat, s, nil)
        }
    }
}
// Random sweep.
for _ in 0..<2000 {
    func maybe(_ lo: Double, _ hi: Double) -> Double? { rng.chance(7) ? nil : (rng.chance(9) ? rng.pick(SP) : lo + rng.unit() * (hi - lo)) }
    let lat = rng.chance(4) ? rng.pick(places).0 : 10 + rng.unit() * 65
    let lon = rng.chance(4) ? rng.pick(places).1 : -170 + rng.unit() * 120
    let elev: Double? = rng.chance(3) ? nil : (rng.chance(8) ? rng.pick(SP) : rng.unit() * 6000 - 1000)
    record(ForecastConditions(temperatureF: maybe(-40, 130), windMph: maybe(0, 100), windFromDegrees: nil, popPercent: maybe(0, 120), qpfInches: nil), lat, lon, elev)
}

FileHandle.standardOutput.write(out.data(using: .utf8)!)
