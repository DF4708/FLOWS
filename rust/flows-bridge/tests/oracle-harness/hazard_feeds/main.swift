import CoreLocation
import Foundation
// Frozen oracle: every output below comes from the ORIGINAL HazardFeedScores, LiveHazardSnapshot,
// WeatherAlertService statics, BackupWarningsCache.severity and MexicoFuelParsing (commit f36ee9e, the
// last before their facade switch), compiled with the original POIRanking.meters and linked against the
// Rust bridge for the facades they already called (RiskTiming). Doubles are IEEE-754 bit patterns in
// hex; text is "t:" + UTF-8 with bytes outside 0x20...0x7E, and the backslash, as \xx; nil is "-";
// lists are "L<n>:" + comma-joined items; a point is hx(lat)/hx(lon), points join with ";" and rings
// with "|"; items carrying text join their fields with U+001F and each other with U+001E (escaped
// inside text, so the joins are unambiguous).

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
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
let FS = "\u{1F}", RS = "\u{1E}"
typealias C = CLLocationCoordinate2D
func pt(_ c: C) -> String { hx(c.latitude) + "/" + hx(c.longitude) }
func pts(_ a: [C]) -> String { a.map(pt).joined(separator: ";") }
func rings(_ r: [[C]]) -> String { r.map(pts).joined(separator: "|") }
var out = ""
func emit(_ f: String...) { out += f.joined(separator: "\t") + "\n" }

struct SM { var s: UInt64
  mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
  mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
  mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
  mutating func chance(_ n: Int) -> Bool { below(n) == 0 } }
var rng = SM(s: 0x48415A4152445346)   // "HAZARDSF"

// ---- the runtime's whitespacesAndNewlines set (the CRE scan trims with it)
do {
    var start: UInt32? = nil; var last: UInt32 = 0
    for v in UInt32(0)...0x10FFFF {
        guard let s = Unicode.Scalar(v) else { continue }
        if CharacterSet.whitespacesAndNewlines.contains(s) {
            if start == nil || v != last &+ 1 { if let st = start { emit("u-wsnl", String(st, radix: 16), String(last, radix: 16), "1") }; start = v }
            last = v
        }
    }
    if let st = start { emit("u-wsnl", String(st, radix: 16), String(last, radix: 16), "1") }
}

let SP: [Double] = [.nan, .infinity, -.infinity, 0, -0.0, 1e300, -1e300, .leastNonzeroMagnitude, .greatestFiniteMagnitude]
let INTS: [Int] = [Int.min, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 100, Int.max]
let centers: [C] = [C(latitude: 43.07, longitude: -89.4), C(latitude: 34.05, longitude: -118.24), C(latitude: 61.22, longitude: -149.9),
  C(latitude: 25.76, longitude: -80.19), C(latitude: 19.43, longitude: -99.13), C(latitude: 47.6, longitude: -122.33), C(latitude: 0, longitude: 0)]
func near(_ c: C, _ spread: Double) -> C {
    C(latitude: c.latitude + (rng.unit() - 0.5) * spread, longitude: c.longitude + (rng.unit() - 0.5) * spread * 1.4)
}
func maybeSpecial(_ v: Double) -> Double { rng.chance(25) ? rng.pick(SP) : v }
func randRing(_ c: C, _ n: Int, _ size: Double) -> [C] {
    (0..<n).map { i in
        let a = Double(i) / Double(max(n, 1)) * 2 * .pi
        return C(latitude: maybeSpecial(c.latitude + size * sin(a) * (0.6 + rng.unit() * 0.4)),
                 longitude: maybeSpecial(c.longitude + size * cos(a) * (0.6 + rng.unit() * 0.4)))
    }
}

// ===================================================================== scalar tables
let doubles: [Double] = SP + [-5, 0.5, 2.9, 3, 5.9, 6, 7.9, 8, 10.9, 11, 12, 25, 49, 50, 51, 99, 100, 101, 149, 150, 199, 200, 201, 300, 400, 1000,
  33.9, 34, 63.9, 64, 82.9, 83, 95.9, 96, 112.9, 113, 136.9, 137, 200]
for d in doubles { emit("hf-air", hx(d), hx(HazardFeedScores.airScore(usAQI: d))); emit("hf-uv", hx(d), hx(HazardFeedScores.uvScore(index: d)))
  emit("hf-tropint", hx(d), hx(HazardFeedScores.tropicalIntensityScore(maxWindKt: d))) }
for i in INTS { emit("hf-space", String(i), hx(HazardFeedScores.spaceWeatherScore(scale: i)))
  emit("hf-avrating", String(i), hx(HazardFeedScores.avalancheRatingScore(i))); emit("hf-spc", String(i), hx(HazardFeedScores.spcCategoricalScore(dn: i))) }
for s in INTS { for g in [0, 1, 3, 5, 9, -2] { for lat in [0.0, 30, 45, 60, 89, -45, .nan, .infinity] {
  emit("hf-rad", String(s), String(g), hx(lat), hx(HazardFeedScores.radiationSpaceWeatherScore(sScale: s, gScale: g, latitude: lat))) } } }
let words = ["", "action", "minor", "moderate", "major", "Major", "MAJOR", "no_flooding", "warning", "WARNING", "Warning", "watch", "WATCH", "advisory",
  "ADVISORY", "Advisory", "normal", "Tsunami Warning", "TSUNAMI WATCH", "advisory\u{301}", "Warnin\u{0301}g", "w\u{0}atch", "\u{1D5AA}dvisory",
  "extreme", "Extreme", "EXTREME", "severe", "Severe", "minor ", " minor", "unknown", "TO", "MA", "SV", "FF", "to", "T\u{0}O", "\u{212A}",
  "\u{FF37}ARNING", "wat\u{200B}ch", "ma\u{301}jor", "Ma\u{0301}jor", "moder\u{AD}ate"]
for w in words {
  emit("hf-floodcat", ht(w), hx(HazardFeedScores.floodCategoryScore(w))); emit("hf-volcanolvl", ht(w), hx(HazardFeedScores.volcanoAlertScore(w)))
  emit("hf-tsulevel", ht(w), hx(HazardFeedScores.tsunamiLevelScore(w))); emit("wa-sev", ht(w), hx(WeatherAlertService.severityScore(w)))
  emit("wa-backup", ht(w), hx(BackupWarningsCache.severity(phenomena: w)))
}

// ===================================================================== geometry
for _ in 0..<300 {
    let c = rng.pick(centers); let n = rng.pick([0, 1, 2, 3, 3, 4, 5, 8, 30]); let ring = randRing(c, n, rng.pick([0.05, 0.3, 2.0]))
    for _ in 0..<3 { let p = rng.chance(4) ? rng.pick(ring.isEmpty ? [c] : ring) : near(c, rng.pick([0.1, 0.6, 3.0]))
        emit("hf-pip", rings([ring]), pt(p), HazardFeedScores.pointInPolygon(p, ring) ? "1" : "0") }
}
for _ in 0..<250 {
    let c = rng.pick(centers); let p = near(c, rng.pick([0.05, 0.3, 1.0, 4.0]))
    let hot = (0..<rng.pick([0, 1, 3, 12, 40])).map { _ in let q = near(c, rng.pick([0.1, 0.5, 2.0])); return (lat: q.latitude, lon: q.longitude, frp: maybeSpecial(rng.pick([0.0, 0.5, 1, 20, 100, 400, -3]) + rng.unit())) }
    emit("hf-fire", hot.map { hx($0.lat) + "/" + hx($0.lon) + "/" + hx($0.frp) }.joined(separator: ","), pt(p), hx(HazardFeedScores.fireScore(hotspots: hot, at: p)))
    let quakes = (0..<rng.pick([0, 1, 4, 15])).map { _ in let q = near(c, rng.pick([0.2, 1.5, 4.0])); return (lat: q.latitude, lon: q.longitude, magnitude: maybeSpecial(rng.unit() * 9), ageHours: maybeSpecial(rng.unit() * 48 - 2)) }
    emit("hf-seis", quakes.map { [hx($0.lat), hx($0.lon), hx($0.magnitude), hx($0.ageHours)].joined(separator: "/") }.joined(separator: ","), pt(p), hx(HazardFeedScores.seismicScore(quakes: quakes, at: p)))
    let perims = (0..<rng.pick([0, 1, 2, 5])).map { _ in randRing(near(c, 0.6), rng.pick([0, 1, 2, 3, 4, 6, 12]), rng.pick([0.02, 0.1, 0.4])) }
    emit("hf-perim", rings(perims), pt(p), hx(HazardFeedScores.firePerimeterScore(perimeters: perims, at: p)))
    let gauges = (0..<rng.pick([0, 2, 6])).map { _ in let q = near(c, 0.4); return (lat: q.latitude, lon: q.longitude, category: rng.pick(words)) }
    emit("hf-gauge", gauges.map { [hx($0.lat), hx($0.lon), ht($0.category)].joined(separator: FS) }.joined(separator: RS), pt(p), hx(HazardFeedScores.floodGaugeScore(gauges: gauges, at: p)))
    let water = (0..<rng.pick([0, 1, 5])).map { _ in near(c, 0.15) }
    emit("hf-water", pts(water), pt(p), hx(HazardFeedScores.waterProximityScore(waterPoints: water, at: p)))
    let volc = (0..<rng.pick([0, 1, 3])).map { _ in let q = near(c, 1.5); return (lat: q.latitude, lon: q.longitude, level: rng.pick(words)) }
    emit("hf-volc", volc.map { [hx($0.lat), hx($0.lon), ht($0.level)].joined(separator: FS) }.joined(separator: RS), pt(p), hx(HazardFeedScores.volcanicScore(volcanoes: volc, at: p)))
    let av = (0..<rng.pick([0, 1, 3])).map { _ in (rings: (0..<rng.pick([1, 1, 2, 3])).map { _ in randRing(near(c, 0.5), rng.pick([3, 4, 6]), 0.4) }, rating: rng.pick(INTS)) }
    emit("hf-aval", av.map { rings($0.rings) + FS + String($0.rating) }.joined(separator: RS), pt(p), hx(HazardFeedScores.avalancheScore(zones: av, at: p)))
    let storms = (0..<rng.pick([0, 1, 3])).map { _ in let q = near(c, rng.pick([1.0, 4.0])); return (lat: q.latitude, lon: q.longitude, maxWindKt: maybeSpecial(rng.unit() * 160)) }
    emit("hf-trop", storms.map { [hx($0.lat), hx($0.lon), hx($0.maxWindKt)].joined(separator: "/") }.joined(separator: ","), pt(p), hx(HazardFeedScores.tropicalScore(storms: storms, at: p)))
    let tsu = (0..<rng.pick([0, 1, 3])).map { _ in let q = near(c, rng.pick([1.0, 6.0])); return (lat: q.latitude, lon: q.longitude, level: rng.pick(words)) }
    emit("hf-tsu", tsu.map { [hx($0.lat), hx($0.lon), ht($0.level)].joined(separator: FS) }.joined(separator: RS), pt(p), hx(HazardFeedScores.tsunamiScore(events: tsu, at: p)))
    let spc = (0..<rng.pick([0, 1, 3])).map { _ in (rings: (0..<rng.pick([1, 2])).map { _ in randRing(near(c, 0.5), rng.pick([3, 5]), 0.5) }, score: maybeSpecial(rng.pick([0.35, 0.45, 0.6, 0.72, 0.88, 1.0, 0]))) }
    emit("hf-outlook", spc.map { rings($0.rings) + FS + hx($0.score) }.joined(separator: RS), pt(p), hx(HazardFeedScores.outlookScore(zones: spc, at: p)))
    let closures = (0..<rng.pick([0, 1, 4])).map { _ in let q = near(c, rng.pick([0.005, 0.03, 0.3])); return (lat: q.latitude, lon: q.longitude) }
    emit("hf-closure", closures.map { hx($0.lat) + "/" + hx($0.lon) }.joined(separator: ","), pt(p), hx(HazardFeedScores.closureScore(closures: closures, at: p)))
}

// ===================================================================== the live snapshot
func snapshot(_ c: C) -> LiveHazardSnapshot {
    var s = LiveHazardSnapshot()
    s.hotspots = (0..<rng.pick([0, 2, 10])).map { _ in let q = near(c, rng.pick([0.2, 3, 20])); return (lat: q.latitude, lon: q.longitude, frp: rng.unit() * 300) }
    s.perimeters = (0..<rng.pick([0, 1, 3])).map { _ in randRing(near(c, rng.pick([0.3, 8])), rng.pick([1, 3, 5]), 0.1) }
    s.quakes = (0..<rng.pick([0, 2])).map { _ in let q = near(c, 3); return (lat: q.latitude, lon: q.longitude, magnitude: rng.unit() * 8, ageHours: rng.unit() * 30) }
    s.space = (r: rng.pick(INTS), s: rng.pick([0, 1, 3, 5]), g: rng.pick([0, 2, 4]))
    s.volcanoes = (0..<rng.pick([0, 1])).map { _ in let q = near(c, 2); return (lat: q.latitude, lon: q.longitude, level: rng.pick(words)) }
    s.avalancheZones = (0..<rng.pick([0, 1])).map { _ in (rings: [randRing(near(c, 1), 4, 0.8)], rating: rng.pick([1, 3, 4])) }
    s.storms = (0..<rng.pick([0, 1])).map { _ in let q = near(c, rng.pick([2, 15])); return (lat: q.latitude, lon: q.longitude, maxWindKt: rng.unit() * 150) }
    s.tsunamis = (0..<rng.pick([0, 1])).map { _ in let q = near(c, rng.pick([3, 15])); return (lat: q.latitude, lon: q.longitude, level: rng.pick(words)) }
    s.spcZones = (0..<rng.pick([0, 1, 2])).map { _ in (rings: [randRing(near(c, 1), 5, 1.2)], score: rng.pick([0.45, 0.72, 1.0])) }
    return s
}
func enc(_ s: LiveHazardSnapshot) -> String {
    [s.hotspots.map { hx($0.lat) + "/" + hx($0.lon) + "/" + hx($0.frp) }.joined(separator: ","),
     rings(s.perimeters),
     s.quakes.map { [hx($0.lat), hx($0.lon), hx($0.magnitude), hx($0.ageHours)].joined(separator: "/") }.joined(separator: ","),
     "\(s.space.r)/\(s.space.s)/\(s.space.g)",
     s.volcanoes.map { [hx($0.lat), hx($0.lon), ht($0.level)].joined(separator: FS) }.joined(separator: RS),
     s.avalancheZones.map { rings($0.rings) + FS + String($0.rating) }.joined(separator: RS),
     s.storms.map { [hx($0.lat), hx($0.lon), hx($0.maxWindKt)].joined(separator: "/") }.joined(separator: ","),
     s.tsunamis.map { [hx($0.lat), hx($0.lon), ht($0.level)].joined(separator: FS) }.joined(separator: RS),
     s.spcZones.map { rings($0.rings) + FS + hx($0.score) }.joined(separator: RS)].joined(separator: "\t")
}
for _ in 0..<120 {
    let c = rng.pick(centers); let s = snapshot(c)
    for _ in 0..<4 {
        let p = near(c, rng.pick([0.2, 2, 9]))
        let f = HazardFeedScores.live(at: p, snapshot: s)
        let contrib = f.bandInputContribution
        let names = ["fire", "seismic", "radiation", "volcanic", "avalanche", "tropical", "tsunami", "convective"].filter { contrib[$0] != nil }
        emit("hf-live", enc(s), pt(p), lst([f.fire, f.seismic, f.spaceRadiation, f.volcanic, f.avalanche, f.tropical, f.tsunami, f.convective].map(hx)), names.joined(separator: ","))
    }
    let box = (minLat: c.latitude - rng.pick([0.5, 3, 40]), minLon: c.longitude - rng.pick([0.5, 3, 40]), maxLat: c.latitude + rng.pick([0.5, 3, 40]), maxLon: c.longitude + rng.pick([0.5, 3, 40]))
    let clipped = s.clipped(minLat: box.minLat, minLon: box.minLon, maxLat: box.maxLat, maxLon: box.maxLon)
    emit("hf-clip", enc(s), hx(box.minLat), hx(box.minLon), hx(box.maxLat), hx(box.maxLon), enc(clipped))
}

// ===================================================================== the alert service statics
for _ in 0..<200 {
    let p = rng.chance(6) ? C(latitude: maybeSpecial(rng.unit() * 180 - 90), longitude: maybeSpecial(rng.unit() * 360 - 180)) : near(rng.pick(centers), rng.pick([0.5, 5, 30]))
    if p.latitude.isFinite, p.longitude.isFinite, abs(p.latitude) < 1e6, abs(p.longitude) < 1e6 {
        emit("wa-cell", pt(p), ht(WeatherAlertService.cellKey(p)))
    }
    emit("wa-states", pt(p), WeatherAlertService.statesContaining(p).sorted().joined(separator: ","))
    emit("wa-marine", pt(p), WeatherAlertService.marineRegionsContaining(p).joined(separator: ","))
}
for (la, lo) in [(30.1, -88.5), (35.0, -84.9), (43.5, -97.2), (49.4, -89.5), (30.0, -115.0), (50.0, -115.0), (31.5, -98.0), (40.5, -93.0), (49.5, -75.5), (24.0, -83.0)] {
    let p = C(latitude: la, longitude: lo)
    emit("wa-states", pt(p), WeatherAlertService.statesContaining(p).sorted().joined(separator: ","))
    emit("wa-marine", pt(p), WeatherAlertService.marineRegionsContaining(p).joined(separator: ","))
}
typealias Alert = WeatherAlertService.NWSAlert
func randAlert(_ c: C, id: String) -> Alert {
    let hasPoly = rng.chance(2)
    let poly: [C]? = hasPoly ? randRing(near(c, 0.3), rng.pick([0, 2, 3, 4, 7]), rng.pick([0.2, 1.0])) : nil
    let extra: [[C]] = rng.chance(3) ? (0..<rng.pick([1, 2])).map { _ in randRing(near(c, 0.5), rng.pick([2, 3, 5]), 0.4) } : []
    let zones: [String] = rng.chance(2) ? (0..<rng.pick([1, 2, 3])).map { _ in "z\(rng.below(5))" } : []
    let expires: Date? = rng.chance(3) ? nil : Date(timeIntervalSinceReferenceDate: rng.pick([-1e9, 0, 1e9, 2e9, 3e9, 1.5e9, .nan]))
    return Alert(id: id, event: rng.pick(["Flood Warning", "Tornado Warning", "Wind Advisory", "Red Flag Warning", "Special Weather Statement"]),
                 headline: "h", severityScore: rng.pick([0.95, 0.88, 0.72, 0.45, 0.30, .nan, 0.88]), polygon: poly, extraRings: extra,
                 expires: expires, affectedZones: zones)
}
func encAlert(_ a: Alert) -> String {
    [ht(a.id), ht(a.event), hx(a.severityScore), a.polygon.map(pts) ?? "-", a.extraRings.isEmpty ? "-" : rings(a.extraRings),
     a.expires.map { hx($0.timeIntervalSinceReferenceDate) } ?? "-", a.affectedZones.map(ht).joined(separator: ",")].joined(separator: FS)
}
for _ in 0..<150 {
    let c = rng.pick(centers)
    let alerts = (0..<rng.pick([0, 1, 3, 6])).map { i in randAlert(c, id: "a\(i)") }
    var zoneRings: [String: [[C]]] = [:]
    for z in 0..<5 where rng.chance(2) { zoneRings["z\(z)"] = (0..<rng.pick([1, 2])).map { _ in randRing(near(c, 0.4), rng.pick([2, 3, 5]), 0.5) } }
    let p = near(c, rng.pick([0.1, 0.5, 2.0]))
    let covering = WeatherAlertService.alertsCovering(p, alerts: alerts, zoneRings: zoneRings)
    let idx = covering.compactMap { a in alerts.firstIndex { $0.id == a.id } }
    emit("wa-cover", pt(p), alerts.map(encAlert).joined(separator: RS),
         zoneRings.keys.sorted().map { ht($0) + FS + rings(zoneRings[$0]!) }.joined(separator: RS), idx.map(String.init).joined(separator: ","))
    // provisional samples over the cells these alerts land in
    let samples = (0..<rng.pick([0, 1, 4, 9])).map { _ in near(c, rng.pick([0.1, 1.0])) }
    var cellAlerts: [String: [Alert]] = [:]
    for s in samples where rng.chance(3) == false { cellAlerts[WeatherAlertService.cellKey(s)] = alerts.filter { _ in rng.chance(2) } }
    let offsets: [TimeInterval]? = rng.chance(3) ? nil : samples.indices.map { _ in rng.pick([0, 600, 3600, 86400, -5, .nan]) }
    let now = Date(timeIntervalSinceReferenceDate: rng.pick([0, 1e9, 1.5e9, 2.5e9]))
    let got = WeatherAlertService.provisionalSamples(samples: samples, cellAlerts: cellAlerts, arrivalOffsets: offsets, now: now)
    emit("wa-prov", pts(samples), alerts.map(encAlert).joined(separator: RS),
         cellAlerts.keys.sorted().map { k in ht(k) + FS + cellAlerts[k]!.map { a in String(alerts.firstIndex { $0.id == a.id }!) }.joined(separator: ",") }.joined(separator: RS),
         offsets.map { lst($0.map(hx)) } ?? "-", hx(now.timeIntervalSinceReferenceDate),
         got.map { s in s.map { [hx($0.risk), hto($0.worstEvent), hto($0.alertID)].joined(separator: FS) } ?? "-" }.joined(separator: RS))
}
// allRings: outer rings as GeoJSON coordinate lists (some short, some huge), decimated
for _ in 0..<120 {
    let c = rng.pick(centers)
    let raws: [[[Double]]] = (0..<rng.pick([1, 2, 3])).map { _ in
        let n = rng.pick([1, 2, 3, 4, 10, 149, 150, 151, 299, 300, 301, 1000, 2000])
        return (0..<n).map { i -> [Double] in
            let k = rng.chance(9) ? rng.pick([0, 1, 3]) : 2
            let q = near(c, 1.0); let coords = [q.longitude, q.latitude, Double(i)]
            return Array(coords.prefix(k)) }
    }
    let maxPoints = rng.pick([150, 150, 600, 3, 1])
    let got = WeatherAlertService.allRings(of: ["type": "MultiPolygon", "coordinates": raws.map { [$0] }], maxPoints: maxPoints)
    emit("wa-rings", raws.map { $0.map { $0.map(hx).joined(separator: "/") }.joined(separator: ";") }.joined(separator: "|"), String(maxPoints), rings(got))
}

// ===================================================================== the CRE fuel files
let idPool = ["1", "12345", "E12345", "\u{212A}9", "9\u{301}", "", "12 ", "a\"b"]
let typePool = ["regular", "premium", "diesel", "Regular", "regular\u{301}", "", "gas\u{200B}", "diesel"]
let numPool = ["23.7", "25.4", " 23.7", "23.7 ", "abc", "", "1e2", "0x1p3", "nan", "-5", "23,7", "24.\u{0}9", "\u{663}3", "19.43", "40", "13", "34", "13.0001", "33.9999", "-99.13", "\n 19.5\n", "\u{2028}20\u{85}", "\u{A0}21\u{3000}"]
func priceXML() -> String {
    var s = "<places>"
    for _ in 0..<rng.pick([0, 1, 3, 8]) {
        s += "<place place_id=\"\(rng.pick(idPool))\">"
        if rng.chance(6) { s += "<gas_price type=\"broken" }
        for _ in 0..<rng.pick([0, 1, 2, 3]) { s += "<gas_price type=\"\(rng.pick(typePool))\">\(rng.pick(numPool))</gas_price>" }
        if rng.chance(8) { s += "<other>$1</other>" }
        s += rng.chance(9) ? "</plac>" : "</place>"
        if rng.chance(5) { s += rng.pick(["\n", "\u{301}", "<place place_id=\"orphan\">", "</place>"]) }
    }
    return s + "</places>"
}
func placeXML() -> String {
    var s = "<places>"
    for _ in 0..<rng.pick([0, 1, 3, 8]) {
        s += "<place place_id=\"\(rng.pick(idPool))\">"
        if rng.chance(4) { s += "<x>\(rng.pick(numPool))</x>" } else { s += "<x>\(rng.pick(["-99.13", "-100.5", "-89", " -98.2\n", "lon"]))</x>" }
        if rng.chance(4) { s += "<y>\(rng.pick(numPool))</y>" } else { s += "<y>\(rng.pick(["19.43", "25.67", "13", "34", "33.99", "13.01", " 20 ", "\u{A0}21\u{3000}"]))</y>" }
        if rng.chance(5) { s += "<name>Pemex \u{1F1F2}\u{1F1FD}</name>" }
        s += rng.chance(9) ? "</plac>" : "</place>"
    }
    return s + "</places>"
}
for _ in 0..<150 {
    let px = priceXML()
    let got = MexicoFuelParsing.parsePrices(px)
    emit("mx-prices", ht(px), got.keys.sorted().map { id in ht(id) + FS + got[id]!.keys.sorted().map { ht($0) + "=" + hx(got[id]![$0]!) }.joined(separator: ",") }.joined(separator: RS))
    let lx = placeXML()
    let places = MexicoFuelParsing.parsePlaces(lx)
    emit("mx-places", ht(lx), places.keys.sorted().map { id in ht(id) + FS + hx(places[id]!.latitude) + FS + hx(places[id]!.longitude) }.joined(separator: RS))
}

FileHandle.standardOutput.write(out.data(using: .utf8)!)
