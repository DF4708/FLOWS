# -----------------------------------------------------------------------------
# risk_constants.R — the canonical risk band thresholds. SINGLE SOURCE OF TRUTH.
#
# These three cut points drive every hazard score and band label in the app
# (scoring.R piecewise curves, risk_band labels/colours) AND are ported to the
# Rust core (rust/flows-core/src/risk.rs — keep in sync + re-run cargo test +
# the rust_equiv gate when retuning). Standalone gate scripts (tests/jobs/*)
# source THIS file rather than hardcoding copies, so a retune can never leave
# a gate silently testing stale values.
#
# Previously defined inline in global.R; moved here so non-Shiny entry points
# (equivalence gates, harnesses) can load them without sourcing the whole app.
# global.R picks this up via its R/ source loop.
# -----------------------------------------------------------------------------

RISK_GREEN_MIN <- 0.3980
RISK_YELLOW_MIN <- 0.6990
RISK_RED_MIN <- 0.8751
