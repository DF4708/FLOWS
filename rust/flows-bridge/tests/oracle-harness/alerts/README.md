# Frozen Swift oracle: the three alert classifiers

`../../fixtures/swift_alerts_oracle.tsv` records what `HazardStyle.kind(forEvent:)`,
`ShelterPolicy.kind(forEvent:severityScore:)` and the `ImminentAlerts` life-safety,
lookout and action rules said for 185 event names, at the commit "Routes see the
same live hazards the map does" — the last commit where those tables were Swift.

Reproduce: compile `main.swift` with `swiftc -O -swift-version 5` against the Swift
files it names (HazardStyle, ShelterPolicy, ImminentAlerts, FlowsCore, plus the
pure files they reach: ScannerIncidents, TextScale, POIRanking, RiskEquations), a
stub `Theme` providing the four colours HazardStyle reads and a no-op `scaledFont`,
and the generated RustBridge sources linked against `rust/target/xcode/macosx`.
Three runs are byte-identical.
