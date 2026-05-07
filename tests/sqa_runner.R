# Persistent SQA test runner — bundles all the smoke tests so future
# changes can be validated by running a single file. Lives at
# /tmp/sqa_runner.R; see also /tmp/mutation_test.R for mutation tests.
suppressMessages({source("global.R", chdir = TRUE)})

failures <- character(0)
fail <- function(msg) failures[[length(failures) + 1L]] <<- msg

cat("=== FLOWS SQA test runner ===\n\n")

# 1. Function presence
expected <- c("score_511_winter_status","score_511_event_risk","score_511_alert_risk",
              "score_511_message_sign_risk","is_operational_only_511_text",
              "is_travel_delay_reason","sanitize_transport_reason",
              "is_nontrivial_string","parse_iso_time","compute_511_zip_transport_risk",
              "compute_511_road_proximity_signal","compute_511_message_sign_road_signal",
              "compute_511_message_sign_zip_signal","compute_511_alert_zip_signal",
              "build_511_roads_overlay","fetch_511_winter_roads_live",
              "fetch_511_events_live","fetch_511_alerts_live",
              "fetch_511_message_signs_live","build_modeled_road_risk_index",
              "build_driving_roads_overlay","compute_driving_risk",
              "build_risk_polygons","build_route_segments","adjusted_route_speed_mph",
              "risk_label_from_score","risk_rgb_hex")
missing <- expected[!sapply(expected, exists)]
if (length(missing) > 0) fail(sprintf("missing functions: %s", paste(missing, collapse=", ")))
cat(sprintf("[1] Function presence: %d / %d expected functions found\n", length(expected) - length(missing), length(expected)))

# 2. Removed-function absence
removed <- c("score_511_travel_delay","fetch_511_travel_times_live",
             "linestring_sfc_from_waypoints","environmental_risk_equation_text",
             "coords_to_linestring_matrix","find_nearest_route_node",
             "route_distance_miles","risk_label_rank","route_request_span_miles",
             "flows_timing_clear")
present <- removed[sapply(removed, exists)]
if (length(present) > 0) fail(sprintf("dead functions reappeared: %s", paste(present, collapse=", ")))
cat(sprintf("[2] Dead-code absence: %d / %d removed functions correctly absent\n", length(removed) - length(present), length(removed)))

# 3. Safety-vs-throughput discipline
ops_inputs <- c("FLEX LANE CLOSED TO TRAFFIC", "RAMP METERING ACTIVE",
                "HOV LANE CLOSED", "EXPRESS LANE CLOSED", "TOLL PLAZA CASH ONLY",
                "PARK AND RIDE FULL", "SPECIAL EVENT TRAFFIC AHEAD")
for (s in ops_inputs) {
  v <- score_511_message_sign_risk(s)
  if (v > 0) fail(sprintf("operational sign scored %.2f (>0): %s", v, s))
}
cat(sprintf("[3] Operational-only sign scores: %d / %d correctly = 0\n",
            length(ops_inputs) - sum(sapply(ops_inputs, function(s) score_511_message_sign_risk(s) > 0)),
            length(ops_inputs)))

# 4. Real safety hazards rise above threshold
safety_inputs <- list(
  list("ROAD CLOSED USE DETOUR", 0.85),
  list("HAZMAT SPILL", 0.90),
  list("CRASH AHEAD MILE 200", 0.55),
  list("ICY ROAD CONDITIONS", 0.50),
  list("TORNADO WATCH IN EFFECT", 0.85),
  list("BLOWING SNOW REDUCED VISIBILITY", 0.50)
)
n_pass <- 0
for (it in safety_inputs) {
  v <- score_511_message_sign_risk(it[[1]])
  if (v >= it[[2]]) n_pass <- n_pass + 1L
  else fail(sprintf("safety hazard scored %.2f, expected >= %.2f: %s", v, it[[2]], it[[1]]))
}
cat(sprintf("[4] Safety-hazard signs surface: %d / %d above floor\n", n_pass, length(safety_inputs)))

# 5. Sanitizer name preservation
v <- setNames(c("a", "511WI travel delay elevated risk by 5.0 minutes over normal.", "b"),
              c("z1","z2","z3"))
s <- sanitize_transport_reason(v)
if (is.null(names(s)) || !identical(names(s), names(v))) fail("sanitize_transport_reason lost names()")
if (!is.na(s["z2"]) || s["z1"] != "a" || s["z3"] != "b") fail("sanitize_transport_reason wrong values")
cat("[5] Sanitizer preserves names + filters travel-delay correctly\n")

# 6. is_nontrivial_string handles NA
v <- is_nontrivial_string(c("a", NA, "", "  ", "x"))
if (!identical(v, c(TRUE, FALSE, FALSE, FALSE, TRUE))) fail(sprintf("is_nontrivial_string wrong: %s", paste(v, collapse=",")))
cat("[6] is_nontrivial_string handles NA + whitespace\n")

# 7. parse_iso_time handles colonized offset
p <- parse_iso_time("2026-05-05T05:00:00-05:00")
if (!identical(format(p, tz="UTC"), "2026-05-05 10:00:00")) fail("parse_iso_time wrong on -05:00 offset")
cat("[7] parse_iso_time handles ISO-8601 offsets\n")

# 8. risk_label boundary
v <- risk_label_from_score(c(0.397, 0.398, 0.399, 0.698, 0.699, 0.875, 0.876))
expected_lbl <- c("Transparent","Green","Green","Green","Yellow","Yellow","Red")
if (!identical(v, expected_lbl)) fail(sprintf("risk_label boundary wrong: %s", paste(v, collapse=",")))
cat("[8] risk_label boundaries align with thresholds\n")

cat("\n=== Summary ===\n")
if (length(failures) == 0) {
  cat("All 8 SQA suites PASSED.\n")
} else {
  cat(sprintf("FAILED: %d issues\n", length(failures)))
  for (f in failures) cat("  - ", f, "\n")
  quit(status = 1)
}
