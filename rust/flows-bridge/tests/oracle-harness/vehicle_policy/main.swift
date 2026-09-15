import Foundation
// Frozen oracle: every output below comes from the ORIGINAL Swift vehicle-policy
// code, before it is replaced by calls into Rust. Doubles are IEEE-754 bit
// patterns in hex; strings are "s:" + UTF-8 hex; nil is "-"; lists are
// "L<n>:" + comma-joined items; a grade segment is "start/end/grade".
func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func hs(_ s: String) -> String { "s:" + s.utf8.map { String(format: "%02x", $0) }.joined() }
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
func opt(_ d: Double?) -> String { d.map(hx) ?? "-" }
func bit(_ b: Bool) -> String { b ? "1" : "0" }
func seg(_ s: GradeSegment) -> String { hx(s.startMile) + "/" + hx(s.endMile) + "/" + hx(s.gradePercent) }
var out = ""
func emit(_ f: String...) { out += f.joined(separator: "\t") + "\n" }

struct SM { var s: UInt64
  mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
  mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) } }
var rng = SM(s: 0x56454849434C45)   // "VEHICLE"

let payloadNaN = Double(nan: 0x2BAD, signaling: false)
let S: [Double] = [.nan, -Double.nan, payloadNaN, .infinity, -.infinity, 0.0, -0.0, .leastNonzeroMagnitude,
  -.leastNonzeroMagnitude, .leastNormalMagnitude, 1e-9, 0.5, 1, -1, 2, 5, 10, 20, 55, 85, 100, 1e300, -1e300,
  .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
func around(_ t: Double) -> [Double] { [t.nextDown, t, t.nextUp] }
func pick(_ a: [Double]) -> Double { a[rng.below(a.count)] }
func mixed(_ lo: Double, _ hi: Double) -> Double { rng.below(4) == 0 ? pick(S) : lo + rng.unit() * (hi - lo) }
func maybe(_ lo: Double, _ hi: Double) -> Double? { rng.below(3) == 0 ? nil : mixed(lo, hi) }

// MARK: constants and tables
emit("const", "stateToleranceMph", hx(SpeedLaw.stateToleranceMph))
emit("const", "excessOverLimitMph", hx(SpeedLaw.excessOverLimitMph))
emit("const", "excessAbsoluteMph", hx(SpeedLaw.excessAbsoluteMph))
emit("const", "speedSignTolerance", hx(SpeedSign.tolerance))
emit("const", "speedSignOverBy", hx(SpeedSign.overBy))
emit("const", "pursuitDefaultSpeedMph", hx(PursuitReach.defaultSpeedMph))
emit("const", "pursuitMinimumRadiusMeters", hx(PursuitReach.minimumRadiusMeters))
emit("const", "pursuitMaximumElapsedSeconds", hx(PursuitReach.maximumElapsedSeconds))
emit("const", "towingEconomyFactor", hx(TowingLimits.towingEconomyFactor))
emit("const", "filterDefaultVehicleHeightMeters", hx(FilterLimits().vehicleHeightMeters))
emit("const", "filterDefaultMaxGradePercent", hx(FilterLimits().maxGradePercent))
emit("const", "filterDefaultClearanceMarginMeters", hx(FilterLimits().clearanceMarginMeters))
emit("const", "filterDefaultRigWeightIsNil", bit(FilterLimits().rigWeightLbs == nil))
emit("const", "driveIdleSpeedMph", hx(DriveEfficiency.idleSpeedMph))
emit("const", "driveInputsDefaultCruiseMph", hx(DriveEfficiency.Inputs(speedMph: 0, accelMphPerSec: 0).efficientCruiseMph))
emit("table", "compassPoints", lst(CompassReading.points.map(hs)))

// The Unicode properties the original's String handling consults, read from
// this Swift runtime, as inclusive scalar ranges.
func ranges(_ pred: (Unicode.Scalar) -> Bool) -> [String] {
  var outR: [String] = []; var start: UInt32? = nil; var last: UInt32 = 0
  for v in UInt32(0)...0x10FFFF {
    guard let sc = Unicode.Scalar(v) else { continue }
    if pred(sc) {
      if start == nil || v != last &+ 1 { if let st = start { outR.append(String(st, radix: 16) + "-" + String(last, radix: 16)) }; start = v }
      last = v
    }
  }
  if let st = start { outR.append(String(st, radix: 16) + "-" + String(last, radix: 16)) }
  return outR
}
let tabNumber = ranges { Character($0).isNumber }
let tabAttach5 = ranges { ("5" + String($0)).count == 1 }
emit("utab", "isNumber", lst(tabNumber))
emit("utab", "attachesAfter5", lst(tabAttach5))
emit("utab", "attachesAfterDot", lst(ranges { ("." + String($0)).count == 1 }))
emit("utab", "attachesAfterH", lst(ranges { ("h" + String($0)).count == 1 }))
emit("utab", "attachesAfterS", lst(ranges { ("s" + String($0)).count == 1 }))
let tabPrependM = ranges { (String($0) + "m").count == 1 }
emit("utab", "prependsToM", lst(tabPrependM))
emit("utab", "prependsToK", lst(ranges { (String($0) + "k").count == 1 }))
emit("utab", "whitespaces", lst(ranges { CharacterSet.whitespaces.contains($0) }))

// MARK: SpeedLaw
var speeds: [Double] = S
for t in [30.0, 42, 52, 62] { speeds += around(t) }
for _ in 0..<120 { speeds.append(mixed(-10, 130)) }
for x in speeds { emit("el", hx(x), hx(SpeedLaw.estimatedLimitMph(speedMph: x))) }

var posted: [Double?] = [nil] + S.map { Optional($0) }
for t in [65.0, 80, 55, 25, 75, 0.0] { posted += around(t).map { Optional($0) } }
for _ in 0..<60 { posted.append(maybe(-20, 140)) }
for p in posted {
  emit("st", opt(p), opt(SpeedLaw.stateThresholdMph(postedLimitMph: p)))
  emit("ft", opt(p), opt(SpeedLaw.federalThresholdMph(postedLimitMph: p)))
  var sp: [Double] = [0, -0.0, .nan, .infinity, 55, 100]
  if let st = SpeedLaw.stateThresholdMph(postedLimitMph: p) { sp += around(st) }
  if let fe = SpeedLaw.federalThresholdMph(postedLimitMph: p) { sp += around(fe) }
  for _ in 0..<3 { sp.append(mixed(0, 120)) }
  for x in sp {
    let code: String
    switch SpeedLaw.standing(speedMph: x, postedLimitMph: p) {
    case .legal: code = "0"
    case .stateViolation: code = "1"
    case .federalViolation: code = "2"
    }
    emit("sd", hx(x), opt(p), code)
  }
  for x in [12.0, 29.999999999999996, 68, .nan, mixed(0, 120)] {
    emit("efl", opt(p), hx(x), hx(SpeedLaw.effectiveLimitMph(postedLimitMph: p, speedMph: x)))
  }
}

// MARK: CompassReading (the table NWSForecastService indexes)
var words: [String] = CompassReading.points + CompassReading.points.map { $0.lowercased() }
words += ["", " N", "N ", "NNNE", "NORTH", "n", "N\u{301}", "\u{212A}", "NN", "SSW\u{0}", "WNW\u{FE0F}", "\u{FF2E}", "E\u{200B}"]
for w in words { emit("cp", hs(w), CompassReading.points.firstIndex(of: w).map { String($0) } ?? "-") }

// MARK: SpeedSign
var raws: [String] = [
  "55 mph", "25mph", "70 MPH", "80", "50", "none", "signals", "variable", "", "fast", "0", "walk",
  "NONE", "None ", " none", "\tnone\t", "Walk", "WALK", "WAL\u{212A}", "wal\u{212A}", "\u{212A}nots", "5 \u{212A}NOTS",
  "5 knots", "10 knots", "10knots", "10 KNOTS", "10 kn", "10 knot", "10 kt", "30 km/h", "30 kmh", "30kph",
  "5.", ".5", ".", "5..", "5.5.", "5.5", "0055", "00", "0.0", "0.", ".0", "-5", "+5", "5e3", "5E3", "0x10", "inf",
  "nan", "infinity", "1.2.3 mph", "50;30", "50 mph;30 mph", "50;30 mph", "mph 50", "50 mphx", "50 mp h", "50 m ph",
  "50 Mph", "50 mPH", "RU:urban", "DE:zone30", "zone:30", "30 zone", "national", "50 mph (signs)", "  55  ",
  "55\u{0}mph", "55 \u{0}mph", "\u{0}55", "55\nmph", "55\r\nmph", "\n55", "55\n", "55\u{85}", "\u{85}55", "\u{FEFF}55",
  "55\u{FEFF}", "\u{200B}55\u{200B}", "\u{200C}55", "55\u{200D}", "\u{3000}55\u{3000}", "\u{A0}55 mph\u{A0}",
  "\u{1680}55", "\u{2000}55\u{200A}", "\u{202F}55\u{205F}", "\u{2028}55", "\u{2029}55", "\u{B}55", "\u{C}55", "\u{D}55",
  "55\u{301} mph", "55.\u{301}mph", "5..\u{301}mph", "5.5.\u{301}", ".\u{301}5", "\u{301}55", " \u{301}55",
  "55 mph\u{301}", "55 mp\u{301}h", "55 knots\u{301}", "55 knot\u{301}s", "55 \u{600}mph", "55\u{600}mph",
  "55 \u{600}knots", "\u{600}55", "55\u{BD}", "55\u{BD} mph", "\u{BD}", "5\u{BD}", "55\u{663}", "\u{663}\u{663}",
  "5\u{4E94}", "\u{4E94}\u{5341}", "\u{FF15}\u{FF15}", "\u{FF15}\u{FF15} mph", "55\u{FF15}", "\u{B2}", "5\u{B2}",
  "\u{216B}", "5\u{216B}", "5\u{217B} mph", "\u{2464}", "5\u{2464}", "5\u{FE0F}\u{20E3}", "5\u{20E3} mph", "5\u{200D}",
  "5\u{1F3FB}", "5\u{E0100}", "5\u{903}", "5.\u{903}mph", "5\u{E33}", "\u{130}55", "55\u{130}", "55 MPH \u{130}",
  "\u{391}\u{3A3} 55", "55 \u{391}\u{3A3}", "55 \u{1C4}", "\u{1E9E}55", "55 mph \u{DF}",
  "1" + String(repeating: "0", count: 400), "0." + String(repeating: "0", count: 400) + "1",
  String(repeating: "9", count: 309), String(repeating: "9", count: 310) + " mph",
  "0." + String(repeating: "0", count: 322) + "5", "0." + String(repeating: "0", count: 323) + "25",
  "17976931348623157" + String(repeating: "0", count: 292), "17976931348623159" + String(repeating: "0", count: 292),
  "5 MPH knots", "5 knots mph", "5 mphknots", "mph", "knots", "5mph5", "5 m.p.h.", "5 mi/h", "35 mph;", "35mph ",
  "3 5 mph", "3.5.mph", "3.5 .mph", "35..mph", "\u{1F1FA}\u{1F1F8}55", "55\u{1F1FA}\u{1F1F8}mph", "e\u{301}55",
  "0.1", "0.30000000000000004", "123456789012345678901234567890", "4.9406564584124654e-324", "88 \u{2003}mph",
]
for w in [" ", "\t", "\u{A0}", "\u{1680}", "\u{2000}", "\u{2005}", "\u{200A}", "\u{200B}", "\u{202F}", "\u{205F}", "\u{3000}",
          "\n", "\r", "\u{85}", "\u{FEFF}", "\u{200C}", "\u{180E}", "\u{2060}"] {
  raws += [w + "55 mph", "55 mph" + w, w + "walk" + w, w + "80" + w, w + w + "none" + w]
}
let pieces = ["5", "55", ".", "0", "9", " ", "mph", "MPH", "knots", "km/h", "none", "walk", "\u{301}", "\u{600}", "\u{BD}",
  "\u{663}", "\t", "\u{A0}", "\u{3000}", ";", "-", "e", "x", "\u{130}", "\u{212A}", "\u{0}", "\n", "\u{FE0F}", "\u{200D}", "k",
  "h", "m", "p", "s", "n", "o", "t"]
for _ in 0..<600 { var r = ""; for _ in 0..<(1 + rng.below(6)) { r += pieces[rng.below(pieces.count)] }; raws.append(r) }
// Every property range edge, placed where each property decides the parse.
func scalarsAt(_ tab: [String]) -> [Unicode.Scalar] {
  var v: [Unicode.Scalar] = []
  for r in tab {
    let parts = r.split(separator: "-").map { UInt32($0, radix: 16)! }
    for x in [parts[0], parts[1] &+ 1] { if let sc = Unicode.Scalar(x) { v.append(sc) } }
  }
  return v
}
for sc in scalarsAt(tabNumber) + scalarsAt(tabAttach5) {
  let c = String(sc)
  raws += ["5" + c + ".5mph", "5.." + c + "mph"]
}
for sc in scalarsAt(tabAttach5) { raws.append("5 mph" + String(sc)) }
for sc in scalarsAt(tabPrependM) { raws += ["5 " + String(sc) + "mph", "5 " + String(sc) + "knots"] }
for r in raws { emit("pm", hs(r), opt(SpeedSign.parseMaxspeed(r))) }

var limits: [Double?] = [nil, 0, -0.0, -5, .nan, .infinity, -.infinity, .leastNonzeroMagnitude, 25, 55, 65.5, 1e300]
for _ in 0..<30 { limits.append(maybe(-10, 90)) }
for l in limits {
  var sp: [Double] = [0, .nan, .infinity, -.infinity, 95]
  if let l { sp += around(l + 5) + around(l + 10) + [l] }
  for _ in 0..<4 { sp.append(mixed(0, 120)) }
  for x in sp {
    let code: String
    switch SpeedSign.judge(speedMph: x, limitMph: l) { case .under: code = "0"; case .slightlyOver: code = "1"; case .over: code = "2" }
    emit("jg", hx(x), opt(l), code)
  }
}

// MARK: PursuitReach
var elapsed: [Double] = S + around(0) + around(10800) + around(3600) + [1500, 36000]
var reachSpeeds: [Double] = [.nan, .infinity, -.infinity, 0, -0.0, -10] + around(5) + [45, 55, 17.89, 120]
for e in elapsed { for sp in reachSpeeds { emit("pr", hx(e), hx(sp), hx(PursuitReach.radiusMeters(elapsedSeconds: e, speedMph: sp))) } }
for sp in [5.0, 45, 55, 17.89, 3] { for e in around(800 / (max(sp, 5) * 0.44704)) {
  emit("pr", hx(e), hx(sp), hx(PursuitReach.radiusMeters(elapsedSeconds: e, speedMph: sp))) } }
for _ in 0..<300 { let e = mixed(-600, 20000), sp = mixed(-5, 130)
  emit("pr", hx(e), hx(sp), hx(PursuitReach.radiusMeters(elapsedSeconds: e, speedMph: sp))) }

// MARK: TowingLimits
var heights: [Double] = S
for t in [5.0, 6, 7, 10] { heights += around(t) }
for _ in 0..<40 { heights.append(mixed(3, 14)) }
for h in heights { for f in FuelType.allCases {
  let r = TowingLimits.estimatedRatings(heightFeet: h, fuelType: f)
  emit("er", hx(h), hs(f.rawValue), opt(r.gvwrLbs), opt(r.towCapacityLbs), opt(r.gcwrLbs), bit(r.estimated)) } }

let rv: [Double?] = [nil, .nan, .infinity, -.infinity, -0.0, 7050, .greatestFiniteMagnitude, -5]
for g in rv { for t in rv { for c in rv {
  emit("eg", opt(g), opt(t), opt(c), opt(TowingLimits.Ratings(gvwrLbs: g, towCapacityLbs: t, gcwrLbs: c).effectiveGCWR)) } } }
func vioList(_ v: [TowingLimits.Violation]) -> String {
  lst(v.map { x -> String in
    switch x { case .overGVWR(let by): return "G:" + hx(by); case .overTowCapacity(let by): return "T:" + hx(by)
    case .overGCWR(let by): return "C:" + hx(by) } })
}
func towCase(_ v: Double, _ t: Double, _ r: TowingLimits.Ratings) {
  emit("tc", hx(v), hx(t), opt(r.gvwrLbs), opt(r.towCapacityLbs), opt(r.gcwrLbs),
       vioList(TowingLimits.check(vehicleWeightLbs: v, towedWeightLbs: t, ratings: r)))
}
let f150 = TowingLimits.Ratings(gvwrLbs: 7050, towCapacityLbs: 11200, gcwrLbs: 17100)
towCase(6500, 8000, f150); towCase(7500, 1000, f150); towCase(7000, 12000, f150)
towCase(99999, 99999, TowingLimits.Ratings(gvwrLbs: nil, towCapacityLbs: nil, gcwrLbs: nil))
for _ in 0..<500 {
  let r = TowingLimits.Ratings(gvwrLbs: rng.below(3) == 0 ? rv[rng.below(rv.count)] : mixed(3000, 30000),
                               towCapacityLbs: rng.below(3) == 0 ? rv[rng.below(rv.count)] : mixed(0, 20000),
                               gcwrLbs: rng.below(3) == 0 ? rv[rng.below(rv.count)] : mixed(5000, 50000))
  var v = mixed(0, 40000), t = mixed(0, 40000)
  switch rng.below(4) {
  case 0: if let g = r.gvwrLbs { v = pick(around(g)) }
  case 1: if let c = r.towCapacityLbs { t = pick(around(c)) }
  case 2: if let c = r.effectiveGCWR, c.isFinite { v = (c / 2).rounded(); t = pick(around(c - v)) }
  default: break
  }
  towCase(v, t, r)
}

// MARK: FilterLimits
var degs: [Double] = S + [14, 6, 45, 90, -90, 180, 360, 30, 60, 89.999, 15, 2, 0.5]
for _ in 0..<120 { degs.append(mixed(-400, 400)) }
for d in degs { emit("dp", hx(d), hx(FilterLimits.degreesToPercent(d))) }

let hm: [Double] = [4.115, 3.048, 0, .nan, .infinity, -.infinity, -0.0, 4.1148]
let margins: [Double] = [0.6096, 0, .nan, -0.6096, .infinity]
for _ in 0..<260 {
  let h = rng.below(2) == 0 ? pick(hm) : mixed(1, 6), m = rng.below(2) == 0 ? pick(margins) : mixed(0, 1)
  let lim = FilterLimits(vehicleHeightMeters: h, clearanceMarginMeters: m)
  let edge = h + m + 1e-9
  var cl: [Double]? = nil
  switch rng.below(5) {
  case 0: cl = nil
  case 1: cl = []
  case 2: cl = [pick(around(edge))]
  default: cl = (0..<(1 + rng.below(5))).map { _ in rng.below(3) == 0 ? pick(around(edge)) : mixed(0, 8) }
  }
  emit("pc", hx(h), hx(m), cl.map { lst($0.map(hx)) } ?? "-", bit(lim.passesClearances(cl)))
}
let tenFoot = FilterLimits(vehicleHeightMeters: 10 * 0.3048)
for c in [12 * 0.3048, (11 + 11.0 / 12) * 0.3048, (12 + 1.0 / 12) * 0.3048, 13.5 * 0.3048] {
  emit("pc", hx(tenFoot.vehicleHeightMeters), hx(tenFoot.clearanceMarginMeters), lst([hx(c)]), bit(tenFoot.passesClearances([c])))
}
for _ in 0..<260 {
  let g = rng.below(3) == 0 ? pick(S + around(6)) : mixed(0, 30)
  let r: Double? = rng.below(4) == 0 ? nil : (rng.below(2) == 0 ? pick(around(g) + [0, -0.0, .nan]) : mixed(0, 30))
  emit("pg", hx(g), opt(r), bit(FilterLimits(maxGradePercent: g).passesGrade(r)))
}
let rigs: [Double?] = [nil, 0, -0.0, .nan, .infinity, -.infinity, .leastNonzeroMagnitude, 15000, -15000]
for _ in 0..<260 {
  let rig: Double? = rng.below(2) == 0 ? rigs[rng.below(rigs.count)] : mixed(1000, 60000)
  let edge = (rig ?? 15000) - 1e-9
  var wl: [Double]? = nil
  switch rng.below(5) {
  case 0: wl = nil
  case 1: wl = []
  default: wl = (0..<(1 + rng.below(4))).map { _ in rng.below(2) == 0 ? pick(around(edge) + [rig ?? 0]) : mixed(0, 80000) }
  }
  emit("pw", opt(rig), wl.map { lst($0.map(hx)) } ?? "-", bit(FilterLimits(rigWeightLbs: rig).passesWeightLimits(wl)))
}
for w in [[20000.0], [15000], [14999], [40000, 12000], []] {
  emit("pw", opt(15000), lst(w.map(hx)), bit(FilterLimits(rigWeightLbs: 15000).passesWeightLimits(w)))
}

func vd(_ p: Double?, _ g: Double?, _ c: Double?, _ h: Double, _ tw: Bool, _ tr: Double) {
  emit("vd", opt(p), opt(g), opt(c), hx(h), bit(tw), hx(tr),
       hx(FilterLimits.vehicleDefaultMaxGradeDegrees(publishedMaxGradePercent: p, gvwrLbs: g, towCapacityLbs: c,
                                                     heightFeet: h, towing: tw, trailerWeightLbs: tr)))
}
let pubs: [Double?] = [nil, .nan, .infinity, -.infinity, 0, -0.0, 1, 6, 10, 18, 3.492076949174773, 26.794919243112269, 100]
var gvwrs: [Double?] = [nil, .nan, 0, .infinity, -.infinity]
for t in [6000.0, 10000, 14000, 26000] { gvwrs += around(t).map { Optional($0) } }
let caps: [Double?] = [nil, .nan, 0, -0.0, .leastNonzeroMagnitude, 11200, 5000, .infinity, -1]
var hts: [Double] = [.nan, .infinity, -.infinity, 4.8, 13.5]
for t in [5.5, 7.0, 9.5] { hts += around(t) }
for p in pubs { vd(p, 7050, 11200, 6.4, false, 0) }
for g in gvwrs { vd(nil, g, 11200, 6.4, false, 0); vd(nil, g, nil, 6.4, true, 0) }
for h in hts { vd(nil, nil, nil, h, false, 0); vd(nil, nil, nil, h, false, 6000) }
for c in caps {
  var trs: [Double] = [0, -0.0, .leastNonzeroMagnitude, .nan, .infinity, 2000, 8000, 11200] + around(5000)
  if let c { trs += around(c * 0.6) + around(c) }
  for tr in trs { vd(nil, 7050, c, 6.4, false, tr); vd(nil, 7050, c, 6.4, true, tr) }
}
for _ in 0..<500 {
  vd(rng.below(3) == 0 ? pubs[rng.below(pubs.count)] : maybe(0, 40), rng.below(3) == 0 ? gvwrs[rng.below(gvwrs.count)] : maybe(2000, 40000),
     rng.below(3) == 0 ? caps[rng.below(caps.count)] : maybe(0, 25000), mixed(3, 15), rng.below(2) == 0,
     rng.below(3) == 0 ? 0 : mixed(0, 30000))
}

// MARK: GradeProfile
func gsCase(_ e: [Double?], _ spacing: Double, _ start: Double?) {
  let segs = start.map { GradeProfile.segments(elevations: e, spacingMeters: spacing, startMile: $0) }
    ?? GradeProfile.segments(elevations: e, spacingMeters: spacing)
  emit("gs", lst(e.map(opt)), hx(spacing), opt(start), lst(segs.map(seg)))
}
gsCase([100, 100, 100, 124, 124], 300, nil); gsCase([100, nil, 200], 300, nil); gsCase([], 300, nil); gsCase([5], 300, nil)
for sp in [0.0, -0.0, .nan, .infinity, .leastNonzeroMagnitude, -300, 1250, 10000] { gsCase([100, 120, nil, 90, 91], sp, nil); gsCase([1, 2], sp, 3.5) }
let elevPool: [Double?] = [nil, .nan, .infinity, -.infinity, 0, -0.0, 1e308, -1e308]
for _ in 0..<150 {
  let n = rng.below(14)
  let e: [Double?] = (0..<n).map { _ in rng.below(5) == 0 ? elevPool[rng.below(elevPool.count)] : Optional(rng.unit() * 3000 - 100) }
  let sp = rng.below(4) == 0 ? pick(S) : [300.0, 1250, 10000, 156.25][rng.below(4)]
  gsCase(e, sp, rng.below(3) == 0 ? nil : Optional(rng.below(3) == 0 ? pick(S) : rng.unit() * 900))
}

// Sorting with |grade| over a palette so ties and NaN are frequent; start mile = input index.
let GP: [Double] = [0, -0.0, 2, -2, 5.999999999999999, 6, -6, 6.000000000000001, 7.5, -8, 9, .nan, .infinity, -.infinity,
  12, 100, -Double.nan, payloadNaN]
func paletteSegs(_ codes: [Int]) -> [GradeSegment] {
  codes.enumerated().map { GradeSegment(startMile: Double($0.offset), endMile: Double($0.offset) + 1, gradePercent: GP[$0.element]) }
}
func gtpCase(_ codes: [Int], _ top: Int) {
  let res = GradeProfile.steepest(paletteSegs(codes), top: top)
  emit("gtp", lst(codes.map { String($0) }), String(top), lst(res.map { String(Int($0.startMile)) }))
}
for n in 0...70 { for _ in 0..<2 {
  let codes = (0..<n).map { _ in rng.below(GP.count) }
  gtpCase(codes, n); if n > 0 { gtpCase(codes, rng.below(n + 2)) } } }
for n in [96, 127, 128, 129, 200, 255, 256, 257, 300, 513, 1000] { for k in 0..<3 {
  let limit = k == 0 ? 3 : (k == 1 ? 6 : GP.count)   // k 0: no NaN, k 1: small palette with signed zero, k 2: all
  let codes = (0..<n).map { _ in rng.below(limit) }
  gtpCase(codes, n) } }
gtpCase(Array(repeating: 11, count: 90), 90); gtpCase((0..<90).map { $0 % 2 == 0 ? 11 : 8 }, 90)
gtpCase((0..<150).map { _ in 8 }, 5); gtpCase((0..<150).map { ($0 / 7) % GP.count }, 150)
for _ in 0..<40 {
  let n = rng.below(7)
  let segsR = (0..<n).map { _ in GradeSegment(startMile: mixed(0, 50), endMile: mixed(0, 50), gradePercent: mixed(-15, 15)) }
  let top = rng.below(n + 3)
  emit("gt", lst(segsR.map(seg)), String(top), lst(GradeProfile.steepest(segsR, top: top).map(seg)))
}

let MP: [Double] = [0, -0.0, 1, 2, 2.5, 3, 5, 8, 10, 11, 13, .nan, .infinity, -.infinity, 0.1, 1e-300, 7.999999999999999, 8.000000000000002]
emit("palette", "GP", lst(GP.map(hx)))
emit("palette", "MP", lst(MP.map(hx)))
func code3(_ s: GradeSegment) -> String {
  func idx(_ a: [Double], _ v: Double) -> String { a.firstIndex { $0.bitPattern == v.bitPattern }.map { String($0) } ?? "?" }
  return idx(MP, s.startMile) + "." + idx(MP, s.endMile) + "." + idx(GP, s.gradePercent)
}
let thrs: [Double] = [6, 0, -0.0, .nan, .infinity, 5.999999999999999, 7.5, 9, -1]
let looks: [Double] = [8, 0, .nan, .infinity, -1, 2.5, 5]
for k in 0..<700 {
  let n = rng.below(9)
  let segsP = (0..<n).map { _ in GradeSegment(startMile: MP[rng.below(MP.count)], endMile: MP[rng.below(MP.count)], gradePercent: GP[rng.below(GP.count)]) }
  let mile = MP[rng.below(MP.count)]
  if k % 5 == 0 {
    emit("gnd", hx(mile), lst(segsP.map(code3)), GradeProfile.nextSteep(after: mile, in: segsP).map(code3) ?? "-")
  } else {
    let t = thrs[rng.below(thrs.count)], l = looks[rng.below(looks.count)]
    emit("gn", hx(mile), hx(t), hx(l), lst(segsP.map(code3)),
         GradeProfile.nextSteep(after: mile, in: segsP, thresholdPercent: t, lookaheadMiles: l).map(code3) ?? "-")
  }
}

// MARK: DriveEfficiency
var dsp: [Double] = S + around(55) + around(0) + [95, 65, 75]
for _ in 0..<60 { dsp.append(mixed(0, 120)) }
for x in dsp {
  for c in [55.0, 0, -0.0, .nan, .infinity, 60, mixed(20, 80)] { emit("dd", hx(x), hx(c), hx(DriveEfficiency.dragPenalty(speedMph: x, efficientCruiseMph: c))) }
  emit("ddd", hx(x), hx(DriveEfficiency.dragPenalty(speedMph: x)))
}
var gr: [Double] = S + around(0) + around(-4.8) + around(1.5) + around(4.5) + [-50, -4, 6]
for _ in 0..<80 { gr.append(mixed(-30, 30)) }
for g in gr { emit("dg", hx(g), hx(DriveEfficiency.gradePenalty(gradePercent: g))) }
var ac: [Double] = S + around(0) + around(-2.4) + around(0.1) + [-2, 4, 1.5]
for _ in 0..<80 { ac.append(mixed(-10, 10)) }
for a in ac { emit("dth", hx(a), hx(DriveEfficiency.throttlePenalty(accelMphPerSec: a))) }
let winds: [Double] = [.nan, .infinity, 0, -0.0, .leastNonzeroMagnitude, -5, 20, 30]
let froms: [Double?] = [nil, .nan, 0, 90, 270, -0.0, 360, 1e300, .infinity]
let heads: [Double?] = [nil, .nan, -0.0, -.leastNonzeroMagnitude, 0, 90, -1, .infinity]
for _ in 0..<500 {
  let w = rng.below(2) == 0 ? pick(winds) : mixed(0, 60)
  let f: Double? = rng.below(2) == 0 ? froms[rng.below(froms.count)] : maybe(-30, 400)
  let h: Double? = rng.below(2) == 0 ? heads[rng.below(heads.count)] : maybe(-30, 400)
  emit("dh", hx(w), opt(f), opt(h), hx(DriveEfficiency.headwindMph(windMph: w, windFromDegrees: f, headingDegrees: h)))
}
let mpus: [Double?] = [nil, .nan, 0, -0.0, -3, .infinity, 26, 35, 15, 16, 1.9285714285714286, 0.75]
for _ in 0..<320 {
  let c: Double? = rng.below(2) == 0 ? mpus[rng.below(mpus.count)] : maybe(5, 60)
  var h: Double? = rng.below(2) == 0 ? mpus[rng.below(mpus.count)] : maybe(5, 60)
  if rng.below(4) == 0, let cc = c, cc.isFinite {
    h = pick(around(cc * [0.6, 1.35 / 0.7, 1.35 / 1.8][rng.below(3)]))
  }
  emit("ds", opt(c), opt(h), hx(DriveEfficiency.dragSensitivity(cityMPU: c, highwayMPU: h)))
}
for _ in 0..<60 {
  let c: Double? = rng.below(2) == 0 ? mpus[rng.below(mpus.count)] : maybe(5, 60)
  let h: Double? = rng.below(2) == 0 ? mpus[rng.below(mpus.count)] : maybe(5, 60)
  emit("ec", opt(c), opt(h), hx(DriveEfficiency.efficientCruiseMph(city: c, highway: h)))
}
func deCase(_ i: DriveEfficiency.Inputs) {
  let v: String
  switch DriveEfficiency.verdict(i) { case .efficient: v = "0"; case .fair: v = "1"; case .wasteful: v = "2" }
  emit("de", hx(i.speedMph), hx(i.accelMphPerSec), hx(i.gradePercent), hx(i.windMph), opt(i.windFromDegrees),
       opt(i.headingDegrees), hx(i.efficientCruiseMph), opt(i.cityMPU), opt(i.highwayMPU), opt(i.loadedWeightLbs),
       opt(i.vehicleWeightLbs), bit(i.towing), opt(i.fuelFraction),
       hx(DriveEfficiency.score(i)), v, hx(DriveEfficiency.loadFactor(i)), hx(DriveEfficiency.airspeedMph(i)))
}
for g in around(1.5) + around(4.5) { for tw in [false, true] {
  var i = DriveEfficiency.Inputs(speedMph: 55, accelMphPerSec: 0, gradePercent: g); i.towing = tw; deCase(i) } }
for sp in around(2) + [0, .nan] { for a in around(0.1) + [0, .nan] { deCase(DriveEfficiency.Inputs(speedMph: sp, accelMphPerSec: a)) } }
let loads: [Double?] = [nil, .nan, 0, -0.0, 5000, 9000, .infinity, 12500, -1]
let fuels: [Double?] = [nil, .nan, 0, -0.0, 1, 1.0000000000000002, -1, 0.05, .infinity]
for _ in 0..<420 {
  var i = DriveEfficiency.Inputs(speedMph: mixed(0, 110), accelMphPerSec: mixed(-8, 8))
  i.gradePercent = rng.below(3) == 0 ? 0 : mixed(-15, 15)
  i.windMph = rng.below(2) == 0 ? 0 : (rng.below(3) == 0 ? pick(winds) : mixed(0, 50))
  i.windFromDegrees = rng.below(2) == 0 ? froms[rng.below(froms.count)] : maybe(0, 360)
  i.headingDegrees = rng.below(2) == 0 ? heads[rng.below(heads.count)] : maybe(-1, 360)
  i.efficientCruiseMph = rng.below(4) == 0 ? mixed(20, 80) : 55
  i.cityMPU = rng.below(2) == 0 ? mpus[rng.below(mpus.count)] : maybe(5, 60)
  i.highwayMPU = rng.below(2) == 0 ? mpus[rng.below(mpus.count)] : maybe(5, 60)
  i.loadedWeightLbs = rng.below(2) == 0 ? loads[rng.below(loads.count)] : maybe(2000, 40000)
  i.vehicleWeightLbs = rng.below(2) == 0 ? loads[rng.below(loads.count)] : maybe(2000, 30000)
  i.towing = rng.below(3) == 0
  i.fuelFraction = rng.below(2) == 0 ? fuels[rng.below(fuels.count)] : maybe(0, 1)
  deCase(i)
}
for _ in 0..<60 {
  let sp = mixed(0, 110), a = mixed(-8, 8), g = mixed(-15, 15)
  let s1 = DriveEfficiency.score(speedMph: sp, accelMphPerSec: a, gradePercent: g)
  let v1: String
  switch DriveEfficiency.verdict(speedMph: sp, accelMphPerSec: a, gradePercent: g) { case .efficient: v1 = "0"; case .fair: v1 = "1"; case .wasteful: v1 = "2" }
  emit("dc", hx(sp), hx(a), hx(g), "-", hx(s1), v1)
  let c = mixed(20, 80)
  let s2 = DriveEfficiency.score(speedMph: sp, accelMphPerSec: a, gradePercent: g, efficientCruiseMph: c)
  let v2: String
  switch DriveEfficiency.verdict(speedMph: sp, accelMphPerSec: a, gradePercent: g, efficientCruiseMph: c) { case .efficient: v2 = "0"; case .fair: v2 = "1"; case .wasteful: v2 = "2" }
  emit("dc", hx(sp), hx(a), hx(g), hx(c), hx(s2), v2)
}

// MARK: GradeSegment.gradeDegrees (display). Its own generator, so nothing above moves.
var grng = SM(s: 0x4752414445)   // "GRADE"
var gpcts: [Double] = S + [6, -6, 7, 12, 25, 33.3, 45, 100, 1000, 1e6, 3, -3, .pi, (6.0).nextUp, (6.0).nextDown]
for d in [14.0, 6, 45, 89.999] { gpcts.append(FilterLimits.degreesToPercent(d)) }
for _ in 0..<150 { gpcts.append(grng.below(4) == 0 ? S[grng.below(S.count)] : -40 + grng.unit() * 80) }
for p in gpcts { emit("gd", hx(p), hx(GradeSegment(startMile: 0, endMile: 1, gradePercent: p).gradeDegrees)) }

FileHandle.standardOutput.write(out.data(using: .utf8)!)
