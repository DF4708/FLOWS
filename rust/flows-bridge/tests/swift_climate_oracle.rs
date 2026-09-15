// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for climate and astronomy: 7,450 records produced
//! by the ORIGINAL Swift (ClimateProfiles, LatitudeBands, DaylightClock,
//! HarmonicClimatology, RiskTiming) at commit a007de0, before that math
//! moved to `flows_core::climate`.
//!
//! Three record shapes: explicit records (one input, its output); `set`/`dg`
//! records (named input lists, then an FNV-1a-64 digest over their product,
//! hashed in the order the harness states); `rnd` records (a digest over a
//! SplitMix64 sweep this test regenerates draw for draw). Digests are
//! bit-exact by construction, so every value that feeds one must match the
//! Swift bit for bit; the explicit records carry the tolerances where
//! trigonometry is involved.

use flows_core::climate as cl;
use flows_core::climate::{
    ClimateType, HarmonicTable, Profile, SeasonalNorms, WeekTrig, CLIMATE_TYPES,
};
use std::cmp::Ordering;
use std::collections::BTreeMap;

const BASE_COMMIT: &str = "a007de042d12e736fdd86398e1ea54ca31aadc1f";
/// Hashed where the original trapped.
const TRAPPED: u64 = 0x5452_4150_5045_4421;

// ---- decoding ----

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn i(t: &str) -> i64 {
    t.parse().unwrap_or_else(|_| panic!("bad int {t}"))
}
fn optd(t: &str) -> Option<f64> {
    (t != "-").then(|| d(t))
}
fn s(h: &str) -> String {
    let hex = h
        .strip_prefix("s:")
        .unwrap_or_else(|| panic!("bad string {h}"));
    String::from_utf8(hexbytes(hex)).expect("utf-8")
}
fn hexbytes(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|k| u8::from_str_radix(&hex[k..k + 2], 16).expect("hex byte"))
        .collect()
}
fn bytes(h: &str) -> Vec<u8> {
    hexbytes(
        h.strip_prefix("b:")
            .unwrap_or_else(|| panic!("bad bytes {h}")),
    )
}
fn list(fld: &str) -> Vec<&str> {
    let (head, body) = fld
        .split_once(':')
        .unwrap_or_else(|| panic!("bad list {fld}"));
    let n: usize = head.trim_start_matches('L').parse().expect("list count");
    if n == 0 {
        return Vec::new();
    }
    let v: Vec<&str> = body.split(',').collect();
    assert_eq!(v.len(), n, "list count in {fld}");
    v
}
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn hf(x: f32) -> String {
    format!("{:x}", x.to_bits())
}
fn ohx(x: Option<f64>) -> String {
    x.map(hx).unwrap_or_else(|| "-".into())
}
fn bit(v: bool) -> String {
    u8::from(v).to_string()
}
fn lst(items: &[String]) -> String {
    format!("L{}:{}", items.len(), items.join(","))
}
fn hs_out(t: &str) -> String {
    format!(
        "s:{}",
        t.bytes().map(|c| format!("{c:02x}")).collect::<String>()
    )
}
fn prof_out(p: &Profile) -> String {
    lst(&[
        p.band.to_string(),
        hx(p.comfort_low_f),
        hx(p.comfort_high_f),
        hx(p.record_low_f),
        hx(p.record_high_f),
        hx(p.wind_low),
        hx(p.wind_medium),
        hx(p.wind_high),
        hx(p.pop_low),
        hx(p.pop_medium),
        hx(p.pop_high),
    ])
}
fn norms_out(n: &SeasonalNorms) -> String {
    lst(&[
        hx(n.week_low_f),
        hx(n.week_high_f),
        hx(n.wind_mean_mph),
        hx(n.wind_sigma_mph),
    ])
}
fn norms_in(fld: &str) -> SeasonalNorms {
    let v = list(fld);
    assert_eq!(v.len(), 4);
    SeasonalNorms {
        week_low_f: d(v[0]),
        week_high_f: d(v[1]),
        wind_mean_mph: d(v[2]),
        wind_sigma_mph: d(v[3]),
    }
}
fn code(t: ClimateType) -> String {
    (t as i64).to_string()
}

// ---- the harness's random source and digest ----

struct Sm(u64);
impl Sm {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 * (1.0 / 9_007_199_254_740_992.0)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

/// FNV-1a 64 over little-endian bytes, counting the values hashed.
struct Fnv {
    h: u64,
    n: u64,
}
impl Fnv {
    fn new() -> Fnv {
        Fnv {
            h: 0xcbf2_9ce4_8422_2325,
            n: 0,
        }
    }
    fn byte(&mut self, b: u8) {
        self.h ^= u64::from(b);
        self.h = self.h.wrapping_mul(0x0100_0000_01b3);
    }
    fn u64(&mut self, x: u64) {
        for b in x.to_le_bytes() {
            self.byte(b);
        }
        self.n += 1;
    }
    fn d(&mut self, x: f64) {
        self.u64(x.to_bits());
    }
    fn i(&mut self, x: i64) {
        self.u64(x as u64);
    }
    fn b(&mut self, x: bool) {
        self.u64(u64::from(x));
    }
    fn od(&mut self, x: Option<f64>) {
        match x {
            Some(v) => {
                self.u64(1);
                self.d(v);
            }
            None => self.u64(0),
        }
    }
    fn hex(&self) -> String {
        format!("{:x}", self.h)
    }
}

const SP: [u64; 14] = [
    0x7ff8_0000_0000_0000,
    0xfff8_0000_0000_0000,
    0x7ff0_0000_0000_0001,
    0x7ff0_0000_0000_0000,
    0xfff0_0000_0000_0000,
    0,
    0x8000_0000_0000_0000,
    0x1,
    0x8000_0000_0000_0001,
    0x0010_0000_0000_0000,
    0x7fef_ffff_ffff_ffff,
    0xffef_ffff_ffff_ffff,
    0x7e37_e43c_8800_759c, // 1e300
    0xfe37_e43c_8800_759c, // -1e300
];
fn sp(j: u64) -> f64 {
    f64::from_bits(SP[usize::try_from(j).expect("index")])
}
/// 1-in-`p` a special value, otherwise `lo + unit × span`.
fn pick(r: &mut Sm, p: u64, lo: f64, span: f64) -> f64 {
    let k = r.below(p);
    if k == 0 {
        let j = r.below(SP.len() as u64);
        return sp(j);
    }
    let u = r.unit();
    lo + u * span
}
/// below(8) == 0 → None; == 1 → special; else unit × 6000 − 1000.
fn pick_elev(r: &mut Sm) -> Option<f64> {
    let k = r.below(8);
    if k == 0 {
        return None;
    }
    if k == 1 {
        let j = r.below(SP.len() as u64);
        return Some(sp(j));
    }
    let u = r.unit();
    Some(u * 6000.0 - 1000.0)
}

fn hash_prof(g: &mut Fnv, p: &Profile) {
    g.i(p.band);
    for v in [
        p.comfort_low_f,
        p.comfort_high_f,
        p.record_low_f,
        p.record_high_f,
        p.wind_low,
        p.wind_medium,
        p.wind_high,
        p.pop_low,
        p.pop_medium,
        p.pop_high,
    ] {
        g.d(v);
    }
}
fn hash_norms(g: &mut Fnv, n: &SeasonalNorms) {
    g.d(n.week_low_f);
    g.d(n.week_high_f);
    g.d(n.wind_mean_mph);
    g.d(n.wind_sigma_mph);
}
/// Everything the harness hashes for one place and instant.
fn hash_day(g: &mut Fnv, lat: f64, lon: f64, t: f64) {
    let jd = cl::julian_day(t);
    g.d(jd);
    g.d(cl::midnight_jd(jd));
    let terms = cl::solar_terms(jd);
    g.d(terms.declination);
    g.d(terms.equation_of_time);
    match cl::twilight(lat, lon, t, cl::CIVIL_TWILIGHT_DEGREES) {
        Some(w) => {
            g.u64(1);
            g.d(w.dawn);
            g.d(w.dusk);
        }
        None => g.u64(0),
    }
    g.b(cl::is_night(lat, lon, t));
    g.d(cl::solar_elevation(lat, lon, t));
    g.d(cl::next_change(lat, lon, t));
}
/// An addition with Apple silicon's NaN selection written out, so the answer
/// does not depend on which operand the optimiser puts first: a signaling
/// NaN in the first operand wins, then one in the second, then a quiet NaN in
/// the first, then the second; the chosen NaN comes back quieted. On numbers
/// it is the plain sum.
fn apple_add(op1: f64, op2: f64) -> f64 {
    const QUIET: u64 = 0x0008_0000_0000_0000;
    let signaling = |x: f64| x.is_nan() && x.to_bits() & QUIET == 0;
    let quiet = |x: f64| f64::from_bits(x.to_bits() | QUIET);
    if signaling(op1) {
        quiet(op1)
    } else if signaling(op2) {
        quiet(op2)
    } else if op1.is_nan() {
        op1
    } else if op2.is_nan() {
        op2
    } else {
        op1 + op2
    }
}
/// `Date`'s `<=`: Comparable's `!(rhs < lhs)`, so it holds for a NaN.
fn date_le(a: f64, b: f64) -> bool {
    b.partial_cmp(&a) != Some(Ordering::Less)
}
/// `Date`'s `>=`: Comparable's `!(lhs < rhs)`.
fn date_ge(a: f64, b: f64) -> bool {
    a.partial_cmp(&b) != Some(Ordering::Less)
}
/// `Date` comparisons: `<`, `>` and `==` on the double; `<=` and `>=` as
/// Comparable derives them.
fn dcmp(a: f64, b: f64) -> String {
    format!(
        "{}{}{}{}{}",
        bit(a < b),
        bit(a > b),
        bit(date_le(a, b)),
        bit(date_ge(a, b)),
        bit(a == b)
    )
}
fn day_fields(lat: f64, lon: f64, t: f64) -> [String; 5] {
    let w = cl::twilight(lat, lon, t, cl::CIVIL_TWILIGHT_DEGREES);
    [
        ohx(w.map(|w| w.dawn)),
        ohx(w.map(|w| w.dusk)),
        bit(cl::is_night(lat, lon, t)),
        hx(cl::solar_elevation(lat, lon, t)),
        hx(cl::next_change(lat, lon, t)),
    ]
}
fn table_out(id: &str, b: &[u8]) -> String {
    match cl::parse_flhh(b) {
        None => format!("{id}\t{}\t0", hb(b)),
        Some(t) => format!(
            "{id}\t{}\t1\t{}\t{}\t{}\t{}",
            hb(b),
            lst(&t.families().iter().map(|x| hs_out(x)).collect::<Vec<_>>()),
            lst(&t.zips().iter().map(|x| hs_out(x)).collect::<Vec<_>>()),
            lst(&t.coefficients().iter().map(|x| hf(*x)).collect::<Vec<_>>()),
            t.family_count()
        ),
    }
}
fn hb(b: &[u8]) -> String {
    format!(
        "b:{}",
        b.iter().map(|x| format!("{x:02x}")).collect::<String>()
    )
}
/// The largest realistic table, regenerated as the harness built it.
fn big_table() -> (Vec<u8>, Vec<String>, Vec<&'static str>) {
    let mut r = Sm(0x464C_4848);
    let n_z = 33_613usize;
    let fams = [
        "wind",
        "heat",
        "cold",
        "air",
        "winter",
        "convective",
        "qpf_flood",
        "fire",
    ];
    let mut zips: Vec<String> = Vec::with_capacity(n_z);
    for k in 0..n_z {
        let b = r.below(2);
        zips.push(format!("{:05}", 2 * k as u64 + b));
    }
    let mut bits: Vec<u32> = Vec::with_capacity(n_z * fams.len() * 5);
    for _ in 0..(n_z * fams.len()) {
        let m = r.unit();
        bits.push(((m * 0.4) as f32).to_bits());
        for _ in 0..4 {
            let u = r.unit();
            bits.push(((u * 0.4 - 0.2) as f32).to_bits());
        }
    }
    let mut out = b"FLHH".to_vec();
    out.extend_from_slice(&1u32.to_le_bytes());
    out.extend_from_slice(&(n_z as u32).to_le_bytes());
    out.extend_from_slice(&(fams.len() as u32).to_le_bytes());
    for fam in fams {
        out.push(fam.len() as u8);
        out.extend_from_slice(fam.as_bytes());
    }
    for z in &zips {
        out.extend_from_slice(z.as_bytes());
    }
    for c in bits {
        out.extend_from_slice(&c.to_le_bytes());
    }
    (out, zips, fams.to_vec())
}

const TOTALS: [u64; 14] = [
    0x7ff8_0000_0000_0000,
    0xfff8_0000_0000_0000,
    0x7ff0_0000_0000_0000,
    0xfff0_0000_0000_0000,
    0,
    0x8000_0000_0000_0000,
    0x3ff0_0000_0000_0000, // 1
    0x40ac_2000_0000_0000, // 3600
    0x40dc_2000_0000_0000, // 28800
    0x7e37_e43c_8800_759c, // 1e300
    0x7fef_ffff_ffff_ffff,
    0x1,
    0xc014_0000_0000_0000, // -5
    0x3fb9_9999_9999_999a, // 0.1
];

// ---- the contract where trigonometry is involved ----
//
// The app's Release build fuses sin/cos pairs into `__sincos_stret`; the Rust
// computes every trig call alone (see `flows_core::fmath`). Values that go
// through trigonometry may therefore differ from the fixture in the last
// place, and the contract is physical:

/// Declination within a nanodegree (an arc of about 0.1 mm at the equator);
/// the equation of time within a nanominute.
const TERM_TOLERANCE: f64 = 1e-9;
/// An hour angle within a nanominute (60 ns of rotation); acos amplifies
/// near ±1, and the largest deviation seen is 6e-14.
const HOUR_ANGLE_TOLERANCE_MINUTES: f64 = 1e-9;
/// An instant — a dawn, a dusk, the next change — within a microsecond
/// (every instant in the fixture matches bit for bit).
const INSTANT_TOLERANCE_SECONDS: f64 = 1e-6;
/// The sun's height within a nanodegree (largest deviation seen 1.4e-14).
const ELEVATION_TOLERANCE_DEGREES: f64 = 1e-9;
/// A yes/no answer (a twilight existing at all) may differ only when the
/// hour-angle cosine lies this close to ±1.
const COSINE_EDGE: f64 = 1e-9;

/// Deviation bookkeeping: how many values needed the tolerance, and the
/// largest deviation seen, per kind of value.
#[derive(Default)]
struct Slack {
    within: usize,
    largest: f64,
}
impl Slack {
    fn note(&mut self, dev: f64) {
        self.within += 1;
        if dev > self.largest {
            self.largest = dev;
        }
    }
}
/// Two doubles agree: bit for bit, both NaN, or within `tol` (recorded).
fn near(a: f64, b: f64, tol: f64, slack: &mut Slack) -> bool {
    if a.to_bits() == b.to_bits() || (a.is_nan() && b.is_nan()) {
        return true;
    }
    let dev = (a - b).abs();
    if dev <= tol {
        slack.note(dev);
        return true;
    }
    false
}
fn near_opt(a: Option<f64>, b: Option<f64>, tol: f64, slack: &mut Slack) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(x), Some(y)) => near(x, y, tol, slack),
        _ => false,
    }
}
/// A byte at or above 0x80 anywhere: the key is outside the ASCII contract.
fn non_ascii(t: &str) -> bool {
    !t.is_ascii()
}

#[test]
fn rust_reproduces_the_original_swift_climate_code() {
    let text = include_str!("fixtures/swift_climate_oracle.tsv");
    assert!(text
        .lines()
        .next()
        .unwrap_or_default()
        .contains(BASE_COMMIT));
    let mut failures: Vec<String> = Vec::new();
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut sets: BTreeMap<String, Vec<&str>> = BTreeMap::new();
    let mut tables: BTreeMap<String, Option<HarmonicTable>> = BTreeMap::new();
    let mut term_slack = Slack::default();
    let mut ha_slack = Slack::default();
    let mut instant_slack = Slack::default();
    let mut elevation_slack = Slack::default();
    let mut edge_flips = 0usize;
    let mut night_flips = 0usize;
    // Records on the odd-UTF-8 tables where the Swift matched canonically
    // equivalent spellings and the port matched bytes: counted, and every one
    // must involve a non-ASCII key or query.
    let mut byte_order_divergences = 0usize;
    let mut check = |kind: &str, line: &str, got: String, want: &str| {
        if got != want {
            failures.push(format!(
                "{kind}\t{}\n    got  {got}\n    want {want}",
                line.chars().take(300).collect::<String>()
            ));
        }
    };
    for line in text
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let fl: Vec<&str> = line.split('\t').collect();
        *counts.entry(fl[0].to_string()).or_default() += 1;
        match fl[0] {
            "set" => {
                sets.insert(fl[1].to_string(), list(fl[2]));
            }
            "const" => {
                let got = match fl[1] {
                    "southAnchor" => cl::SOUTH_ANCHOR,
                    "northAnchor" => cl::NORTH_ANCHOR,
                    "pitchDegrees" => cl::PITCH_DEGREES,
                    "minLatitude" => cl::MIN_LATITUDE,
                    "maxLatitude" => cl::MAX_LATITUDE,
                    "referenceElevationMeters" => cl::REFERENCE_ELEVATION_METERS,
                    "metersPerBandStep" => cl::METERS_PER_BAND_STEP,
                    "windLow" => cl::WIND_LOW,
                    "windMedium" => cl::WIND_MEDIUM,
                    "windHigh" => cl::WIND_HIGH,
                    "popLow" => cl::POP_LOW,
                    "popMedium" => cl::POP_MEDIUM,
                    "popHigh" => cl::POP_HIGH,
                    "tempSigmaF" => cl::TEMP_SIGMA_F,
                    "civilTwilightDegrees" => cl::CIVIL_TWILIGHT_DEGREES,
                    "scoreMax" => cl::SCORE_MAX,
                    other => panic!("unknown const {other}"),
                };
                check("const", line, hx(got), fl[2]);
            }
            // ---- LatitudeBands ----
            "lbi" => check(
                "lbi",
                line,
                cl::band_index(d(fl[1])).map_or("trap".into(), |v| v.to_string()),
                fl[2],
            ),
            "lbs" => check(
                "lbs",
                line,
                cl::elevation_band_shift(optd(fl[1])).to_string(),
                fl[2],
            ),
            "lbp" => {
                let got =
                    cl::band_profile(d(fl[1]), optd(fl[2])).map_or("trap".into(), |p| prof_out(&p));
                check("lbp", line, got, fl[3]);
            }
            // ---- ClimateProfiles ----
            "ctype" => {
                let t = CLIMATE_TYPES[usize::try_from(i(fl[1])).expect("code")];
                check(
                    "ctype",
                    line,
                    format!("{}\t{}", hs_out(t.name()), prof_out(&t.profile())),
                    &fl[2..4].join("\t"),
                );
            }
            "ccl" => check(
                "ccl",
                line,
                code(cl::classify(d(fl[1]), d(fl[2]), optd(fl[3]))),
                fl[4],
            ),
            "cpr" => check(
                "cpr",
                line,
                prof_out(&cl::climate_profile(d(fl[1]), d(fl[2]), optd(fl[3]))),
                fl[4],
            ),
            "csn" => check(
                "csn",
                line,
                norms_out(&cl::seasonal_norms(
                    i(fl[1]),
                    d(fl[2]),
                    d(fl[3]),
                    optd(fl[4]),
                )),
                fl[5],
            ),
            "ctb" => check(
                "ctb",
                line,
                bit(cl::temperature_beyond_normal(d(fl[1]), &norms_in(fl[2]))),
                fl[3],
            ),
            "cwb" => check(
                "cwb",
                line,
                bit(cl::wind_beyond_normal(d(fl[1]), &norms_in(fl[2]))),
                fl[3],
            ),
            // ---- Foundation Date arithmetic ----
            "dref" => {
                let t = d(fl[1]);
                let got = [
                    hx(t),
                    hx(cl::unix_seconds(t)),
                    hx(cl::reference_seconds(t)),
                    hx(t + 3600.0),
                    hx(t + 86400.0),
                ]
                .join("\t");
                check("dref", line, got, &fl[2..7].join("\t"));
            }
            "dcmp" => check("dcmp", line, dcmp(d(fl[1]), d(fl[2])), fl[3]),
            // ---- DaylightClock ----
            "djd" => check("djd", line, hx(cl::julian_day(d(fl[1]))), fl[2]),
            "dmj" => check("dmj", line, hx(cl::midnight_jd(d(fl[1]))), fl[2]),
            "dst" | "rdmj" => {
                // rdmj: jd, midnight, declination, eqTime; dst: jd, declination, eqTime.
                let jd = d(fl[1]);
                let (want_mid, want_decl, want_eq) = if fl[0] == "rdmj" {
                    (Some(fl[2]), fl[3], fl[4])
                } else {
                    (None, fl[2], fl[3])
                };
                let t = cl::solar_terms(jd);
                let mut ok = near(t.declination, d(want_decl), TERM_TOLERANCE, &mut term_slack)
                    && near(
                        t.equation_of_time,
                        d(want_eq),
                        TERM_TOLERANCE,
                        &mut term_slack,
                    );
                if let Some(m) = want_mid {
                    ok &= cl::midnight_jd(jd).to_bits() == d(m).to_bits()
                        || (cl::midnight_jd(jd).is_nan() && d(m).is_nan());
                }
                if !ok {
                    check(
                        fl[0],
                        line,
                        format!("{}\t{}", hx(t.declination), hx(t.equation_of_time)),
                        &format!("{want_decl}\t{want_eq}"),
                    );
                }
            }
            "dha" | "rdha" => {
                let (lat, decl, angle) = (d(fl[1]), d(fl[2]), d(fl[3]));
                let got = cl::hour_angle_minutes(lat, decl, angle);
                let want = optd(fl[4]);
                let ok = near_opt(got, want, HOUR_ANGLE_TOLERANCE_MINUTES, &mut ha_slack)
                    || (got.is_some() != want.is_some() && {
                        let c = cl::hour_angle_cosine(lat, decl, angle);
                        let edge = (c.abs() - 1.0).abs() <= COSINE_EDGE;
                        if edge {
                            edge_flips += 1;
                        }
                        edge
                    });
                if !ok {
                    check(fl[0], line, ohx(got), fl[4]);
                }
            }
            "dday" | "rday" => {
                let (lat, lon, t) = (d(fl[1]), d(fl[2]), d(fl[3]));
                let want_fields = list(fl[fl.len() - 1]);
                assert_eq!(want_fields.len(), 5, "dayFields");
                let mut ok = true;
                if fl[0] == "rday" {
                    let jd = cl::julian_day(t);
                    let terms = cl::solar_terms(jd);
                    ok &= jd.to_bits() == d(fl[4]).to_bits() || (jd.is_nan() && d(fl[4]).is_nan());
                    ok &= cl::midnight_jd(jd).to_bits() == d(fl[5]).to_bits()
                        || (cl::midnight_jd(jd).is_nan() && d(fl[5]).is_nan());
                    ok &= near(terms.declination, d(fl[6]), TERM_TOLERANCE, &mut term_slack);
                    ok &= near(
                        terms.equation_of_time,
                        d(fl[7]),
                        TERM_TOLERANCE,
                        &mut term_slack,
                    );
                }
                let w = cl::twilight(lat, lon, t, cl::CIVIL_TWILIGHT_DEGREES);
                let (want_dawn, want_dusk) = (optd(want_fields[0]), optd(want_fields[1]));
                let twilight_ok = near_opt(
                    w.map(|w| w.dawn),
                    want_dawn,
                    INSTANT_TOLERANCE_SECONDS,
                    &mut instant_slack,
                ) && near_opt(
                    w.map(|w| w.dusk),
                    want_dusk,
                    INSTANT_TOLERANCE_SECONDS,
                    &mut instant_slack,
                );
                if !twilight_ok {
                    // A twilight existing on one side only: allowed at a polar edge.
                    let jd = cl::midnight_jd(cl::julian_day(t) + lon / 360.0);
                    let c = cl::hour_angle_cosine(
                        lat,
                        cl::solar_terms(jd).declination,
                        cl::CIVIL_TWILIGHT_DEGREES,
                    );
                    if w.is_some() != want_dawn.is_some() && (c.abs() - 1.0).abs() <= COSINE_EDGE {
                        edge_flips += 1;
                    } else {
                        ok = false;
                    }
                }
                let night = cl::is_night(lat, lon, t);
                if bit(night) != want_fields[2] {
                    // May flip only within the instant tolerance of a dawn or dusk.
                    let close = w.is_some_and(|w| {
                        (t - w.dawn).abs() <= INSTANT_TOLERANCE_SECONDS
                            || (t - w.dusk).abs() <= INSTANT_TOLERANCE_SECONDS
                    });
                    if close || !twilight_ok {
                        night_flips += 1;
                    } else {
                        ok = false;
                    }
                }
                ok &= near(
                    cl::solar_elevation(lat, lon, t),
                    d(want_fields[3]),
                    ELEVATION_TOLERANCE_DEGREES,
                    &mut elevation_slack,
                );
                ok &= near(
                    cl::next_change(lat, lon, t),
                    d(want_fields[4]),
                    INSTANT_TOLERANCE_SECONDS,
                    &mut instant_slack,
                );
                if !ok {
                    check(fl[0], line, lst(&day_fields(lat, lon, t)), fl[fl.len() - 1]);
                }
            }
            "dtw" => {
                let w = cl::twilight(d(fl[1]), d(fl[2]), d(fl[3]), d(fl[4]));
                let ok = near_opt(
                    w.map(|w| w.dawn),
                    optd(fl[5]),
                    INSTANT_TOLERANCE_SECONDS,
                    &mut instant_slack,
                ) && near_opt(
                    w.map(|w| w.dusk),
                    optd(fl[6]),
                    INSTANT_TOLERANCE_SECONDS,
                    &mut instant_slack,
                );
                if !ok {
                    check(
                        "dtw",
                        line,
                        format!("{}\t{}", ohx(w.map(|w| w.dawn)), ohx(w.map(|w| w.dusk))),
                        &fl[5..7].join("\t"),
                    );
                }
            }
            "dnone" => check(
                "dnone",
                line,
                ohx(
                    cl::twilight(d(fl[1]), d(fl[2]), d(fl[3]), cl::CIVIL_TWILIGHT_DEGREES)
                        .map(|w| w.dawn),
                ),
                "-",
            ),
            // ---- HarmonicClimatology ----
            "hwt" => {
                let w = WeekTrig::new(i(fl[1]));
                check(
                    "hwt",
                    line,
                    [hx(w.cos_t), hx(w.sin_t), hx(w.cos_2t), hx(w.sin_2t)].join("\t"),
                    &fl[2..6].join("\t"),
                );
            }
            "hp" => {
                let b = bytes(fl[2]);
                let parsed = cl::parse_flhh(&b);
                check("hp", line, table_out(fl[1], &b), &fl[1..].join("\t"));
                tables.insert(fl[1].to_string(), parsed);
            }
            "hzc" => {
                let t = tables[fl[1]].as_ref().expect("a parsed table");
                check("hzc", line, t.zip_index_map().len().to_string(), fl[2]);
            }
            "hzi" | "hzm" | "hsn" => {
                let t = tables[fl[1]].as_ref().expect("a parsed table");
                let (got, want) = match fl[0] {
                    "hzi" => (
                        t.zip_index(&s(fl[2])).map_or("-".into(), |v| v.to_string()),
                        fl[3],
                    ),
                    "hzm" => (
                        t.zip_index_map()
                            .get(&s(fl[2]))
                            .map_or("-".into(), |v| v.to_string()),
                        fl[3],
                    ),
                    _ => (ohx(t.score_named(&s(fl[2]), &s(fl[3]), i(fl[4]))), fl[5]),
                };
                if got == want {
                    continue;
                }
                let keys_non_ascii = t.zips().iter().chain(t.families()).any(|k| non_ascii(k));
                let query_non_ascii =
                    non_ascii(&s(fl[2])) || (fl[0] == "hsn" && non_ascii(&s(fl[3])));
                if keys_non_ascii || query_non_ascii {
                    byte_order_divergences += 1;
                } else {
                    check(fl[0], line, got, want);
                }
            }
            "hsc" => {
                let t = tables[fl[1]].as_ref().expect("a parsed table");
                check(
                    "hsc",
                    line,
                    t.score_week(i(fl[2]), i(fl[3]), i(fl[4]))
                        .map_or("trap".into(), hx),
                    fl[5],
                );
            }
            "hst" => {
                let t = tables[fl[1]].as_ref().expect("a parsed table");
                check(
                    "hst",
                    line,
                    t.score(i(fl[2]), i(fl[3]), &WeekTrig::new(i(fl[4])))
                        .map_or("trap".into(), hx),
                    fl[5],
                );
            }
            "hbig" => {
                let (b, zips, fams) = big_table();
                assert_eq!(fl[2], zips.len().to_string());
                let mut bg = Fnv::new();
                for x in &b {
                    bg.byte(*x);
                }
                let t = cl::parse_flhh(&b).expect("the big table parses");
                let mut zg = Fnv::new();
                for z in t.zips() {
                    for x in z.bytes() {
                        zg.byte(x);
                    }
                    zg.byte(0xFF);
                }
                let mut cg = Fnv::new();
                for c in t.coefficients() {
                    cg.u64(u64::from(c.to_bits()));
                }
                let mut sg = Fnv::new();
                for w in [0, 13, 26, 39, 51, -7, 60] {
                    let tr = WeekTrig::new(w);
                    for zi in 0..zips.len() as i64 {
                        for fi in 0..fams.len() as i64 {
                            sg.d(t.score(zi, fi, &tr).expect("in range"));
                        }
                    }
                }
                let map = t.zip_index_map();
                let mut mg = Fnv::new();
                mg.i(map.len() as i64);
                for z in &zips {
                    mg.i(map.get(z).map_or(-1, |v| *v as i64));
                }
                for z in (0..70_000).step_by(7) {
                    let q = format!("{z:05}");
                    mg.i(t.zip_index(&q).map_or(-1, |v| v as i64));
                    mg.i(map.get(&q).map_or(-1, |v| *v as i64));
                }
                let mut ng = Fnv::new();
                let mut names: Vec<&str> = fams.clone();
                names.push("missing");
                for k in (0..zips.len()).step_by(101) {
                    for fam in &names {
                        ng.od(t.score_named(&zips[k], fam, 17));
                    }
                }
                let got = [
                    fl[1].to_string(),
                    zips.len().to_string(),
                    b.len().to_string(),
                    bg.hex(),
                    lst(&t.families().iter().map(|x| hs_out(x)).collect::<Vec<_>>()),
                    zg.hex(),
                    cg.hex(),
                    sg.hex(),
                    mg.hex(),
                    ng.hex(),
                ]
                .join("\t");
                check("hbig", line, got, &fl[1..].join("\t"));
            }
            // ---- RiskTiming ----
            "rta" => check(
                "rta",
                line,
                bit(cl::is_active(optd(fl[1]), d(fl[2]), d(fl[3]))),
                fl[4],
            ),
            "rto" => {
                let got = cl::arrival_offsets(i(fl[1]), d(fl[2])).map_or("refused".into(), |v| {
                    lst(&v.iter().map(|x| hx(*x)).collect::<Vec<_>>())
                });
                check("rto", line, got, fl[3]);
            }
            // ---- traps ----
            "trap" => {
                let trapped = match fl[1] {
                    "bandIndex" => cl::band_index(d(fl[2])).is_none(),
                    "latitudeProfile" => cl::band_profile(d(fl[2]), optd(fl[3])).is_none(),
                    "harmonicScore" => tables["0"]
                        .as_ref()
                        .expect("table 0")
                        .score_week(i(fl[2]), i(fl[3]), i(fl[4]))
                        .is_none(),
                    "arrivalOffsets" => cl::arrival_offsets(i(fl[2]), d(fl[3])).is_none(),
                    other => panic!("unknown trap probe {other}"),
                };
                check(
                    "trap",
                    line,
                    if trapped {
                        "trap".into()
                    } else {
                        "exit0".into()
                    },
                    fl[5],
                );
            }
            // ---- digests over named sets ----
            "dg" => {
                let mut g = Fnv::new();
                match fl[1] {
                    "lbp" => {
                        for lat in &sets["latB"] {
                            for e in &sets["elevB"] {
                                match cl::band_profile(d(lat), optd(e)) {
                                    Some(p) => hash_prof(&mut g, &p),
                                    None => g.u64(TRAPPED),
                                }
                            }
                        }
                    }
                    "ccl" => {
                        for lat in &sets["latC"] {
                            for lon in &sets["lonC"] {
                                for e in &sets["elevC"] {
                                    g.i(cl::classify(d(lat), d(lon), optd(e)) as i64);
                                }
                            }
                        }
                    }
                    "cpr" => {
                        for lat in &sets["latF"] {
                            for lon in &sets["lonF"] {
                                for e in &sets["elevC"] {
                                    hash_prof(
                                        &mut g,
                                        &cl::climate_profile(d(lat), d(lon), optd(e)),
                                    );
                                }
                            }
                        }
                    }
                    "csn" => {
                        for w in &sets["W"] {
                            for lat in &sets["latC"] {
                                for lon in &sets["lonC"] {
                                    for e in &sets["elevC"] {
                                        hash_norms(
                                            &mut g,
                                            &cl::seasonal_norms(i(w), d(lat), d(lon), optd(e)),
                                        );
                                    }
                                }
                            }
                        }
                    }
                    "day" => {
                        for lat in &sets["latD"] {
                            for lon in &sets["lonD"] {
                                for t in &sets["T"] {
                                    hash_day(&mut g, d(lat), d(lon), d(t));
                                }
                            }
                        }
                    }
                    "hwt" => {
                        for w in -1000..=1000 {
                            let tr = WeekTrig::new(w);
                            g.d(tr.cos_t);
                            g.d(tr.sin_t);
                            g.d(tr.cos_2t);
                            g.d(tr.sin_2t);
                        }
                    }
                    "rto" => {
                        for n in [64, 1000, 65_536] {
                            for t in TOTALS {
                                let v =
                                    cl::arrival_offsets(n, f64::from_bits(t)).expect("in bounds");
                                g.i(v.len() as i64);
                                for x in v {
                                    g.d(x);
                                }
                            }
                        }
                    }
                    other => panic!("unknown digest {other}"),
                }
                let want_n = fl[fl.len() - 2];
                let want_h = fl[fl.len() - 1];
                check(
                    &format!("dg {}", fl[1]),
                    line,
                    format!("{}\t{}", g.n, g.hex()),
                    &format!("{want_n}\t{want_h}"),
                );
            }
            // ---- digests over regenerated sweeps ----
            "rnd" => {
                let seed = u64::from_str_radix(fl[2], 16).expect("seed");
                let n: u64 = fl[3].parse().expect("count");
                let mut r = Sm(seed);
                let mut g = Fnv::new();
                for _ in 0..n {
                    match fl[1] {
                        "lbi" => {
                            let lat = pick(&mut r, 4, 5.0, 70.0);
                            match cl::band_index(lat) {
                                Some(v) if !lat.is_nan() => g.i(v),
                                _ => g.u64(TRAPPED),
                            }
                        }
                        "lbs" => {
                            let e = pick_elev(&mut r);
                            g.i(cl::elevation_band_shift(e));
                        }
                        "lbp" => {
                            let lat = pick(&mut r, 4, 5.0, 70.0);
                            let e = pick_elev(&mut r);
                            match cl::band_profile(lat, e) {
                                Some(p) if !lat.is_nan() => hash_prof(&mut g, &p),
                                _ => g.u64(TRAPPED),
                            }
                        }
                        "ccl" => {
                            let lat = pick(&mut r, 6, 10.0, 65.0);
                            let lon = pick(&mut r, 6, -170.0, 120.0);
                            let e = pick_elev(&mut r);
                            g.i(cl::classify(lat, lon, e) as i64);
                        }
                        "cpr" => {
                            let u1 = r.unit();
                            let u2 = r.unit();
                            let e = pick_elev(&mut r);
                            hash_prof(
                                &mut g,
                                &cl::climate_profile(10.0 + u1 * 65.0, -170.0 + u2 * 120.0, e),
                            );
                        }
                        "csn" => {
                            let kk = r.below(4);
                            let w = if kk == 0 {
                                let j = r.below(sets["W"].len() as u64);
                                i(sets["W"][usize::try_from(j).expect("index")])
                            } else {
                                r.below(200) as i64 - 100
                            };
                            let lat = pick(&mut r, 6, 10.0, 65.0);
                            let lon = pick(&mut r, 6, -170.0, 120.0);
                            let e = pick_elev(&mut r);
                            hash_norms(&mut g, &cl::seasonal_norms(w, lat, lon, e));
                        }
                        "cbn" => {
                            let lo = pick(&mut r, 10, -40.0, 100.0);
                            let hi = pick(&mut r, 10, -20.0, 140.0);
                            let mean = pick(&mut r, 10, 0.0, 20.0);
                            let sigma = pick(&mut r, 10, 0.0, 8.0);
                            let t = pick(&mut r, 5, -60.0, 200.0);
                            let v = pick(&mut r, 5, 0.0, 80.0);
                            let nrm = SeasonalNorms {
                                week_low_f: lo,
                                week_high_f: hi,
                                wind_mean_mph: mean,
                                wind_sigma_mph: sigma,
                            };
                            g.b(cl::temperature_beyond_normal(t, &nrm));
                            g.b(cl::wind_beyond_normal(v, &nrm));
                        }
                        "date" => {
                            let a = pick(&mut r, 6, -4e9, 8e9);
                            let delta = pick(&mut r, 6, -1e5, 2e5);
                            // Foundation's addingTimeInterval as the Release build emitted it:
                            // the delta as the first operand.
                            let y = apple_add(delta, a);
                            g.d(a);
                            g.d(cl::unix_seconds(a));
                            g.d(cl::reference_seconds(a));
                            g.d(y);
                            g.b(a < y);
                            g.b(a > y);
                            g.b(date_le(a, y));
                            g.b(date_ge(a, y));
                            g.b(a == y);
                        }
                        "dtw" => {
                            let lat = pick(&mut r, 8, -90.0, 180.0);
                            let lon = pick(&mut r, 8, -180.0, 360.0);
                            let t = pick(&mut r, 8, -3.2e9, 6.4e9);
                            let a = pick(&mut r, 6, -20.0, 40.0);
                            match cl::twilight(lat, lon, t, a) {
                                Some(w) => {
                                    g.u64(1);
                                    g.d(w.dawn);
                                    g.d(w.dusk);
                                }
                                None => g.u64(0),
                            }
                        }
                        "rta" => {
                            let now = pick(&mut r, 8, -1e9, 2e9);
                            let o = pick(&mut r, 8, -1e4, 1e5);
                            let has = r.below(8) != 0;
                            let mut e: Option<f64> = None;
                            if has {
                                let c = now + flows_core::fcmp::smax(o, 0.0);
                                let kk = r.below(3);
                                e = Some(if kk == 0 {
                                    c
                                } else if kk == 1 {
                                    let up = r.below(2) == 0;
                                    if up {
                                        c.next_up()
                                    } else {
                                        c.next_down()
                                    }
                                } else {
                                    pick(&mut r, 8, -1e9, 2e9)
                                });
                            }
                            g.b(cl::is_active(e, o, now));
                        }
                        "rto" => {
                            let nn = r.below(70) as i64;
                            let t = pick(&mut r, 6, 0.0, 1e5);
                            let v = cl::arrival_offsets(nn, t).expect("in bounds");
                            g.i(v.len() as i64);
                            for x in v {
                                g.d(x);
                            }
                        }
                        other => panic!("unknown sweep {other}"),
                    }
                }
                check(&format!("rnd {}", fl[1]), line, g.hex(), fl[4]);
            }
            other => panic!("unknown record kind {other}"),
        }
    }
    let total: usize = counts.values().sum();
    assert!(total >= 13_000, "fixture truncated: {total}");
    assert_eq!(counts.len(), 37, "record kinds: {counts:?}");
    eprintln!(
        "climate oracle: {total} records; within tolerance — terms {} (largest {:e}), hour angles {} (largest {:e}), instants {} (largest {:e} s), elevations {} (largest {:e}°); edge flips {edge_flips}; night flips {night_flips}; byte-order divergences on non-ASCII keys {byte_order_divergences}",
        term_slack.within, term_slack.largest, ha_slack.within, ha_slack.largest, instant_slack.within, instant_slack.largest, elevation_slack.within, elevation_slack.largest
    );
    assert!(
        edge_flips <= 8,
        "twilight existence flips at a polar edge: {edge_flips}"
    );
    assert!(
        night_flips <= 8,
        "is-night flips within a millisecond of a boundary: {night_flips}"
    );
    assert_eq!(
        byte_order_divergences, 287,
        "byte-order divergences on the odd-UTF-8 tables must be exactly those known"
    );
    let mut by_kind: BTreeMap<&str, usize> = BTreeMap::new();
    for fail in &failures {
        *by_kind
            .entry(fail.split('\t').next().unwrap_or_default())
            .or_default() += 1;
    }
    assert!(
        failures.is_empty(),
        "{} of {total} oracle records differ from the original Swift: {by_kind:?}\n{}",
        failures.len(),
        failures
            .iter()
            .take(40)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
