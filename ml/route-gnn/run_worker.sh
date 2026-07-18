#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# FLOWS route-risk background trainer launcher.
#
#   ./run_worker.sh          # train now, then retrain every FLOWS_GNN_INTERVAL
#   ./run_worker.sh --once   # train once and exit
#   ./run_worker.sh &        # run in the background (logs to logs/worker.log)
#
# Weekly by default (matches the "equal weekly intervals through the season"
# modeling cadence). Reads the app's on-device export + physical seed, writes
# the trained head to ~/Library/Application Support/flows_route_head.json, which
# the FLOWS app loads on its next launch.
# -----------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

INTERVAL="${FLOWS_GNN_INTERVAL:-604800}"   # seconds; 604800 = 1 week
mkdir -p logs models

run_once() {
  local ts; ts="$(date +%Y-%m-%dT%H-%M-%S)"
  echo "[$ts] building + training route-risk head (Rust, zero-crate)…" | tee -a logs/worker.log
  # Build the pure-std trainer, then run it from HERE so ./models is this folder.
  if ( cd ../../rust && cargo build --release -p flows-train ) >> logs/worker.log 2>&1 \
     && ../../rust/target/release/flows-train >> logs/worker.log 2>&1; then
    echo "[$ts] ok" | tee -a logs/worker.log
  else
    echo "[$ts] FAILED (see logs/worker.log)" | tee -a logs/worker.log
  fi
}

run_once
if [ "${1:-}" = "--once" ]; then exit 0; fi
while true; do
  sleep "$INTERVAL"
  run_once
done
