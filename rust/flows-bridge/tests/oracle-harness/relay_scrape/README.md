# Frozen Swift oracle: the relay-directory scrape

`../../fixtures/swift_relay_scrape_oracle.tsv` was produced by compiling the
ORIGINAL `TruckerRadio.swift` at 17622c5, the commit that made
`relayChannels(fromDirectory:bundled:)` a pure static and the last before its
facade switch, with this harness, and recording its output.
`../../swift_relay_scrape_oracle.rs` checks the Rust against it.

## What it pins

Every record is one directory page and one bundled station list, and the
relays `relayChannels` answered (or that it answered nothing):

- pages split at `<option value="` by Foundation's search, including a
  separator whose closing quote carries a combining mark (no split);
- the link prefix checked cluster by cluster: `http://`, another path, an
  upper-case host, the bare `/NWR` and a combining mark after the slash;
- links without a closing quote, repeated links (the first wins, even when
  its label is unusable), a `>` inside the link;
- labels between the first `>` and the next `<`, trimmed of whitespace and
  newlines (tabs, CR LF, no-break and em spaces), empty labels, a missing
  `<`;
- pages just under and over ten relays, and pages of thirty to seventy;
- bundled stations whose names have no colon, end in a colon, are only
  colons, or carry two callsigns; callsigns with spaces, canonically
  equivalent callsigns (`É` and `E` + combining acute), stations with one
  or no coordinate, NaN and infinite coordinates, and repeated callsigns
  (the first located station wins).

## What the harness never touches

`TruckerRadio` is never instantiated: its init reads the user's Application
Support and UserDefaults. Only the static runs. `ThrottledNet` and
`FlowsDiag` are stubs; the bridge text helper and the fuel code are copied
byte for byte from 17622c5 by `build_and_run.sh`.

## Reproduce

```sh
BASE=17622c5 bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

Three runs, one with `SWIFT_DETERMINISTIC_HASHING=1`, were byte-identical
(sha1 of the body in the fixture's header).
