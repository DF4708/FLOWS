// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Every data table shipped inside the app has a line in
//! `scripts/tables/TABLES.tsv`: the day its source was last fetched, the
//! oldest it may get, and its checksum. This test holds three things:
//!
//! * no table is older than its limit (a stale airport or transit list
//!   sends a traveller to a service that is gone);
//! * no table changed without a new stamp (the checksum must match, so a
//!   date can never describe other bytes);
//! * no table is missing from the list (a new `*_table.rs` in flows-core or
//!   a new data file in the app's Resources fails until it is listed).
//!
//! `FLOWS_TABLE_WARN_DAYS=N` fails N days early. The weekly scheduled check
//! sets it, so a refresh is asked for before the limit blocks a landing.
//! Refresh with `scripts/tables/refresh.sh`; stamp with
//! `scripts/tables/stamp.sh`.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const LIST: &str = "scripts/tables/TABLES.tsv";

/// Generated from the Swift runtime, not from a dated source: it changes
/// with the toolchain, and `swift_text_tables.rs` already fails on drift.
const NOT_DATED: &[&str] = &["rust/flows-core/src/swift_text/tables.rs"];

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repository root")
}

struct Row {
    path: String,
    built_day: i64,
    max_days: i64,
    /// Checksum and byte count, or `None` for a table inside a hand-edited
    /// file.
    sum: Option<(u32, u64)>,
}

/// Days since 1970-01-01 for a civil date (proleptic Gregorian).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// `YYYY-MM-DD`, a real calendar day.
fn parse_day(text: &str) -> Option<i64> {
    let mut parts = text.split('-');
    let y: i64 = parts.next()?.parse().ok()?;
    let m: i64 = parts.next()?.parse().ok()?;
    let d: i64 = parts.next()?.parse().ok()?;
    if parts.next().is_some() || text.len() != 10 || !(1..=12).contains(&m) {
        return None;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let last = match m {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    };
    (1..=last).contains(&d).then(|| days_from_civil(y, m, d))
}

/// The POSIX `cksum` of a byte string: CRC-32 (polynomial 0x04C11DB7, high
/// bit first) over the bytes, then over the length, low byte first, then
/// complemented.
fn posix_cksum(bytes: &[u8]) -> u32 {
    let mut table = [0u32; 256];
    for (i, slot) in table.iter_mut().enumerate() {
        let mut c = (i as u32) << 24;
        for _ in 0..8 {
            c = if c & 0x8000_0000 != 0 {
                (c << 1) ^ 0x04C1_1DB7
            } else {
                c << 1
            };
        }
        *slot = c;
    }
    let step = |crc: u32, b: u8| (crc << 8) ^ table[((crc >> 24) as u8 ^ b) as usize];
    let mut crc = bytes.iter().fold(0u32, |crc, b| step(crc, *b));
    let mut len = bytes.len() as u64;
    while len != 0 {
        crc = step(crc, (len & 0xFF) as u8);
        len >>= 8;
    }
    !crc
}

fn parse_list(text: &str) -> Result<Vec<Row>, String> {
    let mut rows = Vec::new();
    for (n, line) in text.lines().enumerate() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let at = |what: &str| format!("{LIST} line {}: {what}", n + 1);
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() != 7 {
            return Err(at("needs 7 tab-separated columns"));
        }
        if f.iter().any(|c| c.trim().is_empty() || c.trim() != *c) {
            return Err(at("has an empty or padded column"));
        }
        let built_day = parse_day(f[1]).ok_or_else(|| at("built is not YYYY-MM-DD"))?;
        let max_days: i64 = f[2].parse().map_err(|_| at("max_days is not a number"))?;
        if !(1..=1100).contains(&max_days) {
            return Err(at("max_days must be 1 to 1100"));
        }
        let sum = match (f[3], f[4]) {
            ("-", "-") => None,
            (c, b) => Some((
                c.parse().map_err(|_| at("cksum is not a number"))?,
                b.parse().map_err(|_| at("bytes is not a number"))?,
            )),
        };
        if rows.iter().any(|r: &Row| r.path == f[0]) {
            return Err(at("lists a path twice"));
        }
        rows.push(Row {
            path: f[0].to_string(),
            built_day,
            max_days,
            sum,
        });
    }
    Ok(rows)
}

fn today() -> i64 {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock is after 1970")
        .as_secs();
    (secs / 86_400) as i64
}

/// What is wrong with one row on day `today`, failing `early` days before
/// the limit.
fn check_row(row: &Row, bytes: Option<&[u8]>, today: i64, early: i64) -> Vec<String> {
    let mut found = Vec::new();
    let Some(bytes) = bytes else {
        return vec![format!("{}: listed, but the file cannot be read", row.path)];
    };
    if let Some((sum, len)) = row.sum {
        if (posix_cksum(bytes), bytes.len() as u64) != (sum, len) {
            found.push(format!(
                "{}: changed since it was stamped; run scripts/tables/stamp.sh {} <day its source was fetched>",
                row.path, row.path
            ));
        }
    }
    let age = today - row.built_day;
    // A day of slack: the stamp is a local date, the clock here is UTC.
    if age < -1 {
        found.push(format!("{}: built date is in the future", row.path));
    }
    if age > row.max_days - early {
        found.push(format!(
            "{}: {age} days old, limit {} (checked {early} days early); refresh it (see {LIST})",
            row.path, row.max_days
        ));
    }
    found
}

/// Every table that must have a row: `*_table.rs` and `tables.rs` anywhere
/// under flows-core's sources, and each data file at the top of the app's
/// Resources.
fn tables_that_must_be_listed(root: &Path) -> Vec<String> {
    fn walk(dir: &Path, root: &Path, out: &mut Vec<String>) {
        let entries = std::fs::read_dir(dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
        for entry in entries {
            let path = entry.expect("directory entry").path();
            if path.is_dir() {
                walk(&path, root, out);
                continue;
            }
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if name.ends_with("_table.rs") || name == "tables.rs" {
                let rel = path.strip_prefix(root).expect("under the root");
                out.push(rel.to_string_lossy().into_owned());
            }
        }
    }
    let mut out = Vec::new();
    walk(&root.join("rust/flows-core/src"), root, &mut out);
    let resources = root.join("apple/FLOWS/Resources");
    let entries =
        std::fs::read_dir(&resources).unwrap_or_else(|e| panic!("{}: {e}", resources.display()));
    for entry in entries {
        let path = entry.expect("directory entry").path();
        let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
        if path.is_file() && matches!(ext, "json" | "frb1" | "tsv" | "csv" | "bin" | "plist") {
            let rel = path.strip_prefix(root).expect("under the root");
            out.push(rel.to_string_lossy().into_owned());
        }
    }
    out.retain(|p| !NOT_DATED.contains(&p.as_str()));
    out.sort();
    out
}

#[test]
fn every_table_is_listed_unchanged_and_fresh() {
    let root = repo();
    let text = std::fs::read_to_string(root.join(LIST)).expect("the table list");
    let rows = parse_list(&text).unwrap_or_else(|e| panic!("{e}"));
    let early: i64 = match std::env::var("FLOWS_TABLE_WARN_DAYS") {
        Ok(v) => v
            .parse()
            .expect("FLOWS_TABLE_WARN_DAYS is a number of days"),
        Err(_) => 0,
    };
    assert!(
        (0..=365).contains(&early),
        "FLOWS_TABLE_WARN_DAYS: 0 to 365"
    );
    let now = today();
    let mut found = Vec::new();
    for row in &rows {
        let bytes = std::fs::read(root.join(&row.path)).ok();
        found.extend(check_row(row, bytes.as_deref(), now, early));
    }
    for path in tables_that_must_be_listed(&root) {
        if !rows.iter().any(|r| r.path == path) {
            found.push(format!(
                "{path}: a data table with no line in {LIST}; add one with scripts/tables/stamp.sh"
            ));
        }
    }
    for path in NOT_DATED {
        assert!(root.join(path).is_file(), "{path}: exempt, but not there");
    }
    assert!(found.is_empty(), "data tables:\n{}", found.join("\n"));
}

#[test]
fn the_checksum_is_the_posix_one() {
    // `printf '' | cksum` and `printf 123456789 | cksum`.
    assert_eq!(posix_cksum(b""), 4_294_967_295);
    assert_eq!(posix_cksum(b"123456789"), 930_766_865);
}

#[test]
fn days_are_counted_on_the_real_calendar() {
    assert_eq!(parse_day("1970-01-01"), Some(0));
    assert_eq!(parse_day("2000-03-01"), Some(11_017));
    assert_eq!(parse_day("2024-02-29"), Some(19_782));
    assert_eq!(parse_day("2026-11-11"), Some(20_768));
    for bad in [
        "2025-02-29",
        "2026-13-01",
        "2026-00-10",
        "2026-4-01",
        "2026-04-31",
        "x",
    ] {
        assert_eq!(parse_day(bad), None, "{bad}");
    }
}

#[test]
fn a_stale_changed_or_missing_table_is_caught() {
    let bytes = b"table";
    let row = |built: &str, max_days| Row {
        path: "t".into(),
        built_day: parse_day(built).unwrap(),
        max_days,
        sum: Some((posix_cksum(bytes), 5)),
    };
    let day = parse_day("2026-11-11").unwrap();
    assert!(check_row(&row("2026-08-13", 90), Some(bytes), day, 0).is_empty());
    // One day past the limit.
    assert_eq!(
        check_row(&row("2026-08-12", 90), Some(bytes), day, 0).len(),
        1
    );
    // Inside the limit, but inside the early-warning window too.
    assert_eq!(
        check_row(&row("2026-08-13", 90), Some(bytes), day, 14).len(),
        1
    );
    // Other bytes under the same stamp, a file that is gone, a future date.
    assert_eq!(
        check_row(&row("2026-11-01", 90), Some(b"tablE"), day, 0).len(),
        1
    );
    assert_eq!(check_row(&row("2026-11-01", 90), None, day, 0).len(), 1);
    assert_eq!(
        check_row(&row("2026-11-20", 90), Some(bytes), day, 0).len(),
        1
    );
    // The list itself: a bad date, a missing column, a path given twice.
    assert!(parse_list("a\t2026-02-30\t9\t-\t-\tr\ts\n").is_err());
    assert!(parse_list("a\t2026-02-03\t9\t-\tr\ts\n").is_err());
    assert!(parse_list("a\t2026-02-03\t9\t-\t-\tr\ts\na\t2026-02-03\t9\t-\t-\tr\ts\n").is_err());
    assert_eq!(
        parse_list("# note\na\t2026-02-03\t9\t1\t2\tr\ts\n")
            .unwrap()
            .len(),
        1
    );
}
