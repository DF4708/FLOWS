import Foundation
// Frozen oracle: every output below comes from the ORIGINAL Swift risk code,
// before it is replaced by calls into Rust. Doubles are IEEE-754 bit patterns
// in hex; strings are "s:" + UTF-8 hex; nil is "-"; lists are "L<n>:" + items.
func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func hs(_ s: String) -> String { "s:" + s.utf8.map { String(format: "%02x", $0) }.joined() }
func lst(_ a: [String]) -> String { "L\(a.count):" + a.joined(separator: ",") }
func opt(_ d: Double?) -> String { d.map(hx) ?? "-" }
var out = ""
func emit(_ f: String...) { out += f.joined(separator: "\t") + "\n" }

struct SM { var s: UInt64
  mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
  mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) } }
var rng = SM(s: 0x464C4F5753)   // "FLOWS"

let S: [Double] = [.nan, .infinity, -.infinity, 0.0, -0.0, .leastNonzeroMagnitude, 1e-9, 0.01, 0.1, 0.25,
  0.3979, 0.398, (0.398).nextUp, 0.5, (0.699).nextDown, 0.699, (0.699).nextUp, 0.8, (0.8).nextUp, 0.8751, (0.8751).nextUp,
  0.9, 0.95, (1.0).nextDown, 1.0, (1.0).nextUp, 1.5, 2, 3, 15, 25, 28, 45, 50, 75, 100, -1, -1e300, 1e300, .greatestFiniteMagnitude]
func val() -> Double { rng.below(3) == 0 ? S[rng.below(S.count)] : rng.unit() * 1.2 - 0.1 }
func big() -> Double { rng.below(4) == 0 ? S[rng.below(S.count)] : rng.unit() * 160 - 30 }

// constants and tables
emit("const", "riskGreenMin", hx(FlowsCore.riskGreenMin)); emit("const", "riskYellowMin", hx(FlowsCore.riskYellowMin))
emit("const", "secondaryCeiling", hx(RiskEquations.secondaryCeiling)); emit("const", "acuteNudge", hx(HazardRanking.acuteNudge))
emit("table", "primaryOrder", lst(RiskEquations.primaryOrder.map(hs)))
emit("table", "secondaryOrder", lst(RiskEquations.secondaryOrder.map(hs)))
emit("table", "acuteFamilies", lst(HazardRanking.acuteFamilies.sorted().map(hs)))
for (k, v) in RiskEquations.familyWeights.sorted(by: { $0.key < $1.key }) { emit("weight", hs(k), hx(v)) }

let bandCode: [RiskBand: String] = [.clear: "0", .green: "1", .yellow: "2", .red: "3"]
for x in S { emit("band", hx(x), bandCode[FlowsCore.riskBand(score: x)]!) }
for _ in 0..<260 { let x = val(); emit("band", hx(x), bandCode[FlowsCore.riskBand(score: x)]!) }

let T: [(Double, Double, Double)] = [(15, 28, 45), (25, 50, 75), (0, 0, 0), (1, 1, 1), (5, 3, 1), (.nan, 1, 2),
  (0.1, 0.2, .infinity), (-5, 0, 5), (28, 28, 45), (15, 45, 45)]
for v in S { for t in T { emit("pw", hx(v), hx(t.0), hx(t.1), hx(t.2), hx(RiskEquations.piecewiseScore(v, low: t.0, medium: t.1, high: t.2))) } }
for _ in 0..<400 { var t = [big(), big(), big()]; if rng.below(2) == 0 { t.sort() }; let v = big()
  emit("pw", hx(v), hx(t[0]), hx(t[1]), hx(t[2]), hx(RiskEquations.piecewiseScore(v, low: t[0], medium: t[1], high: t[2]))) }

let E: [(Double, Double, Double, Double)] = [(50, 80, 0, 110), (32, 75, -20, 105), (60, 60, 60, 60), (80, 50, 110, 0),
  (.nan, 80, 0, 110), (50, 80, -.infinity, .infinity)]
let temps = S + [-40, -20, 0, 20, 30, 35, 45, 50, 55, 65, 80, 85, 90, 95, 110, 130]
for e in E { for t in temps {
  emit("tr", hx(t), hx(e.0), hx(e.1), hx(e.2), hx(e.3), hx(RiskEquations.temperatureRisk(tempF: t, comfortLowF: e.0, comfortHighF: e.1, recordLowF: e.2, recordHighF: e.3)))
  emit("ta", hx(t), hx(e.0), hx(e.1), hx(e.2), hx(e.3), RiskEquations.temperatureAnomalous(tempF: t, comfortLowF: e.0, comfortHighF: e.1, recordLowF: e.2, recordHighF: e.3) ? "1" : "0") } }
for _ in 0..<150 { let e = [big(), big(), big(), big()]; let t = big()
  emit("tr", hx(t), hx(e[0]), hx(e[1]), hx(e[2]), hx(e[3]), hx(RiskEquations.temperatureRisk(tempF: t, comfortLowF: e[0], comfortHighF: e[1], recordLowF: e[2], recordHighF: e[3])))
  emit("ta", hx(t), hx(e[0]), hx(e[1]), hx(e[2]), hx(e[3]), RiskEquations.temperatureAnomalous(tempF: t, comfortLowF: e[0], comfortHighF: e[1], recordLowF: e[2], recordHighF: e[3]) ? "1" : "0") }

for x in S + (0..<100).map({ _ in big() }) { emit("wr", hx(x), hx(RiskEquations.windRisk(mph: x))); emit("pr", hx(x), hx(RiskEquations.popRisk(pct: x))) }
for _ in 0..<300 { let a = val(), b = val(), c = val(); emit("fc", hx(a), hx(b), hx(c), hx(RiskEquations.forecastComposite(temp: a, wind: b, pop: c))) }

let pool = RiskEquations.primaryOrder + RiskEquations.secondaryOrder + ["environmental", "unknownfam", "", "Fire", "flood "]
func randDict(_ maxK: Int) -> [String: Double] {
  var d: [String: Double] = [:]; let k = rng.below(maxK + 1)
  for _ in 0..<k { d[pool[rng.below(pool.count)]] = val() }
  let ks = d.keys.sorted()   // never iterate a Dictionary here: its order is seeded per process
  if rng.below(5) == 0, let first = ks.first { let v = d[first]!; for key in ks.prefix(2) { d[key] = v } }  // exact ties
  return d }
func dictFields(_ d: [String: Double]) -> (String, String) {
  let ks = d.keys.sorted(); return (lst(ks.map(hs)), lst(ks.map { hx(d[$0]!) })) }

for _ in 0..<400 { let n = rng.below(9); var arr: [(family: String, score: Double)] = []
  for _ in 0..<n { arr.append((pool[rng.below(pool.count)], val())) }
  emit("no", lst(arr.map { hs($0.family) }), lst(arr.map { hx($0.score) }), hx(RiskEquations.noisyOr(arr))) }

let pinned: [[String: Double]] = [["qpf_flood": 0.7, "precip": 0.9, "wind": 0.6], ["fire": 0.85, "wind": 0.95, "heat": 0.9],
  ["closure": 0.3, "heat": 0.2, "wind": 0.4, "qpf_flood": 0.7, "environmental": 0.9], ["seismic": 0.5, "fire": 0.5],
  Dictionary(uniqueKeysWithValues: RiskEquations.secondaryOrder.map { ($0, 1.0) }), [:]]
for d in pinned + (0..<800).map({ _ in randDict(14) }) { let (k, v) = dictFields(d); emit("rr", k, v, hx(RiskEquations.realizedRisk(d))) }

let floors: [Double] = [FlowsCore.riskGreenMin, 0.45, 0, .nan, -.infinity, .infinity, 1, -0.0]
for _ in 0..<400 { let d = randDict(10); let (k, v) = dictFields(d); let fl = rng.below(3) == 0 ? val() : floors[rng.below(floors.count)]
  emit("pf", k, v, hx(fl), RiskEquations.peakFamily(d, floor: fl).map(hs) ?? "-")
  emit("df", k, v, hx(fl), HazardRanking.dominantFamily(d, floor: fl).map(hs) ?? "-") }
for (a, b) in [(0.6, 0.6), (0.6, 0.65), (0.65, 0.6), (0.7, 0.7)] {   // acute-nudge ties
  for pair in [("fire", "convective"), ("convective", "winter"), ("air", "tsunami")] {
    let d = [pair.0: a, pair.1: b]; let (k, v) = dictFields(d)
    emit("df", k, v, hx(0.45), HazardRanking.dominantFamily(d, floor: 0.45).map(hs) ?? "-")
    emit("pf", k, v, hx(0.45), RiskEquations.peakFamily(d, floor: 0.45).map(hs) ?? "-") } }

for w in S { for p in S { emit("rd", hx(w), hx(p), hx(RouteRiskBand.displayed(weighted: w, peak: p))) } }

let optVals: [Double?] = [nil, .nan, .infinity, -.infinity, 0, -0.0, 0.5, 1, 2, 4, 40, 100, 100.5, 105, 300]
for _ in 0..<400 { let e = rng.below(4) == 0 ? optVals[rng.below(optVals.count)] : Optional(rng.unit() * 20 + 95)
  let lo = rng.below(4) == 0 ? optVals[rng.below(optVals.count)] : Optional(rng.unit() * 10 + 95)
  let q = rng.below(4) == 0 ? optVals[rng.below(optVals.count)] : Optional(rng.unit() * 6)
  let ev = val()
  emit("fe", opt(e), opt(lo), opt(q), hx(ev), hx(RiskEquations.floodElevationMultiplier(sampleElevation: e, localMinElevation: lo, qpfInches: q, supportingEvidence: ev))) }

for _ in 0..<300 { let a = val(), b = val(), c = val(), d = val()
  emit("rk", hx(a), hx(b), hx(c), hx(d), hx(RiskEquations.rankingRisk(band: a, zipExposure: b, seasonalPrior: c, priorConfidence: d))) }

let events = ["Tornado Warning", "Severe Thunderstorm Warning", "Snow Squall Warning", "Dust Storm Warning", "Blowing Dust Warning",
  "Fire Warning", "Fire Weather Warning", "Red Flag Warning", "Flash Flood Warning", "Flash Flood Emergency", "Flood Warning",
  "Tsunami Warning", "Hurricane Warning", "Storm Surge Warning", "Extreme Wind Warning", "Tropical Storm Warning",
  "Ashfall Advisory", "Ashfall Warning", "Volcano Warning", "Winter Storm Warning", "Ice Storm Warning", "Blizzard Warning",
  "Winter Weather Advisory", "Freezing Rain Advisory", "Excessive Heat Warning", "Heat Advisory", "Wind Chill Advisory",
  "Freeze Warning", "Frost Advisory", "Extreme Cold Warning", "Hurricane Watch", "Typhoon Watch", "Tropical Storm Watch",
  "High Wind Warning", "Wind Advisory", "Air Quality Alert", "Dense Smoke Advisory", "Dust Advisory", "Dense Fog Advisory",
  "Flood Watch", "Flood Advisory", "Tornado Watch", "Severe Thunderstorm Watch", "Special Weather Statement", "Tsunami Advisory",
  "Tsunami Watch", "Special Marine Bulletin", "", "TORNADO WARNING", "tOrNaDo WaRnInG", "Coastal Flood Warning",
  "Lake Effect Snow Warning", "Storm Warning", "Gale Warning", "Avertissement de tempête", "Avis de pluie verglaçante",
  "Snow Squall Warnin\u{0301}g", "storm\u{0301}", "TORNADO WARNİNG", "ﬁre warning", "Fire Warning\u{0000}", "  flood  ",
  "Warning: tornado", "Heat", "Wind", "Fog", "smoke", "volcano advisory", "Red Flag Warning (fire weather)"]
for ev in events { emit("af", hs(ev), RiskEquations.alertFamily(ev).map(hs) ?? "-") }

func polyBytes() -> [UInt8] { let n = rng.below(61); return (0..<n).map { _ in rng.below(5) == 0 ? UInt8(rng.below(256)) : UInt8(63 + rng.below(64)) } }
let known = ["_p~iF~ps|U_ulLnnqC_mqNvxq`@", "u{~vFvyys@fS]", "", "_p~iF", String(repeating: "~", count: 24), "??", "@@@@"]
for b in known.map({ Array($0.utf8) }) + (0..<300).map({ _ in polyBytes() }) {
  let pts = FlowsCore.decodePolylineSwift(b)
  emit("pl", lst(b.map { String(format: "%02x", $0) }), lst(pts.flatMap { [hx($0.lon), hx($0.lat)] })) }

FileHandle.standardOutput.write(out.data(using: .utf8)!)
