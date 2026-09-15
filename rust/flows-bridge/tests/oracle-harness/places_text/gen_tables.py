#!/usr/bin/env python3
"""Write rust/flows-core/src/swift_text/tables.rs from the frozen places_text fixture.

The `u-*` records are the Swift runtime's own text tables, read out scalar by
scalar by main.swift: word and number starts, whitespace, the grapheme-break
probe patterns, the full lower- and uppercase mappings, the canonical
decompositions and combining classes. This script only reshapes them into Rust
arrays; `swift_places_text_oracle.rs` checks the arrays against the same
records over the whole scalar domain, so a stale table fails the test.

    python3 gen_tables.py [fixture.tsv] [tables.rs]

The `u-wsnl` records (`CharacterSet.whitespacesAndNewlines`) live in the
hazard-feeds fixture, `../../fixtures/swift_hazard_feeds_oracle.tsv`, whose
harness reads them from the runtime the same way; this script reads that
fixture too (or a file named by `WSNL_FIXTURE`).
"""
import sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "../../fixtures/swift_places_text_oracle.tsv")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "../../../../flows-core/src/swift_text/tables.rs")

# The 17 probes of `u-gcb`, in main.swift's order, name a Grapheme_Cluster_Break
# class (plus Extended_Pictographic and the Indic_Conjunct_Break properties).
# Codes are those of `swift_text::Gcb`.
PATTERNS = {
    "10000000000000000": None,          # Other: not stored, the default
    "00000000000000000": 1,             # Control
    "00000000000000001": 2,             # CR  (only CR + LF is one Character)
    "00000000000000010": 3,             # LF
    "11011001010101100": 4,             # Extend, Indic_Conjunct_Break=Extend
    "11011001010100000": 5,             # Extend without it (ZWNJ)
    "11001001010100000": 6,             # SpacingMark
    "10100110101000000": 7,             # Prepend
    "10001000000000000": 8,             # Extended_Pictographic
    "10000000000100000": 9,             # Indic_Conjunct_Break=Consonant
    "11011001010111100": 10,            # Indic_Conjunct_Break=Linker
    "11001001010101100": 11,            # ZWJ
    "10000100000000000": 12,            # Regional_Indicator
    "10000011100000000": 13,            # L
    "10000001111000000": 14,            # V
    "10000000011000000": 15,            # T
    "10000001101000000": 16,            # LV
    "10000001001000000": 17,            # LVT
}

WSNL_FIXTURE = os.environ.get("WSNL_FIXTURE", os.path.join(HERE, "../../fixtures/swift_hazard_feeds_oracle.tsv"))

word, num, ws, gcb, ccc, lower, upper, nfd, wsnl = [], [], [], [], [], [], [], [], []
for line in open(WSNL_FIXTURE, encoding="utf-8"):
    if line.startswith("u-wsnl\t"):
        f = line.rstrip("\n").split("\t")
        wsnl.append((int(f[1], 16), int(f[2], 16)))
for line in open(FIXTURE, encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    f = line.rstrip("\n").split("\t")
    k = f[0]
    if k == "u-word": word.append((int(f[1], 16), int(f[2], 16)))
    elif k == "u-num": num.append((int(f[1], 16), int(f[2], 16)))
    elif k == "u-ws": ws.append((int(f[1], 16), int(f[2], 16)))
    elif k == "u-gcb":
        if f[3] not in PATTERNS:
            sys.exit(f"unknown grapheme probe pattern {f[3]} at {f[1]}-{f[2]}: add it to PATTERNS and to swift_text::Gcb")
        code = PATTERNS[f[3]]
        if code is not None: gcb.append((int(f[1], 16), int(f[2], 16), code))
    elif k == "u-ccc": ccc.append((int(f[1], 16), int(f[2], 16), int(f[3])))
    elif k == "u-lower": lower.append((int(f[1], 16), [int(x, 16) for x in f[2].split(",")]))
    elif k == "u-upper": upper.append((int(f[1], 16), [int(x, 16) for x in f[2].split(",")]))
    elif k == "u-nfd": nfd.append((int(f[1], 16), [int(x, 16) for x in f[2].split(",")]))

def check_sorted(name, rows):
    keys = [r[0] for r in rows]
    if keys != sorted(keys) or len(set(keys)) != len(keys):
        sys.exit(f"{name} is not sorted and unique")
for name, rows in [("word", word), ("num", num), ("ws", ws), ("wsnl", wsnl), ("gcb", gcb), ("ccc", ccc), ("lower", lower), ("upper", upper), ("nfd", nfd)]:
    check_sorted(name, rows)
    if not rows: sys.exit(f"no {name} records in {FIXTURE}")

def padded(rows, width, name):
    out = []
    for scalar, mapping in rows:
        if len(mapping) > width - 1: sys.exit(f"{name}: mapping of {scalar:x} longer than {width - 1}")
        out.append([scalar] + mapping + [0] * (width - 1 - len(mapping)))
    return out

def array(name, doc, stride, rows, per_line):
    flat = [x for r in rows for x in r]
    lines = [f"/// {d}" for d in doc]
    lines.append(f"pub const {name}: &[u32] = &[")
    for i in range(0, len(flat), per_line):
        lines.append("    " + " ".join(f"0x{v:X}," for v in flat[i:i + per_line]))
    lines.append("];")
    lines.append(f"/// Numbers per entry of [`{name}`].")
    lines.append(f"pub const {name}_STRIDE: usize = {stride};")
    return "\n".join(lines) + "\n\n"

body = "".join([
    array("WORD_RANGES", ["Scalars whose `Character` answers `isLetter || isNumber`, as inclusive `lo, hi` pairs."], 2, word, 8),
    array("NUMBER_RANGES", ["Scalars whose `Character` answers `isNumber`, as inclusive `lo, hi` pairs."], 2, num, 8),
    array("WHITESPACE_RANGES", ["`CharacterSet.whitespaces`, as inclusive `lo, hi` pairs."], 2, ws, 8),
    array("WHITESPACE_NEWLINE_RANGES", ["`CharacterSet.whitespacesAndNewlines`, as inclusive `lo, hi` pairs (from the", "hazard-feeds fixture)."], 2, wsnl, 8),
    array("GCB_RANGES", ["Grapheme-break classes as `lo, hi, class` triples (the codes of `Gcb`); a", "scalar in no range is `Other`."], 3, gcb, 6),
    array("CCC_RANGES", ["Canonical combining classes as `lo, hi, ccc` triples; a scalar in no range has class 0."], 3, ccc, 6),
    array("LOWER_MAP", ["`Unicode.Scalar.Properties.lowercaseMapping` where it is not the scalar itself:", "`scalar, first, second` with 0 for an absent second."], 3, padded(lower, 3, "lower"), 6),
    array("UPPER_MAP", ["`Unicode.Scalar.Properties.uppercaseMapping` where it is not the scalar itself:", "`scalar, first, second, third` with 0 for absent places."], 4, padded(upper, 4, "upper"), 4),
    array("NFD_MAP", ["Full canonical decompositions outside the Hangul syllables, which decompose", "arithmetically: `scalar, d0, d1, d2, d3` with 0 for absent places."], 5, padded(nfd, 5, "nfd"), 5),
])
header = f"""// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The Swift runtime's text tables, as the frozen oracle read them.
//!
//! GENERATED by `flows-bridge/tests/oracle-harness/places_text/gen_tables.py`
//! from the `u-*` records of `fixtures/swift_places_text_oracle.tsv`; do not
//! edit by hand. Every table is sorted by its first column for binary search,
//! and `swift_places_text_oracle.rs` checks each one against the fixture over
//! the whole scalar domain.
//!
//! Counts: {len(word)} word ranges, {len(num)} number ranges, {len(ws)} whitespace ranges
//! ({len(wsnl)} with newlines),
//! {len(gcb)} grapheme-class ranges, {len(ccc)} combining-class ranges, {len(lower)} lowercase
//! mappings, {len(upper)} uppercase mappings, {len(nfd)} decompositions.

#![allow(clippy::unreadable_literal)]

"""
open(OUT, "w", encoding="utf-8").write(header + body.rstrip("\n") + "\n")
print(f"wrote {OUT}: word {len(word)}, num {len(num)}, ws {len(ws)}, gcb {len(gcb)}, ccc {len(ccc)}, lower {len(lower)}, upper {len(upper)}, nfd {len(nfd)}")
