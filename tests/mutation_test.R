# Mutation testing harness for the FLOWS code base.
#
# Approach: pick a target function, swap its body for a perturbed version
# (mutant), run our smoke-test oracles, and assert at least one fails.
# Each surviving mutant flags a gap in the test coverage.
#
# This isn't a generic mutation framework — it's a targeted set of
# semantic mutations on the safety-critical scoring + sanitizer
# functions, where a regression would directly affect what users see.
suppressMessages({source("global.R", chdir = TRUE)})
options(warn = -1)

results <- list()
record <- function(name, killed, detail = "") {
  results[[length(results) + 1L]] <<- list(name = name, killed = killed, detail = detail)
  cat(sprintf("  %s  %s%s\n", if (killed) "KILLED" else "SURVIVED",
              name, if (nzchar(detail)) sprintf("  [%s]", detail) else ""))
}

# ----- Oracle suite: small set of fixed test inputs and expected
# behaviors. Each oracle returns TRUE on PASS (mutation NOT killed) or
# FALSE on FAIL (mutation killed). A mutant is "killed" if AT LEAST ONE
# oracle fails on it. -----
oracle_message_sign <- function() {
  # Operational-only must score 0; real safety must score >= 0.58.
  v <- c(
    score_511_message_sign_risk("FLEX LANE CLOSED TO TRAFFIC"),
    score_511_message_sign_risk("RAMP METERING ACTIVE"),
    score_511_message_sign_risk("HOV LANE CLOSED")
  )
  if (any(v > 0)) return(FALSE)
  v2 <- c(
    score_511_message_sign_risk("ROAD CLOSED USE DETOUR"),
    score_511_message_sign_risk("HAZMAT SPILL"),
    score_511_message_sign_risk("CRASH AHEAD")
  )
  if (any(v2 < 0.58)) return(FALSE)
  TRUE
}
oracle_event <- function() {
  if (score_511_event_risk("Flex lane closed to traffic") > 0) return(FALSE)
  if (score_511_event_risk("Bridge collapse on US-12", is_full_closure = TRUE) < 0.95) return(FALSE)
  if (score_511_event_risk("") > 0) return(FALSE)
  TRUE
}
oracle_alert <- function() {
  if (score_511_alert_risk("FLEX LANE CLOSED OFF-PEAK") > 0) return(FALSE)
  if (score_511_alert_risk("I-94 closed eastbound flooding", "", high_importance = TRUE) < 0.85) return(FALSE)
  if (score_511_alert_risk("Park reopened next week") > 0) return(FALSE)
  TRUE
}
oracle_sanitize <- function() {
  if (!is.na(sanitize_transport_reason("511WI travel delay elevated risk by 5.0 minutes over normal."))) return(FALSE)
  if (is.na(sanitize_transport_reason("CRASH AHEAD"))) return(FALSE)
  # Names preserved
  v <- setNames(c("a", "511WI travel delay elevated risk by 5.0 minutes over normal.", "b"),
                c("z1", "z2", "z3"))
  s <- sanitize_transport_reason(v)
  if (is.null(names(s)) || !identical(names(s), names(v))) return(FALSE)
  if (!is.na(s["z2"]) || s["z1"] != "a" || s["z3"] != "b") return(FALSE)
  TRUE
}
oracle_is_op_only <- function() {
  if (!is_operational_only_511_text("flex lane closed")) return(FALSE)
  if (is_operational_only_511_text("flex lane closed crash ahead")) return(FALSE)
  if (is_operational_only_511_text("crash ahead")) return(FALSE)
  TRUE
}
oracle_is_travel_delay <- function() {
  if (!is_travel_delay_reason("511WI travel delay elevated risk by 5 minutes over normal")) return(FALSE)
  if (is_travel_delay_reason("CRASH AHEAD")) return(FALSE)
  if (is_travel_delay_reason(NA_character_)) return(FALSE)
  TRUE
}
oracle_risk_label <- function() {
  # Boundary values: 0.398 is RISK_GREEN_MIN exactly, 0.399 just above.
  # Without these, an off-by-one mutation (e.g., move threshold to 0.4)
  # passes — every value used to be far from the boundary.
  v <- risk_label_from_score(c(0.1, 0.398, 0.399, 0.5, 0.7, 0.9, NA))
  identical(v, c("Transparent", "Green", "Green", "Green", "Yellow", "Red", "Transparent"))
}
oracle_risk_rgb <- function() {
  v <- risk_rgb_hex(c(0.1, 0.5, 0.7, 0.9))
  identical(v, c("transparent", "#2ecc71", "#f1c40f", "#dc3545"))
}
oracle_is_nontrivial_string <- function() {
  v <- is_nontrivial_string(c("a", NA, "", "  ", "x"))
  identical(v, c(TRUE, FALSE, FALSE, FALSE, TRUE))
}

oracles <- list(
  message_sign = oracle_message_sign,
  event = oracle_event,
  alert = oracle_alert,
  sanitize = oracle_sanitize,
  is_op_only = oracle_is_op_only,
  is_travel_delay = oracle_is_travel_delay,
  risk_label = oracle_risk_label,
  risk_rgb = oracle_risk_rgb,
  is_nontrivial = oracle_is_nontrivial_string
)

cat("Sanity: oracles all PASS on the unmodified codebase:\n")
for (nm in names(oracles)) {
  res <- tryCatch(oracles[[nm]](), error = function(e) FALSE)
  cat(sprintf("  %s: %s\n", nm, if (isTRUE(res)) "PASS" else "FAIL"))
}

run_oracles <- function() {
  any_failed <- FALSE
  for (nm in names(oracles)) {
    ok <- tryCatch(oracles[[nm]](), error = function(e) FALSE)
    if (!isTRUE(ok)) any_failed <- TRUE
  }
  any_failed
}

with_mutation <- function(name, fn_name, mutated_fn) {
  cat(sprintf("\nMutation: %s\n", name))
  original <- get(fn_name, envir = .GlobalEnv)
  assign(fn_name, mutated_fn, envir = .GlobalEnv)
  on.exit(assign(fn_name, original, envir = .GlobalEnv), add = TRUE)
  killed <- run_oracles()
  record(name, killed)
}

cat("\n=== Mutation tests ===\n")

# M1: invert is_operational_only_511_text return value
with_mutation("invert is_operational_only_511_text", "is_operational_only_511_text",
              function(text) {
                txt <- tolower(trimws(as.character(text %||% "")))
                if (!nzchar(txt)) return(FALSE)
                ops_kw <- "flex lane|hov[- ]?lane|managed lane|express lane|ramp meter|ramp metering|toll plaza|park.{0,10}ride|special event traffic"
                safety_kw <- "crash|incident|disabled|hazmat|fire|jackknife|overturned|washout|sinkhole|bridge collapse|flood|ice|snow|fog|slippery|winter|blowing|reduced visibility"
                !(grepl(ops_kw, txt, perl = TRUE) && !grepl(safety_kw, txt, perl = TRUE))
              })

# M2: drop "flex lane" from operational keywords
with_mutation("drop flex lane from operational keywords", "is_operational_only_511_text",
              function(text) {
                txt <- tolower(trimws(as.character(text %||% "")))
                if (!nzchar(txt)) return(FALSE)
                ops_kw <- "hov[- ]?lane|managed lane|express lane|ramp meter|ramp metering|toll plaza|park.{0,10}ride|special event traffic"
                safety_kw <- "crash|incident|disabled|hazmat|fire|jackknife|overturned|washout|sinkhole|bridge collapse|flood|ice|snow|fog|slippery|winter|blowing|reduced visibility"
                grepl(ops_kw, txt, perl = TRUE) && !grepl(safety_kw, txt, perl = TRUE)
              })

# M3: skip safety carve-out (operational-only always wins, even when safety mentioned)
with_mutation("skip safety carve-out in is_operational_only", "is_operational_only_511_text",
              function(text) {
                txt <- tolower(trimws(as.character(text %||% "")))
                if (!nzchar(txt)) return(FALSE)
                grepl("flex lane|hov[- ]?lane|managed lane|express lane|ramp meter|ramp metering|toll plaza|park.{0,10}ride|special event traffic", txt, perl = TRUE)
              })

# M4: sanitize forgets to preserve names
with_mutation("sanitize loses names()", "sanitize_transport_reason",
              function(reason_text) {
                txt <- as.character(reason_text)  # strips names
                txt[is_travel_delay_reason(txt)] <- NA_character_
                txt
              })

# M5: sanitize matches everything (overcorrects)
with_mutation("sanitize overcorrects to NA always", "sanitize_transport_reason",
              function(reason_text) {
                rep(NA_character_, length(reason_text))
              })

# M6: travel-delay detector returns FALSE always (under-correction)
with_mutation("is_travel_delay always FALSE", "is_travel_delay_reason",
              function(reason_text) rep(FALSE, length(as.character(reason_text))))

# M7: travel-delay detector returns TRUE always
with_mutation("is_travel_delay always TRUE", "is_travel_delay_reason",
              function(reason_text) rep(TRUE, length(as.character(reason_text))))

# M8: message sign scorer drops the operational filter
with_mutation("message-sign drops operational filter", "score_511_message_sign_risk",
              function(message_text = "") {
                txt <- tolower(trimws(safe_string(message_text)))
                if (!nzchar(txt) || identical(txt, "no_message")) return(0)
                # No is_operational_only_511_text check; uses the OLD aggressive matching.
                score <- 0.18
                if (grepl("closed|closure|detour|blocked|do not use|exit closed|ramp closed", txt)) score <- max(score, 0.90)
                if (grepl("flood|washout|bridge|sinkhole|hazmat|fire|jackknife", txt)) score <- max(score, 0.95)
                if (grepl("crash|incident|disabled|lane closed|restriction|delay|congestion|slow traffic", txt)) score <- max(score, 0.60)
                if (grepl("slippery|ice|snow|winter|blowing snow|reduced visibility|fog", txt)) score <- max(score, 0.58)
                pmin(1, score)
              })

# M9: event scorer drops operational filter
with_mutation("event drops operational filter", "score_511_event_risk",
              function(description = "", event_type = "", event_subtype = "", severity = "", lanes_affected = "", is_full_closure = FALSE) {
                text <- tolower(trimws(paste(description, event_type, event_subtype, severity, lanes_affected, collapse = " | ")))
                if (isTRUE(is_full_closure) || grepl("all lanes closed|full closure|closed|closure", text)) return(1.00)
                if (grepl("jackknife|hazmat|fire|washout|bridge|sinkhole|flood", text)) return(0.95)
                if (grepl("accident|crash|incident|overturned|disabled vehicle", text)) return(0.75)
                if (grepl("roadwork|construction|maintenance", text)) return(0.45)
                if (grepl("lane closed|shoulder closed|reduced to", text)) return(0.40)
                0.20
              })

# M10: alert scorer reverts to old default 0.20
with_mutation("alert default 0.20", "score_511_alert_risk",
              function(message = "", notes = "", high_importance = FALSE, send_notification = FALSE) {
                text <- tolower(trimws(paste(message, notes, collapse = " | ")))
                if (!nzchar(text)) return(0)
                # Default 0.20 means EVERY alert with any text passes WI511_MIN_RISK_THRESHOLD
                pmin(1, 0.20)
              })

# M11: risk_label_from_score off-by-one threshold (Green starts at 0.4, not 0.398)
with_mutation("risk_label off-by-one threshold", "risk_label_from_score",
              function(score) {
                s <- suppressWarnings(as.numeric(score))
                out <- rep("Transparent", length(s))
                finite <- is.finite(s)
                out[finite & s >= 0.4 & s < RISK_YELLOW_MIN] <- "Green"
                out[finite & s >= RISK_YELLOW_MIN & s <= RISK_RED_MIN] <- "Yellow"
                out[finite & s > RISK_RED_MIN] <- "Red"
                out
              })

# M12: risk_rgb_hex uses transparent for everything
with_mutation("risk_rgb_hex always transparent", "risk_rgb_hex",
              function(score) rep("transparent", length(score)))

# M13: is_nontrivial_string returns nzchar(NA) leak
with_mutation("is_nontrivial leaks NA", "is_nontrivial_string",
              function(x) {
                s <- trimws(as.character(x %||% ""))
                if (length(s) == 0L) return(FALSE)
                nzchar(s)  # may return NA on this R install
              })

cat("\n=== Summary ===\n")
killed <- sum(vapply(results, function(r) isTRUE(r$killed), logical(1)))
total <- length(results)
cat(sprintf("Mutations killed: %d / %d\n", killed, total))
if (killed < total) {
  cat("\nSurviving mutants (test gaps):\n")
  for (r in results) if (!isTRUE(r$killed)) cat("  -", r$name, "\n")
} else {
  cat("All mutants killed by oracle suite.\n")
}
