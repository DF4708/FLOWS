#!/bin/bash
# Keep the /Users/Shared/flows worker testing the latest code, and bring its
# results back into the project. Run after code changes (the autonomous loop
# calls this; you can run it manually too). The worker in /Users/Shared is
# self-contained (no TCC) — this is the only bridge to ~/Documents, and it's
# run from a granted context (Terminal / an active session), not from launchd.
set -e
FLOWS="$(cd "$(dirname "$0")/.." && pwd)"
SHARED=/Users/Shared/flows
# Push code (exclude big regenerables + results, which flow the other way).
# SECRETS: .Renviron holds WI511_API_KEY etc. — it must NEVER reach the mirror
# under /Users/Shared (a shared, historically world-accessible location). Also
# drop other local secret/state dotfiles. (Regression: an unfiltered push
# copied .Renviron world-readable into the mirror.)
rsync -a --delete \
  --exclude='.git/' --exclude='data/runtime_cache/' --include-from=/dev/null --exclude='rust/target/' \
  --exclude='images/' --exclude='*.pbf' --exclude='data/results/' \
  --exclude='.Renviron' --exclude='.Renviron.*' --exclude='.Rhistory' --exclude='.RData' \
  --exclude='.Ruserdata' --exclude='.env' --exclude='*.pem' --exclude='*.key' \
  "$FLOWS/" "$SHARED/repo/"
# Belt-and-suspenders: ensure the mirror tree is not world-accessible and that
# no secret survived a prior push (perms are re-tightened every sync).
chmod 750 "$SHARED/repo" "$SHARED" 2>/dev/null || true
rm -f "$SHARED/repo/.Renviron" "$SHARED/repo/.Renviron."* 2>/dev/null || true
# Results split by AUTHORSHIP direction — critical to avoid clobbering:
#   * continuous_results.jsonl (+ runner logs): written by the WORKER in the
#     mirror -> pull mirror->project (mirror is source of truth).
#   * experiments.jsonl: the scientific-method log, authored ONLY in the
#     project -> it must NEVER be overwritten by the mirror's stale copy.
#     Exclude it from the pull, then push it project->mirror so both hold it.
# (Prior bug: an unfiltered mirror->project pull reverted every experiments
#  append back to the mirror's frozen copy, silently eating records.)
mkdir -p "$FLOWS/data/results"
# Merge-not-clobber for continuous_results.jsonl: gates/benches run directly in
# the project append lines the mirror never saw; an unconditional pull silently
# destroyed them (same clobber class as the old experiments.jsonl bug). Push
# project-only lines INTO the mirror first (lines are unique via timestamps),
# then pull — so both sides converge on the union.
PJ_CR="$FLOWS/data/results/continuous_results.jsonl"
MI_CR="$SHARED/repo/data/results/continuous_results.jsonl"
if [ -s "$PJ_CR" ] && [ -s "$MI_CR" ]; then
  comm -13 <(sort "$MI_CR") <(sort "$PJ_CR") >> "$MI_CR" 2>/dev/null || true
fi
rsync -a --exclude='experiments.jsonl' "$SHARED/repo/data/results/" "$FLOWS/data/results/" 2>/dev/null || true
if [ -f "$FLOWS/data/results/experiments.jsonl" ]; then
  cp -f "$FLOWS/data/results/experiments.jsonl" "$SHARED/repo/data/results/experiments.jsonl" 2>/dev/null || true
fi
echo "synced: code -> mirror, results -> project ($(wc -l < "$SHARED/repo/data/results/continuous_results.jsonl" 2>/dev/null) result lines; experiments: $(wc -l < "$FLOWS/data/results/experiments.jsonl" 2>/dev/null))"
# Startup snapshot for route_bench (excluded from the bulk rsync as part of
# runtime_cache, but route_bench needs it to build the routing graph). Copy
# just this one file so the mirror worker measures real route latency.
if [ -f "$FLOWS/data/runtime_cache/startup_live_environmental.rds" ]; then
  mkdir -p "$SHARED/repo/data/runtime_cache"
  # rsync, not cp -f: skips the multi-MB copy when the snapshot is unchanged
  # (the common case — every sync was paying a full copy for nothing).
  rsync -a "$FLOWS/data/runtime_cache/startup_live_environmental.rds" "$SHARED/repo/data/runtime_cache/" 2>/dev/null || true
fi
