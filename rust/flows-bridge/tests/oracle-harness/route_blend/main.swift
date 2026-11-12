import CoreLocation
import Foundation

// Frozen oracle: every output below comes from the ORIGINAL Swift `RouteBlend.blend` (the corridor blend loop
// as it left AppModel), compiled with the test target's own Core sources at the base commit and linked against
// the Rust bridge for the facades it already called. Doubles are IEEE-754 bit patterns in hex; text is "t:" +
// UTF-8 with bytes outside 0x20...0x7E, and the backslash, as \xx; nil is "-"; lists are "L<n>:" + comma-joined
// items; a point is hx(lat)/hx(lon), points join with ";" and rings with "|"; items carrying text join their
// fields with U+001F and each other with U+001E (escaped inside text, so the joins are unambiguous).

typealias C = CLLocationCoordinate2D
let FS = "\u{1F}", RS = "\u{1E}"
func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func ho(_ d: Double?) -> String { d.map(hx) ?? "-" }
func ht(_ s: String) -> String {
    let digits = Array("0123456789abcdef".unicodeScalars)
    var o = "t:"
    for b in s.utf8 {
        if b >= 0x20, b <= 0x7E, b != 0x5C {
            o.unicodeScalars.append(Unicode.Scalar(b))
        } else {
            o += "\\"
            o.unicodeScalars.append(digits[Int(b >> 4)])
            o.unicodeScalars.append(digits[Int(b & 15)])
        }
    }
    return o
}
func hto(_ s: String?) -> String { s.map(ht) ?? "-" }
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
func pt(_ c: C) -> String { hx(c.latitude) + "/" + hx(c.longitude) }
func pts(_ a: [C]) -> String { a.map(pt).joined(separator: ";") }
func rings(_ r: [[C]]) -> String { r.map(pts).joined(separator: "|") }

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
let centers: [C] = [
    C(latitude: 43.07, longitude: -89.4), C(latitude: 34.05, longitude: -118.24),
    C(latitude: 61.22, longitude: -149.9), C(latitude: 25.76, longitude: -80.19),
    C(latitude: 19.43, longitude: -99.13), C(latitude: 47.6, longitude: -122.33),
    C(latitude: 39.74, longitude: -104.99), C(latitude: 0, longitude: 0),
]
let words = [
    "", "action", "minor", "moderate", "major", "Major", "MAJOR", "no_flooding", "warning", "WARNING", "Warning",
    "watch", "WATCH", "advisory", "ADVISORY", "Advisory", "normal", "Tsunami Warning", "advisory\u{301}",
    "extreme", "minor ", " minor", "unknown", "ma\u{301}jor",
]
let events = [
    "Tornado Warning", "TORNADO WARNING", "Tornado Watch", "Flash Flood Warning", "Flash Flood Emergency",
    "Flood Warning", "Flood Watch", "Flood Advisory", "Winter Storm Warning", "Blizzard Warning",
    "Ice Storm Warning", "Winter Weather Advisory", "High Wind Warning", "Wind Advisory", "Extreme Wind Warning",
    "Red Flag Warning", "Fire Warning", "Fire Weather Watch", "Severe Thunderstorm Warning",
    "Severe Thunderstorm Watch", "Tsunami Warning", "Tsunami Advisory", "Tsunami Watch", "Hurricane Warning",
    "Hurricane Watch", "Tropical Storm Warning", "Storm Surge Warning", "Volcano Warning", "Ashfall Warning",
    "Earthquake Warning", "Avalanche Warning", "Avalanche Watch", "Gale Warning", "Special Marine Warning",
    "Special Weather Statement", "Rain Advisory", "Shelter In Place Warning", "Evacuation Immediate",
    "Civil Danger Warning", "Civil Emergency Message", "Radiological Hazard Warning",
    "Hazardous Materials Warning", "Nuclear Power Plant Warning", "Child Abduction Emergency", "Blue Alert",
    "Law Enforcement Warning", "Local Area Emergency", "911 Telephone Outage", "Air Quality Alert",
    "Heat Advisory", "Excessive Heat Warning", "Extreme Cold Warning", "Wind Chill Warning", "Freeze Warning",
    "Dense Fog Advisory", "Dust Storm Warning", "Snow Squall Warning", "Coastal Flood Warning",
    "High Surf Advisory", "Rip Current Statement", "", " ", "nonsense", "tornado warn\u{131}ng",
    "Aviso de Tornado", "Tornado\u{0}Warning", "\u{FF34}ornado Warning", "warning", "Avalanche",
]
let familyPool = [
    "environmental", "wind", "qpf_flood", "winter", "convective", "heat", "cold", "air", "radiation", "fire",
    "storm", "precip", "Wind", "", "seismic",
]
let INTS: [Int] = [Int.min, -1, 0, 1, 2, 3, 4, 5, 6, 9, 100, Int.max]

@main
@MainActor
enum Oracle {
    static var rng = SM(s: 0x524F_5554_4542_4C44)  // "ROUTEBLD"
    static var out = ""
    static func emit(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }
    static func near(_ c: C, _ spread: Double) -> C {
        C(
            latitude: c.latitude + (rng.unit() - 0.5) * spread,
            longitude: c.longitude + (rng.unit() - 0.5) * spread * 1.4)
    }
    static func maybeSpecial(_ v: Double, _ n: Int = 25) -> Double { rng.chance(n) ? rng.pick(SP) : v }
    static func randRing(_ c: C, _ n: Int, _ size: Double) -> [C] {
        (0..<n).map { i in
            let a = Double(i) / Double(max(n, 1)) * 2 * .pi
            return C(
                latitude: maybeSpecial(c.latitude + size * sin(a) * (0.6 + rng.unit() * 0.4)),
                longitude: maybeSpecial(c.longitude + size * cos(a) * (0.6 + rng.unit() * 0.4)))
        }
    }
    // The live snapshot, as oracle-harness/hazard_feeds draws one (and writes it).
    static func snapshot(_ c: C) -> LiveHazardSnapshot {
        LiveHazardSnapshot(
            hotspots: (0..<rng.pick([0, 2, 10])).map { _ in
                let q = near(c, rng.pick([0.2, 3, 20]))
                return (lat: q.latitude, lon: q.longitude, frp: rng.unit() * 300)
            },
            perimeters: (0..<rng.pick([0, 1, 3])).map { _ in
                randRing(near(c, rng.pick([0.3, 8])), rng.pick([1, 3, 5]), 0.1)
            },
            quakes: (0..<rng.pick([0, 2])).map { _ in
                let q = near(c, 3)
                return (lat: q.latitude, lon: q.longitude, magnitude: rng.unit() * 8, ageHours: rng.unit() * 30)
            },
            space: (r: rng.pick(INTS), s: rng.pick([0, 1, 3, 5]), g: rng.pick([0, 2, 4])),
            volcanoes: (0..<rng.pick([0, 1])).map { _ in
                let q = near(c, 2)
                return (lat: q.latitude, lon: q.longitude, level: rng.pick(words))
            },
            avalancheZones: (0..<rng.pick([0, 1])).map { _ in
                (rings: [randRing(near(c, 1), 4, 0.8)], rating: rng.pick([1, 3, 4]))
            },
            storms: (0..<rng.pick([0, 1])).map { _ in
                let q = near(c, rng.pick([2, 15]))
                return (lat: q.latitude, lon: q.longitude, maxWindKt: rng.unit() * 150)
            },
            tsunamis: (0..<rng.pick([0, 1])).map { _ in
                let q = near(c, rng.pick([3, 15]))
                return (lat: q.latitude, lon: q.longitude, level: rng.pick(words))
            },
            spcZones: (0..<rng.pick([0, 1, 2])).map { _ in
                (rings: [randRing(near(c, 1), 5, 1.2)], score: rng.pick([0.45, 0.72, 1.0]))
            })
    }
    static func enc(_ s: LiveHazardSnapshot) -> [String] {
        [
            s.hotspots.map { hx($0.lat) + "/" + hx($0.lon) + "/" + hx($0.frp) }.joined(separator: ","),
            rings(s.perimeters),
            s.quakes.map { [hx($0.lat), hx($0.lon), hx($0.magnitude), hx($0.ageHours)].joined(separator: "/") }
                .joined(separator: ","),
            "\(s.space.r)/\(s.space.s)/\(s.space.g)",
            s.volcanoes.map { [hx($0.lat), hx($0.lon), ht($0.level)].joined(separator: FS) }
                .joined(separator: RS),
            s.avalancheZones.map { rings($0.rings) + FS + String($0.rating) }.joined(separator: RS),
            s.storms.map { [hx($0.lat), hx($0.lon), hx($0.maxWindKt)].joined(separator: "/") }
                .joined(separator: ","),
            s.tsunamis.map { [hx($0.lat), hx($0.lon), ht($0.level)].joined(separator: FS) }
                .joined(separator: RS),
            s.spcZones.map { rings($0.rings) + FS + hx($0.score) }.joined(separator: RS),
        ]
    }

    static func scenario() {
        // The road: a walk from a centre, check points a few hundred metres to tens of km apart.
        let start = near(rng.pick(centers), 2)
        let n = rng.pick([0, 1, 1, 2, 3, 5, 7, 9, 12, 20, 30])
        let step = rng.pick([0.003, 0.02, 0.08, 0.3])
        var at = start
        var road: [C] = []
        for _ in 0..<n {
            road.append(rng.chance(60) ? C(latitude: rng.pick(SP), longitude: rng.pick(SP)) : at)
            at = C(
                latitude: at.latitude + (rng.unit() - 0.3) * step,
                longitude: at.longitude + (rng.unit() - 0.3) * step * 1.4)
        }
        func onRoad(_ spread: Double) -> C { near(road.isEmpty ? start : rng.pick(road), spread) }
        let samples = road.map { c in
            RiskSample(
                coordinate: c,
                risk: rng.chance(3) ? 0 : maybeSpecial(rng.pick([0.2, 0.45, 0.62, 0.8, 0.95, 1.0]) * rng.unit(), 12),
                worstEvent: rng.chance(2) ? nil : rng.pick(events))
        }

        // The ZIP field: nil, or families (a shuffled part of the pool, now and then with a repeat) and
        // entries on and off the road, their rows mostly whole, sometimes ragged or carrying specials.
        var families: [String] = []
        var entries: [RiskFieldService.ZipEntry] = []
        let hasField = !rng.chance(5)
        if hasField {
            var pool = familyPool
            let keep = rng.pick([0, 3, 6, 9, 12, pool.count])
            while families.count < keep, !pool.isEmpty { families.append(pool.remove(at: rng.below(pool.count))) }
            if rng.chance(6), let f = families.first { families.append(f) }
            for k in 0..<rng.pick([0, 1, 4, 10, 25]) {
                let c = onRoad(rng.pick([0.01, 0.1, 0.4, 1.5]))
                let width = rng.chance(6) ? rng.below(families.count + 3) : families.count
                entries.append(
                    RiskFieldService.ZipEntry(
                        zip: String(10000 + k), centroid: c,
                        scores: (0..<width).map { _ in rng.chance(3) ? 0 : maybeSpecial(rng.unit(), 30) },
                        summary: nil, ring: nil))
            }
        }
        let field = hasField ? RiskField(generated: "oracle", families: families, entries: entries) : nil
        precondition(!hasField || field != nil, "the field did not build")

        // Forecasts: none, every other check point (as the planner fetches), or scattered.
        var onDevice: [Int: (ForecastConditions, Double?)] = [:]
        let pattern = rng.below(4)
        let ground = rng.unit() * 2500
        for i in 0..<n where pattern != 0 {
            let has = pattern == 1 ? i % 2 == 0 : (pattern == 2 ? rng.chance(3) : true)
            guard has else { continue }
            func opt(_ v: Double) -> Double? { rng.chance(5) ? nil : maybeSpecial(v, 30) }
            let c = ForecastConditions(
                temperatureF: opt(rng.unit() * 150 - 35), windMph: opt(rng.unit() * rng.pick([10, 40, 95])),
                windFromDegrees: opt(rng.unit() * 360), popPercent: opt(rng.unit() * 100),
                qpfInches: opt(rng.pick([0, 0, 0.05, 0.4, 1.5, 6]) * rng.unit()))
            onDevice[i] = (c, rng.chance(4) ? nil : maybeSpecial(ground + rng.pick([0.02, 0.5, 30]) * rng.unit(), 30))
        }

        // Flood gauges, mapped water and closed roads: nil (the caller has none) or a list, empty included.
        let gauges: [(lat: Double, lon: Double, category: String)]? =
            rng.chance(3)
            ? nil
            : (0..<rng.pick([0, 1, 3, 6])).map { _ in
                let q = onRoad(rng.pick([0.02, 0.3]))
                return (lat: maybeSpecial(q.latitude, 40), lon: q.longitude, category: rng.pick(words))
            }
        let water: [C]? = rng.chance(3) ? nil : (0..<rng.pick([0, 1, 5])).map { _ in onRoad(rng.pick([0.004, 0.05])) }
        let closures: [C]? =
            rng.chance(3) ? nil : (0..<rng.pick([0, 1, 4])).map { _ in onRoad(rng.pick([0.0005, 0.01, 0.2])) }
        let live: LiveHazardSnapshot? = rng.chance(3) ? nil : snapshot(road.isEmpty ? start : rng.pick(road))

        let answer = RouteBlend.blend(
            samples: samples, onDevice: onDevice, field: field,
            gauges: gauges.map { HazardFeedScores.PreparedGauges($0) },
            water: water.map { HazardFeedScores.PreparedPoints($0) },
            closures: closures.map { HazardFeedScores.PreparedPoints($0) },
            live: live)

        var f: [String] = ["rb"]
        f.append(hasField ? families.map(ht).joined(separator: RS) + FS : "-")
        f.append(
            entries.map { e in
                [ht(e.zip), hx(e.centroid.latitude), hx(e.centroid.longitude), e.scores.map(hx).joined(separator: ",")]
                    .joined(separator: FS)
            }.joined(separator: RS))
        f.append(
            samples.map { [pt($0.coordinate), hx($0.risk), hto($0.worstEvent)].joined(separator: FS) }
                .joined(separator: RS))
        f.append(
            onDevice.keys.sorted().map { i in
                let (c, elev) = onDevice[i]!
                return [
                    String(i), ho(c.temperatureF), ho(c.windMph), ho(c.windFromDegrees), ho(c.popPercent),
                    ho(c.qpfInches), ho(elev),
                ].joined(separator: FS)
            }.joined(separator: RS))
        f.append(
            gauges.map {
                "g" + $0.map { [hx($0.lat), hx($0.lon), ht($0.category)].joined(separator: FS) }.joined(separator: RS)
            } ?? "-")
        f.append(water.map { "p" + pts($0) } ?? "-")
        f.append(closures.map { "p" + pts($0) } ?? "-")
        f.append(live == nil ? "0" : "1")
        f.append(contentsOf: enc(live ?? LiveHazardSnapshot()))
        f.append(lst(answer.risks.map(hx)))
        f.append(answer.peaks.keys.sorted().map { $0 + "=" + hx(answer.peaks[$0]!) }.joined(separator: ","))
        f.append(hx(answer.identifiedSum))
        f.append(answer.liveUnchecked ? "1" : "0")
        emit(f)
    }

    static func main() {
        for _ in 0..<900 { scenario() }
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/stdout"
        FileManager.default.createFile(atPath: path, contents: Data(out.utf8))
    }
}
