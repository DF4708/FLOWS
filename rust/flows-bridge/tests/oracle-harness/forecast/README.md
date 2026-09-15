# Frozen Swift oracle: the forecast predictors

`../../fixtures/swift_forecast_oracle.tsv` was produced by compiling the
ORIGINAL `ForecastConditions.forecastScore` and `.predictorFamilies`
(`NWSForecastService.swift`) with this harness and recording their output,
before the composition moved to `flows_core::forecast`.
`../../swift_forecast_oracle.rs` checks the Rust against it bit for bit.

## The first bridge-linked harness

At the base commit `RiskEquations` was already a facade over the Rust
equations (`flows_temperature_risk`, `flows_piecewise_score`, …), so the
original composition cannot be compiled without the bridge. This harness
links `libflows_bridge.a` and compiles the generated bindings alongside the
base-commit sources: the original `ClimateProfiles` and `LatitudeBands`
(pure Swift then), `RiskEquations` and `FlowsCore` (facades), and
`InternationalWeather` and `SpeedLaw` because `NWSForecastService` names
them. `stubs.swift` stands in for `ThrottledNet`, `CacheEviction`,
`ImminentAlerts`, `AdaptiveTuning` and `FlowsDiag`, none of which the oracle
exercises. The same recipe serves every later group whose original already
called the bridge.

Records: `fc-score` and `fc-fam`, each `temp wind pop lat lon elev →
answer`, with the six predictor scores read from the dictionary by fixed
key in the order wind, precip, heat, cold, winter, convective. Inputs cover
every rule edge (34 °F and 60 °F to the ulp, the national wind and rain
thresholds), the specials in every slot, fourteen places from Mexico City to
Utqiaġvik and the southern hemisphere, odd elevations, and a 2,000-draw
random sweep. Coordinates stay finite: the original's latitude bands trap
on `Int(NaN)`.

## Reproduce

```sh
BASE=a007de042d12e736fdd86398e1ea54ca31aadc1f
BR="$REPO/apple/FLOWS/RustBridge"
mkdir -p /tmp/forecast-oracle && cd /tmp/forecast-oracle
FILES="NWSForecastService RiskEquations ClimateProfiles LatitudeBands FlowsCore InternationalWeather SpeedLaw"
for f in $FILES; do git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"; done
cp "$REPO/rust/flows-bridge/tests/oracle-harness/forecast/"{main,stubs}.swift .
xcrun --sdk macosx swiftc -O -swift-version 5 -import-objc-header "$BR/BridgingHeader.h" -I "$BR" \
  "$BR/SwiftBridgeCore.swift" "$BR/flows-bridge/flows-bridge.swift" \
  $(for f in $FILES; do printf '%s.swift ' "$f"; done) stubs.swift main.swift \
  -L "$REPO/rust/target/xcode/macosx" -lflows_bridge -o oracle
./oracle   # the fixture body (three header lines are prepended)
```

`scripts/build_rust_bridge.sh` builds the static library. Three runs, one
with `SWIFT_DETERMINISTIC_HASHING=1`, were byte-identical (sha1 in the
fixture's header line is of the body).
