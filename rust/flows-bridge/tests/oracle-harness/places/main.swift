import CoreLocation
import Foundation
import MapKit
// Frozen oracle: every output below comes from the ORIGINAL POIRanking (RoutePath, the rankers, the name tables),
// PlacesShard and PlacesStore (the FPS1 reader, its query, the store's state pick and cross-shard merge),
// POIService's shard groups, rank, merged, rowKey and corridorAhead, FuelType's cost table and
// EverydayPlace.attributeID — commit 0f8894b, the last before their facade switch — linked against the
// Rust bridge for the facades those files already called. POIService's private members are made visible
// by an access-only edit (see README). Doubles are IEEE-754 bit patterns in hex; text is "t:" + UTF-8 with
// bytes outside 0x20...0x7E, and the backslash, as \xx; nil is "-"; lists are "L<n>:" + comma-joined items;
// a point is hx(lat)/hx(lon), points join with ";"; items carrying text join their fields with U+001F and
// each other with U+001E. Shards are hex bytes.

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
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
let HEX = Array("0123456789abcdef".utf8)
func hexBytes(_ b: [UInt8]) -> String {
    var o = [UInt8](); o.reserveCapacity(b.count * 2)
    for x in b { o.append(HEX[Int(x >> 4)]); o.append(HEX[Int(x & 15)]) }
    return String(decoding: o, as: UTF8.self)
}
let FS = "\u{1F}", RS = "\u{1E}"
typealias C = CLLocationCoordinate2D
func pt(_ c: C) -> String { hx(c.latitude) + "/" + hx(c.longitude) }
func pts(_ a: [C]) -> String { a.map(pt).joined(separator: ";") }
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
var rng = SM(s: 0x504C414345535253)   // "PLACESRS"

// ===================================================================== RoutePath
var routes: [Int: POIRanking.RoutePath] = [:]
var routeCoords: [Int: [C]] = [:]
var routeIDs: [Int] = []
func addRoute(_ coords: [C]) {
    let id = routeIDs.count
    let path = POIRanking.RoutePath(coords: coords)
    routes[id] = path; routeCoords[id] = coords; routeIDs.append(id)
    emit("rp-route", String(id), pts(coords), lst(path.cumulative.map(hx)))
}
func walk(_ n: Int, _ lat0: Double, _ lon0: Double, _ step: Double) -> [C] {
    var lat = lat0, lon = lon0, o: [C] = []
    for _ in 0..<n { lat += rng.range(-step, step); lon += rng.range(-step, step); o.append(C(latitude: lat, longitude: lon)) }
    return o
}
addRoute([])
for _ in 0..<30 { addRoute(walk(rng.pick([1, 2, 3, 10, 50, 200, 400]), rng.range(20, 60), rng.range(-120, -70), 0.05)) }
for _ in 0..<4 { addRoute(stride(from: -90.0, through: -88.6, by: 0.01).map { C(latitude: 43.0, longitude: $0) }) }
for _ in 0..<4 { let w = walk(rng.pick([5, 40, 120]), rng.range(30, 50), rng.range(-110, -80), 0.03); addRoute(w.flatMap { Array(repeating: $0, count: rng.pick([1, 2, 3])) }) }
for _ in 0..<4 { let w = walk(rng.pick([20, 90]), rng.range(30, 50), rng.range(-110, -80), 0.02); addRoute(w + w.reversed()) }
for _ in 0..<4 { addRoute(walk(rng.pick([30, 150]), rng.range(80, 89.5), rng.range(-170, 170), 0.2)) }
for _ in 0..<3 { addRoute(walk(rng.pick([30, 150]), rng.range(-0.3, 0.3), rng.pick([-179.9, 179.9, 0.0]), 0.04)) }
for _ in 0..<3 { addRoute((0..<rng.pick([4, 10])).map { i in C(latitude: 30 + Double(i) * 2, longitude: -100 + Double(i) * 2.1) }) }
for _ in 0..<3 { let p = C(latitude: rng.range(20, 60), longitude: rng.range(-120, -70)); addRoute(Array(repeating: p, count: rng.pick([1, 2, 7]))) }
addRoute([C(latitude: 43.0, longitude: -89.4)])
addRoute([C(latitude: -33.9, longitude: 151.2), C(latitude: -33.8, longitude: 151.3), C(latitude: 51.5, longitude: -0.1)])

func queries(_ coords: [C]) -> [C] {
    var q: [C] = []
    for _ in 0..<8 { let b = rng.pick(coords); q.append(C(latitude: b.latitude + rng.range(-0.03, 0.03), longitude: b.longitude + rng.range(-0.03, 0.03))) }
    q.append(rng.pick(coords))
    let b = rng.pick(coords)
    q.append(C(latitude: (b.latitude * 10).rounded() / 10, longitude: (b.longitude * 10).rounded() / 10))
    for s in [0.2, 0.9, 1.6, 1.7, 4.0] { let c = rng.pick(coords); q.append(C(latitude: c.latitude + rng.range(-s, s), longitude: c.longitude + rng.range(-s, s))) }
    for _ in 0..<2 { q.append(C(latitude: rng.range(-85, 85), longitude: rng.range(-179, 179))) }
    return q
}
emit("rp-near", "0", pt(C(latitude: .nan, longitude: .nan)), "-")
emit("rp-near", "0", pt(C(latitude: 43, longitude: -89)), routes[0]!.nearest(to: C(latitude: 43, longitude: -89)).map { "\($0.index)/" + hx($0.offRoute) } ?? "-")
for id in routeIDs.dropFirst() {
    let coords = routeCoords[id]!, path = routes[id]!
    for q in queries(coords) {
        emit("rp-near", String(id), pt(q), path.nearest(to: q).map { "\($0.index)/" + hx($0.offRoute) } ?? "-")
    }
}

// ===================================================================== annotate and the rankers
let SPECIAL: [Double] = [.nan, .infinity, -.infinity, -0.0, 0]
func optV(_ lo: Double, _ hi: Double, _ specials: [Double]) -> Double? {
    if rng.chance(4) { return nil }
    if rng.chance(10) { return rng.pick(specials) }
    if rng.chance(3) { return rng.pick([lo, hi, (lo + hi) / 2]) }
    return rng.range(lo, hi)
}
for _ in 0..<500 {
    let id = rng.pick(Array(routeIDs.dropFirst())); let coords = routeCoords[id]!, path = routes[id]!
    let q = rng.pick(queries(coords))
    let va = rng.chance(6) ? rng.pick(SPECIAL + [-1e9, 1e9]) : path.cumulative[rng.below(path.cumulative.count)]
    let price = optV(0, 6, SPECIAL + [-1]), rating = optV(0, 5, SPECIAL)
    let got = POIRanking.annotate(item: 0, at: q, route: path, vehicleAlong: va, pricePerUnit: price, rating: rating)
    emit("rk-annot", String(id), pt(q), hx(va), hdo(price), hdo(rating),
         got.map { [hx($0.aheadMeters), hx($0.detourMeters), hdo($0.pricePerUnit), hdo($0.rating)].joined(separator: "/") } ?? "-")
}
_ = POIRanking.annotate(item: 0, at: C(latitude: 1, longitude: 1), route: routes[0]!, vehicleAlong: 0)

func aheadV() -> Double {
    if rng.chance(12) { return rng.pick(SPECIAL + [-500, -499.99, -500.0000001, 1000, 5000]) }
    if rng.chance(3) { return rng.pick([1000.0, 2000, 3000]) }
    return rng.range(-3000, 200_000)
}
func detourV() -> Double {
    if rng.chance(12) { return rng.pick(SPECIAL + [12_000, 12_000.000001, 25_000, 45_000, 60_000]) }
    if rng.chance(3) { return rng.pick([100.0, 500]) }
    return rng.range(0, 70_000)
}
func cands(_ n: Int) -> [POIRanking.Candidate<Int>] {
    (0..<n).map { i in
        POIRanking.Candidate(item: i, coordinate: C(), aheadMeters: aheadV(), detourMeters: detourV(),
                             pricePerUnit: optV(0, 300, SPECIAL + [-1, 3.2, 120]), rating: optV(0, 5, SPECIAL + [4, 3.5]))
    }
}
func candsOut(_ c: [POIRanking.Candidate<Int>]) -> String {
    c.map { [hx($0.aheadMeters), hx($0.detourMeters), hdo($0.pricePerUnit), hdo($0.rating)].joined(separator: "/") }.joined(separator: ",")
}
let namePool: [String?] = [nil, "", "Free", "FREE lot", "Park & Ride", "park and ride", "Street Parking", "Garage", "GARAGE", "Ramp",
  "valet", "Premium", "Airport", "freedom", "Walmart", "WALMART Supercenter", "Wal-Mart", "Amazon Fresh", "Lowe's", "LOWE\u{2019}S",
  "Sam's Club", "H-E-B", "HEB", "Trader Joe's", "O'Reilly Auto Parts", "The Home Depot", "Bob's", "Kohl's", "Macy's", "Big 5 Sporting",
  "TJ Maxx", "T.J. Maxx", "Ross Dress for Less", "Burlington", "Marshalls", "Cabela's", "Bass Pro Shops", "Caf\u{E9} Walmart",
  "walmart\u{301}", "\u{212A}roger", "\u{130}kea", "STRASSE", "\u{FB01}sh", "\u{FF37}almart", "costco\u{200D}", "targe\u{301}t", "free\u{301}",
  "Premium\u{0}", "AIRPORT PARKING", "garage\u{1F17F}\u{FE0F}", "\u{1F1FA}\u{1F1F8} Walmart", "Pilot Travel Center", "Flying J",
  "Love's Travel Stop", "Loves Travel", "TA Travel Center", "ta petro", "TravelCenters of America", "Petro Stopping Center", "Speedway Petro",
  "Kwik Trip", "Culver's", "Caf\u{E9}", "Cafe\u{301}", "\u{1F354}", "Menards", "ACE HARDWARE", "dollar general", "Dollar Tree",
  "Walgreens", "CVS Pharmacy", "whole foods market", "tractor supply co", "PetSmart", "petco", "AutoZone", "NAPA", "academy sports + outdoors",
  "Sportsman's Warehouse", "SCHEELS", "Nordstrom Rack", "Meijer", "Aldi", "Publix", "Safeway", "Albertsons", "Best Buy", "Target", "Costco"]
func name() -> String? {
    if rng.chance(5) { return [rng.pick(namePool) ?? "", rng.pick(namePool) ?? ""].joined(separator: rng.pick([" ", "", "-", " & "])) }
    return rng.pick(namePool)
}
let detourCaps: [Double] = [12_000, 12_000, 25_000, 45_000, 60_000, 32_000, .nan, -1, .infinity, 0]
for _ in 0..<700 {
    let n = rng.pick([0, 1, 2, 3, 7, 20, 33, 64, 65, 150])
    let c = cands(n); let cap = rng.pick(detourCaps)
    let order: ([POIRanking.Candidate<Int>]) -> String = { lst($0.map { String($0.item) }) }
    switch rng.below(5) {
    case 0: emit("rk-food", candsOut(c), hx(cap), order(POIRanking.rankFood(c, maxDetour: cap)))
    case 1:
        let fill = rng.pick([15.0, 25, 60, 240, 100, .nan, 0]), avg = rng.pick([3.2, 3.9, 0.36, .nan, 0, 3.5])
        emit("rk-fuel", candsOut(c), hx(fill), hx(avg), hx(cap), order(POIRanking.rankFuel(c, fillUnits: fill, averagePricePerUnit: avg, maxDetour: cap)))
    case 2:
        let nightly = rng.pick([120.0, 0, 0.5, -10, .nan, .infinity, 90])
        emit("rk-hotels", candsOut(c), hx(nightly), hx(cap), order(POIRanking.rankHotels(c, averageNightly: nightly, maxDetour: cap)))
    case 3:
        let tiers = c.map { _ in rng.chance(20) ? rng.pick([Int.max, Int.min, -3, 1 << 53 + 1]) : rng.below(3) }
        emit("rk-parking", candsOut(c), lst(tiers.map(String.init)), hx(cap), order(POIRanking.rankParking(c, costTier: { tiers[$0] }, maxDetour: cap)))
    default:
        let names = c.map { _ in name() }
        emit("rk-stores", candsOut(c), names.map(hto).joined(separator: RS), hx(cap), order(POIRanking.rankStores(c, name: { names[$0] }, maxDetour: cap)))
    }
}
// Defaulted arguments, as the app and tests call them.
do {
    let c = cands(40)
    emit("rk-food", candsOut(c), hx(POIRanking.maxDetourMeters), lst(POIRanking.rankFood(c).map { String($0.item) }))
    emit("rk-hotels", candsOut(c), hx(POIRanking.averageNightlyPrice), hx(POIRanking.maxDetourMeters), lst(POIRanking.rankHotels(c).map { String($0.item) }))
}
var tableNames = namePool
for _ in 0..<400 { tableNames.append(name()) }
for n in tableNames {
    emit("pk-tier", hto(n), String(POIRanking.parkingCostTier(name: n)))
    emit("ms-rank", hto(n), String(POIRanking.storeMarketShareRank(name: n)))
}
emit("ms-order", lst(POIRanking.storeMarketShareOrder.map(ht)))
emit("rk-consts", hx(POIRanking.backtrackToleranceMeters), hx(POIRanking.maxDetourMeters), hx(POIRanking.detourSpeedMps), hx(POIRanking.dollarsPerHour), hx(POIRanking.averageNightlyPrice))
for (i, f) in FuelType.allCases.enumerated() { emit("fuel", String(i), ht(f.rawValue), hx(f.fillUnits), hx(f.averagePricePerUnit)) }

// ===================================================================== FPS1 shards
struct Rec { var lat: Float; var lon: Float; var group: UInt8; var flags: UInt8; var strs: [[UInt8]]; var postcode: UInt32 }
func le<T: FixedWidthInteger>(_ v: T, _ d: inout [UInt8]) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
func fnv(_ b: ArraySlice<UInt8>) -> UInt64 { var h: UInt64 = 0xcbf2_9ce4_8422_2325; for x in b { h ^= UInt64(x); h = h &* 0x0000_0100_0000_01b3 }; return h }
let textPool: [[UInt8]] = ["", "", "", "Kwik Trip", "Culver's", "Caf\u{E9} Zo\u{EB}", "Cafe\u{301}", "\u{6771}\u{4EAC}\u{30E9}\u{30FC}\u{30E1}\u{30F3}", "\u{1F354} Burgers",
  "1 Main St", "Madison", "https://example.com/x?y=1", "+1 608 555 0100", String(repeating: "x", count: 300), "tab\there", "back\\slash"].map { Array($0.utf8) }
  + [[0xFF], [0xC0, 0x80], [0xE2, 0x82], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xF0, 0x9F, 0x98, 0x41], [0x80, 0x41], [0xE0, 0x80, 0x80],
     [0x41, 0x00, 0x42], [0xEF, 0xBB, 0xBF, 0x41], [0xF8, 0x88, 0x80, 0x80, 0x80], [0xC3], [0xE1, 0x80, 0xC3, 0xA9], [0xF0, 0x80, 0x80, 0x80], [0xFE, 0xFF]]
func randRecs(_ n: Int, _ c: C, _ spread: Double) -> [Rec] {
    (0..<n).map { _ in
        Rec(lat: Float(c.latitude + (rng.unit() - 0.5) * spread), lon: Float(c.longitude + (rng.unit() - 0.5) * spread * 1.4),
            group: rng.chance(10) ? UInt8(rng.below(256)) : UInt8(rng.below(8)), flags: UInt8(rng.below(256)),
            strs: (0..<5).map { _ in rng.pick(textPool) }, postcode: rng.chance(3) ? UInt32(rng.below(99_999)) : UInt32(truncatingIfNeeded: rng.next()))
    }
}
func cellOf(_ r: Rec) -> Int64 { let a = Int(floor(Double(r.lat) * 5)), b = Int(floor(Double(r.lon) * 5)); return Int64(a + 9000) * 100_000 + Int64(b + 18_000) }
func build(_ recs0: [Rec]) -> [UInt8] {
    let recs = recs0.enumerated().sorted { (cellOf($0.1), $0.0) < (cellOf($1.1), $1.0) }.map(\.1)
    var body: [UInt8] = []
    for r in recs {
        le(r.lat.bitPattern, &body); le(r.lon.bitPattern, &body); body.append(r.group); body.append(r.flags)
        for s in r.strs { le(UInt16(s.count), &body); body += s }
        le(r.postcode, &body)
    }
    let gridOffset = 32 + body.count
    var cells: [(Int64, UInt32, UInt32)] = []
    for (i, r) in recs.enumerated() {
        let k = cellOf(r)
        if let last = cells.last, last.0 == k { cells[cells.count - 1].2 += 1 } else { cells.append((k, UInt32(i), 1)) }
    }
    for c in cells { le(c.0, &body); le(c.1, &body); le(c.2, &body) }
    var d: [UInt8] = Array("FPS1".utf8)
    le(UInt32(1), &d); le(UInt32(recs.count), &d); le(UInt64(gridOffset), &d); le(fnv(body[...]), &d); le(UInt32(cells.count), &d)
    return d + body
}
func rdU32(_ d: [UInt8], _ at: Int) -> UInt32 { UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24 }
func rdU64(_ d: [UInt8], _ at: Int) -> UInt64 { UInt64(rdU32(d, at)) | UInt64(rdU32(d, at + 4)) << 32 }
func put<T: FixedWidthInteger>(_ d: inout [UInt8], _ at: Int, _ v: T) { var t: [UInt8] = []; le(v, &t); for (i, b) in t.enumerated() where at + i < d.count { d[at + i] = b } }
func rehash(_ d: inout [UInt8]) { guard d.count >= 32 else { return }; put(&d, 20, fnv(d[32...])) }
func mutate(_ base: [UInt8], _ kind: Int) -> [UInt8] {
    var d = base
    let grid = Int(rdU64(d, 12)), nCells = Int(rdU32(d, 28)), nRec = Int(rdU32(d, 8))
    switch kind {
    case 1: put(&d, 20, rdU64(d, 20) &+ 1)
    case 2: d[3] = UInt8(ascii: "2")
    case 3: put(&d, 4, UInt32(2))
    case 4: d = Array(d.prefix(rng.below(d.count)))
    case 5: put(&d, 12, UInt64(UInt32.max) + 1)
    case 6: put(&d, 12, UInt64(31))
    case 7: put(&d, 28, UInt32(nCells + 1))
    case 8: put(&d, 8, UInt32(nRec + 1))
    case 9: put(&d, 8, UInt32.max)
    case 10: if d.count > 44 { put(&d, 42, UInt16.max) }; rehash(&d)
    case 11: if nCells > 0 { let at = grid + (nCells - 1) * 16 + 12; put(&d, at, rdU32(d, at) &+ UInt32(rng.pick([1, 2, 1000]))) }; rehash(&d)
    case 12: if nCells > 1 { let a = grid + rng.below(nCells) * 16, b = grid + rng.below(nCells) * 16; let ka = rdU64(d, a), kb = rdU64(d, b); put(&d, a, kb); put(&d, b, ka) }; rehash(&d)
    case 13: if nCells > 1 { let k0 = rdU64(d, grid); for i in 0..<nCells where rng.chance(2) { put(&d, grid + i * 16, k0) } }; rehash(&d)
    case 14: if nCells > 1 { for i in 0..<nCells { put(&d, grid + i * 16 + 8, UInt32(rng.below(max(nRec, 1)))); put(&d, grid + i * 16 + 12, UInt32(0)) }
               for i in 0..<nCells { let s = Int(rdU32(d, grid + i * 16 + 8)); put(&d, grid + i * 16 + 12, UInt32(rng.below(nRec - s + 1))) } }; rehash(&d)
    case 15: d.insert(contentsOf: [0, 0, 0, 0], at: grid); put(&d, 12, UInt64(grid + 4)); rehash(&d)
    case 16: if nRec > 0 { put(&d, 8, UInt32(nRec - 1)) }; rehash(&d)
    case 17: d += [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]; put(&d, 28, UInt32(nCells + 1)); rehash(&d)
    default: break
    }
    return d
}
func placeOut(_ p: PlacesShard.Place) -> String {
    [pt(p.coordinate), String(p.group), ht(p.name), ht(p.street), ht(p.city), ht(p.website), ht(p.tel), String(p.postcode)].joined(separator: FS)
}
func traps(_ center: C, _ radius: Double, _ limit: Int) -> Bool {
    if limit < 0 { return true }
    let dLat = radius / 111_320.0
    let dLon = radius / max(111_320.0 * cos(center.latitude * .pi / 180), 1)
    let v = [floor((center.latitude - dLat) * 5), floor((center.latitude + dLat) * 5), floor((center.longitude - dLon) * 5), floor((center.longitude + dLon) * 5)]
    guard v.allSatisfy({ $0.isFinite && abs($0) < 1e6 }) else { return true }
    if v[0] > v[1] || v[2] > v[3] { return true }
    return (v[1] - v[0] + 1) * (v[3] - v[2] + 1) > 3e6
}
let shardCenters: [C] = [C(latitude: 43.07, longitude: -89.4), C(latitude: 41.88, longitude: -87.63), C(latitude: 0.05, longitude: -0.05),
  C(latitude: 64.8, longitude: -147.7), C(latitude: -33.9, longitude: 151.2), C(latitude: 19.43, longitude: -99.13)]
var shardCount = 0
for s in 0..<150 {
    let c = rng.pick(shardCenters)
    let recs = randRecs(rng.pick([0, 1, 2, 5, 12, 30]), c, rng.pick([0.05, 0.4, 2.0]))
    let base = build(recs)
    let kind = s < 40 ? 0 : (rng.chance(3) ? 0 : 1 + rng.below(17))
    let bytes = mutate(base, kind)
    let id = "s\(s)"
    emit("ps-shard", id, hexBytes(bytes))
    guard let shard = PlacesShard(data: Data(bytes)) else { emit("ps-parse", id, "-"); continue }
    shardCount += 1
    emit("ps-parse", id, "ok")
    for _ in 0..<12 {
        let center = rng.chance(3) ? c : (recs.isEmpty ? c : { let r = rng.pick(recs); return C(latitude: Double(r.lat) + rng.range(-0.02, 0.02), longitude: Double(r.lon) + rng.range(-0.02, 0.02)) }())
        let groups = Set((0..<rng.pick([0, 1, 2, 4, 9])).map { _ in rng.chance(12) ? UInt8(rng.below(256)) : UInt8(rng.below(9)) })
        let radius = rng.pick([0.0, 100, 5_000, 30_000, 60_000, -1, -1e-9, 250_000, rng.range(0, 90_000)])
        let limit = rng.pick([0, 1, 3, 12, 100, -1])
        if traps(center, radius, limit) { continue }
        let got = shard.places(near: center, groups: groups, radiusMeters: radius, limit: limit)
        emit("ps-near", id, pt(center), lst(groups.sorted().map { String($0) }), hx(radius), String(limit), got.map(placeOut).joined(separator: RS))
    }
}
// Hand-made edges: exactly 32 bytes; no records with one empty cell; the minimum record.
do {
    var d: [UInt8] = Array("FPS1".utf8); le(UInt32(1), &d); le(UInt32(0), &d); le(UInt64(32), &d); le(fnv([][...]), &d); le(UInt32(0), &d)
    emit("ps-shard", "e32", hexBytes(d)); emit("ps-parse", "e32", PlacesShard(data: Data(d)) == nil ? "-" : "ok")
    var e: [UInt8] = Array("FPS1".utf8); var body: [UInt8] = []; le(Int64(921_500_017_553), &body); le(UInt32(0), &body); le(UInt32(0), &body)
    le(UInt32(1), &e); le(UInt32(0), &e); le(UInt64(32), &e); le(fnv(body[...]), &e); le(UInt32(1), &e); e += body
    emit("ps-shard", "e48", hexBytes(e)); emit("ps-parse", "e48", PlacesShard(data: Data(e)) == nil ? "-" : "ok")
    if let sh = PlacesShard(data: Data(e)) {
        emit("ps-near", "e48", pt(C(latitude: 43.07, longitude: -89.4)), lst(["0"]), hx(5000), "5", sh.places(near: C(latitude: 43.07, longitude: -89.4), groups: [0], radiusMeters: 5000, limit: 5).map(placeOut).joined(separator: RS))
    }
}
for (a, b) in [(215, -447), (0, 0), (-450, -900), (450, 900), (-9000, -18000), (123_456, -654_321), (-1, -1), (1_000_000, 1_000_000)] {
    emit("ps-key", String(a), String(b), String(PlacesShard.cellKey(lat5: a, lon5: b)))
}
// The tool-built Wisconsin shard, when this machine has it: identified by size and stored hash.
do {
    let path = "\(NSHomeDirectory())/Documents/Coding_Files/FLOWS/data/places/WI.fps"
    if let data = FileManager.default.contents(atPath: path), let shard = PlacesShard(data: data) {
        let stored = data.subdata(in: 20..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        let tag = "\(data.count)/\(String(stored, radix: 16))"
        let spots: [C] = [C(latitude: 43.0747, longitude: -89.3844), C(latitude: 43.0389, longitude: -87.9065), C(latitude: 44.5133, longitude: -88.0133),
                          C(latitude: 42.5, longitude: -90.6), C(latitude: 46.7, longitude: -92.1), C(latitude: 45.0, longitude: -91.0)]
        for s in spots { for g: Set<UInt8> in [[0], [1], [2], [3, 4], [5, 6, 7], [0, 1, 2, 3, 4, 5, 6, 7]] { for (r, l) in [(3_000.0, 10), (8_000, 12), (30_000, 40)] {
            emit("ps-real", tag, pt(s), lst(g.sorted().map { String($0) }), hx(r), String(l), shard.places(near: s, groups: g, radiusMeters: r, limit: l).map(placeOut).joined(separator: RS))
        } } }
    }
}

// ===================================================================== the store: state pick and cross-shard merge
let statePoints: [C] = [C(latitude: 43.07, longitude: -89.4), C(latitude: 41.88, longitude: -87.63), C(latitude: 42.5, longitude: -92.9), C(latitude: 47.1, longitude: -86.2),
  C(latitude: .nan, longitude: -89), C(latitude: 0, longitude: 0), C(latitude: 61.2, longitude: -149.9), C(latitude: 21.3, longitude: -157.8), C(latitude: 36.5, longitude: -94.6)]
for p in statePoints + (0..<300).map({ _ in C(latitude: rng.range(15, 72), longitude: rng.range(-170, -60)) }) {
    emit("st-states", pt(p), lst(PlacesStore.states(containing: p).map(ht)))
}
let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent("flows-places-oracle-\(getpid())")
let placesDir = storeDir.appendingPathComponent("data/places")
try? FileManager.default.createDirectory(at: placesDir, withIntermediateDirectories: true)
let storeStates: [(String, C)] = [("WI", C(latitude: 43.5, longitude: -89.0)), ("IL", C(latitude: 41.9, longitude: -88.0)), ("MI", C(latitude: 42.5, longitude: -86.5)),
  ("MN", C(latitude: 44.9, longitude: -93.2)), ("IA", C(latitude: 42.3, longitude: -91.5))]
for (code, c) in storeStates {
    var recs = randRecs(90, c, 2.5)
    for i in recs.indices where rng.chance(4) { recs[i].group = UInt8(rng.below(3)) }
    let bytes = rng.chance(6) ? mutate(build(recs), 1) : build(recs)
    emit("ps-shard", "store-\(code)", hexBytes(bytes))
    FileManager.default.createFile(atPath: placesDir.appendingPathComponent("\(code).fps").path, contents: Data(bytes))
}
setenv("FLOWS_REPO", storeDir.path, 1)
@MainActor func storeSection() async {
    for _ in 0..<160 {
        let c = rng.pick(storeStates).1
        let center = C(latitude: c.latitude + rng.range(-1.5, 1.5), longitude: c.longitude + rng.range(-2, 2))
        let groups = Set((0..<rng.pick([0, 1, 2, 3])).map { _ in UInt8(rng.below(4)) })
        let radius = rng.pick([5_000.0, 24_000, 45_000, 60_000, 150_000])
        let limit = rng.pick([1, 5, 12, 30])
        let got = await PlacesStore.shared.places(near: center, groups: groups, radiusMeters: radius, limit: limit)
        emit("store-q", pt(center), lst(groups.sorted().map { String($0) }), hx(radius), String(limit), got.map(placeOut).joined(separator: RS))
    }
    let dflt = await PlacesStore.shared.places(near: C(latitude: 43.2, longitude: -89.2), groups: [0, 1, 2], radiusMeters: 80_000)
    emit("store-q", pt(C(latitude: 43.2, longitude: -89.2)), lst(["0", "1", "2"]), hx(80_000), "12", dflt.map(placeOut).joined(separator: RS))
}
await storeSection()
try? FileManager.default.removeItem(at: storeDir)

// ===================================================================== the service
func mapItem(_ n: String?, _ c: C) -> MKMapItem { let it = MKMapItem(placemark: MKPlacemark(coordinate: c)); it.name = n; return it }
func itemOut(_ it: MKMapItem) -> String { hto(it.name) + FS + pt(it.placemark.coordinate) }
let kinds = POIService.Kind.allCases
for (i, k) in kinds.enumerated() { emit("svc-groups", String(i), ht(k.rawValue), POIService.shardGroups(for: k).map { lst($0.sorted().map { String($0) }) } ?? "-") }
@MainActor func serviceSection() async {
    for _ in 0..<600 {
        let kindIndex = rng.below(kinds.count); let kind = kinds[kindIndex]
        let fuelIndex = rng.chance(3) ? nil : Optional(rng.below(FuelType.allCases.count))
        let trucker = rng.chance(2)
        let routeID: Int? = rng.chance(8) ? nil : rng.pick(routeIDs)
        let coords = routeID.flatMap { routeCoords[$0] } ?? []
        let base = coords.isEmpty ? C(latitude: rng.range(25, 49), longitude: rng.range(-120, -70)) : rng.pick(coords)
        let position: C? = rng.chance(6) ? nil : C(latitude: base.latitude + rng.range(-0.05, 0.05), longitude: base.longitude + rng.range(-0.05, 0.05))
        let n = rng.pick([0, 1, 3, 8, 9, 20, 40])
        let items = (0..<n).map { _ -> MKMapItem in
            let b = coords.isEmpty ? base : rng.pick(coords)
            let s = rng.pick([0.01, 0.1, 0.5])
            return mapItem(name(), C(latitude: b.latitude + rng.range(-s, s), longitude: b.longitude + rng.range(-s, s)))
        }
        let pn = rng.chance(10) ? max(n - 1, 0) : n, rn = rng.chance(10) ? max(n - 2, 0) : n
        let prices = (0..<pn).map { _ in optV(0, 250, SPECIAL + [3.2]) }
        let ratings = (0..<rn).map { _ in optV(0, 5, SPECIAL + [4]) }
        let rows = await POIService.rank(items, kind: kind, prices: prices, ratings: ratings, fuel: fuelIndex.map { FuelType.allCases[$0] },
                                         position: position, path: routeID.flatMap { routes[$0] }, trucker: trucker)
        let got = rows.map { r -> String in
            let k = items.firstIndex { $0 === r.item }!
            return [String(k), hx(r.aheadMeters), hx(r.detourMeters), hdo(r.pricePerUnit), hdo(r.rating)].joined(separator: "/")
        }
        emit("svc-rank", String(kindIndex), fuelIndex.map(String.init) ?? "-", trucker ? "1" : "0", position.map(pt) ?? "-", routeID.map(String.init) ?? "-",
             items.map(itemOut).joined(separator: RS), prices.map(hdo).joined(separator: ","), ratings.map(hdo).joined(separator: ","), got.joined(separator: ","))
    }
    let spots: [C] = [C(latitude: 43.07, longitude: -89.4), C(latitude: 43.0701, longitude: -89.4001), C(latitude: 43.0719, longitude: -89.4), C(latitude: -0.001, longitude: 0.0019),
                      C(latitude: 43.072, longitude: -89.402), C(latitude: 0, longitude: -0.0)]
    let keyNames: [String?] = [nil, "?", "", "Caf\u{E9}", "Cafe\u{301}", "Kwik Trip", "kwik trip", "\u{212A}wik Trip", "A|B", "Kwik Trip "]
    for _ in 0..<400 {
        let row = { (a: Double) -> POIService.RankedPOI in POIService.RankedPOI(item: mapItem(rng.pick(keyNames), rng.pick(spots)), aheadMeters: a, detourMeters: 0, pricePerUnit: nil) }
        let ev = (0..<rng.pick([0, 1, 2, 4, 8])).map { _ in row(rng.unit()) }
        let net = (0..<rng.pick([0, 1, 3, 8])).map { _ in row(rng.unit()) }
        let merged = POIService.merged(everyday: ev, network: net)
        let got = merged.map { r -> String in
            if let i = net.firstIndex(where: { $0.id == r.id }) { return "n\(i)" }
            return "e\(ev.firstIndex(where: { $0.id == r.id })!)"
        }
        emit("svc-merged", ev.map { itemOut($0.item) }.joined(separator: RS), net.map { itemOut($0.item) }.joined(separator: RS), lst(got))
        for r in ev + net where rng.chance(3) { emit("svc-rowkey", itemOut(r.item), ht(POIService.rowKey(r))) }
    }
    let svc = POIService()
    for _ in 0..<250 {
        let id = rng.pick(routeIDs); let coords = routeCoords[id]!
        let position: C? = rng.chance(8) ? nil : (coords.isEmpty || rng.chance(4) ? C(latitude: rng.range(20, 60), longitude: rng.range(-120, -70)) : { let b = rng.pick(coords); return C(latitude: b.latitude + rng.range(-0.05, 0.05), longitude: b.longitude) }())
        svc.corridor = coords
        let ahead = svc.corridorAhead(of: position)
        emit("svc-corridor", String(id), position.map(pt) ?? "-", String(coords.count - ahead.count))
    }
}
await serviceSection()
let attrNames: [String] = ["", "?", "Kwik Trip", "Caf\u{E9}", "A|B|C", "\u{1F354}", "tab\t", "Premium\u{0}"]
let attrCoords: [Double] = [0, -0.0, 0.0019999, 0.002, -0.002, -0.0019999, 43.07, -89.4, 1e15, -1e15, 1.8e16, 0.001, 0.003, 90, -180, 179.999, 12.3456789]
for _ in 0..<300 {
    let lat = rng.chance(2) ? rng.pick(attrCoords) : rng.range(-90, 90), lon = rng.chance(2) ? rng.pick(attrCoords) : rng.range(-180, 180)
    let nm = rng.pick(attrNames)
    emit("ev-attr", ht(nm), hx(lat), hx(lon), ht(EverydayPlace.attributeID(name: nm, latitude: lat, longitude: lon)))
}

// ===================================================================== a runtime rule the service's brand pick reads
// String.hasPrefix, cluster by cluster: the shower brand pick tests `lower.hasPrefix("ta ")`.
var rng2 = SM(s: 0x5052454649584553)   // "PREFIXES"
let prefixes = ["ta ", "t", "", "ta", "ta \u{301}", "\r", "ab\r", "\u{212A}", "k", "caf\u{E9}", "cafe", "\u{1F1FA}", "\u{1F1FA}\u{1F1F8}"]
var prefixTexts = ["ta travel", "ta \u{301}x", "t\u{301}a ", "ab\r\n", "ab\r", "\u{212A}roger", "kroger", "cafe\u{301} x", "caf\u{E9}", "\u{1F1FA}\u{1F1F8}\u{1F1FA}", "ta", "", " ta ", "TA ", "ta\u{200D} "]
for n in namePool { prefixTexts.append((n ?? "").lowercased()) }
for _ in 0..<200 { prefixTexts.append([rng2.pick(prefixes), rng2.pick(prefixTexts)].joined(separator: rng2.pick(["", " ", "\u{301}"]))) }
for t in prefixTexts { for p in prefixes { emit("u-prefix", ht(t), ht(p), t.hasPrefix(p) ? "1" : "0") } }

if CommandLine.arguments.count > 1 {
    FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: out.data(using: .utf8)!)
} else {
    FileHandle.standardOutput.write(out.data(using: .utf8)!)
}
