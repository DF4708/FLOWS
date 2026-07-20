#!/bin/sh
# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------
# Regenerate the national seasonal-climatology ZIP baseline and merge it into
# data/runtime_cache/app_risk_bundle.json, then emit the FRB1 binary sibling
# the app ships. Every entry already in the bundle is copied through
# byte-for-byte; only ZCTAs not yet present get a freshly generated entry. The
# field is one unified national climatology — no special-cased Wisconsin /
# R-engine entries and no polygon rings.
#
# Usage: scripts/generate_national_bundle.sh [week 0-51]
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WEEK="${1:-}"
if [ -z "$WEEK" ]; then
    DOY=$(date +%j | sed 's/^0*//')
    WEEK=$((DOY / 7))
    [ "$WEEK" -gt 51 ] && WEEK=51
fi

PATH="$HOME/.cargo/bin:$PATH" cargo build --release -p flows-train \
    --manifest-path "$REPO/rust/Cargo.toml"
cd "$REPO"
./rust/target/release/national-bundle "$WEEK"
# FRB1 binary sibling: the app parses this with zero JSON cost on the launch
# path (bit-exact doubles; bundle-frb.rs documents the format). Refresh the
# bundled Resources copy so device builds ship the same bytes.
./rust/target/release/bundle-frb \
    data/runtime_cache/app_risk_bundle.json \
    data/runtime_cache/app_risk_bundle.frb1
cp data/runtime_cache/app_risk_bundle.frb1 apple/FLOWS/Resources/app_risk_bundle.frb1
