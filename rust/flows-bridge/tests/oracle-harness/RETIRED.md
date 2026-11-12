# Retired harnesses

These harnesses froze the oracles of waves 1 and 2. Each one compiled the
ORIGINAL Swift at its base commit with `-swift-version 5`, the language mode
the app used then. The app has been Swift 6 since 84328b1, the Swift they
compiled is gone from the app, and no build, test or gate ever ran them, so
they were removed. Their fixtures stay: the frozen records in
`../fixtures/swift_<name>_oracle.tsv` and the Rust tests that read them are
the durable tests, and they are unchanged.

A fixture header that says "see oracle-harness/<name>" means the folder
below. Every one was last present at 7d9f40a. To read or rerun one:

```sh
git show 7d9f40a:rust/flows-bridge/tests/oracle-harness/<name>/README.md
git archive 7d9f40a rust/flows-bridge/tests/oracle-harness/<name> | tar -x -C <a folder outside the tree>
```

alert_text, alerts, climate, forecast, geo, hazard_feeds, learning,
long_trips, modes, places, places_text, recents_and_rides, relay_scrape,
risk, risk_field, seasonal, tags_and_replies, trip_vehicle, vehicle_policy.

The other folders here froze the wave 3 and wave 4 oracles in Swift 6 mode
and still reproduce their fixtures.
