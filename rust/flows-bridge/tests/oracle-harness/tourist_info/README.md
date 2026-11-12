# Frozen Swift oracle: the tourist stop card's rules

`../../fixtures/swift_tourist_info_oracle.tsv` was produced by compiling
the ORIGINAL `TouristInfo` (`TouristInfo.swift`) at 2b9201f, the last
commit before the facade switch, with this harness, and recording its
output. `../../swift_tourist_info_oracle.rs` checks the Rust against it.

## What it pins

6,716 records.

- `t` (14): the fee tables the `f` records use: the bundled
  `nps_entry_fees.json` as `loadBundled` reads it, the unit test's four
  parks, a table of odd keys (empty and blank keys, keys that hold other
  keys, case, canonically equal spellings, marks, joiners, emoji, Hangul,
  letters that change when lowercased), an empty table, and ten random
  mixes of those;
- `f` (3,965): the "Cost to get in" line: the unit test's names against
  the first four tables, then 4,000 names built from park names, odd keys
  and other words with scalars dropped in, against every table. This pins
  the national-park gate, the longest key winning (counted in Characters,
  found the way Swift's `contains` finds it), the park default, the
  national-site words and their default, and "prices vary";
- `k` (2,668): the card header's kind from 2,500 random names and MapKit
  categories (including categories spelled with the Kelvin sign, which
  Swift's `==` takes for "K"), then each name word with one of six scalars
  glued to its end (a joiner, a variation selector, a skin tone, a mark, a
  virama, an enclosing circle), alone and inside other letters, so a word
  that ends inside a bigger Character is pinned;
- `d` (69): the Monday-first day for weekdays -30 to 30 and the extremes
  Swift's `+ 5` does not trap on.

83 fee records are left out. When a park's name holds two of the longest
keys and they are the same length, the original picked whichever the
dictionary gave first, and that order changes from run to run; the harness
counts such records on stderr. The Rust gives the tie to the smaller key
by bytes, which `a_tie_between_equal_keys_goes_to_the_smaller_bytes`
checks. The five largest weekdays, where Swift's `+ 5` traps, answer in
Rust; `the_weekdays_swift_cannot_add_to_still_answer` checks them.

Sixteen changed rules were tried against the fixture before it was frozen,
and each failed: no national-park gate (1,390 records), ties to the larger
key (the tie test), key length in bytes (10), keys found by bytes (130),
the shorter key winning (642), no site default (186), no national preserve
(16), state park before national park (2), zoo before museum (4), memorial
as a landmark (58), categories compared by bytes (120; it survived until
the Kelvin categories were added), the category ignored (548), name words
found by bytes (24; it survived until the glued words were added), no park
fallback (185), Monday plus six (69), and a Euclidean remainder (26).

Three changed facades were run through the harness the same way: the park
and site defaults swapped (1,184 records), the zoo and aquarium words
swapped (221) and the kind asked of the raw name instead of the cleaned
one (967).

## What the harness never touches

Nothing is stubbed. The harness compiles the test target's own Core sources
as `project.yml` lists them at the base commit and links the Rust bridge
those sources already call. `normalized` (Foundation's diacritic folding,
which is not per scalar), reading the bundled JSON and the card's words
stay in Swift; the oracle records hand Rust the name as Swift cleaned it.
No network, no user data.

## Reproduce

```sh
BASE=2b9201f bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

The three runs (one with `SWIFT_DETERMINISTIC_HASHING=1`) must be
byte-identical; the body's sha1 is in the fixture's header
(10417e46abe2…). Run against a later commit, the same script checks the
facade: the Swift that now calls Rust printed the same bytes on the day of
the switch.
