import Foundation

// Frozen oracle: every output below comes from the ORIGINAL Swift `ManeuverSymbol`, `LaneGuidance` and `LaneBox`
// (ManeuverSymbol.swift), compiled with the test target's own Core sources at the base commit. Text is its UTF-8 in
// hex, nil is "-".
//
// Kinds:
// u-icu-digit / u-icu-space / u-icu-word / u-icu-skip / u-cws lo hi: inclusive scalar ranges where ICU
//   (NSRegularExpression, which `lanePhrase` runs on, scalar by scalar) answers yes: `\d`, `\s`, a word character for
//   `\b`, a scalar `\b` looks through (no boundary just before it whatever came first); and `Character.isWhitespace`
//   of the scalar alone.
// u-rx-digit / u-rx-space / u-rx-word / u-rx-ci-az / u-rx-ci-e / -x / -i / -t lo hi: the same for Swift Regex with
//   simple word boundaries, which `exitNumber`'s `range(of:options: .regularExpression)` runs on, Character by
//   Character: `\d`, `\s`, a word Character for `\b`, `(?i)[a-z]`, `(?i)e` / x / i / t, each scalar as a Character.
// u-rx-cluster text bits: those eight answers, as 0/1 in that order, for a Character of several scalars.
// m instruction, symbol, side(of:), turn(for:) code, advice ("count,side,text" with text in hex, or "-"),
//   exitNumber, strippedDestination(instruction), lanePhrase(instruction), lanePhrase(instruction.lowercased())
//   (each "side,count" or "-"). Sides: 0 left, 1 right, 2 none / center.
// h count, side, total, highlighted (sorted, joined by ",").
// b instruction, lane primaries (codes joined by ","), recommended (joined by ","), arrows (turn:lit:uTurnLeft
//   joined by ",").

func th(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }
func optText(_ s: String?) -> String { s.map(th) ?? "-" }

struct SM {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
    mutating func chance(_ n: Int) -> Bool { below(n) == 0 }
}

// Apple's phrasings and the unit tests' phrases.
let REAL: [String] = [
    "At the roundabout, take the 2nd exit", "Continue on I-94 E", "Continue on I-94 W", "Keep left at the fork",
    "Keep right at the fork", "Keep straight to stay on I-94 E", "Make a U-turn", "Proceed to the route",
    "Sharp left onto Oak", "Slight left onto the ramp", "Stay on US-12 W", "Take Exit 5 onto US-51 S",
    "Take exit 142A toward I-94 E", "Take exit 2 toward Lane County", "Take the exit toward Madison",
    "Turn left onto Main St", "Turn left onto Oak St", "Turn left onto Shady Lane", "Turn left onto W Johnson St",
    "Turn left toward Right Bank Ave", "Turn right onto Left Fork Rd", "Turn right onto Main St",
    "Turn right onto Park St", "Use the 2 right lanes to turn right onto I-285",
    "Use the 2 right lanes toward Stone Rd", "Use the left 3 lanes", "Use the middle lane",
    "Use the right 2 lanes to take exit 142A", "Use the three left lanes", "You have arrived", "turn left", "right",
    "Left Fork", "Arrive at your destination", "Your destination is on the right", "Make a U turn",
    "Make a u turn at Elm St", "Enter the traffic circle", "Take the rotary", "Bear right onto Pine Rd",
    "Bear left", "Merge onto I-90 W", "Merge left onto I-39 N", "Take the ramp onto I-94 E",
    "Take the ramp on the left toward Chicago", "Sharp right onto 3rd Ave", "Head north on State St",
    "Head toward Main", "Continue straight", "Keep left to continue on US-151 N", "Stay right at the fork",
    "Use the 3 left lanes to take exit 7B toward Madison", "Use any lane to turn left", "Use the center lane",
    "Use the 2 middle lanes", "Use the six right lanes", "Use the right lane to take exit 12",
    "Take exit 1234 toward Airport", "Take exit 12345", "Take exit 7Z", "Take exit 7ZZ", "exit 9", "EXIT 44B",
    "Take exit\t31", "Take exit 31\u{A0}toward Elm", "Take exit \u{B2}", "Take exit 1\u{B3}a toward Elm",
    "Take exit \u{BC} toward Elm", "exit 4\u{BD}", "Take exit \u{2460}", "Keep left, then keep right",
    "Keep right, then stay left", "Stay right and keep left at the fork", "keep left keep right", "Turn left on to Elm", "Turn right towards Left Hand Canyon",
    "Turn left to stay on Right Rd", "Keep right onto the ramp to I-94 E", "Slight right toward Exit 4",
    "Use the left 2 lanes to turn left onto Leftwich Rd", "Use the 7 right lanes", "Use the 0 left lanes",
    "use the left lanes", "Use the right   lanes", "the right lane", "right lanes", "left lanex", "left laness",
    "left lane-2", "Take the 2nd exit at the roundabout onto Rotary Rd", "Turn", "Proceed", "", " ",
]

// Words random instructions are built from.
let WORDS: [String] = [
    "turn", "Turn", "TURN", "left", "Left", "LEFT", "right", "Right", "RIGHT", "slight", "Slight", "bear", "keep",
    "Keep", "stay", "Stay", "merge", "Merge", "exit", "Exit", "EXIT", "eXiT", "exits", "ramp", "sharp", "Sharp",
    "u-turn", "U-Turn", "make", "a", "u", "arrive", "arrived", "you", "have", "roundabout", "traffic", "circle",
    "rotary", "continue", "head", "proceed", "onto", "on", "to", "toward", "towards", "the", "lane", "lanes",
    "Lane", "LANES", "center", "middle", "Middle", "one", "two", "three", "four", "five", "six", "seven", "One",
    "1", "2", "3", "4", "5", "6", "7", "0", "12", "142", "142a", "142A", "5b", "9999", "12345", "7zz",
    "leftover", "bright", "turnpike", "emerge", "exiting", "lanesville", "stone", "fork", "I-94", "US-12",
    "\u{130}", "\u{131}", "\u{17F}", "\u{212A}", "\u{1E97}", "\u{661}", "\u{FF13}", "\u{966}", "l\u{435}ft",
    "\u{130}xit", "ex\u{130}t", "exi\u{1E97}", "\u{1E9E}", "ﬁ", "\u{212B}", "\u{3A3}",
    "rig\u{200D}ht", "le\u{301}ft", "lef\u{AD}t", "e\u{301}xit", "exit\u{301}", "2\u{301}", "\u{1F3FB}",
    "\u{1F1FA}\u{1F1F8}", "_", "-", ",", ".", "(", ")", "\u{B2}", "1\u{B3}", "\u{BD}",
]

// Separators between words.
let SEPS: [String] = [
    " ", " ", " ", " ", " ", "  ", "\t", "\u{A0}", "\u{2028}", "\u{85}", "\u{3000}", "\u{200B}", "\u{180E}",
    "\u{1C}", "\u{B}", "\u{C}", "\r\n", "\n", "\r", "\u{1680}", "\u{202F}", "\u{2009}", "", "-", "_",
]

// Scalars dropped into real phrases at every position.
let STRAY: [UInt32] = [
    0x301, 0x308, 0x200D, 0x200C, 0x200B, 0xAD, 0x600, 0x110BD, 0xFE0F, 0x1F3FB, 0x1F1FA, 0x903, 0x94D, 0xE33,
    0x1100, 0x1160, 0x5F, 0x345, 0x3099, 0xDF, 0xFB01, 0x1F600, 0x20, 0xA0, 0x9, 0x2028, 0x130, 0x17F, 0x212A,
    0x661, 0x41, 0x31,
]

@main
@MainActor
enum Oracle {
    static var rng = SM(s: 0x4D41_4E45_5556_4552)  // "MANEUVER"
    static var out = ""
    static func emit(_ f: [String]) { out += f.joined(separator: "\t") + "\n" }

    static func sideCode(_ s: ManeuverSymbol.Side) -> String {
        switch s {
        case .left: return "0"
        case .right: return "1"
        case .none: return "2"
        }
    }
    static func laneSideCode(_ s: LaneGuidance.Side) -> String {
        switch s {
        case .left: return "0"
        case .right: return "1"
        case .center: return "2"
        }
    }
    static func phrase(_ p: (side: LaneGuidance.Side, count: Int)?) -> String {
        p.map { laneSideCode($0.side) + "," + String($0.count) } ?? "-"
    }

    /// Inclusive ranges of the scalars where `yes` holds, emitted as `kind lo hi` records.
    static func ranges(_ kind: String, _ yes: (Unicode.Scalar) -> Bool) {
        var lo: UInt32? = nil
        var last: UInt32 = 0
        func close() {
            if let l = lo { emit([kind, String(l, radix: 16, uppercase: true), String(last, radix: 16, uppercase: true)]) }
            lo = nil
        }
        for v in UInt32(0)...0x10FFFF {
            guard let c = Unicode.Scalar(v) else { continue }
            if yes(c) {
                if lo == nil || last + 1 != v && !(last == 0xD7FF && v == 0xE000) { close(); lo = v }
                last = v
            } else {
                close()
            }
        }
        close()
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
    }

    static func instruction(_ s: String) {
        let advice = LaneGuidance.advice(for: s).map {
            String($0.laneCount) + "," + laneSideCode($0.side) + "," + th($0.text)
        }
        emit([
            "m", th(s), th(ManeuverSymbol.symbol(for: s)), sideCode(ManeuverSymbol.side(of: s)),
            String(ManeuverSymbol.turn(for: s).rustCode), advice ?? "-", optText(ManeuverSymbol.exitNumber(in: s)),
            th(ManeuverSymbol.strippedDestination(s)), phrase(LaneGuidance.lanePhrase(in: s)),
            phrase(LaneGuidance.lanePhrase(in: s.lowercased())),
        ])
    }

    static func box(_ s: String, _ lanes: [LaneData.Lane], _ rec: Set<Int>) {
        let arrows = LaneBox.arrows(lanes: lanes, recommended: rec, instruction: s)
        emit([
            "b", th(s), lanes.map { String($0.primary.rustCode) }.joined(separator: ","),
            rec.sorted().map(String.init).joined(separator: ","),
            arrows.map { "\($0.turn.rustCode):\($0.lit ? 1 : 0):\($0.uTurnLeft ? 1 : 0)" }.joined(separator: ","),
        ])
    }

    static func randomInstruction() -> String {
        var s = ""
        let n = 1 + rng.below(7)
        for i in 0..<n {
            if i > 0 || rng.chance(8) { s += rng.pick(SEPS) }
            s += rng.pick(WORDS)
        }
        if rng.chance(8) { s += rng.pick(SEPS) }
        if rng.chance(4) { s.unicodeScalars.append(Unicode.Scalar(rng.pick(STRAY))!) }
        return s
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count == 2 else {
            FileHandle.standardError.write(Data("usage: oracle out.tsv\n".utf8))
            exit(2)
        }

        // ICU's classes, scalar by scalar, which `lanePhrase`'s NSRegularExpression runs on.
        func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
        let digit = re(#"\A\d\z"#), space = re(#"\A\s\z"#), boundary = re(#"(?s)\A.\b"#)
        ranges("u-icu-digit") { matches(digit, String($0)) }
        ranges("u-icu-space") { matches(space, String($0)) }
        ranges("u-icu-skip") { !matches(boundary, "a" + String($0)) && !matches(boundary, " " + String($0)) }
        ranges("u-icu-word") { matches(boundary, " " + String($0)) && !matches(boundary, "a" + String($0)) }
        ranges("u-cws") { Character($0).isWhitespace }

        // Swift Regex's classes, which `exitNumber`'s `range(of:options: .regularExpression)` runs on: whole
        // Characters, simple word boundaries. First each scalar as a Character of its own, then Characters of
        // several scalars.
        func rx(_ p: String) -> Regex<AnyRegexOutput> { try! Regex(p).wordBoundaryKind(.simple) }
        let rxDigit = rx(#"\d"#), rxSpace = rx(#"\s"#), rxAz = rx(#"(?i)[a-z]"#), rxWord = rx(#"(?s).\b"#)
        let rxLetters = ["e", "x", "i", "t"].map { rx("(?i)" + $0) }
        func whole(_ r: Regex<AnyRegexOutput>, _ s: String) -> Bool { (try? r.wholeMatch(in: s)) != nil }
        func isWord(_ s: String) -> Bool { (try? rxWord.prefixMatch(in: s + "\n")) != nil }
        ranges("u-rx-digit") { whole(rxDigit, String($0)) }
        ranges("u-rx-space") { whole(rxSpace, String($0)) }
        ranges("u-rx-word") { isWord(String($0)) }
        ranges("u-rx-ci-az") { whole(rxAz, String($0)) }
        for (l, r) in zip(["e", "x", "i", "t"], rxLetters) { ranges("u-rx-ci-" + l) { whole(r, String($0)) } }
        func cluster(_ s: String) {
            guard s.count == 1 else { return }
            let bits = [whole(rxDigit, s), whole(rxSpace, s), isWord(s), whole(rxAz, s)] + rxLetters.map { whole($0, s) }
            emit(["u-rx-cluster", th(s), bits.map { $0 ? "1" : "0" }.joined()])
        }
        let bases: [UInt32] = [
            0x65, 0x45, 0x78, 0x69, 0x74, 0x61, 0x212A, 0x35, 0x663, 0x5F, 0x20, 0xA0, 0x09, 0x17F, 0x110BD, 0x903,
            0x1100, 0x1F600,
        ]
        let extenders: [UInt32] = [
            0x301, 0x200D, 0x200C, 0xFE0F, 0x1F3FB, 0x903, 0x94D, 0xE33, 0x20DD, 0x308, 0x1161,
        ]
        func text(_ v: [UInt32]) -> String {
            var t = String.UnicodeScalarView()
            for x in v { t.append(Unicode.Scalar(x)!) }
            return String(t)
        }
        for b in bases {
            for e in extenders {
                cluster(text([b, e]))
                for f in extenders { cluster(text([b, e, f])) }
            }
        }
        for p: UInt32 in [0x110BD, 0x600, 0xD4E] {
            for b in bases { cluster(text([p, b])) }
        }
        for v: [UInt32] in [[0x0D, 0x0A], [0x1F1FA, 0x1F1F8], [0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467]] {
            cluster(text(v))
        }

        // Instructions: the real ones, each with a stray scalar at every position, then random ones.
        var pool = REAL
        for s in REAL { instruction(s) }
        for s in REAL where !s.isEmpty {
            let scalars = Array(s.unicodeScalars)
            for pos in 0...scalars.count {
                let stray = Unicode.Scalar(STRAY[(pos + scalars.count) % STRAY.count])!
                var t = String.UnicodeScalarView()
                t.append(contentsOf: scalars[..<pos])
                t.append(stray)
                t.append(contentsOf: scalars[pos...])
                instruction(String(t))
            }
        }
        for _ in 0..<6000 {
            let s = randomInstruction()
            pool.append(s)
            instruction(s)
        }

        // The lit lanes for every stated count, side and total.
        let sides: [LaneGuidance.Side] = [.left, .right, .center]
        for count in 0...8 {
            for side in sides {
                for total in -3...10 {
                    let lit = LaneGuidance.highlighted(
                        advice: LaneGuidance.Advice(laneCount: count, side: side, text: ""), total: total)
                    emit([
                        "h", String(count), laneSideCode(side), String(total),
                        lit.sorted().map(String.init).joined(separator: ","),
                    ])
                }
            }
        }

        // The lane box: from the road's lanes, from the words, or one arrow.
        for s in REAL { box(s, [], []) }
        for _ in 0..<1500 {
            let s = rng.pick(pool)
            var lanes: [LaneData.Lane] = []
            if !rng.chance(3) {
                for _ in 0..<(1 + rng.below(7)) {
                    var turns: [LaneData.Turn] = []
                    for _ in 0..<(1 + rng.below(3)) { turns.append(LaneData.Turn.byCode[rng.below(11)]) }
                    lanes.append(LaneData.Lane(turns: turns))
                }
            }
            var rec: Set<Int> = []
            for _ in 0..<rng.below(5) { rec.insert(rng.below(9)) }
            box(s, lanes, rec)
        }

        FileManager.default.createFile(atPath: args[1], contents: Data(out.utf8))
    }
}
