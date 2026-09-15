import CoreLocation
import Foundation
// Frozen oracle: every output below comes from the ORIGINAL Swift climate code
// (ClimateProfiles, LatitudeBands, DaylightClock, HarmonicClimatology, RiskTiming),
// before it is replaced by calls into Rust. Doubles are IEEE-754 bit patterns in
// hex, Floats likewise; strings are "s:" + UTF-8 hex, raw bytes "b:" + hex; nil is
// "-"; lists are "L<n>:" + items; integers decimal; booleans 0/1.
//
// Three record shapes:
//   explicit   one input and its output per line;
//   set / dg   named input lists, then an FNV-1a-64 digest over their product;
//   rnd        a digest over a SplitMix64 sweep the Rust test regenerates draw for draw;
//   rdha/rday/rdmj  the trigonometric sweeps, written out sample by sample (see below).
// A digest's hashing order is written next to each loop; the Rust test mirrors it.

func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func hf(_ f: Float) -> String { String(f.bitPattern, radix: 16) }
func hs(_ s: String) -> String { "s:" + s.utf8.map { String(format: "%02x", $0) }.joined() }
func hb(_ b: [UInt8]) -> String { "b:" + b.map { String(format: "%02x", $0) }.joined() }
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
func opt(_ d: Double?) -> String { d.map(hx) ?? "-" }
func bit(_ b: Bool) -> String { b ? "1" : "0" }
var out = ""
func emit(_ f: String...) { out += f.joined(separator: "\t") + "\n" }

struct SM { var s: UInt64
  mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
  mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) } }

/// FNV-1a 64 over little-endian bytes.
struct FNV { var h: UInt64 = 0xcbf29ce484222325; var n = 0
  mutating func byte(_ b: UInt8) { h ^= UInt64(b); h = h &* 0x100000001b3 }
  mutating func u64(_ x: UInt64) { for i in 0..<8 { byte(UInt8(truncatingIfNeeded: x >> (8 * UInt64(i)))) }; n += 1 }
  mutating func d(_ x: Double) { u64(x.bitPattern) }
  mutating func i(_ x: Int) { u64(UInt64(bitPattern: Int64(x))) }
  mutating func b(_ x: Bool) { u64(x ? 1 : 0) }
  mutating func od(_ x: Double?) { if let x { u64(1); d(x) } else { u64(0) } }
  var hex: String { String(h, radix: 16) } }

/// Hashed in place of an output where the original Swift traps (the trap itself is pinned by a `trap` record).
let TRAPPED: UInt64 = 0x5452415050454421

let SP: [Double] = [.nan, -Double.nan, Double(bitPattern: 0x7ff0000000000001), .infinity, -.infinity, 0.0, -0.0,
  .leastNonzeroMagnitude, -.leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude,
  -.greatestFiniteMagnitude, 1e300, -1e300]
/// 1-in-`p` a special value, otherwise `lo + unit * span`. Draw order: below(p), then below(SP) or unit.
func pick(_ r: inout SM, _ p: Int, _ lo: Double, _ span: Double) -> Double {
  let k = r.below(p)
  if k == 0 { let j = r.below(SP.count); return SP[j] }
  let u = r.unit(); return lo + u * span
}
/// Elevation draw: below(8) == 0 → nil; == 1 → special; else unit * 6000 − 1000.
func pickElev(_ r: inout SM) -> Double? {
  let k = r.below(8)
  if k == 0 { return nil }
  if k == 1 { let j = r.below(SP.count); return SP[j] }
  let u = r.unit(); return u * 6000 - 1000
}
func around(_ x: Double) -> [Double] { [x.nextDown, x, x.nextUp] }
func dset(_ name: String, _ v: [Double]) { emit("set", name, lst(v.map(hx))) }
func oset(_ name: String, _ v: [Double?]) { emit("set", name, lst(v.map(opt))) }
func iset(_ name: String, _ v: [Int]) { emit("set", name, lst(v.map { String($0) })) }
func dd(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }

// ---- FLHH builder (the layout rust/flows-train history-baseline writes)
func le32(_ v: UInt32, _ b: inout [UInt8]) { for i in 0..<4 { b.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
func flhh(magic: [UInt8] = Array("FLHH".utf8), version: UInt32 = 1, nZips: UInt32? = nil, nFams: UInt32? = nil,
          fams: [[UInt8]], zips: [[UInt8]], coeffBits: [UInt32]) -> [UInt8] {
  var b = magic
  le32(version, &b); le32(nZips ?? UInt32(zips.count), &b); le32(nFams ?? UInt32(fams.count), &b)
  for f in fams { b.append(UInt8(truncatingIfNeeded: f.count)); b += f }
  for z in zips { b += z }
  for c in coeffBits { le32(c, &b) }
  return b
}
func u8s(_ s: String) -> [UInt8] { Array(s.utf8) }
func fb(_ a: [Float]) -> [UInt32] { a.map(\.bitPattern) }
let t0Bytes = flhh(fams: [u8s("winter"), u8s("heat")], zips: [u8s("53703"), u8s("85004")],
  coeffBits: fb([0.3, 0.25, 0, 0, 0, 0.05, 0, 0, 0, 0, 0.02, 0, 0, 0, 0, 0.3, -0.25, 0, 0, 0]))

// ---- trap child: a Swift trap ends the process, so each one runs alone
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "trap" {
  let a = CommandLine.arguments
  switch a[2] {
  case "bandIndex": print(LatitudeBands.bandIndex(latitude: dd(a[3])))
  case "latitudeProfile":
    print(LatitudeBands.profile(latitude: dd(a[3]), elevationMeters: a[4] == "-" ? nil : dd(a[4])).band)
  case "harmonicScore":
    let t = HarmonicClimatology(data: Data(t0Bytes))!
    print(t.score(zipIndex: Int(a[3])!, familyIndex: Int(a[4])!, week: Int(a[5])!))
  case "arrivalOffsets":
    print(RiskTiming.arrivalOffsets(sampleCount: Int(a[3])!, totalTravelSeconds: dd(a[4])).count)
  case "preciseCell": print(ClimateProfiles.profile(latitude: dd(a[3]), longitude: dd(a[4])).band)
  default: exit(3)
  }
  exit(0)
}
func probe(_ args: [String]) -> String {
  let p = Process()
  p.executableURL = Bundle.main.executableURL
  p.arguments = ["trap"] + args
  p.standardOutput = FileHandle.nullDevice
  p.standardError = FileHandle.nullDevice
  do { try p.run() } catch { return "spawn-failed" }
  p.waitUntilExit()
  switch p.terminationReason {
  case .uncaughtSignal: return "trap"
  case .exit: return "exit\(p.terminationStatus)"
  @unknown default: return "unknown"
  }
}

emit("# FROZEN SWIFT ORACLE — produced by running the original Swift climate code at commit a007de042d12e736fdd86398e1ea54ca31aadc1f")
emit("# (ClimateProfiles.swift, LatitudeBands.swift, DaylightClock.swift, HarmonicClimatology.swift, RiskTiming.swift) before it was replaced by Rust. Do not edit.")

// ============================================================ LatitudeBands
emit("const", "southAnchor", hx(LatitudeBands.southAnchor)); emit("const", "northAnchor", hx(LatitudeBands.northAnchor))
emit("const", "pitchDegrees", hx(LatitudeBands.pitchDegrees)); emit("const", "minLatitude", hx(LatitudeBands.minLatitude))
emit("const", "maxLatitude", hx(LatitudeBands.maxLatitude))
emit("const", "referenceElevationMeters", hx(LatitudeBands.referenceElevationMeters))
emit("const", "metersPerBandStep", hx(LatitudeBands.metersPerBandStep))
let dp = LatitudeBands.Profile(band: 0, comfortLowF: 0, comfortHighF: 0, recordLowF: 0, recordHighF: 0)
emit("const", "windLow", hx(dp.windLow)); emit("const", "windMedium", hx(dp.windMedium)); emit("const", "windHigh", hx(dp.windHigh))
emit("const", "popLow", hx(dp.popLow)); emit("const", "popMedium", hx(dp.popMedium)); emit("const", "popHigh", hx(dp.popHigh))

func prof(_ p: LatitudeBands.Profile) -> [String] {
  [String(p.band), hx(p.comfortLowF), hx(p.comfortHighF), hx(p.recordLowF), hx(p.recordHighF),
   hx(p.windLow), hx(p.windMedium), hx(p.windHigh), hx(p.popLow), hx(p.popMedium), hx(p.popHigh)]
}
func hashProf(_ g: inout FNV, _ p: LatitudeBands.Profile) {
  g.i(p.band); g.d(p.comfortLowF); g.d(p.comfortHighF); g.d(p.recordLowF); g.d(p.recordHighF)
  g.d(p.windLow); g.d(p.windMedium); g.d(p.windHigh); g.d(p.popLow); g.d(p.popMedium); g.d(p.popHigh)
}

let south = LatitudeBands.southAnchor, pitch = LatitudeBands.pitchDegrees
var latB: [Double] = [.infinity, -.infinity, 0, -0.0, .leastNonzeroMagnitude, -90, 90, 1e300, -1e300,
  .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 43.07, 39.74, 36.0, 14.5, 69.5, 25.76]
latB += around(14) + around(70) + around(LatitudeBands.southAnchor) + around(LatitudeBands.northAnchor)
for k in -60...60 { latB += around(south + Double(k) * pitch) + around(south + (Double(k) + 1e-9) * pitch) }
for lat in latB { emit("lbi", hx(lat), String(LatitudeBands.bandIndex(latitude: lat))) }

let ref = LatitudeBands.referenceElevationMeters, step = LatitudeBands.metersPerBandStep
var elevB: [Double?] = [nil, .nan, -Double.nan, .infinity, -.infinity, 0, -0.0, 1e300, -1e300, .greatestFiniteMagnitude,
  -.greatestFiniteMagnitude, .leastNonzeroMagnitude, 1609, -80, 310, 5000]
for m in [-1.5, -0.5, 0.5, 1.5, 2.5] { elevB += around(ref + m * step).map { Optional($0) } }
elevB += around(ref).map { Optional($0) }
for e in elevB { emit("lbs", opt(e), String(LatitudeBands.elevationBandShift(elevationMeters: e))) }

let latP: [Double] = [.infinity, -.infinity, 0, 14, 14.5, 36, 39.74, 42.312985, (42.312985).nextUp, 43.0, 47.080621, 69.5, 70, 90]
let elevP: [Double?] = [nil, .nan, 0, 300, (ref + 0.5 * step).nextDown, ref + 0.5 * step, 1609, -80, 1e300]
for lat in latP { for e in elevP { emit("lbp", hx(lat), opt(e), lst(prof(LatitudeBands.profile(latitude: lat, elevationMeters: e)))) } }
dset("latB", latB); oset("elevB", elevB)
do { var g = FNV(); for lat in latB { for e in elevB { hashProf(&g, LatitudeBands.profile(latitude: lat, elevationMeters: e)) } }
  emit("dg", "lbp", "latB", "elevB", String(g.n), g.hex) }
do { var r = SM(s: 0x4C4231), g = FNV()   // rnd lbi: lat = pick(4, 5, 70); NaN traps
  for _ in 0..<20000 { let lat = pick(&r, 4, 5, 70); if lat.isNaN { g.u64(TRAPPED) } else { g.i(LatitudeBands.bandIndex(latitude: lat)) } }
  emit("rnd", "lbi", "4c4231", "20000", g.hex) }
do { var r = SM(s: 0x4C4232), g = FNV()   // rnd lbs: elev = pickElev
  for _ in 0..<20000 { let e = pickElev(&r); g.i(LatitudeBands.elevationBandShift(elevationMeters: e)) }
  emit("rnd", "lbs", "4c4232", "20000", g.hex) }
do { var r = SM(s: 0x4C4233), g = FNV()   // rnd lbp: lat = pick(4, 5, 70), elev = pickElev; NaN lat traps
  for _ in 0..<20000 { let lat = pick(&r, 4, 5, 70); let e = pickElev(&r)
    if lat.isNaN { g.u64(TRAPPED) } else { hashProf(&g, LatitudeBands.profile(latitude: lat, elevationMeters: e)) } }
  emit("rnd", "lbp", "4c4233", "20000", g.hex) }

// ============================================================ ClimateProfiles
emit("const", "tempSigmaF", hx(ClimateProfiles.SeasonalNorms.tempSigmaF))
for (i, t) in ClimateProfiles.ClimateType.allCases.enumerated() { emit("ctype", String(i), hs(t.rawValue), lst(prof(t.profile))) }
func code(_ t: ClimateProfiles.ClimateType) -> Int { ClimateProfiles.ClimateType.allCases.firstIndex(of: t)! }

var latC: [Double] = [.nan, .infinity, -.infinity, 0, -0.0]
for x in [66.0, 25, 27, 37, 42, 43, 50] { latC += around(x) }
latC += [47.61, 33.45, 44.98, 39.74, 25.76, 19.4, 71.3, 60]
var lonC: [Double] = [.nan, .infinity, -.infinity, 0, -0.0]
for x in [-83.0, -117, -102] { lonC += around(x) }
lonC += [-122.33, -112.07, -93.27, -104.99, -80.19, -150, 180, -180]
var elevC: [Double?] = [nil, .nan, .infinity, -.infinity, 0, -0.0]
for x in [2000.0, 1000] { elevC += around(x).map { Optional($0) } }
elevC += [1609, -80, 5000]
let latF = latC.filter(\.isFinite), lonF = lonC.filter(\.isFinite)
dset("latC", latC); dset("lonC", lonC); oset("elevC", elevC); dset("latF", latF); dset("lonF", lonF)

let cities: [(Double, Double, Double?)] = [(47.61, -122.33, nil), (33.45, -112.07, nil), (44.98, -93.27, nil), (39.74, -104.99, 1609),
  (25.76, -80.19, nil), (34.05, -118.24, nil), (29.76, -95.37, nil), (61.22, -149.9, nil), (71.29, -156.79, nil), (39.74, -104.99, nil),
  (36.17, -115.14, 610), (26.1, -81.8, nil), (40.71, -74.0, nil), (53.55, -113.49, 668), (19.43, -99.13, 2240), (45.5, -73.57, nil)]
for c in cities { emit("ccl", hx(c.0), hx(c.1), opt(c.2), String(code(ClimateProfiles.classify(latitude: c.0, longitude: c.1, elevationMeters: c.2)))) }
for lat in latC { for lon in [-122.0, -110, -90, -82.5] { emit("ccl", hx(lat), hx(lon), "-", String(code(ClimateProfiles.classify(latitude: lat, longitude: lon, elevationMeters: nil)))) } }
for lon in lonC { for lat in [24.0, 26, 30, 40, 45, 55] { emit("ccl", hx(lat), hx(lon), "-", String(code(ClimateProfiles.classify(latitude: lat, longitude: lon, elevationMeters: nil)))) } }
for e in elevC { for (lat, lon) in [(40.0, -110.0), (30.0, -110), (45.0, -90), (30.0, -125)] {
  emit("ccl", hx(lat), hx(lon), opt(e), String(code(ClimateProfiles.classify(latitude: lat, longitude: lon, elevationMeters: e)))) } }
do { var g = FNV(); for lat in latC { for lon in lonC { for e in elevC { g.i(code(ClimateProfiles.classify(latitude: lat, longitude: lon, elevationMeters: e))) } } }
  emit("dg", "ccl", "latC", "lonC", "elevC", String(g.n), g.hex) }
do { var r = SM(s: 0x43434C), g = FNV()   // rnd ccl: lat = pick(6, 10, 65), lon = pick(6, -170, 120), elev = pickElev
  for _ in 0..<20000 { let lat = pick(&r, 6, 10, 65); let lon = pick(&r, 6, -170, 120); let e = pickElev(&r)
    g.i(code(ClimateProfiles.classify(latitude: lat, longitude: lon, elevationMeters: e))) }
  emit("rnd", "ccl", "43434c", "20000", g.hex) }

for c in cities { emit("cpr", hx(c.0), hx(c.1), opt(c.2), lst(prof(ClimateProfiles.profile(latitude: c.0, longitude: c.1, elevationMeters: c.2)))) }
do { var g = FNV(); for lat in latF { for lon in lonF { for e in elevC { hashProf(&g, ClimateProfiles.profile(latitude: lat, longitude: lon, elevationMeters: e)) } } }
  emit("dg", "cpr", "latF", "lonF", "elevC", String(g.n), g.hex) }
do { var r = SM(s: 0x435052), g = FNV()   // rnd cpr: lat = 10 + unit * 65, lon = −170 + unit * 120, elev = pickElev
  for _ in 0..<20000 { let u1 = r.unit(); let u2 = r.unit(); let e = pickElev(&r)
    hashProf(&g, ClimateProfiles.profile(latitude: 10 + u1 * 65, longitude: -170 + u2 * 120, elevationMeters: e)) }
  emit("rnd", "cpr", "435052", "20000", g.hex) }

let W: [Int] = [Int.min, Int.min + 1, -105, -104, -53, -52, -51, -27, -26, -1, 0, 1, 12, 13, 25, 26, 27, 38, 39, 51, 52, 53, 103, 104, Int.max - 1, Int.max]
iset("W", W)
func norms(_ n: ClimateProfiles.SeasonalNorms) -> [String] { [hx(n.weekLowF), hx(n.weekHighF), hx(n.windMeanMph), hx(n.windSigmaMph)] }
for c in cities { for w in [0, 1, 12, 13, 25, 26, 27, 38, 39, 51, 52, -1] {
  emit("csn", String(w), hx(c.0), hx(c.1), opt(c.2), lst(norms(ClimateProfiles.seasonalNorms(week: w, latitude: c.0, longitude: c.1, elevationMeters: c.2)))) } }
do { var g = FNV()
  for w in W { for lat in latC { for lon in lonC { for e in elevC {
    let n = ClimateProfiles.seasonalNorms(week: w, latitude: lat, longitude: lon, elevationMeters: e)
    g.d(n.weekLowF); g.d(n.weekHighF); g.d(n.windMeanMph); g.d(n.windSigmaMph) } } } }
  emit("dg", "csn", "W", "latC", "lonC", "elevC", String(g.n), g.hex) }
do { var r = SM(s: 0x43534E), g = FNV()   // rnd csn: k = below(4); k == 0 → W[below(W)], else below(200) − 100; lat, lon, elev as rnd ccl
  for _ in 0..<20000 {
    let k = r.below(4); var w = 0
    if k == 0 { let j = r.below(W.count); w = W[j] } else { w = r.below(200) - 100 }
    let lat = pick(&r, 6, 10, 65); let lon = pick(&r, 6, -170, 120); let e = pickElev(&r)
    let n = ClimateProfiles.seasonalNorms(week: w, latitude: lat, longitude: lon, elevationMeters: e)
    g.d(n.weekLowF); g.d(n.weekHighF); g.d(n.windMeanMph); g.d(n.windSigmaMph) }
  emit("rnd", "csn", "43534e", "20000", g.hex) }

for c in cities.prefix(3) { for w in [0, 26] {
  let n = ClimateProfiles.seasonalNorms(week: w, latitude: c.0, longitude: c.1, elevationMeters: c.2)
  var temps: [Double] = SP + [20, 62, 80, -5]
  temps += around(n.weekHighF + ClimateProfiles.SeasonalNorms.tempSigmaF) + around(n.weekLowF - ClimateProfiles.SeasonalNorms.tempSigmaF)
  for t in temps { emit("ctb", hx(t), lst(norms(n)), bit(ClimateProfiles.temperatureBeyondNormal(tempF: t, norms: n))) }
  var winds: [Double] = SP + [15, 18, 30]
  winds += around(n.windMeanMph + 2 * n.windSigmaMph)
  for v in winds { emit("cwb", hx(v), lst(norms(n)), bit(ClimateProfiles.windBeyondNormal(windMph: v, norms: n))) } } }
for n in [ClimateProfiles.SeasonalNorms(weekLowF: .nan, weekHighF: .nan, windMeanMph: .nan, windSigmaMph: .nan),
          ClimateProfiles.SeasonalNorms(weekLowF: .infinity, weekHighF: -.infinity, windMeanMph: .infinity, windSigmaMph: -.infinity),
          ClimateProfiles.SeasonalNorms(weekLowF: -0.0, weekHighF: 0, windMeanMph: -0.0, windSigmaMph: 0)] {
  for t in SP + [0, 12, -12, 13, -13] {
    emit("ctb", hx(t), lst(norms(n)), bit(ClimateProfiles.temperatureBeyondNormal(tempF: t, norms: n)))
    emit("cwb", hx(t), lst(norms(n)), bit(ClimateProfiles.windBeyondNormal(windMph: t, norms: n))) } }
do { var r = SM(s: 0x435442), g = FNV()   // rnd ctb/cwb: lo, hi, mean, sigma, temp, wind — each pick(10, …) in that order
  for _ in 0..<20000 {
    let lo = pick(&r, 10, -40, 100); let hi = pick(&r, 10, -20, 140); let mean = pick(&r, 10, 0, 20); let sigma = pick(&r, 10, 0, 8)
    let t = pick(&r, 5, -60, 200); let v = pick(&r, 5, 0, 80)
    let n = ClimateProfiles.SeasonalNorms(weekLowF: lo, weekHighF: hi, windMeanMph: mean, windSigmaMph: sigma)
    g.b(ClimateProfiles.temperatureBeyondNormal(tempF: t, norms: n)); g.b(ClimateProfiles.windBeyondNormal(windMph: v, norms: n)) }
  emit("rnd", "cbn", "435442", "20000", g.hex) }

// ============================================================ Foundation Date arithmetic the Rust relies on
func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, _ s: Int = 0, _ frac: Double = 0) -> Double {
  var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
  var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
  return cal.date(from: c)!.timeIntervalSinceReferenceDate + frac
}
var T: [Double] = [utc(2026, 6, 21, 18), utc(2026, 6, 21, 6), utc(2026, 6, 22, 2), utc(2026, 6, 22, 3), utc(2026, 6, 22, 1, 30),
  utc(2026, 12, 21, 23), utc(2026, 12, 21, 12), utc(2026, 6, 21, 12), utc(2026, 9, 10, 20), utc(2000, 1, 1, 12), utc(1970, 1, 1, 0),
  utc(1900, 1, 1, 0), utc(2100, 1, 1, 0), utc(2026, 9, 14, 17, 33, 12, 0.345), utc(2024, 2, 29, 23, 59, 59, 0.999),
  utc(2038, 1, 19, 3, 14, 7), utc(2026, 3, 20, 14, 46), utc(2026, 9, 23, 0, 5)]
for h in stride(from: 0, to: 24, by: 3) { T.append(utc(2026, 3, 15, h)) }
let realisticT = T
T += [0, -0.0, .nan, -Double.nan, .infinity, -.infinity, .leastNonzeroMagnitude, 1e10, -1e10, 1e12, 1e15, 1e17, 1e20, 1e50,
  1e80, 1e89, 1e100, 1e200, 1e300, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, -1e300]
dset("T", T)
for t in T {
  let dt = Date(timeIntervalSinceReferenceDate: t)
  emit("dref", hx(t), hx(dt.timeIntervalSinceReferenceDate), hx(dt.timeIntervalSince1970),
       hx(Date(timeIntervalSince1970: t).timeIntervalSinceReferenceDate),
       hx(dt.addingTimeInterval(3600).timeIntervalSinceReferenceDate), hx(dt.addingTimeInterval(86400).timeIntervalSinceReferenceDate))
}
for a in SP + [1, 2] { for b in SP + [1, 2] {
  let x = Date(timeIntervalSinceReferenceDate: a), y = Date(timeIntervalSinceReferenceDate: b)
  emit("dcmp", hx(a), hx(b), bit(x < y) + bit(x > y) + bit(x <= y) + bit(x >= y) + bit(x == y)) } }
do { var r = SM(s: 0x44415445), g = FNV()   // rnd date: a = pick(6, −4e9, 8e9), delta = pick(6, −1e5, 2e5)
  for _ in 0..<20000 {
    let a = pick(&r, 6, -4e9, 8e9); let delta = pick(&r, 6, -1e5, 2e5)
    let x = Date(timeIntervalSinceReferenceDate: a)
    let y = x.addingTimeInterval(delta)
    g.d(x.timeIntervalSinceReferenceDate); g.d(x.timeIntervalSince1970); g.d(Date(timeIntervalSince1970: a).timeIntervalSinceReferenceDate)
    g.d(y.timeIntervalSinceReferenceDate); g.b(x < y); g.b(x > y); g.b(x <= y); g.b(x >= y); g.b(x == y) }
  emit("rnd", "date", "44415445", "20000", g.hex) }

// ============================================================ DaylightClock
emit("const", "civilTwilightDegrees", hx(DaylightClock.civilTwilightDegrees))
func coord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
func now(_ t: Double) -> Date { Date(timeIntervalSinceReferenceDate: t) }
func tw(_ lat: Double, _ lon: Double, _ t: Double, _ angle: Double? = nil) -> (Double, Double)? {
  let r = angle.map { DaylightClock.twilight(at: coord(lat, lon), on: now(t), angle: $0) } ?? DaylightClock.twilight(at: coord(lat, lon), on: now(t))
  return r.map { ($0.dawn.timeIntervalSinceReferenceDate, $0.dusk.timeIntervalSinceReferenceDate) }
}
func hashDay(_ g: inout FNV, _ lat: Double, _ lon: Double, _ t: Double) {
  let jd = DaylightClock.julianDay(now(t)); g.d(jd); g.d(DaylightClock.midnightJD(jd))
  let s = DaylightClock.solarTerms(julianDay: jd); g.d(s.declination); g.d(s.equationOfTime)
  if let w = tw(lat, lon, t) { g.u64(1); g.d(w.0); g.d(w.1) } else { g.u64(0) }
  g.b(DaylightClock.isNight(at: coord(lat, lon), now: now(t)))
  g.d(DaylightClock.solarElevation(at: coord(lat, lon), now: now(t)))
  g.d(DaylightClock.nextChange(at: coord(lat, lon), now: now(t)).timeIntervalSinceReferenceDate)
}
func dayFields(_ lat: Double, _ lon: Double, _ t: Double) -> [String] {
  let w = tw(lat, lon, t)
  return [opt(w?.0), opt(w?.1), bit(DaylightClock.isNight(at: coord(lat, lon), now: now(t))),
          hx(DaylightClock.solarElevation(at: coord(lat, lon), now: now(t))),
          hx(DaylightClock.nextChange(at: coord(lat, lon), now: now(t)).timeIntervalSinceReferenceDate)]
}

var jdSet: [Double] = T.map { DaylightClock.julianDay(now($0)) }
jdSet += [2451545, 2451544.5, 0, -0.0, .nan, .infinity, -.infinity, 1e300, -1e300, .greatestFiniteMagnitude, 1e20, -1e20]
for x in [2451545.5, 2460000.5, 0.5, -0.5, 2461207.0] { jdSet += around(x) }
for t in T { emit("djd", hx(t), hx(DaylightClock.julianDay(now(t)))) }
for jd in jdSet {
  let s = DaylightClock.solarTerms(julianDay: jd)
  emit("dmj", hx(jd), hx(DaylightClock.midnightJD(jd))); emit("dst", hx(jd), hx(s.declination), hx(s.equationOfTime)) }

let haLat: [Double] = [0, 43.07, 66.56, 89.9, 90, -90, .nan, .infinity, -0.0]
let haDecl: [Double] = [0, 23.44, -23.44, 90, .nan, -0.0]
let haAngle: [Double] = [-6, 0, 90, -90, 180, .nan, -0.833, -0.0]
for a in haLat { for b in haDecl { for c in haAngle {
  emit("dha", hx(a), hx(b), hx(c), opt(DaylightClock.hourAngleMinutes(latitude: a, declination: b, angle: c))) } } }
// Random sweeps over the trigonometric functions are written out sample by sample, not
// digested: the Release compiler fuses sin/cos pairs, whose sine can differ from a standalone
// sin by one ulp, so a digest of 20,000 values would break on a harmless last-bit difference.
// The Rust test compares these with a stated physical tolerance.
do { var r = SM(s: 0x444841)   // rdha: lat = pick(6, −90, 180), decl = pick(6, −24, 48), angle = pick(6, −20, 40)
  for _ in 0..<2000 { let a = pick(&r, 6, -90, 180); let b = pick(&r, 6, -24, 48); let c = pick(&r, 6, -20, 40)
    emit("rdha", hx(a), hx(b), hx(c), opt(DaylightClock.hourAngleMinutes(latitude: a, declination: b, angle: c))) } }

let realCoords: [(Double, Double)] = [(43.07, -89.40), (25.76, -80.19), (71.29, -156.79), (64.84, -147.72), (47.6, -122.3),
  (19.43, -99.13), (0, 0), (-33.87, 151.21), (66.56, -150), (45, -179.99), (45, 179.99), (60, -150)]
for c in realCoords { for t in realisticT { emit("dday", hx(c.0), hx(c.1), hx(t), lst(dayFields(c.0, c.1, t))) } }

let angles: [Double] = [-6, 0, -0.833, -12, -18, 90, -90, 89.99, .nan, .infinity, -.infinity, 180, -0.0]
for c in realCoords.prefix(4) { for t in [utc(2026, 6, 21, 18), utc(2026, 12, 21, 18), utc(2026, 3, 20, 18)] { for a in angles {
  let w = tw(c.0, c.1, t, a); emit("dtw", hx(c.0), hx(c.1), hx(t), hx(a), opt(w?.0), opt(w?.1)) } } }

// Boundary probes: exactly at, just before and just after each dawn and dusk.
for c in [(43.07, -89.40), (25.76, -80.19), (64.84, -147.72), (60.0, -150.0), (66.0, -150.0), (23.4, -100.0), (45.0, -179.99), (45.0, 179.99)] {
  for day in [(2026, 6, 21), (2026, 12, 21), (2026, 3, 20), (2026, 9, 22), (2027, 1, 1)] {
    let noon = utc(day.0, day.1, day.2, 12) - c.1 / 15 * 3600
    guard let w = tw(c.0, c.1, noon) else { emit("dnone", hx(c.0), hx(c.1), hx(noon)); continue }
    for t in around(w.0) + around(w.1) { emit("dday", hx(c.0), hx(c.1), hx(t), lst(dayFields(c.0, c.1, t))) } } }

let latD: [Double] = [43.07, 25.76, 71.29, 0, -33.87, 66.56, 89.9, -89.9, 90, -90, 64.84, 19.43, 47.6, .nan, .infinity, -.infinity,
  -0.0, 1e300, 45, 60, 80, -60, 23.44, 66.5622]
let lonD: [Double] = [-89.4, -80.19, -156.79, 0, 151.21, -150, -147.72, -99.13, -122.3, 180, -180, 179.99, -179.99, .nan,
  .infinity, -.infinity, -0.0, 1e300, 360, -360, 90]
dset("latD", latD); dset("lonD", lonD)
do { var g = FNV(); for lat in latD { for lon in lonD { for t in T { hashDay(&g, lat, lon, t) } } }
  emit("dg", "day", "latD", "lonD", "T", String(g.n), g.hex) }
do { var r = SM(s: 0x444159)   // rday: lat = pick(8, −90, 180), lon = pick(8, −180, 360), t = pick(8, −3.2e9, 6.4e9)
  for _ in 0..<2000 { let lat = pick(&r, 8, -90, 180); let lon = pick(&r, 8, -180, 360); let t = pick(&r, 8, -3.2e9, 6.4e9)
    let jd = DaylightClock.julianDay(now(t)); let st = DaylightClock.solarTerms(julianDay: jd)
    emit("rday", hx(lat), hx(lon), hx(t), hx(jd), hx(DaylightClock.midnightJD(jd)), hx(st.declination), hx(st.equationOfTime),
         lst(dayFields(lat, lon, t))) } }
do { var r = SM(s: 0x445457), g = FNV()   // rnd dtw: lat, lon, t as rnd day, then angle = pick(6, −20, 40)
  for _ in 0..<20000 { let lat = pick(&r, 8, -90, 180); let lon = pick(&r, 8, -180, 360); let t = pick(&r, 8, -3.2e9, 6.4e9)
    let a = pick(&r, 6, -20, 40)
    if let w = tw(lat, lon, t, a) { g.u64(1); g.d(w.0); g.d(w.1) } else { g.u64(0) } }
  emit("rnd", "dtw", "445457", "20000", g.hex) }
do { var r = SM(s: 0x444D4A)   // rdmj: jd = pick(6, 2.4e6, 1e5); every 3rd draw snaps to floor(jd) + 0.5
  for i in 0..<2000 { var jd = pick(&r, 6, 2.4e6, 1e5); if i % 3 == 0 && jd.isFinite { jd = jd.rounded(.down) + 0.5 }
    let s = DaylightClock.solarTerms(julianDay: jd)
    emit("rdmj", hx(jd), hx(DaylightClock.midnightJD(jd)), hx(s.declination), hx(s.equationOfTime)) } }

// ============================================================ HarmonicClimatology
emit("const", "scoreMax", hx(HarmonicClimatology.scoreMax))
for w in W { let tr = HarmonicClimatology.WeekTrig(week: w); emit("hwt", String(w), hx(tr.cosT), hx(tr.sinT), hx(tr.cos2T), hx(tr.sin2T)) }
do { var g = FNV(); for w in -1000...1000 { let tr = HarmonicClimatology.WeekTrig(week: w); g.d(tr.cosT); g.d(tr.sinT); g.d(tr.cos2T); g.d(tr.sin2T) }
  emit("dg", "hwt", "-1000..1000", String(g.n), g.hex) }

func mirror<T>(_ t: HarmonicClimatology, _ label: String) -> T { Mirror(reflecting: t).children.first { $0.label == label }!.value as! T }
let WK: [Int] = [Int.min, -53, -52, -1, 0, 1, 13, 26, 39, 51, 52, 53, 104, Int.max]
var tableID = 0
func table(_ name: String, _ bytes: [UInt8], zipQ: [String] = [], famQ: [String] = []) {
  let id = tableID; tableID += 1
  guard let t = HarmonicClimatology(data: Data(bytes)) else { emit("hp", String(id), hb(bytes), "0"); return }
  let zips: [String] = mirror(t, "zips"), coeffs: [Float] = mirror(t, "coeffs"), nf: Int = mirror(t, "nFamilies")
  emit("hp", String(id), hb(bytes), "1", lst(t.families.map(hs)), lst(zips.map(hs)), lst(coeffs.map(hf)), String(nf))
  // Queries: every decoded zip, its NFC/NFD forms and near misses; the first four families, their forms, and extras.
  var zq = zips + zipQ + ["", "99999", "00000"]
  for z in zips { zq += [z.precomposedStringWithCanonicalMapping, z.decomposedStringWithCanonicalMapping, z + "0", String(z.prefix(4))] }
  let fams4 = Array(t.families.prefix(4)) + (nf > 4 ? [t.families[nf - 1]] : [])
  var fq = fams4 + famQ + ["", "volcanic", "HEAT"]
  for f in fams4 { fq += [f.precomposedStringWithCanonicalMapping, f.decomposedStringWithCanonicalMapping, f.uppercased()] }
  let map = t.zipIndexMap()
  emit("hzc", String(id), String(map.count))
  for q in zq { emit("hzi", String(id), hs(q), t.zipIndex(q).map { String($0) } ?? "-"); emit("hzm", String(id), hs(q), map[q].map { String($0) } ?? "-") }
  for z in zips + zipQ + ["", "99999"] { for f in fq { for w in [0, 26] {
    emit("hsn", String(id), hs(z), hs(f), String(w), opt(t.score(zip: z, family: f, week: w))) } } }
  let fis = Array(0..<min(nf, 4)) + (nf > 4 ? [nf - 1] : [])
  for zi in 0..<zips.count { for fi in fis {
    for w in WK { emit("hsc", String(id), String(zi), String(fi), String(w), hx(t.score(zipIndex: zi, familyIndex: fi, week: w))) }
    for w in [Int.min, 0, 26, Int.max] {
      emit("hst", String(id), String(zi), String(fi), String(w), hx(t.score(zipIndex: zi, familyIndex: fi, trig: HarmonicClimatology.WeekTrig(week: w)))) } } }
}

let z5 = [u8s("53703"), u8s("85004")], wh = [u8s("winter"), u8s("heat")]
let z0 = [Float](repeating: 0, count: 5)
table("test fixture", t0Bytes)
table("clamp fixture", flhh(fams: wh, zips: z5, coeffBits: fb([0.5, 0.5, 0, 0, 0] + [-0.5, 0, 0, 0, 0] + z0 + z0)))
table("1x1", flhh(fams: [u8s("wind")], zips: [u8s("00001")], coeffBits: fb([0.1, 0.2, 0.3, 0.4, 0.5])))
let specialF: [UInt32] = [0x7fc00000, 0x7f800001, 0xffc00000, 0x7f800000, 0xff800000, 0x80000000, 0x00000001, 0x7f7fffff,
  Float(0.6).bitPattern, Float(0.6).nextUp.bitPattern, Float(0.6).nextDown.bitPattern, 0x80000001, 0x3e99999a, 0xbe99999a, 0x3f000000]
table("special coefficients", flhh(fams: [u8s("a"), u8s("b"), u8s("c")], zips: [u8s("11111"), u8s("22222")],
  coeffBits: specialF + [0x80000000, 0x80000000, 0x80000000, 0x80000000, 0x80000000] + fb([0.6, 0, 0, 0, 0]) + fb([0.3, 0.3, 0, 0, 0]) + fb([0, 0, 0, 0, -0.0]) + fb([0.2, 0.1, 0.1, 0.1, 0.1])))
var fams32: [[UInt8]] = [[], [UInt8](repeating: 0x61, count: 255)]
for i in 2..<32 { fams32.append(u8s("f\(i)")) }
table("32 families, empty and 255-byte names", flhh(fams: fams32, zips: [u8s("10000"), u8s("20000"), u8s("30000")],
  coeffBits: (0..<(3 * 32 * 5)).map { Float(Double($0) * 0.001 - 0.05).bitPattern }))
table("33 families", flhh(fams: fams32 + [u8s("x")], zips: [u8s("10000")], coeffBits: [UInt32](repeating: 0, count: 33 * 5)))
table("unsorted zips", flhh(fams: [u8s("heat")], zips: [u8s("85004"), u8s("53703"), u8s("60601")], coeffBits: fb([0.1, 0, 0, 0, 0, 0.2, 0, 0, 0, 0, 0.3, 0, 0, 0, 0])))
table("duplicate zips", flhh(fams: [u8s("heat")], zips: [u8s("53703"), u8s("53703"), u8s("53703"), u8s("60601")],
  coeffBits: fb([0.1, 0, 0, 0, 0, 0.2, 0, 0, 0, 0, 0.3, 0, 0, 0, 0, 0.4, 0, 0, 0, 0])))
let oddZips: [[UInt8]] = [[0x31, 0x32, 0x00, 0x33, 0x34], [0x65, 0xCC, 0x81, 0x31, 0x32], [0xC3, 0xA9, 0x31, 0x32, 0x33], [0xEF, 0xBB, 0xBF, 0x31, 0x32]]
let oddFams: [[UInt8]] = [[0xEF, 0xBB, 0xBF, 0x68, 0x65, 0x61, 0x74], [0xC3, 0xA9], [0x65, 0xCC, 0x81], [0x68, 0x00, 0x74], [0xEF, 0xBB, 0xBF], [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF], [0xEF, 0xBF, 0xBE], [0xF4, 0x8F, 0xBF, 0xBF]]
table("odd but valid UTF-8", flhh(fams: oddFams, zips: oddZips, coeffBits: (0..<(4 * 8 * 5)).map { Float(Double($0) * 0.002).bitPattern }),
  zipQ: ["\u{E9}12", "e\u{301}12", "\u{E9}123", "e\u{301}123", "12", "\u{FEFF}12", "12\u{0}34"], famQ: ["\u{E9}", "e\u{301}", "heat", "\u{FEFF}heat", "h\u{0}t", "\u{FEFF}"])
table("same zips NFC then NFD", flhh(fams: [u8s("e\u{301}"), u8s("\u{E9}")], zips: [[0x65, 0xCC, 0x81, 0x31, 0x32], [0xC3, 0xA9, 0x31, 0x32, 0x33]],
  coeffBits: (0..<20).map { Float(Double($0) * 0.01).bitPattern }), zipQ: ["\u{E9}12", "e\u{301}123"], famQ: ["\u{E9}", "e\u{301}"])
for bad in [[0xFF], [0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82], [0xFE, 0xFF, 0x00, 0x61], [0x61, 0x80]] as [[UInt8]] {
  table("invalid family name", flhh(fams: [bad], zips: [u8s("12345")], coeffBits: [0, 0, 0, 0, 0]))
  let zip = (bad + [UInt8](repeating: 0x30, count: 5)).prefix(5)
  table("invalid zip", flhh(fams: [u8s("heat")], zips: [Array(zip)], coeffBits: [0, 0, 0, 0, 0]))
}
table("bad magic", flhh(magic: u8s("XXXX"), fams: wh, zips: z5, coeffBits: [UInt32](repeating: 0, count: 20)))
table("lowercase magic", flhh(magic: u8s("flhh"), fams: wh, zips: z5, coeffBits: [UInt32](repeating: 0, count: 20)))
for v: UInt32 in [0, 2, 0xFFFF_FFFF, 0x0100_0000] { table("version", flhh(version: v, fams: wh, zips: z5, coeffBits: [UInt32](repeating: 0, count: 20))) }
for n: UInt32 in [0, 1, 3, 99_999, 100_000, 0xFFFF_FFFF] { table("nZips", flhh(nZips: n, fams: wh, zips: z5, coeffBits: [UInt32](repeating: 0, count: 20))) }
for n: UInt32 in [0, 1, 3, 32, 33, 0xFFFF_FFFF] { table("nFams", flhh(nFams: n, fams: wh, zips: z5, coeffBits: [UInt32](repeating: 0, count: 20))) }
table("name length past the end", Array(t0Bytes.prefix(16)) + [200, 0x61, 0x62])
table("empty", [])
for cut in 0..<t0Bytes.count { table("truncated", Array(t0Bytes.prefix(cut))) }
table("trailing byte", t0Bytes + [0])
table("trailing float", t0Bytes + [0, 0, 0, 0])

// The largest realistic table: 33,613 zips × 8 families, generated from a seeded SplitMix64.
// Zips: z_i = 2i + below(2), as "%05d". Coefficients, per zip, per family: mean = Float(unit × 0.4), then
// a1, b1, a2, b2 = Float(unit × 0.4 − 0.2). All zips are drawn first, then all coefficients.
do {
  var r = SM(s: 0x464C4848)
  let nZ = 33_613, fams = ["wind", "heat", "cold", "air", "winter", "convective", "qpf_flood", "fire"]
  var zipStrs: [String] = []
  for i in 0..<nZ { let k = r.below(2); zipStrs.append(String(format: "%05d", 2 * i + k)) }
  var bits: [UInt32] = []
  for _ in 0..<(nZ * fams.count) {
    let m = r.unit(); bits.append(Float(m * 0.4).bitPattern)
    for _ in 0..<4 { let u = r.unit(); bits.append(Float(u * 0.4 - 0.2).bitPattern) } }
  let bytes = flhh(fams: fams.map(u8s), zips: zipStrs.map(u8s), coeffBits: bits)
  var bg = FNV(); for b in bytes { bg.byte(b) }
  let t = HarmonicClimatology(data: Data(bytes))!
  let zips: [String] = mirror(t, "zips"), coeffs: [Float] = mirror(t, "coeffs")
  var zg = FNV(); for z in zips { for b in z.utf8 { zg.byte(b) }; zg.byte(0xFF) }
  var cg = FNV(); for c in coeffs { cg.u64(UInt64(c.bitPattern)) }
  var sg = FNV()
  for w in [0, 13, 26, 39, 51, -7, 60] { let tr = HarmonicClimatology.WeekTrig(week: w)
    for zi in 0..<nZ { for fi in 0..<fams.count { sg.d(t.score(zipIndex: zi, familyIndex: fi, trig: tr)) } } }
  let map = t.zipIndexMap()
  var mg = FNV(); mg.i(map.count)
  for z in zipStrs { mg.i(map[z] ?? -1) }
  for z in stride(from: 0, to: 70_000, by: 7) { let q = String(format: "%05d", z); mg.i(t.zipIndex(q) ?? -1); mg.i(map[q] ?? -1) }
  var ng = FNV()
  for i in stride(from: 0, to: nZ, by: 101) { for f in fams + ["missing"] { ng.od(t.score(zip: zipStrs[i], family: f, week: 17)) } }
  emit("hbig", "464c4848", String(nZ), String(bytes.count), bg.hex, lst(t.families.map(hs)), zg.hex, cg.hex, sg.hex, mg.hex, ng.hex)
}

// ============================================================ RiskTiming
let nowT: [Double] = [utc(2026, 9, 14, 12), 0, -0.0, .nan, .infinity, 1e300]
let offT: [Double] = [.nan, -Double.nan, .infinity, -.infinity, 0, -0.0, -1, 1, 3600, 36000, 86400.5, .leastNonzeroMagnitude,
  .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e-7]
for n in nowT { for o in offT {
  let c = Date(timeIntervalSinceReferenceDate: n).addingTimeInterval(max(o, 0)).timeIntervalSinceReferenceDate
  var ex: [Double?] = [nil, .nan, .infinity, -.infinity, 0, -0.0]
  ex += around(c).map { Optional($0) }
  for e in ex {
    emit("rta", opt(e), hx(o), hx(n), bit(RiskTiming.isActive(expires: e.map { Date(timeIntervalSinceReferenceDate: $0) }, arrivalOffset: o, now: Date(timeIntervalSinceReferenceDate: n)))) } } }
do { var r = SM(s: 0x525441), g = FNV()   // rnd rta: now = pick(8, −1e9, 2e9), off = pick(8, −1e4, 1e5), has = below(8) != 0,
  // then if has: k = below(3); k == 0 → the arrival instant; k == 1 → its nextUp (below(2) == 0) or nextDown; else pick(8, −1e9, 2e9)
  for _ in 0..<20000 {
    let n = pick(&r, 8, -1e9, 2e9); let o = pick(&r, 8, -1e4, 1e5); let has = r.below(8) != 0
    var e: Double? = nil
    if has {
      let c = Date(timeIntervalSinceReferenceDate: n).addingTimeInterval(max(o, 0)).timeIntervalSinceReferenceDate
      let k = r.below(3)
      if k == 0 { e = c } else if k == 1 { let up = r.below(2) == 0; e = up ? c.nextUp : c.nextDown } else { e = pick(&r, 8, -1e9, 2e9) }
    }
    g.b(RiskTiming.isActive(expires: e.map { Date(timeIntervalSinceReferenceDate: $0) }, arrivalOffset: o, now: Date(timeIntervalSinceReferenceDate: n))) }
  emit("rnd", "rta", "525441", "20000", g.hex) }

let totals: [Double] = [.nan, -Double.nan, .infinity, -.infinity, 0, -0.0, 1, 3600, 28800, 1e300, .greatestFiniteMagnitude,
  .leastNonzeroMagnitude, -5, 0.1]
for n in [Int.min, -1, 0, 1, 2, 3, 5, 7] { for t in totals {
  emit("rto", String(n), hx(t), lst(RiskTiming.arrivalOffsets(sampleCount: n, totalTravelSeconds: t).map(hx))) } }
do { var g = FNV()
  for n in [64, 1000, 65_536] { for t in totals { let v = RiskTiming.arrivalOffsets(sampleCount: n, totalTravelSeconds: t); g.i(v.count); for x in v { g.d(x) } } }
  emit("dg", "rto", "64,1000,65536", String(g.n), g.hex) }
do { var r = SM(s: 0x52544F), g = FNV()   // rnd rto: n = below(70), total = pick(6, 0, 1e5)
  for _ in 0..<5000 { let n = r.below(70); let t = pick(&r, 6, 0, 1e5)
    let v = RiskTiming.arrivalOffsets(sampleCount: n, totalTravelSeconds: t); g.i(v.count); for x in v { g.d(x) } }
  emit("rnd", "rto", "52544f", "5000", g.hex) }

// ============================================================ traps (each run in a child process)
emit("trap", "bandIndex", hx(.nan), "-", "-", probe(["bandIndex", hx(.nan)]))
emit("trap", "bandIndex", hx(-Double.nan), "-", "-", probe(["bandIndex", hx(-Double.nan)]))
emit("trap", "bandIndex", hx(43), "-", "-", probe(["bandIndex", hx(43)]))
emit("trap", "latitudeProfile", hx(.nan), "-", "-", probe(["latitudeProfile", hx(.nan), "-"]))
emit("trap", "latitudeProfile", hx(.nan), hx(1609), "-", probe(["latitudeProfile", hx(.nan), hx(1609)]))
emit("trap", "latitudeProfile", hx(43), hx(1609), "-", probe(["latitudeProfile", hx(43), hx(1609)]))
for (zi, fi) in [(2, 0), (0, 2), (-1, 0), (0, -1), (Int.max, 0), (Int.max / 2, 1), (1, 1)] {
  emit("trap", "harmonicScore", String(zi), String(fi), "0", probe(["harmonicScore", String(zi), String(fi), "0"])) }
// arrivalOffsets(sampleCount:) with an absurd count does NOT trap: Swift starts
// allocating the array and the process grows until the system runs out of
// memory (observed with Int.max and Int.max / 4; each run held the machine).
// The Rust port refuses such counts with a documented value instead, so the
// probe is not run; the finding is recorded here.
emit("trap", "arrivalOffsets", "3", hx(3600), "-", probe(["arrivalOffsets", "3", hx(3600)]))

// ============================================================ ClimateProfiles.cell
// The cell function is private; it is observed through loadPrecise and profile: a
// marker profile is loaded at one point and a probe "hits" when profile() returns it.
// The map is emptied by a trim around a far home with maxCells 0 — nothing below lies
// within 25 cells of (89.9, 179.9) on both axes. Its own generator, so nothing above moves.
var crng = SM(s: 0x43454C4C)   // "CELL"
let farHome = CLLocationCoordinate2D(latitude: 89.9, longitude: 179.9)
func clearPrecise() { ClimateProfiles.loadPrecise([], home: farHome, maxCells: 0) }
func marker(_ k: Int) -> LatitudeBands.Profile {
  LatitudeBands.Profile(band: k, comfortLowF: Double(k), comfortHighF: 1, recordLowF: 0, recordHighF: 2) }
func hits(_ lat: Double, _ lon: Double, _ k: Int) -> Bool {
  let p = ClimateProfiles.profile(latitude: lat, longitude: lon)
  return p.band == k && p.comfortLowF == Double(k) && p.recordHighF == 2
}
// cpc: are two coordinates in one cell?  lat0 lon0 lat1 lon1 → 0/1
var cpc: [(Double, Double, Double, Double)] = []
let anchors: [(Double, Double)] = [(40.0, -83.0), (-0.05, -0.05), (0.0, 0.0), (-0.0, -0.0), (0.05, 0.05), (0.1, -0.1), (43.0, -89.4),
  (71.29, -156.79), (-33.9, 151.2), (89.95, -179.95), (-89.95, 176.0), (25.7617, -80.1918), (47.6062, -122.3321), (40.0, 6000.0)]
let offsets: [(Double, Double)] = [(0, 0), (0.04, 0), (0, 0.04), (0.1, 0), (0, 0.1), (-0.1, 0), (0, -0.1), (0.05, 0.05), (-0.05, -0.05),
  (0.099, 0.099), (-0.001, 0), (0, -0.001), (0.1, -10000)]   // the last: (40.0, 6000) and (40.1, -4000) share a key
for (la, lo) in anchors { for (dla, dlo) in offsets { cpc.append((la, lo, la + dla, lo + dlo)) } }
for b in [-83.0, -83.1, -82.9, 0.0, 40.0, 40.1, 39.9, -0.1, 0.1] { for v in [b.nextDown, b, b.nextUp] {
  cpc.append((40.0, -83.0, v, -83.0)); cpc.append((40.0, -83.0, 40.0, v)); cpc.append((v, v, b, b)) } }
for _ in 0..<300 {
  let la = 20 + crng.unit() * 55, lo = -170 + crng.unit() * 120
  let k = crng.below(3), u1 = crng.unit(), u2 = crng.unit()
  let (dla, dlo) = k == 0 ? ((u1 - 0.5) * 0.3, (u2 - 0.5) * 0.3) : k == 1 ? ((u1 - 0.5) * 0.02, 0.0) : (0.0, (u2 - 0.5) * 0.02)
  cpc.append((la, lo, la + dla, lo + dlo))
}
var mk = 1
for c in cpc {
  clearPrecise(); ClimateProfiles.loadPrecise([(c.0, c.1, marker(mk))], home: nil)
  emit("cpc", hx(c.0), hx(c.1), hx(c.2), hx(c.3), bit(hits(c.2, c.3, mk))); mk += 1
}
// cpt: after a trim around home, does an earlier cell survive?  homeLat homeLon lat lon → 0/1
// (the entries loaded with the trim always survive: that re-add is the store's own step, not recorded)
let homes: [(Double, Double)] = [(43.07, -89.4), (0.0, 0.0), (-0.05, -0.05), (71.29, -156.79), (40.0, 0.04), (-33.9, 151.2)]
func axis(_ d: Double) -> Int { Int((d / 0.1).rounded(.down)) }   // input selection only: one point per cell
for (h, home) in homes.enumerated() {
  clearPrecise()
  var pts: [(Double, Double)] = []
  var seen = Set<[Int]>()
  func add(_ la: Double, _ lo: Double) { let key = [axis(la), axis(lo)]; if !seen.contains(key) { seen.insert(key); pts.append((la, lo)) } }
  for dx in [-27, -26, -25, -24, -1, 0, 1, 24, 25, 26, 27] { for dy in [-26, -25, -24, 0, 24, 25, 26] {
    add(home.0 + Double(dy) * 0.1 + 0.03, home.1 + Double(dx) * 0.1 + 0.03) } }
  for _ in 0..<60 { let u1 = crng.unit(), u2 = crng.unit(); add(home.0 + (u1 - 0.5) * 8, home.1 + (u2 - 0.5) * 8) }
  var loaded: [(lat: Double, lon: Double, profile: LatitudeBands.Profile)] = []
  for (j, p) in pts.enumerated() { loaded.append((p.0, p.1, marker(100_000 * (h + 1) + j))) }
  ClimateProfiles.loadPrecise(loaded, home: nil)
  ClimateProfiles.loadPrecise([(home.0 + 5.03, home.1 + 5.03, marker(7))],
                              home: CLLocationCoordinate2D(latitude: home.0, longitude: home.1), maxCells: 0)
  for (j, p) in pts.enumerated() { emit("cpt", hx(home.0), hx(home.1), hx(p.0), hx(p.1), bit(hits(p.0, p.1, 100_000 * (h + 1) + j))) }
}
for (la, lo) in [(Double.nan, 0.0), (0.0, Double.infinity), (1e300, 0.0), (40.0, -83.0)] {
  emit("trap", "preciseCell", hx(la), hx(lo), "-", probe(["preciseCell", hx(la), hx(lo)])) }

FileHandle.standardOutput.write(out.data(using: .utf8)!)
