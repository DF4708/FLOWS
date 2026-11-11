# Collapse archive rows to one event each, then print how long events ran.
# usage: awk -F, -f events.awk file.csv...   (output: one line per event)
# out: phen.sig <TAB> hours <TAB> zones <TAB> flood severity <TAB> year
function days(y, m, d) { # days from civil, proleptic Gregorian
  if (m <= 2) { y--; m += 12 }
  return 365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d
}
function mins(s) { # "YYYY-MM-DD HH:MM"
  if (length(s) < 16) return -1
  return days(substr(s, 1, 4) + 0, substr(s, 6, 2) + 0, substr(s, 9, 2) + 0) * 1440 \
    + substr(s, 12, 2) * 60 + substr(s, 15, 2)
}
FNR == 1 { next }
{
  k = $1 "|" $6 "." $8 "|" $9 "|" $NF
  a = mins($2); b = mins($3)
  if (a < 0 || b < 0) next
  if (!(k in lo) || a < lo[k]) lo[k] = a
  if (!(k in hi) || b > hi[k]) hi[k] = b
  if (!((k, $11) in seen)) { seen[k, $11] = 1; n[k]++ }
  if ($15 != "" && $15 != "None") sev[k] = $15
  ps[k] = $6 "." $8; yr[k] = $NF
}
END {
  for (k in lo) {
    h = (hi[k] - lo[k]) / 60
    if (h <= 0) continue
    printf "%s\t%.2f\t%d\t%s\t%s\n", ps[k], h, n[k], (k in sev) ? sev[k] : "-", yr[k]
  }
}
