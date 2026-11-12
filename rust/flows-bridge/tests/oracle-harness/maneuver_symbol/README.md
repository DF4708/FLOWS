# Frozen Swift oracle: reading a turn-by-turn instruction

`../../fixtures/swift_maneuver_symbol_oracle.tsv` was produced by compiling
the ORIGINAL `ManeuverSymbol`, `LaneGuidance` and `LaneBox`
(`ManeuverSymbol.swift`) at 9e8fcef, the last commit before the facade
switch, with this harness, and recording its output.
`../../swift_maneuver_symbol_oracle.rs` checks the Rust against it.

## What it pins

14,610 records.

- `u-icu-*` and `u-cws` (1,356): the classes of ICU, which `lanePhrase`'s
  `NSRegularExpression` runs on scalar by scalar, as inclusive scalar
  ranges over the whole scalar range: `\d` (72), `\s` (10), a word scalar
  for `\b` (867), a scalar `\b` looks through (397), and
  `Character.isWhitespace` of the scalar alone (10);
- `u-rx-*` (1,105): the classes of Swift Regex with simple word
  boundaries, which `exitNumber`'s `range(of:options: .regularExpression)`
  runs on Character by Character, each scalar taken as a Character: `\d`
  (235), `\s` (10), a word Character (850), `(?i)[a-z]` and `(?i)e`, `x`,
  `i`, `t` (2 each);
- `u-rx-cluster` (1,948): those eight answers for Characters of several
  scalars: letters, digits, "_", spaces and emoji with marks, joiners,
  variation selectors, skin tones, enclosing marks, Hangul jamo and
  prepended scalars, a CRLF, a flag and a family;
- `m` (8,229): for each instruction, the symbol, the side, the lane turn,
  the lane advice, the exit number, the stripped destination and the lane
  phrase of the text as written and lowercased. The instructions are
  Apple's phrasings and the unit tests' phrases, then random ones built
  from direction words, lane words, numbers in digits and words, exit
  numbers, look-alike letters (dotted and dotless I, long s, Kelvin sign,
  Cyrillic e), digits of other scripts, digits only Swift Regex calls
  digits (superscripts and fractions such as ² and ½), instructions that
  say both "keep left" and "keep right", and words with marks, joiners and
  soft hyphens inside or at their ends;
- `h` (378): the lit lanes for every count from 0 to 8, side and total
  from -3 to 10;
- `b` (1,594): the lane box for Apple's phrasings, then 1,500 random
  instructions with one to seven random road lanes (a third with none, so
  the words decide) and up to four recommended lanes, some past the end.

Nothing is left out.

## What it found

The two patterns run on different engines. `lanePhrase` uses
`NSRegularExpression`, so it is ICU, scalar by scalar, and its `\b` looks
through marks and format characters. `exitNumber` uses
`String.range(of:options: .regularExpression)`, which is Swift Regex, not
ICU: it steps whole Characters, a Character's class is decided by its
first scalar, its `\b` is the simple one (a word Character on one side
only), "_" is a word Character only when it stands alone, and its
case-insensitive letters are ASCII only (the Kelvin sign and the long s
are not "k" and "s" to it). A first port that read `exitNumber` the ICU
way differed on 33 records. Swift Regex's `\d` also takes ², ³, ¹ and ¼
to ¾, which ICU's does not.

Thirty-one changed rules were tried against the fixture before it was
frozen. Twenty-six failed it: the exit's leading `\b` dropped (13
records), its trailing `\b` dropped after the letter (17) or after the
digits (39), one digit fewer (420), "_" a word Character inside bigger
Characters too (110 cluster records), exit digits by ICU (64; it survived
until the superscript and fraction exits were added), zero spaces allowed
(6), five digits (12), the first exit kept instead of the last (403), the
letter not uppercased (25), Unicode letters for `[a-z]` (3, and its class
record), the lane `\b` not looking through marks (17) or not looking back
through them (2), "lane" without "s" (302), "middle" as left (28), an
unknown digit as no lanes (158), "keep right" read before "keep left" (50;
it survived until instructions saying both were added), merge before the
gentle turns (51), a plain exit on the left (1,087), the last side word
winning (221), no " to stay on " marker (40), sharp before exit (67), the
lit half rounded down (571), a box of at least four (22), the center
rounding right (24) and a U-turn curling left only when it says left
(428).

Five survived, and each is the same rule written another way:

- the exit's letters "e", "x", "i", "t" compared by Unicode lowercasing:
  only the ASCII capital and small letter lowercase to each of them;
- the exit's spaces by ICU `\s` instead of `Character.isWhitespace`, and
  the lane's spaces the other way round: the three sets are the same ten
  ranges (the `u-` records pin it);
- the lane phrase trying the side word before the number: no word is both
  a number and a side, so at most one can start at a place;
- the symbol's lowercasing by Rust's `to_lowercase` instead of Swift's:
  the symbol only looks for ASCII words, and the two agree on every scalar
  that lowercases into ASCII (the Kelvin sign, the dotted capital I).

Four changed facades were run through the harness the same way: the slight
left and right arrows swapped (386 records), "lanes" for one lane too
(147), the left and right codes swapped for the lit lanes (88) and an
empty exit number kept instead of nil (7,898).

## What the harness never touches

Nothing is stubbed. The harness compiles the test target's own Core sources
as `project.yml` lists them at the base commit and links the Rust bridge
those sources already call. The SF Symbol names, the lane advice's words
and the lane box's drawing stay in Swift. No network, no user data.

## Reproduce

```sh
BASE=9e8fcef bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

The three runs (one with `SWIFT_DETERMINISTIC_HASHING=1`) must be
byte-identical; the body's sha1 is in the fixture's header
(f9e5b96cd68b…). Run against a later commit, the same script checks the
facade: the Swift that now calls Rust printed the same bytes on the day of
the switch.
