# Frozen Swift oracle: the national weather alerts

`../../fixtures/swift_wmo_alerts_oracle.tsv` was produced by compiling the
ORIGINAL `WMOAlertParsing` (`WMOAlerts.swift`) at 923174c, the last commit
before the facade switch, with this harness, and recording its output.
`../../swift_wmo_alerts_oracle.rs` checks the Rust against it.

## What it pins

8,559 records.

- `f` (3,724): `feedCode`, `southOfMexico`, `besideBelize` and
  `besideCostaRica` for one point. Every edge of every country's box and
  every border step, each with the doubles just above and below; the line
  along the Hondo river in 0.05 degree steps with points a tenth either
  side; NaN, the infinities, both zeros and 1e300; 1,500 random points
  from 5 to 34 north and 120 to 58 west; and real towns on both banks of
  each border.
- `p` (433): `polygonCoords` on fixed rings (empty, one pair, a bad pair,
  extra commas, every kind of white space) and 400 random ring texts.
- `r` (536): `parseRSSItems` on fixed lists (RSS and Atom, missing tags,
  a link that starts with a byte-order mark, an empty link, tags split
  over lines) and 500 random lists.
- `c` (533): `parseCAP` on fixed files (no `<alert`, `cap:` prefixes,
  tests, cancellations, all clears, missing parts, several rings, references
  with too few fields, long descriptions cut at 280 Characters inside
  emoji and combining marks) and 500 random files.
- `e` (964): `eventInRiskWords` on 88 event names in Spanish and English,
  in every case, with combining marks, the Kelvin sign, dotted and
  dotless I, ligatures and NUL, each at three severities, then 700 random
  event, severity and detail mixes. Each record carries Swift's own
  folded text, which the Rust takes as the facade hands it in.
- `h` (2,369): `namesHeavyRain` alone: 74 written amounts (ranges, commas
  for points, Arabic and fullwidth digits, a prepended mark, 400 nines,
  units in every case), the rain words against the heavy words, "sin"
  in front in every spacing, the words between them, every gap and odd
  Character on every side, and 1,200 random phrases.

## What it found

The answers are the original's text because the Rust reads text the way
Swift did, through `swift_text`: Foundation's `range(of:)`, `contains`
and `replacingOccurrences`, the standard library's `lowercased()` and
`==`, a white-space split by Characters, and a description cut at 280
Characters.

Both regular expressions in `namesHeavyRain` are matched by hand, as ICU
reads them, scalar by scalar. The amounts ran on `NSRegularExpression`,
which is ICU. The class phrases went through
`range(of:options: .regularExpression)`, which usually steps Characters
(see the "Swift Regex is not ICU" note in `maneuver`), but this pattern
carries a lookbehind, and the frozen records show ICU's classes and `\b`
there instead. `Range(match.range(at: 1), in:)` also never rejects a group
that starts inside a Character (after a prepended combining mark), so the
group is read as scalars.

The facade switch found one bridge-wide fault. swift-bridge 0.1.59's
`toString()` reads Rust text through `String(bytes:encoding: .utf8)`,
which drops a leading U+FEFF, so a list link that began with one came back
without it. `RustStringRef.text` (in `Islands/RustLoans.swift`) now
decodes the bytes as they are. Rust text is always valid UTF-8, so the
decoding repairs nothing. A test in `SafetyAndGradeTests` pins it.

Seventy-two changed rules were tried against the fixture before the
facade switch. Sixty-nine failed it:

- the boxes: Panama's west edge (2 records), the Dominican Republic's
  west edge (17), Jamaica's top (5), Mexico's bottom (5), a box's top
  edge by `<` (25), Mexico taken south of its border (1,088), an unsure
  Belize point named anyway (160), Trinidad's cut moved (1), Costa Rica
  named beside its borders (23);
- Mexico's south border steps (11, 4, 1 and 66), Belize's four edges (29,
  17, 24 and 6), the Hondo line's slope (48) and band (14), Costa Rica's
  north (14) and south (12) lines;
- the tags: no trim (164 lists, 224 files), empty pieces kept in a comma
  split (115 rings, 71 files);
- the lists: no Atom entries (134), the link's `href` read from the
  start (1), an empty link kept (91), another default event (127) or
  severity (181), no title fallback (58), no `updated` fallback (27);
- the rings: a pair of three or more numbers read (9 files, 22 rings), a
  bad pair skipped instead of dropping the ring (58, 80), `<alert>`
  needed in full (123), two-point rings kept (29);
- the live mark: no status taken as live (157), updates taken as
  cancellations (43), all clears kept (35);
- the file's words: a reference's first field instead of its second (60),
  no `onset` fallback (69), descriptions cut at 200 (3);
- the risk words: scored events renamed (48), "extreme" not strong (75),
  "tropical" (13), marine names renamed (97), the flood names swapped
  (39), a strong rain notice an advisory (70), a heavy one a rain
  advisory (52), and one word dropped from each of snow (21), cold (38),
  heat (16), wind (28), storm (16) and fog (20), and "tormenta" read as
  wind (32);
- heavy rain: "torrential" dropped (51 and 1), a threshold of 51 mm (13
  and 166), "lluvias" (10 and 205) or "torrencial" (21) dropped, "mar"
  not refused between the words (3), "milimetros" dropped (1 and 10), the
  en dash not a range (6), `\b` not skipping marks (50), the "sin"
  lookbehind one scalar off (124 and 2) or without its `\b` (54), at most
  three words between (1), the words between without `\b` (14), the heavy
  word without `\b` (1 and 115), the whole number tried before its
  fraction (22 and 2), the comma not read as a point (2 and 10), and the
  next match starting after the group instead of after the match (31).

Three survived, and each is the same rule written another way:

- Belize's lower edge at 15.9 instead of 15.8: that strip was already
  "unsure" and then tested against Mexico's south border, which names
  none there;
- Costa Rica's top edge at 11.2 instead of 11.3: that strip is already
  beside Costa Rica's border, which names none;
- a ring's text not trimmed before it is split: the white-space split
  already drops the ends.

After the switch, twenty-five changed facades were run through this
harness against the switched Swift's own output. Twenty-four failed it:
an empty feed code kept as a code (2,419 records), Belize's two sides
swapped (1,338) or its unsure answer read as Belize (2,413), each list
item's link (248), severity (240) or published time (118) read from the
wrong slot, or a stride of four (248), the event (112) or rain text (7)
not folded, or folded without case (4), heavy rain not folded (266), the
coordinates swapped (370), the file's event read from the wrong slot
(341), each of the seven presence and live marks read one place off
(236, 226, 226, 151, 151, 181 and 182), the optional texts (298) or
references (130) read from the wrong offset, and a ring's start (113)
or length (113) read wrong. The twenty-fifth is the same rule written
another way: dropping the `v[0] == "1"` test on a file. The "not an
alert file" answer is the single `"0"`, so the count test already
refuses it.

## What the harness never touches

Nothing is stubbed. The harness compiles the test target's own Core sources
as `project.yml` lists them at the base commit and links the Rust bridge
those sources already call. The diacritic folding (Foundation's own table),
the fetches and the alert store stay in Swift. No network, no user data.

## Reproduce

```sh
BASE=923174c bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

The three runs (one with `SWIFT_DETERMINISTIC_HASHING=1`) must be
byte-identical; the body's sha1 is in the fixture's header
(3bce9895587f…). Run against a later commit, the same script checks the
facade: the Swift that now calls Rust must print the same bytes.
