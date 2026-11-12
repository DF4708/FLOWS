# Frozen Swift oracle: the international weather rules

`../../fixtures/swift_intl_weather_oracle.tsv` was produced by compiling
the ORIGINAL `IntlWeatherParsing` (`InternationalWeather.swift`) at 66e95db,
the last commit before the facade switch, with this harness, and recording
its output. `../../swift_intl_weather_oracle.rs` checks the Rust against it.

## What it pins

4,225 records, every number bit for bit.

- `c` (300): Celsius to Fahrenheit, km/h and m/s to mph, with numbers that
  are not finite, zero of both signs and the extremes;
- `at` (600): the air temperature from a SWOB station's fields: which of
  `air_temp`, `air_temp_1` and `avg_air_temp_pst1hr` speaks first, values
  that are JSON numbers, text that reads as a number or does not, whole
  numbers, booleans, nulls and arrays, keys in other cases and spellings;
- `w` (1,600): the wind from up to seven random fields: which field counts
  as wind (`wnd_spd` in any case; `-uom`, `-qa` and `flag` exact), 10 m
  sensors first, then by name, speeds below zero skipped, and the unit from
  the field's `-uom` sibling (metres a second when it holds `m/s` in any
  case, km/h otherwise, also when the unit is missing or not text);
- `wp` (1,325): every two wind keys side by side, so the order of each
  pair is pinned, including keys whose "10m" a mark, a joiner or an emoji
  modifier splits (Swift does not find "10m" there; a byte search does);
- `smn` (400): the SMN daily row's temperature (the midpoint of the high
  and the low, or whichever is there) and wind; the rain chance passes
  through.

One pair is left out. Swift's own `<` gives "wnd_spd_o\u{308}" and
"wnd_spd_\u{F6}z" no order (neither is less, and they are not equal), so
the original's pick between them followed the dictionary's order, which
changes from run to run; the harness counts such pairs on stderr (one).
The Rust orders the NFC names by their bytes, which is Swift's `<`
everywhere else.

Eleven changed rules were tried against the fixture before it was frozen,
and each broke records: no 10 m preference (319), a speed of zero skipped
(127), the unit not lowercased (35), the key not lowercased (502), `flag`
kept (93), `-qa` kept (81), names in reverse (894), the SMN high only
(210), the last air-temperature field first (69), km/h always (125), and
"10m" found by bytes (51; it survived until the `wp` keys were added).

Two changed facades were run through the harness the same way: names sent
without NFC (34 records) and the SMN temperature and wind swapped (392).

## What the harness never touches

Nothing is stubbed. The harness compiles the test target's own Core sources
as `project.yml` lists them at the base commit and links the Rust bridge
those sources already call. The gzip body, the JSON, `smnRow` and the
choice of the nearest SMN row stay in Swift and are not pinned here
(`IntlWeatherParsingTests` covers them). No network, no files, no user
data.

## Reproduce

```sh
BASE=66e95db bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

The three runs must be byte-identical; the body's sha1 is in the fixture's
header (d52878f38a5b…). Run against a later commit, the same script checks
the facade: the Swift that now calls Rust printed the same bytes on the day
of the switch.
