# Oracle harness: brand, price and tag text (not yet run)

`main.swift` is the frozen-oracle harness for the last wave-1 group —
`BrandKnowledge`, `RatingsAndCost`, `FuelPrices` with the AAA page parser,
`LaneData.parse(turnLanes:)` and the `EnforcementCameras` tag interpretation
— written against commit a007de042d12e736fdd86398e1ea54ca31aadc1f. It has
not been run and there is no fixture yet: the group is not ported.

What it will pin, and why the port is the heaviest of wave 1: these files
stand on Swift's `String` — grapheme clusters, `Character.isLetter` and
`isNumber`, `lowercased()`/`uppercased()`, canonical equivalence in `==`,
and `Double(String)` with hex floats and NaN payloads. The harness therefore
begins by reading the Swift runtime's own tables per scalar (`u-word`,
`u-num`, `u-ws`, `u-lower`, `u-upper`, `u-canon`, `u-gcb`) and probing
segmentation on 2,500 random scalar sequences (`u-seg`), so a
zero-dependency Rust port can embed those tables and be checked over the
whole scalar domain, as the vehicle-policy parser was.

Compile with the five files named above from the base commit plus
`ThrottledNet`/`CacheEviction`/`FuelType`/`POIRanking` stand-ins the harness
carries; it drives `AAAFuelPrices.refresh` through a stubbed transport that
answers from `aaaPages`, so the real parse and cache code run with no
network. Text is written as `t:` + UTF-8 with bytes outside 0x20…0x7E (and
the backslash) escaped as `\\xx`.
