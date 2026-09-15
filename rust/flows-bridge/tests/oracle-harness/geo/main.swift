import CoreLocation
import Foundation
// Frozen oracle for the geo kernel. Every output below comes from the ORIGINAL
// Swift at the base commit named in the fixture header, compiled unmodified
// with the app files it needs, before any of it is replaced by calls into Rust.
// Doubles are IEEE-754 bit patterns in hex; integers are decimal; nil is "-";
// lists are "L<n>:" + comma-separated items; an input on which the Swift traps
// (crashes the app) records "trap".
//
// Inputs that can trap run in a child process (this binary, `trap <n>`) whose
// SIGTRAP/SIGILL handler exits with status 86: a trap is observed, never
// predicted, and leaves no crash report. The trap table uses literal inputs
// only, so parent and child build it identically.
func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func ho(_ d: Double?) -> String { d.map(hx) ?? "-" }
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
func hl(_ a: [Double]) -> String { lst(a.map(hx)) }
func b01(_ b: Bool) -> String { b ? "1" : "0" }
func C(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
var out = ""
func emit(_ f: String...) { out += f.joined(separator: "\t") + "\n" }
func emitAll(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }

struct SM { var s: UInt64
  mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
  mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) } }
var rng = SM(s: 0x47454F)   // "GEO"

typealias Entry = ShowerAvailability.LocationTable.Entry
func routeResult(_ r: (index: Int, offRoute: CLLocationDistance)?) -> String {
  r.map { "\($0.index)\t\(hx($0.offRoute))" } ?? "-\t-" }
func coords(_ lats: [Double], _ lons: [Double]) -> [CLLocationCoordinate2D] { zip(lats, lons).map { C($0, $1) } }
func entries(_ lats: [Double], _ lons: [Double]) -> [Entry] {
  zip(lats, lons).enumerated().map { Entry(lat: $0.element.0, lon: $0.element.1, brand: "\($0.offset)", shower: nil) } }

// ---- VERBATIM from OfflineCorridors.swift at the base commit, lines 177-184 (OfflineCorridorStore.nearest).
// The store cannot be built here without reading and writing the user's Application Support
// directory and keychain, so its method body is compiled over the corridors it reads.
// `coordinates(of:)` in the original is a cache that returns `SavedCorridor.coordinates`.
struct CorridorStoreProbe {
    let corridors: [SavedCorridor]
    func coordinates(of c: SavedCorridor) -> [CLLocationCoordinate2D] { c.coordinates }

    /// The corridor most useful from here: the one whose road passes nearest.
    func nearest(to position: CLLocationCoordinate2D) -> SavedCorridor? {
        corridors.min { a, b in
            let da = coordinates(of: a).map { POIRanking.meters($0, position) }.min() ?? .infinity
            let db = coordinates(of: b).map { POIRanking.meters($0, position) }.min() ?? .infinity
            return da < db
        }
    }
}
// ---- end verbatim

// =============================================================================
// Trap table (literal inputs only)
// =============================================================================
struct TrapCase { let fields: [String]; let trapFill: String; let run: () -> String }
var traps: [TrapCase] = []

func sweep(_ base: Double, _ steps: Int) -> [Double] {
  var up = base, down = base, v = [base]
  for _ in 0..<steps { up = up.nextUp; down = down.nextDown; v.append(up); v.append(down) }
  return v }
let nonFinite: [Double] = [.nan, .infinity, -.infinity]
let big01 = sweep(922_337_203_685_477_580.8, 3)     // quotient by 0.1 straddles 2^63
let big001 = sweep(92_233_720_368_547_758.08, 3)    // quotient by 0.01 straddles 2^63
let bad01 = nonFinite + big01 + big01.map { -$0 }
let bad001 = nonFinite + big001 + big001.map { -$0 }

let keyEdges: [(Int, Int)] = [
  (92_233_720_368_547 - 9_000, 57_807), (92_233_720_368_547 - 9_000, 57_808), (92_233_720_368_547 - 8_999, 0),
  (-92_233_720_368_547 - 9_000, -93_808), (-92_233_720_368_547 - 9_000, -93_809), (-92_233_720_368_547 - 9_001, 0),
  (Int.max - 9_000, 0), (Int.max - 8_999, 0), (0, Int.max - 18_000), (0, Int.max - 17_999), (-9_000, Int.max - 18_000),
  (Int.min, 0), (0, Int.min), (Int.max, Int.max), (Int.min, Int.min), (Int.min + 1, -18_000)]
for (a, b) in keyEdges {
  traps.append(TrapCase(fields: ["cellkey", "\(a)", "\(b)"], trapFill: "trap",
                        run: { "\(PlacesShard.cellKey(lat5: a, lon5: b))" }))
}

let routeT = ([43.07, 43.08, 43.10, 43.10], [-89.40, -89.38, -89.35, -89.30])
for x in bad01 {
  for (lats, lons) in [([43.0, x], [-89.0, -89.0]), ([43.0, 43.0], [-89.0, x]), ([x], [x])] {
    traps.append(TrapCase(fields: ["rp", "X\(traps.count)", hl(lats), hl(lons)], trapFill: "trap",
                          run: { hl(POIRanking.RoutePath(coords: coords(lats, lons)).cumulative) }))
  }
}
for x in bad01 {
  for (lat, lon) in [(x, -89.0), (43.0, x)] {
    traps.append(TrapCase(fields: ["rpn", "T", hx(lat), hx(lon)], trapFill: "trap\t-",
                          run: { routeResult(POIRanking.RoutePath(coords: coords(routeT.0, routeT.1)).nearest(to: C(lat, lon))) }))
  }
}
for (lat, lon) in [(Double.nan, Double.nan), (.infinity, 0), (0, -.infinity), (big01[0], 0), (-big01[0], -big01[0])] {
  traps.append(TrapCase(fields: ["rpn", "E", hx(lat), hx(lon)], trapFill: "trap\t-",
                        run: { routeResult(POIRanking.RoutePath(coords: []).nearest(to: C(lat, lon))) }))
}

let tableS = ([35.0, 35.004, 35.004, 34.995], [-97.0, -97.0, -97.0, -97.008])
for x in bad001 {
  for (lats, lons) in [([35.0, x], [-97.0, -97.0]), ([35.0, 35.0], [-97.0, x]), ([x], [x])] {
    traps.append(TrapCase(fields: ["showert", "Y\(traps.count)", hl(lats), hl(lons)], trapFill: "trap",
                          run: { _ = ShowerAvailability.LocationTable(entries: entries(lats, lons)); return "ok" }))
  }
}
for x in bad001 {
  for (lat, lon) in [(x, -97.0), (35.0, x)] {
    traps.append(TrapCase(fields: ["shower", "S", hx(lat), hx(lon)], trapFill: "trap",
                          run: { ShowerAvailability.LocationTable(entries: entries(tableS.0, tableS.1)).entry(nearLat: lat, lon: lon)?.brand ?? "-" }))
  }
}
for (lat, lon) in [(Double.nan, 0.0), (0, .infinity), (-big001[0], 0), (0, -big001[0]), (big001[0], big001[0])] {
  traps.append(TrapCase(fields: ["shower", "SE", hx(lat), hx(lon)], trapFill: "trap",
                        run: { ShowerAvailability.LocationTable(entries: []).entry(nearLat: lat, lon: lon)?.brand ?? "-" }))
}

let argv = CommandLine.arguments
if argv.count == 3, argv[1] == "trap", let i = Int(argv[2]) {
  signal(SIGTRAP) { _ in _exit(86) }
  signal(SIGILL) { _ in _exit(86) }
  FileHandle.standardOutput.write(traps[i].run().data(using: .utf8)!)
  exit(0)
}

// =============================================================================
// Seeded inputs
// =============================================================================
let SPECIAL: [Double] = [.nan, .infinity, -.infinity, 0.0, -0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
  .leastNormalMagnitude, 1e-300, 1e-9, -1e-9, 0.01, (0.01).nextDown, 0.05, 0.1, (0.1).nextUp, (0.1).nextDown, 1, -1,
  45, 60, 84.26, 89.9, (90.0).nextDown, 90, (90.0).nextUp, -90, 179.99999, (180.0).nextDown, 180, (180.0).nextUp, -180,
  (-180.0).nextDown, 270, 360, -360, 540, 1e6, 1e17, 1e154, -1e155, 1e300, -1e300, .greatestFiniteMagnitude,
  -.greatestFiniteMagnitude]
func sp() -> Double { SPECIAL[rng.below(SPECIAL.count)] }
func uLat() -> Double { rng.unit() * 180 - 90 }
func uLon() -> Double { rng.unit() * 360 - 180 }
func naLat() -> Double { 18 + rng.unit() * 54 }     // Hawaii and the Mexican border to arctic Alaska
func naLon() -> Double { -168 + rng.unit() * 115 }
func jit(_ x: Double, _ span: Double) -> Double { x + (rng.unit() * 2 - 1) * span }
func mixed() -> Double {
  switch rng.below(4) { case 0: return sp(); case 1: return uLat(); case 2: return uLon(); default: return naLat() } }
let spans: [Double] = [1e-7, 1e-4, 0.003, 0.05, 0.4, 3]
func span() -> Double { spans[rng.below(spans.count)] }

// =============================================================================
// POIRanking.meters
// =============================================================================
func rm(_ a: Double, _ b: Double, _ c: Double, _ d: Double) {
  emit("m", hx(a), hx(b), hx(c), hx(d), hx(POIRanking.meters(C(a, b), C(c, d)))) }
for _ in 0..<500 { let la = naLat(), lo = naLon(), s = span(); rm(la, lo, jit(la, s), jit(lo, s)) }
for _ in 0..<100 { rm(uLat(), uLon(), uLat(), uLon()) }
for _ in 0..<200 { rm(mixed(), mixed(), mixed(), mixed()) }
for x in SPECIAL { rm(x, 0, 0, 0); rm(0, x, 0, 0); rm(45, -93, x, -93); rm(45, -93, 45, x) }
rm(10, 179.9, 10, -179.9); rm(90, 0, 90, 180); rm(89.9999, 10, -89.9999, -170); rm(-0.0, -0.0, 0, 0); rm(45, -93, 45, -93)

// =============================================================================
// EnforcementCameras.bearingDegrees and its copy FuelWarning.bearingDegrees
// =============================================================================
func rb(_ a: Double, _ b: Double, _ c: Double, _ d: Double) {
  emit("brg", hx(a), hx(b), hx(c), hx(d),
       hx(EnforcementCameras.bearingDegrees(from: C(a, b), to: C(c, d))),
       hx(FuelWarning.bearingDegrees(from: C(a, b), to: C(c, d)))) }
for _ in 0..<300 { let la = naLat(), lo = naLon(), s = span(); rb(la, lo, jit(la, s), jit(lo, s)) }
for _ in 0..<80 { rb(uLat(), uLon(), uLat(), uLon()) }
for _ in 0..<120 { rb(mixed(), mixed(), mixed(), mixed()) }
for x in SPECIAL { rb(x, 0, 1, 1); rb(10, 10, x, 10); rb(10, 10, 10, x) }
let bases: [(Double, Double)] = [(0, 0), (45, -93), (-33.9, 151.2), (89, 0), (-89.5, 170)]
let offs: [(Double, Double)] = [(1, 0), (-1, 0), (0, 1), (0, -1), (0, 0), (0, -0.0), (1, -0.0), (-1, -0.0),
  (1e-9, -1e-13), (1e-3, -1e-13), (1, -1e-12), (1, -1e-15), (1, 1e-15), (-1e-9, -0.0), (0, 180), (0, -180), (-180, 0)]
for a in bases { for o in offs { rb(a.0, a.1, a.0 + o.0, a.1 + o.1) } }

// =============================================================================
// EnforcementCameras.isAhead
// =============================================================================
func ra(_ t: (Double, Double), _ p: (Double, Double), _ h: Double?) {
  emit("ahead", hx(t.0), hx(t.1), hx(p.0), hx(p.1), ho(h),
       b01(EnforcementCameras.isAhead(C(t.0, t.1), from: C(p.0, p.1), headingDegrees: h))) }
let headings: [Double?] = [nil, .nan, -1, -0.0, 0, .leastNonzeroMagnitude, 90, 180, 270, (360.0).nextDown, 360, 720,
  -360, 1e300, .infinity, -.infinity]
for _ in 0..<220 {
  let p = (naLat(), naLon()), s = span(); let t = (jit(p.0, s), jit(p.1, s))
  let h: Double? = rng.below(3) == 0 ? headings[rng.below(headings.count)] : rng.unit() * 720 - 180
  ra(t, p, h) }
for _ in 0..<40 { ra((mixed(), mixed()), (mixed(), mixed()), rng.unit() * 360) }
for _ in 0..<14 {
  let p = (naLat(), naLon()); let t = (jit(p.0, 0.01), jit(p.1, 0.01))
  let b = EnforcementCameras.bearingDegrees(from: C(p.0, p.1), to: C(t.0, t.1))
  for off in [100.0, -100.0, 180, -180, 260, -260, 280, -280, 460, -460, 540] {
    for h in [b + off, (b + off).nextUp, (b + off).nextDown] { ra(t, p, h) } } }

// =============================================================================
// FuelWarning.isReachable
// =============================================================================
func rr(_ st: (Double, Double), _ here: (Double, Double), _ course: Double, _ rl: [Double], _ ro: [Double],
        _ corridor: Double) {
  emit("reach", hx(st.0), hx(st.1), hx(here.0), hx(here.1), hx(course), hx(corridor), hl(rl), hl(ro),
       b01(FuelWarning.isReachable(station: C(st.0, st.1), from: C(here.0, here.1), courseDegrees: course,
                                   routeAhead: coords(rl, ro), corridorMeters: corridor))) }
let courses: [Double] = [-1, -0.0, 0, .nan, 360, 720, .infinity, -.infinity, 1e300]
let corridorsV: [Double] = [8_000, 0, -0.0, .nan, .infinity, -1, 1e-9]
for _ in 0..<240 {
  let here = (naLat(), naLon()); let st = (jit(here.0, 0.15), jit(here.1, 0.15))
  let n = [0, 0, 0, 1, 2, 4, 9][rng.below(7)]
  var rl: [Double] = [], ro: [Double] = []
  for _ in 0..<n { rl.append(jit(here.0, 0.2)); ro.append(jit(here.1, 0.2)) }
  if n > 0 && rng.below(8) == 0 { rl[rng.below(n)] = sp() }
  let course = rng.below(4) == 0 ? courses[rng.below(courses.count)] : rng.unit() * 360
  let corridor = rng.below(3) == 0 ? corridorsV[rng.below(corridorsV.count)] : rng.unit() * 20_000
  rr(st, here, course, rl, ro, corridor) }
for _ in 0..<30 {
  let here = (naLat(), naLon()); let st = (jit(here.0, 0.05), jit(here.1, 0.05))
  let rl = [jit(here.0, 0.05), jit(here.0, 0.05)], ro = [jit(here.1, 0.05), jit(here.1, 0.05)]
  let d = POIRanking.meters(C(st.0, st.1), C(rl[1], ro[1]))
  for c in [d, d.nextDown, d.nextUp] { rr(st, here, 90, rl, ro, c) } }
for _ in 0..<12 {
  let here = (naLat(), naLon()); let st = (jit(here.0, 0.05), jit(here.1, 0.05))
  let b = FuelWarning.bearingDegrees(from: C(here.0, here.1), to: C(st.0, st.1))
  for off in [100.0, -100.0, 180, 260, -260] {
    for c in [b + off, (b + off).nextUp, (b + off).nextDown] { rr(st, here, c, [], [], 8_000) } } }

// =============================================================================
// HazardFeedScores.distanceToSegmentMeters (both overloads)
// =============================================================================
func rs(_ p: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) {
  emit("seg", hx(p.0), hx(p.1), hx(a.0), hx(a.1), hx(b.0), hx(b.1),
       hx(HazardFeedScores.distanceToSegmentMeters(C(p.0, p.1), C(a.0, a.1), C(b.0, b.1)))) }
func rsk(_ p: (Double, Double), _ a: (Double, Double), _ b: (Double, Double), _ k: Double) {
  emit("segk", hx(p.0), hx(p.1), hx(a.0), hx(a.1), hx(b.0), hx(b.1), hx(k),
       hx(HazardFeedScores.distanceToSegmentMeters(C(p.0, p.1), C(a.0, a.1), C(b.0, b.1), mPerDegLon: k))) }
for _ in 0..<220 {
  let p = (naLat(), naLon()), s = span()
  rs(p, (jit(p.0, s), jit(p.1, s)), (jit(p.0, s), jit(p.1, s))) }
for _ in 0..<30 {
  let p = (naLat(), naLon()), s = span(); let a = (jit(p.0, s), jit(p.1, s)), b = (jit(p.0, s), jit(p.1, s))
  rs(p, a, a); rs(a, a, b); rs(b, a, b); rs(((a.0 + b.0) / 2, (a.1 + b.1) / 2), a, b) }
for _ in 0..<100 { rs((mixed(), mixed()), (mixed(), mixed()), (mixed(), mixed())) }
let ks: [Double] = [0, -0.0, .nan, .infinity, -.infinity, -1, 1e300, 1e-300]
for _ in 0..<150 {
  let p = (naLat(), naLon()), s = span(); let a = (jit(p.0, s), jit(p.1, s)), b = (jit(p.0, s), jit(p.1, s))
  let k = rng.below(3) == 0 ? ks[rng.below(ks.count)] : 111_320.0 * cos(p.0 * .pi / 180)
  rsk(p, a, b, k) }
rsk((0, 0), (0, -1e200), (0, 1e200), 1); rsk((0, 0), (0, 1e200), (0, -1e200), 1)
rs((0, 0), (0, -1e160), (0, 1e160)); rs((0, 0), (1e-310, 0), (-1e-310, 0))

// =============================================================================
// AmtrakStations.nearest
// =============================================================================
func ramtrak(_ q: (Double, Double), _ st: [AmtrakStation], _ maxM: Double) {
  let r = AmtrakStations.nearest(to: C(q.0, q.1), within: maxM, in: st)
  emit("amtrak", hl(st.map(\.lat)), hl(st.map(\.lon)), hx(q.0), hx(q.1), hx(maxM), r?.code ?? "-") }
let radii: [Double] = [0, 50_000, 200_000, .infinity, .nan, -1]
for _ in 0..<110 {
  let q = (naLat(), naLon()); let n = rng.below(13)
  var st: [AmtrakStation] = []
  for i in 0..<n {
    var la = jit(q.0, 1.5), lo = jit(q.1, 1.5)
    if rng.below(6) == 0, let prev = st.last { la = prev.lat; lo = prev.lon }
    if rng.below(25) == 0 { la = sp() }
    st.append(AmtrakStation(code: "\(i)", name: "", lat: la, lon: lo)) }
  let ds = st.map { POIRanking.meters($0.coordinate, C(q.0, q.1)) }   // only to aim radii at the edge
  var maxM = radii[rng.below(radii.count)]
  if let m = ds.min(), rng.below(2) == 0 { maxM = [m, m.nextDown, m.nextUp][rng.below(3)] }
  ramtrak(q, st, maxM) }
for pts in [[(40.5, -90.0), (39.5, -90.0)], [(39.5, -90.0), (40.5, -90.0)], [(41.0, -90.0), (40.5, -90.0), (39.5, -90.0)]] {
  let st = pts.enumerated().map { AmtrakStation(code: "\($0.offset)", name: "", lat: $0.element.0, lon: $0.element.1) }
  for m in [55_660.0, (55_660.0).nextDown] { ramtrak((40.0, -90.0), st, m) } }

// =============================================================================
// RadioTuning.nearest
// =============================================================================
func rradio(_ q: (Double, Double), _ st: [RadioTuning.Station]) {
  let r = RadioTuning.nearest(to: C(q.0, q.1), in: st)
  emit("radio", hl(st.map { $0.coordinate.latitude }), hl(st.map { $0.coordinate.longitude }),
       lst(st.map { b01($0.isExact) }), hx(q.0), hx(q.1), r?.station.id ?? "-", ho(r?.meters)) }
for _ in 0..<110 {
  let q = (naLat(), naLon()); let n = rng.below(10)
  var st: [RadioTuning.Station] = []
  for i in 0..<n {
    var c = C(jit(q.0, 1), jit(q.1, 1))
    if rng.below(3) == 0, let prev = st.last { c = prev.coordinate }
    if rng.below(25) == 0 { c = C(sp(), c.longitude) }
    st.append(RadioTuning.Station(id: "\(i)", coordinate: c, isExact: rng.below(2) == 0)) }
  rradio(q, st) }
let tiePts: [(Double, Double)] = [(40.5, -90.0), (39.5, -90.0), (40.5, -90.0), (39.5, -90.0)]
for ex in [[false, true], [true, false], [false, false], [true, true], [false, false, true], [true, false, true],
           [false, true, false], [false, true, true, false], [false, false, false, true]] {
  let st = ex.enumerated().map { RadioTuning.Station(id: "\($0.offset)", coordinate: C(tiePts[$0.offset].0, tiePts[$0.offset].1),
                                                     isExact: $0.element) }
  rradio((40.0, -90.0), st) }
rradio((40.0, -90.0), [RadioTuning.Station(id: "0", coordinate: C(.nan, -90), isExact: false),
                       RadioTuning.Station(id: "1", coordinate: C(40.5, -90), isExact: true)])

// =============================================================================
// ScannerFeedStore.nearest
// =============================================================================
for _ in 0..<110 {
  let q = (naLat(), naLon()); let n = rng.below(9)
  var feeds: [ScannerFeed] = []
  for i in 0..<n {
    var la: Double? = jit(q.0, 1), lo: Double? = jit(q.1, 1)
    if rng.below(5) == 0, let prev = feeds.last { la = prev.latitude; lo = prev.longitude }
    if rng.below(6) == 0 { la = nil }
    if rng.below(6) == 0 { lo = nil }
    if rng.below(25) == 0 { la = sp() }
    feeds.append(ScannerFeed(name: "\(i)", url: "", latitude: la, longitude: lo)) }
  let r = ScannerFeedStore.nearest(to: C(q.0, q.1), in: feeds)
  emit("scanner", lst(feeds.map { ho($0.latitude) }), lst(feeds.map { ho($0.longitude) }), hx(q.0), hx(q.1),
       r?.name ?? "-") }

// =============================================================================
// OfflineCorridorStore.nearest (verbatim body above, over real SavedCorridor decoding)
// =============================================================================
let zeroID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
let epoch = Date(timeIntervalSince1970: 0)
for _ in 0..<100 {
  let q = (naLat(), naLon()); let n = rng.below(5)
  var cs: [SavedCorridor] = []
  for i in 0..<n {
    var pts: [[Double]] = []
    let k = rng.below(7)
    for _ in 0..<k {
      switch rng.below(14) {
      case 0: pts.append([])
      case 1: pts.append([jit(q.0, 1)])
      case 2: pts.append([jit(q.0, 1), jit(q.1, 1), 7])
      case 3: pts.append([sp(), jit(q.1, 1)])
      default: pts.append([jit(q.0, 1), jit(q.1, 1)])
      } }
    if rng.below(5) == 0, let prev = cs.last { pts = prev.points }
    cs.append(SavedCorridor(id: zeroID, savedAt: epoch, destinationName: "\(i)", points: pts)) }
  let decoded = cs.map { $0.coordinates }
  let r = CorridorStoreProbe(corridors: cs).nearest(to: C(q.0, q.1))
  emit("corr", lst(decoded.map { "\($0.count)" }), hl(decoded.flatMap { $0.map(\.latitude) }),
       hl(decoded.flatMap { $0.map(\.longitude) }), hx(q.0), hx(q.1), r?.destinationName ?? "-") }

// =============================================================================
// ShowerAvailability.LocationTable
// =============================================================================
func showerTable(_ id: String, _ lats: [Double], _ lons: [Double], _ queries: [(Double, Double)]) {
  let table = ShowerAvailability.LocationTable(entries: entries(lats, lons))
  emit("showert", id, hl(lats), hl(lons), "ok")
  for q in queries { emit("shower", id, hx(q.0), hx(q.1), table.entry(nearLat: q.0, lon: q.1)?.brand ?? "-") } }
func tableQueries(_ lats: [Double], _ lons: [Double], _ k: Int) -> [(Double, Double)] {
  var qs: [(Double, Double)] = []
  for _ in 0..<k {
    let i = rng.below(lats.count)
    switch rng.below(6) {
    case 0: qs.append((lats[i], lons[i]))
    case 1: qs.append(((lats[i] * 100).rounded(.down) / 100, (lons[i] * 100).rounded(.down) / 100))
    case 2: qs.append((jit(lats[i], 0.03), jit(lons[i], 0.03)))
    default: qs.append((jit(lats[i], 0.012), jit(lons[i], 0.012)))
    } }
  return qs }
showerTable("SE", [], [], [(35.0, -97.0), (0, 0), (-0.0, -0.0)])
showerTable("S", tableS.0, tableS.1, [(35.0, -97.0), (35.005, -97.0), (34.999, -97.004), (35.02, -97.0)])
do {
  let lats = [41.5], lons = [-87.6]
  showerTable("one", lats, lons, [(41.5, -87.6), (41.505, -87.6), (41.5099999, -87.6), (41.51, -87.6), (41.5, -87.59),
                                  (41.49, -87.6), (41.4900001, -87.6099999)] + tableQueries(lats, lons, 12))
}
do {
  var lats: [Double] = [], lons: [Double] = []
  for _ in 0..<80 {
    var la = jit(35.0, 0.03), lo = jit(-97.0, 0.03)
    if rng.below(6) == 0, let pl = lats.last, let po = lons.last { la = pl; lo = po }
    if rng.below(8) == 0 { la = (la * 100).rounded(.down) / 100; lo = (lo * 100).rounded(.up) / 100 }
    lats.append(la); lons.append(lo) }
  showerTable("cluster", lats, lons, tableQueries(lats, lons, 110))
}
do {   // exact ties across cells: entry 1 sits in the cell scanned first
  let lats = [0.50390625, 0.49609375, 0.5, 0.5, 0.5078125]
  let lons = [0.5, 0.5, 0.50390625, 0.5, 0.5]
  showerTable("binary", lats, lons, [(0.5, 0.5), (0.5, 0.50390625), (0.50390625, 0.5), (0.5, 0.49609375),
                                     (0.50390625, 0.50390625), (0.505859375, 0.5)])
}
do {
  let lats = [0.004, -0.004, 0.004, -0.004, -0.0, 0.0, -33.9, -33.905]
  let lons = [0.004, -0.004, -0.004, 0.004, 0.0, -0.0, 151.2, 151.195]
  showerTable("zero", lats, lons, [(0, 0), (-0.0, -0.0), (0.001, -0.001), (-0.009, 0.009), (-33.9025, 151.1975),
                                   (-0.01, -0.01), (0.0099, 0.0099)] + tableQueries(lats, lons, 20))
}
do {
  var lats: [Double] = [], lons: [Double] = []
  for _ in 0..<1_000 { lats.append(naLat()); lons.append(naLon()) }
  var qs = tableQueries(lats, lons, 160)
  for _ in 0..<40 { qs.append((naLat(), naLon())) }
  showerTable("big", lats, lons, qs)
}

// =============================================================================
// POIRanking.RoutePath (cumulative meters, 0.1-degree grid, nearest)
// =============================================================================
func route(_ id: String, _ lats: [Double], _ lons: [Double], _ queries: [(Double, Double)]) {
  let rp = POIRanking.RoutePath(coords: coords(lats, lons))
  emit("rp", id, hl(lats), hl(lons), hl(rp.cumulative))
  for q in queries { emit("rpn", id, hx(q.0), hx(q.1), routeResult(rp.nearest(to: C(q.0, q.1)))) } }
func walk(_ n: Int, _ start: (Double, Double), _ step: (Double, Double), _ drift: (Double, Double)) -> ([Double], [Double]) {
  var la = start.0, lo = start.1, lats: [Double] = [], lons: [Double] = []
  for _ in 0..<n {
    lats.append(la); lons.append(lo)
    la += drift.0 + (rng.unit() * 2 - 1) * step.0; lo += drift.1 + (rng.unit() * 2 - 1) * step.1 }
  return (lats, lons) }
func routeQueries(_ lats: [Double], _ lons: [Double], _ k: Int) -> [(Double, Double)] {
  var qs: [(Double, Double)] = []
  for _ in 0..<k {
    let i = rng.below(lats.count)
    switch rng.below(7) {
    case 0: qs.append((lats[i], lons[i]))
    case 1: if i + 1 < lats.count { qs.append(((lats[i] + lats[i + 1]) / 2, (lons[i] + lons[i + 1]) / 2)) }
    case 2: qs.append((jit(lats[i], 0.3), jit(lons[i], 0.3)))
    case 3: qs.append((jit(lats[i], 2.5), jit(lons[i], 2.5)))
    case 4: qs.append(((lats[i] * 10).rounded(.down) / 10, (lons[i] * 10).rounded(.down) / 10))
    default: qs.append((jit(lats[i], 0.05), jit(lons[i], 0.05)))
    } }
  return qs }
route("E", [], [], [(43, -89), (0, 0), (-0.0, -0.0)])
route("T", routeT.0, routeT.1, [(43.07, -89.40), (43.09, -89.36), (44, -90)])
do { let (a, b) = ([43.07], [-89.40]); route("one", a, b, routeQueries(a, b, 15) + [(60, 10), (-43.07, 89.4)]) }
do { let (a, b) = ([43.07, 43.08], [-89.40, -89.38]); route("two", a, b, routeQueries(a, b, 20)) }
do {   // exact ties: repeated vertices and an equidistant midpoint (binary-exact offsets)
  let a = [40.0, 40.0, 40.0625, 40.0, 40.0625], b = [-100.0, -100.0, -100.0, -100.0, -100.0]
  route("dup", a, b, [(40.0, -100.0), (40.0625, -100.0), (40.03125, -100.0), (40.03125, -100.5), (41, -100)]
                     + routeQueries(a, b, 20))
}
do { let (a, b) = walk(1_000, (43.07, -89.40), (0.006, 0.006), (0.002, -0.012)); route("i94", a, b, routeQueries(a, b, 150)) }
do { let (a, b) = walk(250, (64.8, -147.7), (0.004, 0.004), (0.01, -0.002)); route("arctic", a, b, routeQueries(a, b, 70)) }
do { let (a, b) = walk(60, (89.5, -180), (0.01, 3), (0.007, 6)); route("pole", a, b, routeQueries(a, b, 40)) }
do {
  let a = (0..<150).map { _ in 52.0 + rng.unit() * 0.01 }
  let b = (0..<150).map { i -> Double in let v = 179.0 + 0.0133 * Double(i); return v > 180 ? v - 360 : v }
  route("anti", a, b, routeQueries(a, b, 40) + [(52, -179.99), (52, 179.99), (52, 180), (52, -180)])
}
do {
  let a = (0..<50).map { 30 + Double($0) / 10 }, b = (0..<50).map { -90 - Double($0) / 10 }
  route("cells", a, b, routeQueries(a, b, 40) + [(30, -90), (30.1, -90.1), (30.05, -90.05), (29.95, -89.95)])
}
do { let (a, b) = walk(12, (35, -110), (0.5, 0.5), (1.5, 2.2)); route("sparse", a, b, routeQueries(a, b, 40)) }
do { let (a, b) = walk(120, (-0.5, -0.5), (0.004, 0.004), (0.01, 0.01)); route("equator", a, b, routeQueries(a, b, 40)) }
do {
  let a = (0..<200).map { i -> Double in let k = i % 8; return 41.0 + 0.0625 * Double(k < 4 ? k : 8 - k) }
  let b = [Double](repeating: -88.0, count: 200)
  route("zig", a, b, routeQueries(a, b, 30) + [(41.03125, -88.0), (41.25, -88.0), (41.0, -88.01)])
}
do {   // above the cosine clamp: a nearer vertex two rings out is not scanned
  let a = [85.0 + 1_050.0 / 111_320.0, 85.0, 85.0 - 0.3], b = [0.0999, 0.2, 0.0999]
  route("hilat", a, b, [(85.0, 0.0999), (85.0, 0.1), (85.0, 0.05), (84.9, 0.0999)] + routeQueries(a, b, 10))
}

// =============================================================================
// PlacesShard.cellKey
// =============================================================================
let keyPairs: [(Int, Int)] = [(0, 0), (-1, -1), (1, 1), (225, -450), (-450, -900), (450, 900), (449, 899),
  (-9_000, -18_000), (-9_001, -18_001), (0, 81_999), (0, 82_000), (0, 100_000)]
for (a, b) in keyPairs { emit("cellkey", "\(a)", "\(b)", "\(PlacesShard.cellKey(lat5: a, lon5: b))") }
for _ in 0..<40 {
  let a = rng.below(2_000_001) - 1_000_000, b = rng.below(2_000_001) - 1_000_000
  emit("cellkey", "\(a)", "\(b)", "\(PlacesShard.cellKey(lat5: a, lon5: b))") }
for _ in 0..<30 {   // as places(near:) derives them from coordinates
  let a = Int(floor(naLat() * 5)), b = Int(floor(naLon() * 5))
  emit("cellkey", "\(a)", "\(b)", "\(PlacesShard.cellKey(lat5: a, lon5: b))") }

// =============================================================================
// HybridWalk.prefixCoordinates
// =============================================================================
let odd: [Double] = [0, -0.0, -1, .nan, .infinity, -.infinity, .leastNonzeroMagnitude]
for _ in 0..<140 {
  let n = [0, 1, 2, 2, 3, 5, 8, 10][rng.below(8)]
  var lats: [Double] = [], lons: [Double] = []
  var la = naLat(), lo = naLon()
  for _ in 0..<n {
    let repeatLast = rng.below(6) == 0 && !lats.isEmpty
    if !repeatLast { la = jit(la, 0.01); lo = jit(lo, 0.01) }
    lats.append(la); lons.append(lo) }
  if n > 0 && rng.below(10) == 0 { lats[rng.below(n)] = sp() }
  let cs = coords(lats, lons)
  var sums: [Double] = [0]
  if n >= 2 { for i in 1..<n { sums.append(sums[sums.count - 1] + POIRanking.meters(cs[i - 1], cs[i])) } }
  let total = sums[sums.count - 1]
  let mark: Double
  switch rng.below(6) {
  case 0: mark = odd[rng.below(odd.count)]
  case 1: mark = sums[rng.below(sums.count)]
  case 2: let s = sums[rng.below(sums.count)]; mark = rng.below(2) == 0 ? s.nextUp : s.nextDown
  case 3: mark = total.nextUp
  default: mark = rng.unit() * total * 1.2
  }
  let p = HybridWalk.prefixCoordinates(cs, meters: mark)
  emit("prefix", hl(lats), hl(lons), hx(mark), hl(p.map(\.latitude)), hl(p.map(\.longitude))) }

// =============================================================================
// Trap cases, each in its own child process
// =============================================================================
for (i, c) in traps.enumerated() {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: argv[0])
  p.arguments = ["trap", String(i)]
  let pipe = Pipe()
  p.standardOutput = pipe
  try! p.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  let result: String
  if p.terminationReason == .exit && p.terminationStatus == 0 {
    result = String(decoding: data, as: UTF8.self)
  } else if p.terminationReason == .exit && p.terminationStatus == 86 {
    result = c.trapFill
  } else {
    fatalError("trap case \(i): unexpected termination \(p.terminationReason.rawValue) status \(p.terminationStatus)")
  }
  emitAll(c.fields + [result])
}

FileHandle.standardOutput.write(out.data(using: .utf8)!)
