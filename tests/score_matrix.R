suppressMessages({source("global.R", chdir = TRUE)})

cat("====== score_511_winter_status (winter conditions are inherently safety-relevant) ======\n")
ws <- c("Closed","Travel Not Advised","Ice Covered","Partly Ice Covered","Snow Covered",
        "Slippery","Wet","Drifting Snow","Normal","Clear","Good","Unknown",NA,"")
for (s in ws) {
  cat(sprintf("  %5.2f  %s\n", score_511_winter_status(s), if (is.na(s)) "<NA>" else if (!nzchar(s)) "<empty>" else s))
}

cat("\n====== score_511_message_sign_risk (operational-only must be 0) ======\n")
ms <- c(
  # Operational-only (expected 0):
  "FLEX LANE CLOSED TO TRAFFIC","FLEX LANE OPEN","HOV LANE CLOSED",
  "EXPRESS LANE CLOSED FOR MAINT","RAMP METERING ACTIVE","TOLL PLAZA CASH ONLY",
  "PARK AND RIDE FULL","SPECIAL EVENT TRAFFIC AHEAD",
  # Throughput-only (expected 0 or 0.18 below threshold):
  "EXPECT DELAYS","SLOW MOVING TRAFFIC","TRAVEL TIME 25 MIN",
  # Real safety hazards (expected >= 0.58):
  "ROAD CLOSED USE DETOUR","HIGHWAY CLOSED FLOODING","INTERSTATE CLOSED CRASH",
  "ALL LANES CLOSED HAZMAT SPILL","CRASH AHEAD MILE 200","DISABLED VEHICLE",
  "OVERTURNED TRUCK","ICY ROAD CONDITIONS","BLACK ICE","SNOW COVERED",
  "BLOWING SNOW REDUCED VISIBILITY","FOG ADVISORY","TRAFFIC SIGNAL OUT",
  "JACKKNIFE","BRIDGE COLLAPSE","SINKHOLE",
  # Safety mixed with operational (expected: safety wins):
  "FLEX LANE CLOSED CRASH AHEAD","HOV LANE - HAZMAT SPILL DETOUR",
  # Public-safety alerts unrelated to driving (expected: filtered):
  "AMBER ALERT 1234XYZ","SILVER ALERT","DRIVE SAFELY HOLIDAY WEEKEND",
  # Edge cases:
  "","NO_MESSAGE",NA
)
for (m in ms) {
  v <- score_511_message_sign_risk(m)
  flag <- if (v >= 0.875) "RED" else if (v >= 0.699) "YELLOW" else if (v >= 0.398) "GREEN" else if (v >= 0.20) ".kept" else "filtered"
  cat(sprintf("  %5.2f  %-9s  %s\n", v, flag, if (is.na(m)) "<NA>" else if (!nzchar(m)) "<empty>" else m))
}

cat("\n====== score_511_event_risk (events feed) ======\n")
ev <- list(
  list(d="Flex lane closed to traffic", c=FALSE, sev=""),
  list(d="Ramp closed for ramp metering", c=FALSE, sev=""),
  list(d="Special event traffic - State Fair", c=FALSE, sev="major"),
  list(d="Crash on shoulder", c=FALSE, sev="medium"),
  list(d="Construction zone, lane shift", c=FALSE, sev="low"),
  list(d="Flood conditions, road impassable", c=FALSE, sev="severe"),
  list(d="I-94 EB ALL LANES CLOSED CRASH", c=TRUE, sev="severe"),
  list(d="Disabled vehicle on shoulder", c=FALSE, sev="minor"),
  list(d="Hazmat spill", c=FALSE, sev=""),
  list(d="Bridge collapse on US-12", c=TRUE, sev=""),
  list(d="Roadwork - shoulder closed", c=FALSE, sev=""),
  list(d="Reduced to one lane for paving", c=FALSE, sev=""),
  list(d="Generic event with severity major", c=FALSE, sev="major"),
  list(d="", c=FALSE, sev="")
)
for (e in ev) {
  v <- score_511_event_risk(description=e$d, severity=e$sev, is_full_closure=e$c)
  flag <- if (v >= 0.875) "RED" else if (v >= 0.699) "YELLOW" else if (v >= 0.398) "GREEN" else if (v >= 0.20) ".kept" else "filtered"
  cat(sprintf("  %5.2f  %-9s  %s%s%s\n", v, flag,
              if (!nzchar(e$d)) "<empty>" else e$d,
              if (e$c) " [full_closure]" else "",
              if (nzchar(e$sev)) sprintf(" sev=%s", e$sev) else ""))
}

cat("\n====== score_511_alert_risk (text alert feed) ======\n")
al <- list(
  list(m="Park entrance closed for maintenance", n="", h=FALSE),
  list(m="Special event traffic on Park Ave", n="", h=FALSE),
  list(m="HOV lane will be closed Saturday", n="", h=TRUE),
  list(m="FLEX LANE CLOSED OFF-PEAK", n="", h=FALSE),
  list(m="I-94 closed eastbound flooding", n="Use detour via Hwy 12", h=TRUE),
  list(m="Crash with injuries near exit 309", n="", h=FALSE),
  list(m="Severe weather alert - tornado watch", n="", h=TRUE),
  list(m="Roadwork construction maintenance ongoing", n="", h=FALSE),
  list(m="Disabled vehicle blocking lane", n="", h=FALSE),
  list(m="Travel times will increase due to event", n="", h=FALSE),
  list(m="Restriction in effect", n="", h=FALSE),
  list(m="", n="", h=FALSE)
)
for (a in al) {
  v <- score_511_alert_risk(message=a$m, notes=a$n, high_importance=a$h)
  flag <- if (v >= 0.875) "RED" else if (v >= 0.699) "YELLOW" else if (v >= 0.398) "GREEN" else if (v >= 0.20) ".kept" else "filtered"
  cat(sprintf("  %5.2f  %-9s  %s%s%s\n", v, flag,
              if (!nzchar(a$m)) "<empty>" else a$m,
              if (nzchar(a$n)) paste0(" | ", a$n) else "",
              if (a$h) " [high]" else ""))
}

cat("\n====== is_operational_only_511_text ======\n")
ops <- c("FLEX LANE CLOSED","HOV LANE CLOSED","ramp metering active",
         "Express lane closed for paving","Toll plaza cash only","Park-and-ride lot full",
         "Special event traffic management","FLEX LANE CRASH AHEAD","CRASH ON I-94",
         "Slippery road conditions","")
for (o in ops) cat(sprintf("  %-5s  %s\n", is_operational_only_511_text(o), if (!nzchar(o)) "<empty>" else o))
