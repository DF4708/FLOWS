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
- `scripts/install_launch_agent.sh install` is **disabled** — it refuses to
  recreate the FDA agent and points at `com.flows.worker` instead.
- `scripts/com.flows.testrunner.plist.template` is marked **DEPRECATED — DO NOT
  USE** (kept only as a record of the abandoned approach).

The `/Users/Shared` worker replaces all of this and needs **no permission grants
at all**, which is strictly safer than a persistent FDA-holding launcher.
