# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# wi511_sanitizer.R - throughput-vs-safety classifiers used to keep
# congestion / lane-management text out of the driving-risk overlay.
# is_travel_delay_reason: matches legacy travel-time fetcher's text.
# is_operational_only_511_text: flex/HOV/managed/express lane, ramp
#   metering, toll plaza, special-event-traffic - unless the same
#   text also carries a real safety keyword.
# sanitize_transport_reason: drops travel-delay strings to NA while
#   preserving names() so per-zip lookups stay correct.


# NOTE: score_511_travel_delay and fetch_511_travel_times_live were
# removed during the safety-vs-throughput audit. Travel-time delays are a
# congestion signal, not a safety hazard, so they no longer feed the
# risk overlay; nothing else consumed them. If a future feature wants
# to use the WI511 travel-time feed for ETA adjustment (decoupled from
# the risk overlay), recover the implementations from git history.

# Why: travel-time delays are a congestion signal, not a driver safety
# hazard, so they must never colour a road red on the risk overlay. The
# legacy travel-times fetcher emitted recognisable strings ("511WI
# travel delay elevated risk by N min over normal", "511tt-..." road
# IDs) — once that fetcher was retired, those strings could still slip
# through stale upstream caches and propagate via per-zip transport
# reason → modeled-road dominant-zip into popup driving_reason_text.
# What: returns a logical vector the same length as reason_text; TRUE
# at positions whose text matches the legacy travel-delay templates,
# FALSE everywhere else (including NA inputs).
# How: word-bounded grepl against a tight regex covering the four
# legacy templates; explicit !is.na guard so NA inputs don't leak
# through nzchar(NA)=TRUE on this R install.
# When: called by sanitize_transport_reason and by load_startup_map_
# snapshot's defensive scrub of any pre-fix persisted payload.
# Impact: the regex is intentionally specific to the legacy fetcher's
# strings — broadening to "delay" / "congestion" generally would
# silence legitimate safety alerts that happen to mention those words.
is_travel_delay_reason <- function(reason_text) {
  txt <- as.character(reason_text)
  out <- rep(FALSE, length(txt))
  hit <- !is.na(txt) & grepl(
    "travel delay elevated risk|511WI travel times?|^511tt-|elevated risk by [0-9.]+ minutes? over normal",
    txt,
    ignore.case = TRUE,
    perl = TRUE
  )
  out[hit] <- TRUE
  out
}


# Why: 511WI message signs and events frequently announce lane-management
# state (flex lane open/closed, HOV reservation, ramp metering active,
# toll plaza state, special-event traffic). These are throughput
# controls, not safety hazards — closing a flex lane to general traffic
# off-peak does not endanger drivers in the adjacent general-purpose
# lanes. Without this filter, the operational-text fired the bare
# "closed" keyword in the score functions and surfaced as red roads
# with no real corroborating safety reason behind them.
# What: returns a single TRUE/FALSE for the input string — TRUE only
# when the text matches an operational-only keyword AND does not also
# carry a real-safety keyword (so mixed text like "FLEX LANE CLOSED
# CRASH AHEAD" returns FALSE and the safety side wins).
# How: case-folded grepl against an operational keyword list with a
# carve-out grepl against a safety keyword list.
# When: called as the first guard inside score_511_message_sign_risk,
# score_511_event_risk, and score_511_alert_risk; an operational-only
# string returns 0 from all three.
# Impact: keep the operational keyword list tight — anything matching
# it without a safety carve-out drops to score 0. Adding a category
# here is the lever for "this sign type should never colour the map".
is_operational_only_511_text <- function(text) {
  txt <- tolower(trimws(as.character(text %||% "")))
  if (!nzchar(txt)) return(FALSE)
  ops_kw <- "flex lane|hov[- ]?lane|managed lane|express lane|ramp meter|ramp metering|toll plaza|park.{0,10}ride|special event traffic"
  safety_kw <- "crash|incident|disabled|hazmat|fire|jackknife|overturned|washout|sinkhole|bridge collapse|flood|ice|snow|fog|slippery|winter|blowing|reduced visibility"
  grepl(ops_kw, txt, perl = TRUE) && !grepl(safety_kw, txt, perl = TRUE)
}


# Why: a defensive boundary that strips any legacy travel-delay text
# from a per-zip transport reason vector before it leaves
# compute_511_zip_transport_risk or before it's read back from a
# persisted external bundle, so the score / reason pair handed to
# build_modeled_road_risk_index can never mention pure congestion.
# What: returns reason_text with NA_character_ in every position where
# is_travel_delay_reason matched, all other entries unchanged. Names()
# are preserved so per-zip lookups (`out_reasons["53713"]`) keep working.
# How: as.character coerces the input (which might arrive as a factor
# or named numeric); names() are explicitly re-attached because
# as.character() strips them on named character vectors. Then the
# travel-delay positions are masked to NA via is_travel_delay_reason.
# When: called at the end of compute_511_zip_transport_risk (compute
# boundary) and inside compute_external_risk_bundle's transport step
# both for the native-mode write and the loaded-from-snapshot read.
# Impact: a stale persisted bundle from before the safety-vs-throughput
# audit can hold travel-delay strings; without this sanitizer those
# strings would resurface every time the bundle was loaded, silently
# painting modeled roads red with no real hazard behind them.
sanitize_transport_reason <- function(reason_text) {
  txt <- as.character(reason_text)
  if (!is.null(names(reason_text))) names(txt) <- names(reason_text)
  txt[is_travel_delay_reason(txt)] <- NA_character_
  txt
}

