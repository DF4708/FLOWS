import CoreLocation
import Foundation
import MapKit
// Frozen oracle: every output below comes from the ORIGINAL RiskFieldService (with the
// ORIGINAL HarmonicClimatology it rescored against), before that code moved to Rust.
// Doubles are IEEE-754 bit patterns in hex; text is "t:" + UTF-8 with every byte outside
// 0x20...0x7E, and the backslash, written as \xx; raw bytes are "b:" + hex; nil is "-";
// lists are "L<n>:" + comma-joined items; an entry is its fields joined by U+001F and
// entries are joined by U+001E (both escaped inside text, so the joins are unambiguous).

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
func hb(_ b: [UInt8]) -> String { "b:" + b.map { String(format: "%02x", $0) }.joined() }
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
var rng = SM(s: 0x5249534B4649454C)   // "RISKFIEL"

typealias Entry = RiskFieldService.ZipEntry
let FS = "\u{1F}", RS = "\u{1E}"
func ent(_ e: Entry) -> String {
    [ht(e.zip), hx(e.centroid.latitude), hx(e.centroid.longitude), e.scores.map(hx).joined(separator: ","),
     hto(e.summary), e.ring.map { $0.map { hx($0.latitude) + "/" + hx($0.longitude) }.joined(separator: ",") } ?? "-"]
        .joined(separator: FS)
}
func ents(_ es: [Entry]) -> String { es.map(ent).joined(separator: RS) }

// ---- FRB1 builder: the writer's layout (bundle-frb.rs), byte for byte
func le16(_ v: UInt16, _ b: inout [UInt8]) { b.append(UInt8(v & 0xFF)); b.append(UInt8(v >> 8)) }
func le32(_ v: UInt32, _ b: inout [UInt8]) { for i in 0..<4 { b.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
func le64(_ v: UInt64, _ b: inout [UInt8]) { for i in 0..<8 { b.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
func f64b(_ d: Double, _ b: inout [UInt8]) { le64(d.bitPattern, &b) }
struct RawZip { var zip: [UInt8]; var lat: Double; var lon: Double; var scores: [Double]; var summary: [UInt8]?; var ring: [(Double, Double)]? }
func frb1(generated: [UInt8], fams: [[UInt8]], zips: [RawZip], version: UInt32 = 1, nFams: UInt32? = nil, nZips: UInt32? = nil,
          genLen: UInt32? = nil, hashDelta: UInt64 = 0, trailing: [UInt8] = [], magic: [UInt8] = Array("FRB1".utf8)) -> [UInt8] {
    var p: [UInt8] = generated
    for f in fams { p.append(UInt8(truncatingIfNeeded: f.count)); p += f }
    for z in zips { p += z.zip }
    for z in zips { f64b(z.lon, &p); f64b(z.lat, &p) }
    for z in zips { for s in z.scores { f64b(s, &p) } }
    for z in zips { if let s = z.summary { le16(UInt16(s.count), &p); p += s } else { le16(0, &p) } }
    for z in zips { if let r = z.ring { le16(UInt16(r.count), &p); for (lon, lat) in r { f64b(lon, &p); f64b(lat, &p) } } else { le16(0, &p) } }
    p += trailing
    var h: UInt64 = 0xcbf29ce484222325
    for b in p { h ^= UInt64(b); h = h &* 0x100000001b3 }
    var out = magic
    le32(version, &out); le32(nFams ?? UInt32(fams.count), &out); le32(nZips ?? UInt32(zips.count), &out)
    le32(genLen ?? UInt32(generated.count), &out); le64(h &+ hashDelta, &out)
    return out + p
}
func u8s(_ s: String) -> [UInt8] { Array(s.utf8) }
func parseOut(_ bytes: [UInt8]) -> String {
    guard let (entries, fams, gen) = RiskFieldService.parseFRB1(Data(bytes)) else { return "-" }
    return [ht(gen), lst(fams.map(ht)), ents(entries)].joined(separator: "\t")
}
func emitParse(_ id: String, _ bytes: [UInt8]) { emit("rf-parse", id, hb(bytes), parseOut(bytes)) }

// ---- shard pools
let SP: [Double] = [.nan, .infinity, -.infinity, 0, -0.0, 1e300, -1e-300, .leastNonzeroMagnitude, 0.6, -0.1, 1.5]
let zipPool: [[UInt8]] = [u8s("53703"), u8s("85004"), u8s("99999"), u8s("00000"), u8s("01001"), u8s("abcde"), [0xff, 0xfe, 0x41, 0x42, 0x43],
  u8s("5370\u{0}"), u8s("  123"), u8s("Z9999")]
let summaryPool: [[UInt8]?] = [nil, nil, u8s("windy"), u8s("Flood & ice: Caf\u{E9} \u{1F327}"), u8s(""), [0xc3, 0x28, 0x41], u8s("x")]
func score(_ r: inout SM) -> Double { r.chance(9) ? r.pick(SP) : Double(r.below(13)) / 20.0 }
func ring(_ r: inout SM, _ lat: Double, _ lon: Double) -> [(Double, Double)]? {
    let n = r.pick([0, 0, 0, 1, 2, 3, 3, 4, 6])
    if n == 0 { return nil }
    return (0..<n).map { _ in (lon + (r.unit() - 0.5) * 0.1, lat + (r.unit() - 0.5) * 0.1) }
}
/// A random shard: `count` zips around `center`, dense enough that cells hold several.
func randomShard(_ r: inout SM, count: Int, center: (Double, Double), spread: Double, fams: [String]) -> [UInt8] {
    var zips: [RawZip] = []
    for i in 0..<count {
        let lat = center.0 + (r.unit() - 0.5) * spread, lon = center.1 + (r.unit() - 0.5) * spread * 1.5
        let zip = r.chance(6) ? r.pick(zipPool) : u8s(String(format: "%05d", (i * 7919 + r.below(90000)) % 100000))
        zips.append(RawZip(zip: zip, lat: lat, lon: lon, scores: fams.map { _ in score(&r) }, summary: r.pick(summaryPool),
                           ring: ring(&r, lat, lon)))
    }
    if count > 1 && r.chance(2) { zips[1].lat = zips[0].lat; zips[1].lon = zips[0].lon }   // a duplicated centroid: ties
    return frb1(generated: u8s(r.pick(["2026-07-04T11:39:45Z", "", "gen\u{301}"])), fams: fams.map(u8s), zips: zips)
}

// ===================================================================== rf-parse
let hand = frb1(generated: u8s("2026-07-04T11:39:45Z"), fams: [u8s("wind"), u8s("fire")], zips: [
    RawZip(zip: u8s("01001"), lat: 42.0624, lon: -72.6258, scores: [0.125, 0.5], summary: u8s("windy"), ring: nil),
    RawZip(zip: u8s("99999"), lat: 40.25, lon: -100.5, scores: [0, 0.043], summary: nil, ring: [(-100.0, 40.0), (-100.1, 40.1), (-100.2, 40.0)])])
emitParse("hand", hand)
var corrupt = hand; corrupt[40] ^= 0xFF; emitParse("hash", corrupt)
emitParse("trunc5", Array(hand.prefix(hand.count - 5)))
emitParse("trunc1", Array(hand.prefix(hand.count - 1)))
emitParse("header-only", Array(hand.prefix(28)))
emitParse("header-plus1", Array(hand.prefix(29)))
emitParse("empty", [])
emitParse("magic", Array("XXXX".utf8) + Array(hand.dropFirst(4)))
emitParse("version2", frb1(generated: u8s("g"), fams: [u8s("a")], zips: [], version: 2))
emitParse("nofams", frb1(generated: u8s("g"), fams: [], zips: []))
emitParse("nozips", frb1(generated: u8s("g"), fams: [u8s("a"), u8s("b")], zips: []))
emitParse("badfamcount", frb1(generated: u8s("g"), fams: [u8s("a")], zips: [], nFams: 2))
emitParse("badzipcount", frb1(generated: u8s("g"), fams: [u8s("a")], zips: [RawZip(zip: u8s("11111"), lat: 1, lon: 2, scores: [0.1], summary: nil, ring: nil)], nZips: 2))
emitParse("badgenlen", frb1(generated: u8s("gen"), fams: [u8s("a")], zips: [], genLen: 4))
emitParse("shortgenlen", frb1(generated: u8s("gen"), fams: [u8s("a")], zips: [], genLen: 2))
emitParse("trailing", frb1(generated: u8s("g"), fams: [u8s("a")], zips: [], trailing: [0]))
emitParse("hashoff", frb1(generated: u8s("g"), fams: [u8s("a")], zips: [], hashDelta: 1))
emitParse("ring2", frb1(generated: u8s("g"), fams: [u8s("a")], zips: [RawZip(zip: u8s("11111"), lat: 1, lon: 2, scores: [0.1], summary: u8s(""), ring: [(1, 2), (3, 4)])]))
emitParse("badutf8", frb1(generated: [0xff, 0x41], fams: [[0xc3, 0x28], u8s("b\u{0}c")], zips: [RawZip(zip: [0xff, 0xfe, 0x41, 0x42, 0x43], lat: 1, lon: 2, scores: [.nan, 0.5], summary: [0xed, 0xa0, 0x80, 0x41], ring: nil)]))
emitParse("bom", frb1(generated: [0xef, 0xbb, 0xbf] + u8s("x"), fams: [[0xef, 0xbb, 0xbf] + u8s("f")], zips: [RawZip(zip: [0xef, 0xbb, 0xbf, 0x41, 0x42], lat: 1, lon: 2, scores: [0.2], summary: [0xef, 0xbb, 0xbf], ring: nil)]))
emitParse("dupfam", frb1(generated: u8s("g"), fams: [u8s("a"), u8s("a"), u8s("b")], zips: [RawZip(zip: u8s("11111"), lat: 1, lon: 2, scores: [0.1, 0.2, 0.3], summary: nil, ring: nil)]))
let famSets: [[String]] = [["wind", "fire"], ["environmental", "flood", "winter", "heat", "convective", "wind", "fire", "cold"], ["x"]]
for i in 0..<30 {
    let shard = randomShard(&rng, count: [0, 1, 2, 3, 8, 25, 60][i % 7], center: (rng.pick([43.0, 30.0, 65.0, 71.3, -0.05, 89.5]), rng.pick([-89.4, -95.0, -150.0, -179.9, 0.0])),
                            spread: rng.pick([0.05, 0.4, 2.0, 12.0]), fams: rng.pick(famSets))
    emitParse("r\(i)", shard)
}

// ===================================================================== rf-near / rf-zips: the loaded service
// The service reads its bundle from $FLOWS_REPO/data/runtime_cache/app_risk_bundle.frb1 on macOS; a temp
// repo holds one shard at a time and a fresh service instance loads it (no harmonic table there, so no rescore).
let repo = FileManager.default.temporaryDirectory.appendingPathComponent("flows-risk-oracle-\(getpid())")
try! FileManager.default.createDirectory(at: repo.appendingPathComponent("data/runtime_cache"), withIntermediateDirectories: true)
setenv("FLOWS_REPO", repo.path, 1)
@MainActor func loadedService(_ shard: [UInt8]) async -> RiskFieldService? {
    try! Data(shard).write(to: repo.appendingPathComponent("data/runtime_cache/app_risk_bundle.frb1"))
    let svc = RiskFieldService()
    for _ in 0..<2000 {
        if svc.loaded { return svc }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return nil
}
func rowOut(_ row: [Double]?) -> String { row.map { lst($0.map(hx)) } ?? "-" }
let nearTargets: [(Double, Double)] = [(43.0, -89.4), (65.0, -150.0), (71.3, -156.8), (30.0, -95.0), (-0.05, 0.0), (89.5, -179.9), (47.6, -122.3)]
var shardId = 0
for (cLat, cLon) in nearTargets {
    for spread in [0.05, 0.4, 3.0] {
        var r2 = SM(s: rng.next())
        let fams = rng.pick(famSets)
        let shard = randomShard(&r2, count: rng.pick([3, 12, 40, 90]), center: (cLat, cLon), spread: spread, fams: fams)
        emit("rf-shard", "s\(shardId)", hb(shard))
        guard let svc = await loadedService(shard) else { emit("rf-loadfail", "s\(shardId)"); shardId += 1; continue }
        emit("rf-families", "s\(shardId)", lst(svc.families.map(ht)), hto(svc.generatedUTC))
        var queries: [(Double, Double)] = [(cLat, cLon), (cLat + 0.27, cLon), (cLat, cLon + 0.27), (cLat + 0.5, cLon), (cLat, cLon + 2.0),
                                           (cLat - 0.1, cLon - 0.1), (cLat + 0.19, cLon + 0.19), (cLat + 0.2, cLon + 0.2)]
        // Exactly on centroids and just beside them (ties between a duplicated pair; boundary of the reach).
        let parsed = RiskFieldService.parseFRB1(Data(shard))!.entries
        for e in parsed.prefix(6) {
            queries.append((e.centroid.latitude, e.centroid.longitude))
            queries.append((e.centroid.latitude + 0.001, e.centroid.longitude - 0.002))
            queries.append((e.centroid.latitude, e.centroid.longitude + 0.27 / cos(e.centroid.latitude * .pi / 180)))
        }
        for _ in 0..<25 { queries.append((cLat + (rng.unit() - 0.5) * spread * 1.4, cLon + (rng.unit() - 0.5) * spread * 2.2)) }
        for (la, lo) in queries {
            let c = CLLocationCoordinate2D(latitude: la, longitude: lo)
            emit("rf-near", "s\(shardId)", hx(la), hx(lo), rowOut(svc.scoreRow(at: c)), hto(svc.summary(at: c)))
        }
        for fam in fams + ["nope"] {
            for (dLat, dLon) in [(0.1, 0.1), (1.0, 2.0), (spread * 1.2, spread * 2.0), (180.0, 360.0), (0.0, 0.0), (-1.0, 1.0)] {
                for limit in [0, 3, 220, 100_000] {
                    let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: cLat + (rng.unit() - 0.5) * spread, longitude: cLon),
                                                    span: MKCoordinateSpan(latitudeDelta: dLat, longitudeDelta: dLon))
                    emit("rf-zips", "s\(shardId)", hx(region.center.latitude), hx(region.center.longitude), hx(dLat), hx(dLon), ht(fam), String(limit),
                         lst(svc.zips(in: region, family: fam, limit: limit).map { ht($0.zip) }))
                }
            }
        }
        shardId += 1
    }
}
try? FileManager.default.removeItem(at: repo)

// ===================================================================== rf-select: the static selection over entry arrays
func randomEntries(_ r: inout SM, _ n: Int, _ cLat: Double, _ cLon: Double, famCount: Int) -> [Entry] {
    (0..<n).map { k in
        let lat = cLat + (r.unit() - 0.5) * 8, lon = cLon + (r.unit() - 0.5) * 12
        let scores = (0..<(r.chance(7) ? r.below(famCount + 2) : famCount)).map { _ in r.chance(6) ? r.pick(SP) : Double(r.below(5)) / 4.0 }
        let ringed: [CLLocationCoordinate2D]? = k % 4 == 0 ? nil : [CLLocationCoordinate2D(latitude: lat, longitude: lon)]
        return Entry(zip: "z\(k)", centroid: CLLocationCoordinate2D(latitude: lat, longitude: lon), scores: scores,
                     summary: r.chance(3) ? "s\(k)" : nil, ring: ringed)
    }
}
for i in 0..<20 {
    let cLat = 25 + rng.unit() * 30, cLon = -120 + rng.unit() * 45
    let entries = randomEntries(&rng, rng.pick([0, 1, 7, 60, 300, 500]), cLat, cLon, famCount: 2)
    emit("rf-set", "e\(i)", ents(entries))
    let grid = RiskFieldService.buildGrid(entries)
    let boxes: [(Double, Double, Double, Double)] = [(cLat - 1, cLat + 1, cLon - 1.5, cLon + 1.5), (cLat - 0.3, cLat + 0.3, cLon - 0.3, cLon + 0.3),
        (-90, 90, -180, 180), (80, 85, 100, 120), (cLat + 1, cLat - 1, cLon, cLon + 1), (cLat, cLat, cLon, cLon), (.nan, cLat, cLon, cLon + 1),
        (-.infinity, .infinity, -.infinity, .infinity), (cLat - 4, cLat + 4, cLon - 6, cLon + 6), (-1e9, 1e9, -1e9, 1e9)]
    for (a, b, c, d) in boxes {
        for fi in [0, 1, 7] {
            for limit in [0, 5, 50, 10_000] {
                emit("rf-select", "e\(i)", hx(a), hx(b), hx(c), hx(d), String(fi), String(limit),
                     lst(RiskFieldService.selectZips(entries: entries, grid: grid, latMin: a, latMax: b, lonMin: c, lonMax: d, fi: fi, limit: limit).map { ht($0.zip) }))
            }
        }
    }
}

// ===================================================================== rf-rescore: harmonicRescore against a synthetic FLHH table
func flhhLe32(_ v: UInt32, _ b: inout [UInt8]) { le32(v, &b) }
func flhh(fams: [[UInt8]], zips: [[UInt8]], coeffBits: [UInt32]) -> [UInt8] {
    var b = Array("FLHH".utf8)
    flhhLe32(1, &b); flhhLe32(UInt32(zips.count), &b); flhhLe32(UInt32(fams.count), &b)
    for f in fams { b.append(UInt8(truncatingIfNeeded: f.count)); b += f }
    for z in zips { b += z }
    for c in coeffBits { flhhLe32(c, &b) }
    return b
}
func fb(_ a: [Float]) -> [UInt32] { a.map(\.bitPattern) }
var tables: [(String, [UInt8])] = []
do {
    var r3 = SM(s: 0x464C4848)
    let famsA = ["winter", "heat", "wind"], zipsA = ["01001", "53703", "85004", "99999", "53703"]
    var coeffs: [Float] = []
    for _ in 0..<(zipsA.count * famsA.count) { for k in 0..<5 { coeffs.append(k == 0 ? Float(r3.unit() * 0.7) : Float((r3.unit() - 0.5) * 0.4)) } }
    tables.append(("t0", flhh(fams: famsA.map(u8s), zips: zipsA.map(u8s), coeffBits: fb(coeffs))))
    tables.append(("t1", flhh(fams: [u8s("fire")], zips: [u8s("00000")], coeffBits: fb([0.5, 0.5, 0, 0, 0]))))
}
for (tid, bytes) in tables {
    emit("rf-table", tid, hb(bytes))
    guard let table = HarmonicClimatology(data: Data(bytes)) else { emit("rf-tablefail", tid); continue }
    for week in [0, 1, 13, 26, 51, 52, -1, 104] {
        for (fi, famsB) in [["wind", "fire"], ["heat", "winter", "wind"], ["environmental", "flood"], ["winter", "winter"]].enumerated() {
            var r4 = SM(s: rng.next())
            let entries: [Entry] = (0..<40).map { k in
                let zip = r4.pick(["01001", "53703", "85004", "99999", "00000", "abcde", "5370"])
                let lat = 40.0 + r4.unit(), lon = -90.0 - r4.unit()
                return Entry(zip: zip, centroid: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                             scores: (0..<(r4.chance(5) ? r4.below(4) : famsB.count)).map { _ in Double(r4.below(10)) / 10 },
                             summary: nil, ring: k % 5 == 0 ? [CLLocationCoordinate2D(latitude: lat, longitude: lon)] : nil)
            }
            let famIdx: [(bundle: Int, harmonic: Int)] = famsB.enumerated().compactMap { (i, name) in table.families.firstIndex(of: name).map { (i, $0) } }
            var got = entries
            let rebuilt = RiskFieldService.harmonicRescore(entries: &got, table: table, trig: HarmonicClimatology.WeekTrig(week: week), famIdx: famIdx)
            emit("rf-rescore", tid, String(week), lst(famsB.map(ht)), ents(entries), String(rebuilt), ents(got))
        }
    }
}

FileHandle.standardOutput.write(out.data(using: .utf8)!)
