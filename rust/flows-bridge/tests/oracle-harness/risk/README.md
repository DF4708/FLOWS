# Frozen Swift oracle: risk equations and polyline decoder

`../../fixtures/swift_risk_oracle.tsv` was produced by compiling the ORIGINAL
Swift implementation, before it was replaced by calls into Rust, with this
harness, and recording its output.

Reproduce (the base commit is named in the fixture's first line):

```sh
BASE=17f6436
mkdir -p /tmp/oracle && cd /tmp/oracle
for f in RiskEquations FlowsCore ImminentAlerts; do
  git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"
done
cp "$REPO/rust/flows-bridge/tests/oracle-harness/risk/main.swift" .
xcrun --sdk macosx swiftc -O -swift-version 5 RiskEquations.swift FlowsCore.swift ImminentAlerts.swift main.swift -o oracle
./oracle   # the fixture body, byte for byte (header lines are prepended)
```

Rules the harness follows, so the output is a function of the code alone:
- a seeded SplitMix64, never `Math.random`-style sources;
- never iterate a `Dictionary` to choose inputs; its order is seeded per process;
- doubles as IEEE bit patterns in hex, strings as UTF-8 hex.
