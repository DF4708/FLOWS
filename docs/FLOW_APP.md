<!--
  Copyright (c) 2026 David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# Autonomous worker — and why FLOW.app was removed

> **Historical note.** An earlier design hosted the continuous worker in a
> `FLOW.app` bundle to obtain a scoped TCC grant. **That app has been deleted**
> for security reasons (see below). The active worker is the grant-free
> `/Users/Shared/flows` mirror described in
> [`CRASH_SURVIVAL.md`](CRASH_SURVIVAL.md) — read that for how the worker runs
> today. This file exists only to record why the FLOW.app approach was retired.

## Current mechanism (summary)

- LaunchAgent **`com.flows.worker`** runs `/bin/bash /Users/Shared/flows/worker.sh`
  with `KeepAlive` + `RunAtLoad` — survives crash, reboot, and sleep with **zero
  TCC / Gatekeeper grants**, because `/Users/Shared` is neither TCC-protected nor
  Gatekeeper-gated (the "FANS pattern").
- `scripts/worker.sh` is the canonical launcher (version-controlled; deployed to
  `/Users/Shared/flows/worker.sh`). It hardens PATH (system dirs first) and
  refuses to run if the executed tree is owned by anyone else or is
  group/other-writable.
- `scripts/sync_to_shared.sh` is the only bridge between `~/Documents` and the
  mirror. It excludes secrets (`.Renviron`, `*.key`, …) and keeps the mirror
  `drwxr-x---`.
- The runner the worker exec's (`scripts/autonomous_test_runner.sh`) now rotates
  R regression gates alongside a governed Rust suite (`rust_r0_gate`,
  memory-gated `cargo test --release -j 1`) and the in-house polyline-decoder
  gate — see [`TESTING_STRATEGY.md`](TESTING_STRATEGY.md) for the rotation.

*Re-verified 2026-07-10:* `com.flows.worker` is loaded and running,
`worker.sh`'s ownership/permission guards and system-first `PATH` are in place,
the sync's secret exclusions and `chmod 750` hold, and none of the deleted
FLOW.app toolchain files (`install_launch_agent.sh`,
`com.flows.testrunner.plist.template`, `flow_launcher.c`) exist on disk.

## Why FLOW.app was deleted (security)

`FLOW.app` was an **ad-hoc-signed** bundle that had been granted **Full Disk
Access** and whose Mach-O `exec`'d a **user-writable** script
(`scripts/autonomous_test_runner.sh`). That combination is a **TCC-bypass
bridge**: any code able to write the runner script would inherit the app's FDA
identity, defeating the per-app privacy boundary. A codebase security audit
confirmed the live FDA grant in `TCC.db`.

Remediation applied:
- Both copies of `FLOW.app` (`/Applications` and `~/Applications`) removed; the
  orphaned FDA grant is dead (TCC re-verifies the now-absent ad-hoc cdhash).
- The entire FLOW.app toolchain has been **deleted** (2026-07-04, after
  verifying no `com.flows.testrunner` agent remains loaded or on disk):
  `scripts/install_launch_agent.sh` (latterly a refusal stub),
  `scripts/com.flows.testrunner.plist.template`, and `scripts/flow_launcher.c`
  (the app's Mach-O launcher source). This document is the durable record of
  the approach and why it was retired.
- If a stale `com.flows.testrunner` agent ever reappears on a machine:
  `launchctl bootout gui/$(id -u)/com.flows.testrunner` and delete
  `~/Library/LaunchAgents/com.flows.testrunner.plist`.

The `/Users/Shared` worker replaces all of this and needs **no permission grants
at all**, which is strictly safer than a persistent FDA-holding launcher.
