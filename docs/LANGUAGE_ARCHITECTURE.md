<!--
  Copyright (c) 2026 David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# FLOWS — language architecture: Rust compute, Swift UI

The rule: **Rust owns the compute, Assembly owns the innermost hot loops, Swift
owns the UI, C is the thin ABI between them.** A thing is written in the highest
tier only when a lower tier genuinely can't do the job. Everything portable is
Rust so it's tested once and reused (app, R server, CLI); the platform edge is
Swift because Apple's frameworks have no other binding.

## The tiers and when each is *required*

### Swift — required for the UI and anything touching an Apple framework
Use Swift only where there is no portable alternative:
- **SwiftUI** (all views), **MapKit** (map, overlays, `MKDirections` routing,
  `MKLocalSearch` POIs), **CoreLocation** (GPS/heading), **AVFoundation**
  (radio, speech), **CoreBluetooth** (TPMS/OBD), **WatchConnectivity**,
  **ExternalAccessory**, **Contacts**, **Speech**, **CoreMotion**.
- These are Apple-only APIs; Rust can't call them, so the UI and device I/O
  layer is Swift by necessity, not by preference.
- **Also Swift by deliberate exception:** tiny *scalar* helpers called once per
  value in a tight loop (risk banding, a single piecewise score, one
  point-to-point distance). A Rust FFI round-trip per scalar call costs more
  than the 3–5 arithmetic ops it would run — so these stay inline Swift. They
  are byte-pinned to the **same R oracle** as their Rust twins
  (`RiskEquationVectors.swift` ⇔ `risk::tests::*_match_r_oracle`), so "two
  implementations" never means "two answers."

### Rust — the default for all portable compute
Everything that is pure computation with no Apple dependency lives in
`rust/flows-core` and is shared by the app (FFI), the R server (`dyn.load`), and
the test suite:
- **polyline decode** (varint/zig-zag — a real hot loop, batch per route),
- **distance matrix** (batch, scalar — `distance.rs`; R-bridge only),
- **contraction-hierarchy routing** (`ch.rs`) and Dijkstra,
- **risk banding, piecewise/temperature scoring** (`risk.rs`, `scoring.rs`) as
  *batch* FFI entry points (`flows_piecewise_score_batch`, …) for whole-corridor
  scoring.
The app calls these through the C ABI in `ffi.rs`. Batch granularity is what
makes the FFI worth it — one call amortized over many values.

### Assembly — only the innermost kernel, only where measured
- `polyline.rs` SHIPPED an **AArch64 hand-written kernel** until 2026-07-19,
  when the pure-std bake-off (`flows-core/src/bin/bench.rs`) measured rustc
  out-scheduling it (asm 3.20 ns/byte vs portable-raw-pointer 2.59). The asm
  was deleted per the dead-fast-variant rule; the shipped kernel is the
  portable raw-pointer body, still pinned against the safe oracle
  (`decode_deltas_rust`) by the same equivalence tests that once held the
  asm byte-identical.
- `distance.rs` is scalar-only — reached only through the R `.C()` bridge, not
  the app, so it stays the plain reference; the SIMD seam waits behind its
  signature until a profile mandates it (see docs/CODING_STANDARDS.md).
- Assembly is never written speculatively — a kernel earns its place only when
  a benchmark shows the compiler's auto-vectorization leaves real time on the
  table, and it always ships behind a byte-identical scalar twin so correctness
  never depends on the asm being right.

### C — the ABI, and nothing more
`extern "C"` in `ffi.rs` is the only C surface: the stable calling convention
Swift and R both speak. No business logic lives in C; it's the boundary layer.

## When we are *forced* to a different language

| Need | Language | Why forced |
|---|---|---|
| Any on-screen UI, map, gestures | Swift | SwiftUI/MapKit are Apple-only |
| GPS, BLE, speech, motion, CarPlay, Watch | Swift | Apple framework APIs |
| Traffic-aware turn-by-turn routing | Swift (`MKDirections`) | Apple's live-traffic router; no portable equal |
| Portable algorithms / hot loops | Rust | one tested implementation, all platforms |
| Swift ⇄ Rust ⇄ R calling convention | C ABI | the shared, stable interface |
| Per-scalar helper inside a tight loop | Swift inline | FFI overhead > the compute (documented exception) |

## Linkage — the fix this pass

The FFI surface and the byte-identical asm existed, **but the app was not
actually linking the Rust core** — `project.yml` only had comments. So the
shipping product ran the pure-Swift fallback everywhere; the asm hot loop was
reachable only on a macOS dev box via a `dlopen` of the repo `dylib`.

Now the Rust `.a` is **static-linked into every app target**:
- macOS: `libflows_core.a` (arm64) via `OTHER_LDFLAGS` + a pre-build
  `cargo build --release`; the loader's `dlsym(dlopen(nil))` resolves the
  force-kept (`-u`) symbol.
- iOS: per-SDK slices — `aarch64-apple-ios` (device) and `aarch64-apple-ios-sim`
  (simulator), cross-compiled by the target's pre-build step.
- watchOS: not linked — the watch companion receives *pre-decoded* route points
  over WatchConnectivity and does no polyline/route compute, so it has no Rust
  hot path to link. (If that changes, add the `arm64_32`/`aarch64` watch slice.)

Verified by `RustCoreLinkageTests`: `rustCoreLoaded == true` (it's the Rust
path, not the fallback) **and** the Rust decoder is **bit-for-bit identical** to
the Swift fallback (`bitPattern` equality on every coordinate).

## Dependencies — minimize, and prove sameness

- **Third-party runtime deps: none.** The app links only Apple frameworks + our
  own Rust core. No SPM packages, no vendored SDKs. (RainViewer, the last
  third-party *data* dependency, was removed — see `DATA_FEEDS.md` §11.)
- **The "duplication" that remains is deliberate and safe:** the scalar Swift
  risk helpers mirror Rust, but both are pinned to the same R oracle, so they're
  one source of truth expressed twice for a measured performance reason — not a
  drift risk. The heavy/batch compute has exactly one implementation (Rust).
- **Byte-identical is enforced, not asserted:** the Rust suite holds asm≡scalar
  and fast≡reference; the Swift suite holds the ports to the R vectors and now
  holds Rust≡Swift for the decoder. Any optimization must keep all of them
  green with no tolerance loosening.
