#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# autonomous_test_runner.sh — continuous local test/measurement loop.
#
# Keeps the local machine saturated with useful testing work so there is
# never lull time or standby. Each pass runs a rotation of regression gates,
# reference-load measurements, and the route-latency benchmark, appending
# structured results to data/results/continuous_results.jsonl. Over many passes
# these build DISTRIBUTIONS (p50/p95, variance) rather than single point
# estimates — the statistical foundation for proving "cross-country loads
# as fast as local".
#
# Design principles:
#   * Sequential, not a fork bomb — one job at a time, steady ~1-core load,
#     so the machine stays responsive for the user.
#   * Self-refilling — when the rotation completes it starts over, forever.
#   * Stop-flag controlled — `touch tests/.stop_runner` ends it cleanly at
#     the next job boundary.
#   * Crash-resilient — one failing job logs its failure and the loop
#     continues; it never dies on a single error.
#
# Usage:
#   bash scripts/autonomous_test_runner.sh          # run until stop flag
#   touch tests/.stop_runner                        # request stop
# -----------------------------------------------------------------------------

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# Results live under a PERSISTENT, non-temp directory so a crash never loses
# accumulated measurement history. data/results/ is on the project volume
# (not /tmp, not /var/folders, not the OS scratchpad) and is append-only.
PERSIST_DIR="data/results"
RESULTS="$PERSIST_DIR/continuous_results.jsonl"
HEARTBEAT="$PERSIST_DIR/runner_heartbeat"
STOP_FLAG="tests/.stop_runner"
RUNNER_LOG="$PERSIST_DIR/runner.log"
LOCK_PID="$PERSIST_DIR/runner.lock.pid"

# Size-based rollover for the append-only diagnostic files. A long-running loop
# would otherwise grow ONE huge file whose cold tail wastes disk/page-cache
# blocks; instead each file is capped at a block-aligned 8 MiB (2048 × 4 KiB fs
# blocks) and rolls to .1/.2/.3, oldest discarded. Bounded total, full blocks,
# recent data hot — the standard log-rotation shape.
ROLL_BYTES=$((8 * 1024 * 1024))
ROLL_KEEP=3
rotate_if_big() {   # $1 = file path
  local f="$1" sz i
  [ -f "$f" ] || return 0
  sz=$(wc -c < "$f" 2>/dev/null || echo 0)
  [ "${sz:-0}" -lt "$ROLL_BYTES" ] && return 0
  rm -f "$f.$ROLL_KEEP" 2>/dev/null
  i="$ROLL_KEEP"
  while [ "$i" -gt 1 ]; do mv -f "$f.$((i-1))" "$f.$i" 2>/dev/null; i=$((i-1)); done
  mv -f "$f" "$f.1" 2>/dev/null
  : > "$f"
}

# Singleton guard: FLOW.app AND launchd (and any manual launch) all target
# this script, but only ONE runner may exist. If a live runner already owns
# the lock, this instance exits immediately — no stacked workers, no doubled
# CPU/memory. The lock stores our PID; a stale lock (dead PID) is reclaimed.
mkdir -p "$PERSIST_DIR"
# Atomic acquisition via noclobber (O_EXCL): the old check-then-write let two
# near-simultaneous launches both pass the liveness check and run doubled.
acquire_lock() {
  if ( set -o noclobber; echo "$$" > "$LOCK_PID" ) 2>/dev/null; then return 0; fi
  local other
  other="$(cat "$LOCK_PID" 2>/dev/null)"
  if [ -n "$other" ] && [ "$other" != "$$" ] && kill -0 "$other" 2>/dev/null; then
    # Exit NON-zero so a KeepAlive(SuccessfulExit=false) LaunchAgent keeps
    # retrying (throttled) and takes over the moment the owner releases.
    echo "runner already active (pid $other) — this instance exits (singleton)"
    exit 3
  fi
  # Stale lock (dead PID): reclaim, but still atomically.
  rm -f "$LOCK_PID"
  if ( set -o noclobber; echo "$$" > "$LOCK_PID" ) 2>/dev/null; then return 0; fi
  echo "lock contention during stale reclaim — this instance exits"
  exit 3
}
acquire_lock
# Release only if WE still own it — an unconditional rm let the first exiter
# delete a successor's live lock.
trap '[ "$(cat "$LOCK_PID" 2>/dev/null)" = "$$" ] && rm -f "$LOCK_PID" 2>/dev/null' EXIT

mkdir -p tests/jobs "$PERSIST_DIR"
rm -f "$STOP_FLAG"

# Crash recovery: if a previous run was killed mid-write, the last JSONL
# line may be truncated/invalid. Drop only a malformed trailing line so the
# durable history is never corrupted and the file stays append-safe.
repair_jsonl_tail() {
  local f="$1"
  [ -s "$f" ] || return 0
  local last
  last="$(tail -1 "$f")"
  # A complete JSON object line ends with '}' — if not, it was a partial write.
  # sed '$d' (portable BSD+GNU), NOT `head -n -1` (GNU-only: fails on macOS,
  # leaving the corrupt line in place while the old code logged success).
  if [ "${last: -1}" != "}" ]; then
    if sed '$d' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"; then
      echo "[recovery] dropped truncated trailing line from $f"
    else
      rm -f "$f.tmp"
      echo "[recovery] WARNING: could not repair truncated line in $f"
    fi
  fi
}

# One-time migration: fold any pre-existing tests/ results into the durable
# store so no measurement history is lost when the location moved.
if [ -f "tests/continuous_results.jsonl" ] && [ ! -f "$RESULTS.migrated" ]; then
  cat "tests/continuous_results.jsonl" >> "$RESULTS" 2>/dev/null
  touch "$RESULTS.migrated"
  echo "[persist] migrated prior tests/continuous_results.jsonl into $RESULTS"
fi
repair_jsonl_tail "$RESULTS"

# Resume detection: a pass-in-progress marker is written at each pass start
# and cleared at each pass end. If it survives to the next startup, the
# previous pass was interrupted (sleep-kill, shutdown, crash). We DISCARD the
# partial pass (its partial appends were already tail-repaired above) and
# start a fresh pass — never trusting partial results. Logged for audit so
# the durable record shows exactly when a resume happened.
PASS_MARKER="$PERSIST_DIR/.pass_in_progress"
if [ -f "$PASS_MARKER" ]; then
  interrupted="$(cat "$PASS_MARKER" 2>/dev/null)"
  printf '{"runner":"resume","event":"discarded_partial_pass","interrupted_pass":"%s","timestamp":"%s"}\n' \
    "$interrupted" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$RESULTS"
  echo "[resume] discarded interrupted pass ($interrupted); starting fresh from last successful result"
  rm -f "$PASS_MARKER"
  sync
fi
sync

log_result() {
  # $1 job name, $2 status (pass/fail/measure), $3 seconds, $4 detail
  local job="$1" status="$2" secs="$3" detail="$4"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '{"runner":"gate","job":"%s","status":"%s","seconds":%s,"detail":"%s","timestamp":"%s"}\n' \
    "$job" "$status" "$secs" "$detail" "$ts" >> "$RESULTS"
}

run_gate() {
  # $1 job name, $2 command, $3 success-grep pattern
  local job="$1" cmd="$2" pat="$3"
  local t0 t1 secs out status
  t0="$(date +%s.%N)"
  out="$(eval "$cmd" 2>&1)"
  t1="$(date +%s.%N)"
  # awk %.3f, not bc: bc prints sub-second results with NO leading zero
  # (".507"), which is invalid JSON when interpolated into "seconds":%s and
  # silently drops the record from every jsonlite-based report.
  secs="$(awk -v a="$t1" -v b="$t0" 'BEGIN{printf "%.3f", a-b}')"
  if echo "$out" | grep -qE "$pat"; then status="pass"; else status="fail"; fi
  log_result "$job" "$status" "$secs" "$(echo "$out" | tail -1 | tr '"' "'" | cut -c1-120)"
  echo "[$(date -u '+%H:%M:%S')] $job: $status (${secs}s)"
}

# Memory governor (bash-side). Computes macOS "memory pressure" used% the
# (wired + active + compressed) / total — the same memory-pressure formula
# and BLOCKS the runner until usage drops below the ceiling so the test loop
# never pushes the system past MEM_CEILING_PCT given other background tasks.
MEM_CEILING_PCT="${FLOWS_MEM_CEILING_PCT:-90}"
memory_used_pct() {
  local ps free active wired compr memsize total_pages used_pages
  local vm; vm="$(vm_stat 2>/dev/null)" || { echo 50; return; }
  ps="$(echo "$vm" | sed -n 's/.*page size of \([0-9]*\) bytes.*/\1/p')"
  [ -z "$ps" ] && ps=16384
  active="$(echo "$vm" | awk '/Pages active/       {gsub(/[^0-9]/,"",$NF); print $NF}')"
  wired="$( echo "$vm" | awk '/Pages wired down/    {gsub(/[^0-9]/,"",$NF); print $NF}')"
  compr="$( echo "$vm" | awk '/occupied by compressor/ {gsub(/[^0-9]/,"",$NF); print $NF}')"
  memsize="$(sysctl -n hw.memsize 2>/dev/null)"
  [ -z "$memsize" ] && { echo 50; return; }
  total_pages=$(( memsize / ps ))
  used_pages=$(( active + wired + compr ))
  [ "$total_pages" -le 0 ] && { echo 50; return; }
  echo $(( used_pages * 100 / total_pages ))
}

wait_for_memory() {
  # Block until used% < ceiling, or 120 s elapse (then proceed anyway so a
  # sustained-pressure machine still makes slow progress rather than hanging).
  local waited=0 used
  while :; do
    used="$(memory_used_pct)"
    if [ "$used" -lt "$MEM_CEILING_PCT" ]; then return 0; fi
    if [ "$waited" -ge 120 ]; then
      echo "[$(date -u '+%H:%M:%S')] mem ${used}% >= ${MEM_CEILING_PCT}% for 120s — proceeding cautiously"
      printf '{"runner":"governor","event":"mem_ceiling_timeout","used_pct":%s,"timestamp":"%s"}\n' \
        "$used" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$RESULTS"
      return 0
    fi
    echo "[$(date -u '+%H:%M:%S')] mem ${used}% >= ${MEM_CEILING_PCT}% — waiting for headroom"
    printf '{"runner":"governor","event":"mem_wait","used_pct":%s,"ceiling":%s,"timestamp":"%s"}\n' \
      "$used" "$MEM_CEILING_PCT" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$RESULTS"
    sleep 5
    waited=$(( waited + 5 ))
  done
}

pass_number=0

while true; do
  [ -f "$STOP_FLAG" ] && { echo "stop flag seen — exiting"; break; }
  pass_number=$((pass_number + 1))
  rotate_if_big "$RESULTS"
  rotate_if_big "$RUNNER_LOG"
  echo "=== pass $pass_number $(date -u '+%H:%M:%SZ') ===" | tee -a "$RUNNER_LOG"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$HEARTBEAT"
  # Mark this pass in-progress so an interruption is detectable on next start.
  printf 'pass=%d started=%s\n' "$pass_number" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$PASS_MARKER"

  # Memory governor: hold here until the system is below the ceiling so the
  # test loop never adds pressure past MEM_CEILING_PCT. Record the posture
  # each pass so the distribution log shows how often we throttled.
  wait_for_memory
  printf '{"runner":"governor","event":"pass_start","used_pct":%s,"ceiling":%s,"pass":%d,"timestamp":"%s"}\n' \
    "$(memory_used_pct)" "$MEM_CEILING_PCT" "$pass_number" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$RESULTS"

  # --- ONE-SYSTEM gates (Rust + Swift; the R engine is retired) ---------
  # The Wisconsin R engine was removed 2026-07 — the native app + Rust core
  # ARE the system. Its byte-identity oracles live on as PINNED fixtures
  # (RiskEquationVectors.swift, the polyline triple-identity tests) inside
  # the cargo/xcodebuild suites below, so the equivalence guarantees survive
  # the runtime's removal.

  # Swift suite — mtime-gated on apple/ sources (xcodebuild is too heavy to
  # re-prove on an unchanged tree every pass) and memory-gated like rust_r0.
  if [ -d apple ] && command -v xcodebuild >/dev/null 2>&1; then
    swift_used="$(memory_used_pct)"
    swift_marker="$PERSIST_DIR/.swift_tested"
    swift_src_new=1
    if [ -f "$swift_marker" ] \
       && [ -z "$(find apple/FLOWS apple/FLOWSTests -name '*.swift' -newer "$swift_marker" -print -quit 2>/dev/null)" ]; then
      swift_src_new=0
    fi
    if [ "$swift_used" -lt 82 ] && [ "$swift_src_new" -eq 1 ] && [ -d apple/FLOWS.xcodeproj ]; then
      echo "[$(date -u '+%H:%M:%S')] swift_suite: mem ${swift_used}% < 82% — running xcodebuild test"
      st0="$(date +%s.%N)"
      swift_out="$(cd apple && xcodebuild -project FLOWS.xcodeproj -scheme FLOWSTests -destination 'platform=macOS' test 2>&1 | tail -40)"
      st1="$(date +%s.%N)"
      ssecs="$(awk -v a="$st1" -v b="$st0" 'BEGIN{printf "%.3f", a-b}')"
      if echo "$swift_out" | grep -q "TEST SUCCEEDED"; then
        sstatus="pass"; touch "$swift_marker"
      else
        sstatus="fail"
      fi
      scount="$(echo "$swift_out" | grep -oE 'Executed [0-9]+ tests' | tail -1)"
      log_result "swift_suite" "$sstatus" "$ssecs" "${scount:-xcodebuild}"
      echo "[$(date -u '+%H:%M:%S')] swift_suite: $sstatus (${ssecs}s, ${scount:-?})"
    fi
  fi
  [ -f "$STOP_FLAG" ] && break

  # Rust R0 equivalence gate — the full LLVM test build. Gated on a STRICTER
  # memory threshold (82%) than the 90% ceiling because LLVM codegen spikes;
  # runs at most once per source change (mtime marker) so it does not re-burn
  # the machine every pass. This completes the Rust proof-of-concept
  # verification autonomously the moment the machine has room, without ever
  # risking the memory ceiling.
  if [ -d rust ]; then
    rust_used="$(memory_used_pct)"
    rust_marker="$PERSIST_DIR/.rust_r0_tested"
    rust_src_new=1
    # Prune rust/target: without it, the no-change common case stats tens of
    # thousands of build-artifact inodes on every pass.
    if [ -f "$rust_marker" ] && [ -z "$(find rust -path 'rust/target' -prune -o -name '*.rs' -newer "$rust_marker" -print -quit 2>/dev/null)" ]; then
      rust_src_new=0
    fi
    if [ "$rust_used" -lt 82 ] && [ "$rust_src_new" -eq 1 ]; then
      echo "[$(date -u '+%H:%M:%S')] rust_r0: mem ${rust_used}% < 82% — running governed cargo test"
      rt0="$(date +%s.%N)"
      rust_out="$(cd rust && CARGO_BUILD_JOBS=1 cargo test --release -j 1 2>&1)"
      rt1="$(date +%s.%N)"
      rsecs="$(awk -v a="$rt1" -v b="$rt0" 'BEGIN{printf "%.3f", a-b}')"
      if echo "$rust_out" | grep -qE "test result: ok"; then
        rstatus="pass"; touch "$rust_marker"
      else
        rstatus="fail"
      fi
      ntests="$(echo "$rust_out" | grep -oE '[0-9]+ passed' | head -1)"
      log_result "rust_r0_gate" "$rstatus" "$rsecs" "cargo test: ${ntests:-unknown}"
      echo "[$(date -u '+%H:%M:%S')] rust_r0: $rstatus (${rsecs}s, ${ntests:-?})"
    fi
  fi
  [ -f "$STOP_FLAG" ] && break

  # Pass completed cleanly — clear the in-progress marker so a restart after
  # this point does NOT count as an interrupted pass.
  rm -f "$PASS_MARKER"

  # Flush this pass's appended results to durable storage so a crash between
  # passes cannot lose the just-completed measurements. `sync` commits the
  # filesystem buffers; cheap relative to a full pass.
  sync

  # Brief pause between passes so the machine stays responsive but never
  # truly idle — 3 s, far below any human-perceptible standby.
  sleep 3
done

date -u '+%Y-%m-%dT%H:%M:%SZ stopped' > "$HEARTBEAT"
echo "runner stopped after $pass_number passes"
