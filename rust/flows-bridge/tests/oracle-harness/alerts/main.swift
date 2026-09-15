import Foundation
// Classifier oracle: what the three Swift alert classifiers say today, for
// every event name we know, so a single Rust classifier can be pinned to it.
let events: [String] = [
 // NWS products (weather.gov/alerts event catalogue)
 "911 Telephone Outage Emergency","Administrative Message","Air Quality Alert","Air Stagnation Advisory","Arroyo And Small Stream Flood Advisory",
 "Ashfall Advisory","Ashfall Warning","Avalanche Advisory","Avalanche Warning","Avalanche Watch","Beach Hazards Statement","Blizzard Warning",
 "Blizzard Watch","Blowing Dust Advisory","Blowing Dust Warning","Blowing Snow Advisory","Blue Alert","Brisk Wind Advisory","Child Abduction Emergency",
 "Civil Danger Warning","Civil Emergency Message","Coastal Flood Advisory","Coastal Flood Statement","Coastal Flood Warning","Coastal Flood Watch",
 "Cold Weather Advisory","Dense Fog Advisory","Dense Smoke Advisory","Dust Advisory","Dust Storm Warning","Earthquake Warning","Evacuation - Immediate",
 "Excessive Heat Warning","Excessive Heat Watch","Extreme Cold Warning","Extreme Cold Watch","Extreme Fire Danger","Extreme Heat Warning","Extreme Heat Watch",
 "Extreme Wind Warning","Fire Warning","Fire Weather Watch","Flash Flood Statement","Flash Flood Warning","Flash Flood Watch","Flood Advisory",
 "Flood Statement","Flood Warning","Flood Watch","Freeze Warning","Freeze Watch","Freezing Fog Advisory","Freezing Rain Advisory","Freezing Spray Advisory",
 "Frost Advisory","Gale Warning","Gale Watch","Hard Freeze Warning","Hard Freeze Watch","Hazardous Materials Warning","Hazardous Seas Warning",
 "Hazardous Seas Watch","Hazardous Weather Outlook","Heat Advisory","Heavy Freezing Spray Warning","Heavy Freezing Spray Watch","High Surf Advisory",
 "High Surf Warning","High Wind Warning","High Wind Watch","Hurricane Force Wind Warning","Hurricane Force Wind Watch","Hurricane Local Statement",
 "Hurricane Warning","Hurricane Watch","Hydrologic Advisory","Hydrologic Outlook","Ice Storm Warning","Lake Effect Snow Advisory","Lake Effect Snow Warning",
 "Lake Effect Snow Watch","Lake Wind Advisory","Lakeshore Flood Advisory","Lakeshore Flood Statement","Lakeshore Flood Warning","Lakeshore Flood Watch",
 "Law Enforcement Warning","Local Area Emergency","Low Water Advisory","Marine Weather Statement","Nuclear Power Plant Warning","Radiological Hazard Warning",
 "Red Flag Warning","Rip Current Statement","Severe Thunderstorm Warning","Severe Thunderstorm Watch","Severe Weather Statement","Shelter In Place Warning",
 "Short Term Forecast","Small Craft Advisory","Small Craft Advisory For Hazardous Seas","Small Craft Advisory For Rough Bar","Small Craft Advisory For Winds",
 "Small Stream Flood Advisory","Snow Squall Warning","Special Marine Warning","Special Weather Statement","Storm Surge Warning","Storm Surge Watch",
 "Storm Warning","Storm Watch","Test","Tornado Warning","Tornado Watch","Tropical Depression Local Statement","Tropical Storm Local Statement",
 "Tropical Storm Warning","Tropical Storm Watch","Tsunami Advisory","Tsunami Warning","Tsunami Watch","Typhoon Local Statement","Typhoon Warning",
 "Typhoon Watch","Urban And Small Stream Flood Advisory","Volcano Warning","Wind Advisory","Wind Chill Advisory","Wind Chill Warning","Wind Chill Watch",
 "Winter Storm Warning","Winter Storm Watch","Winter Weather Advisory","Flash Flood Emergency","Tornado Emergency","AMBER Alert","Silver Alert",
 "Missing Person","Endangered Missing Person","Derecho Warning","Wildfire Warning","Dam Failure Warning","Dam Break Warning",
 // ECCC / WMO shapes
 "Freezing Rain Warning","Snowfall Warning","Rainfall Warning","Wind Warning","Fog Advisory","Heat Warning","Arctic Outflow Warning","Weather Advisory",
 "Special Air Quality Statement","Severe Thunderstorm","Thunderstorm","Storm","Hail","Lightning","Hydroplaning Risk","Heavy Rain","Downpour","Whiteout",
 "Black Ice","Blowing Snow","Freezing Fog",
 // adversarial
 "","tornado warning","TORNADO WARNING","tOrNaDo WaRnInG","  Flood Warning  ","Fire Weather Warning","Red Flag Warning (fire weather)","Warning: tornado",
 "Storm\u{301}","Snow Squall Warnin\u{301}g","TORNADO WARNİNG","ﬁre warning","Fire Warning\u{0000}","Heat","Wind","Fog","smoke","volcano advisory",
 "Dust Storm Warning for I-10","Blowing dust","Dust",
]
func hx(_ s: String) -> String { "s:" + s.utf8.map { String(format: "%02x", $0) }.joined() }
let sev: [Double] = [0.30, 0.45, 0.72, 0.88, 0.95]
let now = Date(timeIntervalSince1970: 1_800_000_000)
var out = "# CLASSIFIER ORACLE — the three Swift alert classifiers as written (working tree, 2026-09-15). Strings are UTF-8 hex.\n"
out += "# af: display kind name | sh: shelter kind per severity 0.30,0.45,0.72,0.88,0.95 | ls: lifeSafety | lo: lookout | ac: imminent action per severity, transient expiry | an: same, no expiry\n"
for e in events {
    let disp = HazardStyle.kind(forEvent: e).name
    let sh = sev.map { String(describing: ShelterPolicy.kind(forEvent: e, severityScore: $0)) }.joined(separator: ",")
    let ls = ImminentAlerts.isLifeSafetyEvent(e) ? "1" : "0"
    let lo = ImminentAlerts.isLookoutEvent(e) ? "1" : "0"
    let ac = sev.map { String(describing: ImminentAlerts.classify(event: e, severityScore: $0, expires: now.addingTimeInterval(3600), now: now)) }.joined(separator: ",")
    let an = sev.map { String(describing: ImminentAlerts.classify(event: e, severityScore: $0, expires: nil, now: now)) }.joined(separator: ",")
    out += ["ev", hx(e), hx(disp), sh, ls, lo, ac, an].joined(separator: "\t") + "\n"
}
FileHandle.standardOutput.write(out.data(using: .utf8)!)
