<!--
  Copyright (c) David B. Foster. All rights reserved.
  Contact: d.foster@marquette.edu
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# Crash-surviving worker (FANS pattern)

Learned from the FANS project's proven setup. The worker survives crash,
reboot, and sleep with **zero permission grants** by sidestepping macOS TCC
and Gatekeeper entirely.

## How it works
- **Runtime mirror in `/Users/Shared/flows/repo`** — `/Users/Shared` is NOT
  TCC-protected and NOT Gatekeeper-gated. A lean 23MB rsync mirror of the
  project (code + reference data + results; excludes .git, runtime_cache,
  rust/target, images). The worker runs entirely here and never reads
  `~/Documents`, so there is no TCC to satisfy.
- **`launchd` agent `com.flows.worker`** — `KeepAlive`+`RunAtLoad` running
  `/bin/bash /Users/Shared/flows/worker.sh`. KeepAlive respawns within 30s of
  any crash (verified: killed the worker, launchd brought it back). RunAtLoad
  starts it on boot. Sleep defers the job to wake.
- **`scripts/sync_to_shared.sh`** — the only bridge to `~/Documents`, run from
  a *granted* session context (Terminal / active session), NOT from launchd.
  Pushes code changes Documents→mirror and pulls results mirror→project.

## Why not FLOW.app + Full Disk Access
That path fought three layers: TCC attributed access to `/bin/bash` not the
app; re-signing to fix it invalidated the FDA grant (ad-hoc cdhash changes);
and Gatekeeper rejected the ad-hoc-signed app (`spctl rejected`). Robust
launchd+TCC+Gatekeeper cooperation needs a paid Developer ID. The `/Users/Shared`
self-contained mirror avoids all of it — which is exactly what FANS does.

## Operating it
- Status: `launchctl print gui/$(id -u)/com.flows.worker | grep state`
- Results: `/Users/Shared/flows/repo/data/results/` (mirrored back to the project by sync)
- Stop: `launchctl bootout gui/$(id -u)/com.flows.worker`
- After editing code: `bash scripts/sync_to_shared.sh` (the autonomous loop does this automatically)
