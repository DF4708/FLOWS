# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------
#
# R/region_config.R — geographic region registry for the CONUS expansion.
#
# This is the seam that lets FLOWS grow from Wisconsin-only to multi-state
# without hardcoding "WI" / "55" throughout the codebase. The DEFAULT
# active region is Wisconsin, so every downstream constant resolves
# identically to the pre-refactor values — the Wisconsin baseline is
# behaviour-neutral. Phase 1 of the CONUS expansion widens ACTIVE_REGION
# to include border states; the registry is the single place that changes.
#
# See docs/CONUS_EXPANSION.md §1.1 for the full list of Wisconsin-hardcoded
# constants this generalises.

# Why: the state FIPS <-> USPS <-> name mapping is needed in several places
# (alert area codes, Census download URLs, RadNet station filters). One
# authoritative table beats scattering the crosswalk across modules.
# What: a data.frame with columns fips, usps, name for the 50 states + DC.
# How: a literal table; small enough to inline, stable enough to never
# need a network fetch.
# When: read by region-config accessors at source time and by any module
# that needs to translate between FIPS / USPS / name forms.
# Impact: the authoritative crosswalk; a typo here silently mis-targets an
# entire state's feeds, so it mirrors the Census STATE FIPS reference.
US_STATE_CROSSWALK <- data.frame(
  fips = c("01","02","04","05","06","08","09","10","11","12","13","15","16",
           "17","18","19","20","21","22","23","24","25","26","27","28","29",
           "30","31","32","33","34","35","36","37","38","39","40","41","42",
           "44","45","46","47","48","49","50","51","53","54","55","56"),
  usps = c("AL","AK","AZ","AR","CA","CO","CT","DE","DC","FL","GA","HI","ID",
           "IL","IN","IA","KS","KY","LA","ME","MD","MA","MI","MN","MS","MO",
           "MT","NE","NV","NH","NJ","NM","NY","NC","ND","OH","OK","OR","PA",
           "RI","SC","SD","TN","TX","UT","VT","VA","WA","WV","WI","WY"),
  name = c("Alabama","Alaska","Arizona","Arkansas","California","Colorado",
           "Connecticut","Delaware","District of Columbia","Florida","Georgia",
           "Hawaii","Idaho","Illinois","Indiana","Iowa","Kansas","Kentucky",
           "Louisiana","Maine","Maryland","Massachusetts","Michigan","Minnesota",
           "Mississippi","Missouri","Montana","Nebraska","Nevada","New Hampshire",
           "New Jersey","New Mexico","New York","North Carolina","North Dakota",
           "Ohio","Oklahoma","Oregon","Pennsylvania","Rhode Island",
           "South Carolina","South Dakota","Tennessee","Texas","Utah","Vermont",
           "Virginia","Washington","West Virginia","Wisconsin","Wyoming"),
  stringsAsFactors = FALSE
)

# Why: the active region set defines which states' feeds, geometry, and
# routing graph the running instance covers. Defaulting to Wisconsin keeps
# the current behaviour exact while making the code path multi-state.
# What: a character vector of USPS codes. Overridable via the
# FLOWS_ACTIVE_REGION env var (comma-separated USPS codes, or the sentinel
# "CONUS" for the full lower-48 + DC).
# How: reads the env var once at source time; falls back to c("WI").
# When: read by every region accessor below.
# Impact: THE lever for the CONUS expansion. Widening this triggers larger
# reference loads, more feeds, and (past a single region) the hierarchical
# router. Phase gates in docs/TESTING_STRATEGY.md bound each widening.
ACTIVE_REGION <- local({
  raw <- trimws(Sys.getenv("FLOWS_ACTIVE_REGION", "WI"))
  if (!nzchar(raw)) return("WI")
  if (identical(toupper(raw), "CONUS")) {
    return(setdiff(US_STATE_CROSSWALK$usps, c("AK", "HI")))
  }
  codes <- toupper(trimws(unlist(strsplit(raw, ",", fixed = TRUE))))
  codes <- codes[nzchar(codes)]
  valid <- codes[codes %in% US_STATE_CROSSWALK$usps]
  if (length(valid) == 0) c("WI") else valid
})

# Why: modules that build alert-area codes or Census URLs need the FIPS
# form; the crosswalk lookup should be one call, not a repeated match().
# What: returns the FIPS codes (character) for the active region, in the
# order ACTIVE_REGION lists them.
# How: match ACTIVE_REGION USPS codes against the crosswalk.
# When: called by global.R when deriving TARGET_STATE_FIPS and by any
# feed builder that filters by state FIPS.
# Impact: an empty return would break every FIPS-filtered feed; the
# ACTIVE_REGION validation above guarantees at least one valid code.
active_state_fips <- function() {
  idx <- match(ACTIVE_REGION, US_STATE_CROSSWALK$usps)
  US_STATE_CROSSWALK$fips[idx]
}

# Why: the NWS alerts API and several feeds accept a USPS "area" code; a
# single-region instance uses the one code, a multi-region instance
# multiplexes.
# What: returns the primary USPS code (first active region) — preserves the
# scalar TARGET_STATE contract for backward compatibility.
# How: first element of ACTIVE_REGION.
# When: read by global.R to set TARGET_STATE.
# Impact: downstream code that assumed a scalar TARGET_STATE keeps working;
# multi-region alert fanout is a Phase 1 change that reads ACTIVE_REGION
# directly instead of this accessor.
primary_state_usps <- function() ACTIVE_REGION[[1]]

# Why: the primary state's FIPS is the backward-compatible scalar that the
# pre-refactor TARGET_STATE_FIPS held.
# What: returns the first active region's FIPS code (character scalar).
# How: crosswalk lookup on the primary USPS.
# When: read by global.R to set TARGET_STATE_FIPS.
# Impact: preserves the scalar contract; feeds that need ALL active FIPS
# codes call active_state_fips() instead.
primary_state_fips <- function() {
  US_STATE_CROSSWALK$fips[match(primary_state_usps(), US_STATE_CROSSWALK$usps)]
}

# Why: the alert / border config historically listed Wisconsin plus its
# five neighbours. Generalise: the "coverage" FIPS set is the active region
# plus (for a single-state region) its documented neighbours so cross-border
# alerts still land.
# What: returns a character vector of FIPS codes = active region ∪ neighbours.
# How: unions active_state_fips() with a static neighbour table; for a
# multi-state active region the neighbour padding is dropped (the region
# already spans borders).
# When: read by global.R to set BORDER_STATE_FIPS.
# Impact: too small a set drops cross-border alerts near the edge; too large
# a set pulls needless geometry. The WI default reproduces the original
# 5-code list exactly.
coverage_state_fips <- function() {
  active <- active_state_fips()
  if (length(active) > 1L) return(unique(active))
  # Single-state region: pad with documented land neighbours.
  neighbours <- STATE_LAND_NEIGHBOURS[[primary_state_usps()]] %||% character(0)
  neighbour_fips <- US_STATE_CROSSWALK$fips[match(neighbours, US_STATE_CROSSWALK$usps)]
  unique(c(active, neighbour_fips))
}

# Why: coverage_state_fips needs each state's land neighbours to reproduce
# the original Wisconsin border-state list and to pad any future single-state
# region. Only the states we might run single-region need entries today;
# the table grows as regions are added.
# What: a named list mapping USPS -> character vector of neighbour USPS codes.
# How: static adjacency (land borders only). Wisconsin's entry reproduces
# the original BORDER_STATE_FIPS c("55","27","19","17","26") = WI,MN,IA,IL,MI.
# When: read by coverage_state_fips for single-state regions.
# Impact: an incomplete entry drops edge alerts; the WI entry is verified
# against the original hardcoded list in the phase-1 experiment.
STATE_LAND_NEIGHBOURS <- list(
  WI = c("MN", "IA", "IL", "MI"),
  MN = c("WI", "IA", "SD", "ND"),
  IA = c("MN", "WI", "IL", "MO", "NE", "SD"),
  IL = c("WI", "IA", "MO", "KY", "IN"),
  MI = c("WI", "IN", "OH"),
  IN = c("MI", "OH", "KY", "IL"),
  OH = c("MI", "IN", "KY", "WV", "PA")
)

# Why: a human-readable label for the active region set is handy for logs
# and UI headers as the map widens beyond one state.
# What: returns a string like "Wisconsin" (single) or "WI, MN, IA (+3)".
# How: joins the active USPS codes; for one state uses the full name.
# When: informational — logging, future UI headers.
# Impact: cosmetic; never gates behaviour.
active_region_label <- function() {
  if (length(ACTIVE_REGION) == 1L) {
    return(US_STATE_CROSSWALK$name[match(ACTIVE_REGION, US_STATE_CROSSWALK$usps)])
  }
  head_codes <- utils::head(ACTIVE_REGION, 3L)
  extra <- length(ACTIVE_REGION) - length(head_codes)
  paste0(paste(head_codes, collapse = ", "),
         if (extra > 0) sprintf(" (+%d)", extra) else "")
}
