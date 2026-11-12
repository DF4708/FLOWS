import CoreLocation
import Foundation

// Frozen oracle: every output below comes from the ORIGINAL Swift `WMOAlertParsing` (WMOAlerts.swift), compiled
// with the test target's own Core sources at the base commit. Text is its UTF-8 in hex ("-" for nil, "" for empty),
// doubles are IEEE-754 bit patterns in hex, booleans 0/1.
//
// Kinds:
//   f   lat, lon, feedCode (text), southOfMexico, besideBelize (b belize, m mexico, u unsure), besideCostaRica
//   p   raw, polygonCoords (points "lat:lon" joined by ";")
//   r   xml, parseRSSItems (each item's link, event, severity, expires, published joined by ":", items by ",")
//   c   raw, parseCAP: "-" for nil, else event, severity, polygons (rings joined by "|"), areaDesc, expires,
//       effective, web, description, isLive, identifier, references (joined by ",") as further fields
//   e   event, severity, detail, eventInRiskWords, then the two foldings the app does in Swift (it keeps
//       Foundation's folding): the event's, and that of event + " " + (detail ?? "")
//   h   text, namesHeavyRain, the text's folding
//
// The folding is `folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)`.

func th(_ s: String) -> String { s.utf8.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() }
func ot(_ s: String?) -> String { s.map(th) ?? "-" }
func hx(_ d: Double) -> String { String(d.bitPattern, radix: 16) }
func b01(_ b: Bool) -> String { b ? "1" : "0" }
func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
func C(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
func ringStr(_ r: [CLLocationCoordinate2D]) -> String {
    r.map { "\(hx($0.latitude)):\(hx($0.longitude))" }.joined(separator: ";")
}

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
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

// Spaces and odd Characters the text rules must see the way Swift does.
let GAPS: [String] = [
    " ", " ", " ", "  ", "\t", "\n", "\r\n", "\r", "\u{A0}", "\u{2003}", "\u{3000}", "\u{2028}", "\u{85}",
    " \u{301}", "\u{200B}", "\u{200D}", "\u{FEFF}", ", ", ",", "-", "\u{1680}",
]
let ODD: [String] = [
    "\u{301}", "\u{200D}", "\u{FE0F}", "\u{600}", "\u{E0001}", "\u{212A}", "\u{130}", "\u{131}", "\u{1F600}",
    "\u{1F1FA}\u{1F1F8}", "\u{FB01}", "\u{FF41}", "\u{DF}", "\u{17F}", "\u{1E9E}", "\u{0}", "\u{2013}", "\u{2014}",
    "e\u{301}", "\u{E9}", "\u{F1}", "n\u{303}", "\u{C1}", "\u{2126}", "\u{660}", "\u{FF15}",
]

let RAIN = [
    "lluvia", "lluvias", "Lluvias", "LLUVIAS", "lluvía", "precipitacion", "precipitación", "precipitaciones",
    "Precipitaciones", "chubasco", "chubascos", "aguacero", "aguaceros", "lluviass", "llu\u{301}vias",
    "lluvias\u{301}", "rain", "Rain", "lluvia\u{200D}s", "\u{FB01}lluvias", "slluvias", "_lluvias",
]
let HEAVY = [
    "muy fuerte", "muy fuertes", "Muy Fuertes", "muy  fuertes", "muy\tfuertes", "muy\u{A0}fuertes", "intensa",
    "intensas", "INTENSAS", "intensass", "torrencial", "torrenciales", "torrencialés", "extraordinaria",
    "extraordinarias", "extraordinarías", "fuertes", "fuerte", "muy fuertesx", "intensas\u{301}", "intensas_",
    "intensas1", "inténsas", "torrenciale", "intensa\u{200D}s",
]
let MIDDLE = [
    "de", "a", "puntuales", "y", "sin", "viento", "vientos", "vientosx", "racha", "rachas", "oleaje", "olas", "ola",
    "mar", "mares", "marea", "sinx", "con", "muy", "fuertes", "en", "x1", "1", "_", "más", "M\u{E1}s", "zona",
    "localmente", "sinviento", "dé", "e\u{301}", "\u{212A}",
]
let LEAD = [
    "", "", "", "sin ", "Sin ", "SIN ", "sín ", "sin  ", "sin\t", "sin\n", "sin\r\n", "asin ", "no solo ", "sin\u{A0}",
    "_sin ", "1sin ", "sin\u{301} ", "s\u{301}in ", "x ", "pero sin ", "sin y ", "\u{212A}sin ",
]
let AMOUNTS = [
    "75 a 150 mm", "50-75 mm", "de 150 mm", "49.9 mm", "50 mm", "50,0mm", "1.2.3 mm", "49,99 milímetros",
    "49,99 milimetros", "50 millimeters", "50 millimetres", "\u{660}\u{665} mm", "\u{FF15}\u{FF10} mm", "\u{600}50 mm",
    "50\u{200D} mm", "50 mmx", "50 mm.", "50mm", "25 \u{2013} 75 mm", "25 to 75 millimeters", "x50 mm",
    "500 millimetres", "1e3 mm", "50 a mm", "49 a 75 mm", "10 a 60 mm", "0050 mm", String(repeating: "9", count: 400) + " mm",
    "50 MM", "50 Mm", "50\u{301} mm", "5\u{301}0 mm", "50 mm\u{301}", "50 m\u{301}m", "50.5.5 mm", "49.999999999999999 mm",
    "49,5 a 80 mm", "50 ,5 mm", "50., mm", "50\tmm", "50\u{A0}mm", "50\nmm", "50\r\nmm", "50 - mm", "50 -75mm",
    "50 \u{2014} 75 mm", "50 to75 mm", "50 tomm", "50 a\u{301} 75 mm", "50mm_", "50mm1", "50mmé", "50 mm\u{200D}",
    "50 mm\u{FE0F}", "50 mm\u{E0001}", "١٢٠ mm", "60 milímetros", "60 MILÍMETROS", "-60 mm", "+60 mm", "6\u{0}0 mm",
    "24.9 a 49.9 mm", "49 mm y 51 mm", "49mm, 52mm", "1,5 mm", "50,", "50 m m", "\u{1D7D3}\u{1D7CE} mm",
    "50 \u{3000}mm", "50 mm\u{2028}", "75–150 mm", "75 a 150mm.", "acumulados de 50 a 75 mm",
]
let EVENTS = [
    "Aviso de Ciclón Tropical", "Aviso de Huracán", "Tormenta Tropical", "Depresión Tropical", "Hot Spell",
    "Hot Weather", "Ola de Calor", "Lluvias Intensas", "Lluvias fuertes", "Rain", "Heavy Rain", "Rainfall Warning",
    "Inundaciones", "Riverine Flooding", "Crecida", "Desbordamiento de ríos", "Oleaje Elevado", "Mar de Fondo",
    "Marejada", "Small Craft Advisory", "High Seas", "Marine Warning", "High Surf", "Nevada", "Nieve", "Aguanieve",
    "Frente Frío", "Frío", "Helada", "Viento Fuerte", "Vientos", "Gusts", "Tormenta Eléctrica", "Tormentas",
    "Granizo", "Adverse Weather", "Niebla", "Neblina", "Tornado Warning", "Flood Warning", "Severe Thunderstorm Warning",
    "Heat Advisory", "Earthquake Warning", "Avalanche", "Gale Warning", "Rain Advisory", "", "Weather alert",
    "Aviso", "Tsunami", "Volcanic Ash", "CICLÓN", "HURACÁN", "Ciclo\u{301}n", "Hurac\u{E1}n tropical", "Ola de calor y lluvias",
    "Lluvias y viento", "Viento y lluvias", "Oleaje y lluvias", "Lluvia\u{200D}", "Lluv\u{131}as", "L\u{130}uvias",
    "Rain\u{301}", "TROPICAL", "tropical\u{0}", "\u{212A}", "Inunda\u{301}ciones", "lluvia\u{FB01}", "seas",
    "Frio", "fri\u{301}o", "Nevada intensa", "Calor extremo", "Tormenta", "Tormenta de nieve", "Niebla densa",
    "Sin lluvias", "Brainstorm", "Training", "Fríolento", "Granizada", "Rain and Wind", "Electrical storm",
    "Tormenta eléctrica y granizo", "Dense Fog", "Winter Storm Warning", "Flash Flood Warning", "aviso",
]
let SEVERITIES = [
    "Severe", "Extreme", "severe", "extreme", "SEVERE", "EXTREME", "Moderate", "Minor", "Unknown", "", " Severe",
    "Severe ", "Se\u{301}vere", "S\u{E9}vere", "\u{17F}evere", "Extreme\u{301}", "ExtrEme", "Severe\u{0}", "severo",
    "extremo", "\u{212A}",
]
let DETAILS: [String?] = [
    nil, nil, "", "Se esperan lluvias intensas en la región.", "Lluvias de fuertes a muy fuertes.",
    "Lluvias fuertes y vientos muy fuertes.", "Acumulados de 75 a 150 mm.", "Hasta 40 mm.", "sin lluvias intensas",
    "Torrential rain expected", "very heavy rain", "Extreme rain", "lluvias puntuales intensas",
    "no solo lluvias intensas", "Precipitación de 50 mm", "Chubascos con rachas muy fuertes",
    "aguaceros torrenciales", "intensas lluvias", "Lluvias, intensas", "50,5 mm", "\u{660}\u{665} mm",
]

func phrase(_ r: inout SM) -> String {
    var s = ""
    if r.chance(3) { s += r.pick(["Pronóstico: ", "Se esperan ", "AVISO. ", "x", "1", "_", "\u{301}", "(", "«"]) }
    switch r.below(6) {
    case 0, 1:
        s += r.pick(LEAD) + r.pick(RAIN)
        for _ in 0..<r.below(6) { s += r.pick(GAPS) + r.pick(MIDDLE) }
        s += r.pick(GAPS) + r.pick(HEAVY)
    case 2:
        s += r.pick(LEAD) + r.pick(HEAVY) + r.pick(GAPS) + r.pick(RAIN)
    case 3:
        s += r.pick(AMOUNTS)
    case 4:
        s += r.pick(LEAD) + r.pick(RAIN) + r.pick(GAPS) + r.pick(["de", "hasta", "con", ""]) + r.pick(GAPS)
            + r.pick(AMOUNTS)
    default:
        s += r.pick(["very heavy rain", "Very Heavy Rain", "torrential", "TORRENTIAL", "extreme rain", "extreme  rain",
                     "very heavy\u{A0}rain", "torrent", "extreme rains", "torrenti\u{301}al", "very heavy rain\u{301}"])
    }
    if r.chance(3) { s += r.pick(GAPS) + r.pick(ODD) }
    if r.chance(3) { s += r.pick([".", "", " en el norte.", ", y vientos", "s", "\u{301}", " mm", "x"]) }
    return s
}

func rssDoc(_ r: inout SM) -> String {
    var s = r.pick(["", "<?xml version=\"1.0\"?><rss><channel>", "<feed xmlns=\"http://www.w3.org/2005/Atom\">",
                    "\u{FEFF}<rss>", "<rss>\r\n"])
    for _ in 0..<r.below(5) {
        let atom = r.chance(2)
        var b = ""
        func tag(_ n: String, _ v: String) -> String {
            switch r.below(9) {
            case 0: return "<\(n)>  \(v)\r\n</\(n)>"
            case 1: return "<\(n)>\n\t\(v) </\(n)>"
            case 2: return "<\(n) a=\"1\">\(v)</\(n)>"
            case 3: return "<\(n)></\(n)>"
            case 4: return "<\(n)>\(v)"
            default: return "<\(n)>\(v)</\(n)>"
            }
        }
        let link = r.pick(["https://x.example/a.xml", "https://x.example/cap?id=7", " ", "", "a\u{301}",
                           "https://x.example/\u{E9}.xml", "\u{FEFF}https://x.example/b.xml", "\r\nhttps://y/z\r\n"])
        var parts: [String] = []
        switch r.below(6) {
        case 0: parts.append("<link href=\"\(link)\"/>")
        case 1: parts.append("<link rel=\"alternate\" type=\"application/cap+xml\" href=\"\(link)\" />")
        case 2: parts.append("<link>\(link)</link>")
        case 3: parts.append(tag("link", link))
        case 4: parts.append("<link\thref=\"\(link)\"/>")
        default: if !r.chance(4) { parts.append(r.pick(["<link href=\(link)/>", "<link href='\(link)'/>",
                                                          "<link href=\"\(link)", "<link >\u{301}\(link)</link>",
                                                          "<link href=\"\"/>", "<link></link><link href=\"q\"/>"])) }
        }
        if r.chance(2) { parts.append(tag("cap:event", r.pick(EVENTS))) }
        if r.chance(2) { parts.append(tag("title", r.pick(EVENTS))) }
        if r.chance(2) { parts.append(tag("cap:severity", r.pick(SEVERITIES))) }
        if r.chance(2) { parts.append(tag("cap:expires", r.pick(["2026-11-12T10:00:00-06:00", "", " x "]))) }
        if r.chance(2) { parts.append(tag("pubDate", r.pick(["Wed, 11 Nov 2026 10:00:00 GMT", "", "\u{301}"]))) }
        if r.chance(2) { parts.append(tag("updated", r.pick(["2026-11-11T10:00:00Z", "  "]))) }
        if r.chance(5) { parts.append(r.pick(ODD)) }
        for _ in 0..<parts.count { let i = r.below(parts.count), j = r.below(parts.count); parts.swapAt(i, j) }
        b = parts.joined(separator: r.pick(["", "\n", "\r\n", " ", "\u{301}"]))
        let open = atom ? "<entry>" : "<item>"
        let close = atom ? "</entry>" : "</item>"
        switch r.below(10) {
        case 0: s += open + b
        case 1: s += close + open + b + close
        case 2: s += open + "\u{301}" + b + close
        case 3: s += open + b + close + "\u{301}"
        case 4: s += (atom ? "<entry xml:lang=\"es\">" : "<item>") + b + close
        default: s += open + b + close
        }
        s += r.pick(["", "\n", "\r\n", "  "])
    }
    s += r.pick(["", "</channel></rss>", "</feed>"])
    return s
}

func ringText(_ r: inout SM) -> String {
    let n = r.pick([0, 1, 2, 3, 3, 4, 5, 7])
    var pairs: [String] = []
    for _ in 0..<n {
        let lat = !r.chance(10) ? String(r.range(14, 19)) : r.pick(["15.5", "-0", "+16", "1e1", "18.25", "0x1p4", "inf", "nan", "17", "16.75000001", ".5", "5.",
                          "", "a", "1\u{301}", "\u{FF11}", "17.0\u{0}", "1_0", "-90", "90.0000000000000001"])
        let lon = !r.chance(10) ? String(r.range(-92, -86)) : r.pick(["-88.5", "-89", "-87.25", "-1e2", "-88", "-0x1.6p6", "-inf", "-88.1", "", "x", "-88.\u{301}5"])
        switch r.below(60) {
        case 0: pairs.append(lat + ",," + lon)
        case 1: pairs.append("," + lat + "," + lon)
        case 2: pairs.append(lat + "," + lon + ",0")
        case 3: pairs.append(lat + ",\u{301}" + lon)
        case 4: pairs.append(lat + " ," + lon)
        default: pairs.append(lat + "," + lon)
        }
    }
    var s = ""
    for (i, p) in pairs.enumerated() {
        if i > 0 { s += r.pick([" ", " ", "  ", "\n", "\r\n", "\t", "\u{A0}", "\u{2028}", "\u{3000}", " \u{301}", "\u{85}"]) }
        s += p
    }
    if r.chance(4) { s = r.pick([" ", "\n", "\r\n", "\t", "\u{A0}"]) + s + r.pick([" ", "\r\n", "\n"]) }
    return s
}

func capDoc(_ r: inout SM) -> String {
    let pre = r.chance(3) ? "cap:" : ""
    func T(_ n: String, _ v: String) -> String {
        let p = r.chance(6) ? (pre.isEmpty ? "cap:" : "") : pre
        switch r.below(8) {
        case 0: return "<\(p)\(n)>\r\n  \(v)\r\n</\(p)\(n)>"
        case 1: return "<\(p)\(n)>\(v)"
        case 2: return "<\(p)\(n) x=\"y\">\(v)</\(p)\(n)>"
        default: return "<\(p)\(n)>\(v)</\(p)\(n)>"
        }
    }
    var parts: [String] = []
    if r.chance(2) { parts.append(T("identifier", r.pick(["MX-SMN-1", "  id 2 ", "", "\u{E9}"]))) }
    if r.chance(2) { parts.append(T("status", r.pick(["Actual", "actual", "ACTUAL", "Test", "Exercise", "", "Actual\u{301}",
                                                       " Actual", "Draft", "\u{130}"]))) }
    if r.chance(2) { parts.append(T("msgType", r.pick(["Alert", "Update", "Cancel", "cancel", "CANCEL", "Ack", "Cancel\u{301}"]))) }
    var info: [String] = []
    if r.chance(2) { info.append(T("event", r.pick(EVENTS))) }
    if r.chance(2) { info.append(T("severity", r.pick(SEVERITIES))) }
    if r.chance(2) { info.append(T("responseType", r.pick(["Prepare", "AllClear", "allclear", "ALLCLEAR", "All Clear", "None"]))) }
    if r.chance(2) { info.append(T("effective", "2026-11-11T08:00:00-06:00")) }
    if r.chance(2) { info.append(T("onset", r.pick(["2026-11-11T09:00:00-06:00", ""]))) }
    if r.chance(2) { info.append(T("expires", r.pick(["2026-11-12T08:00:00-06:00", " "]))) }
    if r.chance(2) { info.append(T("web", r.pick(["https://smn.example/aviso", "", "\u{301}w"]))) }
    if r.chance(2) {
        var d = r.pick(["Lluvias intensas. ", "Se esperan rachas. ", "\u{1F600}\u{1F1FA}\u{1F1F8}", "e\u{301}", "\r\n"])
        for _ in 0..<r.below(40) { d += r.pick(["palabra ", "lluvias ", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} ",
                                                "e\u{301}", "\r\n", "\u{E9}", "  ", "x", "\u{1F1E8}\u{1F1F7}"]) }
        info.append(T("description", d))
    }
    if r.chance(3) {
        var refs = ""
        for _ in 0..<r.below(5) {
            refs += r.pick(["smn@x,MX-1,2026-11-11", "a,b", "a", ",b,c", "a,,b", "a,b\u{301},c", "x,y,z,w", ""])
                + r.pick([" ", "\r\n", "\t", "\u{A0}", "", "  "])
        }
        info.append(T("references", refs))
    }
    var areas = ""
    for _ in 0..<r.below(4) {
        var a = T("areaDesc", r.pick(["Chiapas", "Belize District", "", "Q\u{301}"]))
        for _ in 0..<r.below(3) {
            let p = r.chance(5) ? (pre.isEmpty ? "cap:" : "") : pre
            a += "<\(p)polygon>" + ringText(&r) + (r.chance(12) ? "" : "</\(p)polygon>")
        }
        areas += "<\(pre)area>" + a + "</\(pre)area>"
    }
    for _ in 0..<parts.count { let i = r.below(parts.count), j = r.below(parts.count); parts.swapAt(i, j) }
    let head = r.pick(["<alert xmlns=\"urn:oasis:names:tc:emergency:cap:1.2\">", "<cap:alert>", "<alert>", "<html>",
                       "<alerts>", "<?xml version=\"1.0\"?>\r\n<alert>", "<ale\u{301}rt>", "<cap:alert\u{301}>"])
    return head + parts.joined() + "<\(pre)info>" + info.joined(separator: r.pick(["", "\n"])) + areas
        + "</\(pre)info>" + r.pick(["</alert>", "</cap:alert>", ""])
}

@main
@MainActor
struct Oracle {
    static var out = ""
    static func emit(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }

    static func main() {
        let args = CommandLine.arguments
        guard args.count == 2 else { FileHandle.standardError.write(Data("usage: oracle out.tsv\n".utf8)); exit(2) }
        var rng = SM(s: 0x5EED_0A1E_27)

        // f: the feeds' boxes, their edges, the border steps and lines, and points around them.
        func feed(_ lat: Double, _ lon: Double) {
            let c = C(lat, lon)
            let side: String
            switch WMOAlertParsing.besideBelize(c) {
            case .belize: side = "b"
            case .mexico: side = "m"
            case .unsure: side = "u"
            }
            emit(["f", hx(lat), hx(lon), ot(WMOAlertParsing.feedCode(for: c)), b01(WMOAlertParsing.southOfMexico(c)),
                  side, b01(WMOAlertParsing.besideCostaRica(c))])
        }
        let lats: [Double] = [7.0, 8.0, 9.7, 10.0, 10.45, 10.7, 11.0, 11.3, 11.4, 14.3, 15.2, 15.8, 15.9, 16.07, 16.5,
                              17.5, 17.6, 17.8, 17.82, 18.2, 18.45, 18.5, 18.7, 20.1, 32.8]
        let lons: [Double] = [-118.5, -92.25, -92.0, -91.0, -90.6, -89.3, -89.15, -88.88, -88.3, -88.1, -87.3, -86.7,
                              -86.0, -85.0, -83.1, -82.5, -78.5, -77.1, -76.1, -72.1, -68.3, -62.1, -61.8, -60.8]
        for la in lats { for lo in lons { feed(la, lo); feed(la.nextUp, lo.nextDown); feed(la.nextDown, lo.nextUp) } }
        for lo in stride(from: -89.2, through: -87.2, by: 0.05) {
            let river = 17.90 + 1.07 * (lo + 88.88)
            for dl in [-0.1, 0.1, 0.0] {
                let l = river + dl
                feed(l, lo); feed(l.nextUp, lo); feed(l.nextDown, lo)
            }
        }
        for v in [Double.nan, .infinity, -.infinity, 0, -0.0, 1e300] {
            feed(v, -88.5); feed(17.0, v); feed(v, v); feed(16.0, v); feed(v, -91.5)
        }
        for _ in 0..<1500 { feed(rng.range(5, 34), rng.range(-120, -58)) }
        // Real places by the borders.
        let places: [(Double, Double)] = [
            (14.6349, -90.5069), (13.6929, -89.2182), (14.0723, -87.1921), (15.5042, -88.0250), (17.2510, -88.7590),
            (17.4986, -88.1976), (18.5001, -88.2961), (18.2711, -87.8350), (14.8350, -91.5180), (14.9640, -91.7960),
            (15.3197, -91.4710), (10.6918, -61.2225), (10.6500, -61.9000), (9.9281, -84.0907), (11.0220, -85.6300),
            (9.4500, -82.5200), (8.9824, -79.5199), (18.4861, -69.9312), (18.0179, -76.8099), (19.4326, -99.1332),
            (16.9000, -89.8900), (15.9000, -88.6000), (16.1000, -88.8100), (17.8167, -89.1500), (18.0833, -88.5667),
        ]
        for (la, lo) in places { feed(la, lo) }

        // p: polygon text.
        let fixedRings = [
            "", " ", "1,2", "1,2 3,4 5,6", "1,2\r\n3,4\r\n5,6", "1,2\n3,4\t5,6", "1,2\u{A0}3,4", "1,2\u{2028}3,4",
            "1,,2", ",1,2", "1,2,", "1,2,3", "a,b", "1e2,3", "+1,-2", "0x1p3,2", "inf,nan", "1,2\u{301}", "1,2\u{0}3",
            "1 ,2", "1, 2", "1,2  3,4", "1,2 \u{301}3,4", "\u{FF11},2", "-0,-0", "1.,.5", "1_0,2", "1,2\u{85}3,4",
            "1,2\u{200B}3,4", "1,2\u{3000}3,4", "1,2\u{1680}3,4", "1,2\u{FEFF}3,4", "17.1,-88.2 17.2,-88.3 17.3,-88.1 17.1,-88.2",
        ]
        for s in fixedRings { emit(["p", th(s), ringStr(WMOAlertParsing.polygonCoords(s))]) }
        for _ in 0..<400 { let s = ringText(&rng); emit(["p", th(s), ringStr(WMOAlertParsing.polygonCoords(s))]) }

        // r: the lists.
        func rss(_ x: String) {
            let items = WMOAlertParsing.parseRSSItems(x)
            emit(["r", th(x), items.map { [th($0.link), th($0.event), th($0.severity), th($0.expires),
                                            th($0.published)].joined(separator: ":") }.joined(separator: ",")])
        }
        let fixedRSS = [
            "", "<item></item>", "<item><link>a</link></item>", "<item><link> </link></item>",
            "<item><link></link><link href=\"b\"/></item>", "<entry><link href=\"c\"/></entry>",
            "<entry><link rel=\"x\" href=\"d\" /></entry><item><link>e</link></item>",
            "<item><link>f</link><cap:event>Lluvias</cap:event><title>T</title><cap:severity>Severe</cap:severity><cap:expires>x</cap:expires><pubDate>p</pubDate><updated>u</updated></item>",
            "<item><link>g</link><title> Hot Spell </title><updated>u</updated></item>",
            "<item><link>h</link></item><item><link>i</link></item>", "<item><link>j</link>", "</item><item><link>k</link></item>",
            "<item>\u{301}<link>l</link></item>", "<item><link>m</link></item>\u{301}<item><link>n</link></item>",
            "<item><link>\u{301}o</link></item>", "<item><link>p\u{301}</link></item>", "<item><link >q</link></item>",
            "<item><link href=\"r\"></link></item>", "<item><link href=\"s\">t</link></item>",
            "<entry><link href=\"\"/></entry>", "<entry><link href='u'/></entry>", "<entry><link href=\"v</entry>",
            "<entry><link href=\"w\"/>\u{301}</entry>", "<item><link>\r\nx\r\n</link></item>",
            "<item><item><link>y</link></item></item>", "<entry><item><link>z</link></entry></item>",
            "<item><link>aa</link><cap:event></cap:event></item>", "<item><link>ab</link><title></title></item>",
            "<item><link>ac</link><cap:event>e1</cap:event><cap:event>e2</cap:event></item>",
            "<item><link>ad</link><cap:event>e<cap:event>f</cap:event></cap:event></item>",
            "<item><link>ae</link><cap:expires></cap:expires><pubDate></pubDate></item>",
            "<ITEM><link>af</link></ITEM>", "<item ><link>ag</link></item>", "<item>\u{FEFF}<link>ah</link></item>",
            "<item><link>\u{FEFF}ai\u{FEFF}</link></item>", "<item><link>\u{A0}aj\u{2028}</link></item>",
        ]
        for x in fixedRSS { rss(x) }
        for _ in 0..<500 { rss(rssDoc(&rng)) }

        // c: the alert files.
        func cap(_ x: String) {
            guard let p = WMOAlertParsing.parseCAP(x) else { emit(["c", th(x), "-"]); return }
            emit(["c", th(x), th(p.event), th(p.severity), p.polygons.map(ringStr).joined(separator: "|"), ot(p.areaDesc),
                  ot(p.expires), ot(p.effective), ot(p.web), ot(p.description), b01(p.isLive), ot(p.identifier),
                  p.references.map(th).joined(separator: ",")])
        }
        let fixedCAP = [
            "", "<alert>", "<cap:alert>", "<html><body>404</body></html>", "<alerts>", "<ale\u{301}rt>", "<Alert>",
            "<alert><polygon>1,2 3,4 5,6</polygon></alert>", "<alert><cap:polygon>1,2 3,4 5,6</cap:polygon></alert>",
            "<alert><polygon>1,2 3,4</polygon><polygon>1,2 3,4 5,6 7,8</polygon><polygon>a,b 1,2 3,4</polygon></alert>",
            "<alert><polygon>1,2 3,4 5,6</alert>", "<alert><polygon> \r\n1,2\r\n3,4\r\n5,6\r\n </polygon></alert>",
            "<alert><status>Test</status></alert>", "<alert><status></status></alert>", "<alert><status> actual </status></alert>",
            "<alert><msgType>CANCEL</msgType></alert>", "<alert><responseType>AllClear</responseType></alert>",
            "<alert><effective></effective><onset>o</onset></alert>", "<alert><onset>o</onset></alert>",
            "<alert><description>" + String(repeating: "e\u{301}", count: 300) + "</description></alert>",
            "<alert><description>" + String(repeating: "\u{1F1FA}\u{1F1F8}", count: 290) + "</description></alert>",
            "<alert><description>" + String(repeating: "a", count: 279) + "\r\n" + "bc</description></alert>",
            "<alert><references>a,b,c d,e,f g h,i</references></alert>", "<alert><references></references></alert>",
            "<alert><references>,x ,,y z,\u{301}w a,b\u{301}</references></alert>",
            "<cap:alert><cap:event>Huracán</cap:event><cap:severity>Extreme</cap:severity></cap:alert>",
            "<alert><event>a</event><cap:event>b</cap:event></alert>", "<alert><cap:event>a</event></alert>",
            "<<cap:alert>", "<cap:<cap:alert>", "<alert><event>\u{301}x</event></alert>", "<alert><event>>x</event></alert>",
            "<alert><polygon>1,2 3,4 5,6</polygon>\u{301}<polygon>7,8 9,10 11,12</polygon></alert>",
        ]
        for x in fixedCAP { cap(x) }
        for _ in 0..<500 { cap(capDoc(&rng)) }

        // e: the alert names.
        func ev(_ e: String, _ s: String, _ d: String?) {
            emit(["e", th(e), th(s), ot(d), th(WMOAlertParsing.eventInRiskWords(e, severity: s, detail: d)), th(fold(e)),
                  th(fold(e + " " + (d ?? "")))])
        }
        for e in EVENTS { for s in ["Severe", "Moderate", "extreme"] { ev(e, s, nil) } }
        for _ in 0..<700 {
            var e = rng.pick(EVENTS)
            if rng.chance(4) { e = rng.pick(["", "Aviso de ", "AVISO: ", "\u{301}"]) + e + rng.pick(["", " ", "\u{301}", rng.pick(ODD)]) }
            if rng.chance(5) { e = phrase(&rng) }
            ev(e, rng.pick(SEVERITIES), rng.chance(3) ? phrase(&rng) : rng.pick(DETAILS))
        }

        // h: the heavy-rain test alone.
        func hr(_ t: String) { emit(["h", th(t), b01(WMOAlertParsing.namesHeavyRain(t)), th(fold(t))]) }
        for a in AMOUNTS { hr(a) }
        for d in DETAILS { if let d { hr(d) } }
        for l in LEAD { for rw in ["lluvias", "precipitaciones"] { for h in ["intensas", "muy fuertes", "fuertes"] {
            hr(l + rw + " " + h); hr(l + h + " " + rw)
        } } }
        for rw in RAIN { for h in HEAVY { hr(rw + " " + h) } }
        for m in MIDDLE { hr("lluvias " + m + " intensas"); hr("lluvias " + m + " " + m + " intensas") }
        hr("lluvias a b c d intensas"); hr("lluvias a b c d e intensas"); hr("lluvias a b c d e f intensas")
        hr("lluvias a, intensas"); hr("lluvias a , intensas"); hr("lluvias\u{A0}a\u{2003}intensas")
        for g in GAPS { hr("lluvias" + g + "intensas"); hr("intensas" + g + "lluvias"); hr("sin" + g + "lluvias intensas") }
        for o in ODD { hr("lluvias " + o + " intensas"); hr(o + "lluvias intensas"); hr("lluvias intensas" + o)
            hr("sin " + o + "lluvias intensas"); hr("50" + o + " mm") }
        for _ in 0..<1200 { hr(phrase(&rng)) }

        FileManager.default.createFile(atPath: args[1], contents: Data(out.utf8))
    }
}
