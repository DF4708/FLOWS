// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! `Double(String)` as Swift 6.4 answers it on Darwin.
//!
//! Swift refuses an empty string and one whose first byte is ASCII
//! whitespace, hands the text to `strtod` as a C string (so it ends at the
//! first NUL) and requires every remaining byte consumed. Darwin's `strtod`
//! then accepts, after one optional sign:
//!
//! - `inf` or `infinity`, in any case;
//! - `nan` or `snan`, in any case, with an optional `(payload)`: the payload
//!   is empty, `0x` and hex digits, `0` and octal digits, or decimal digits,
//!   accumulated wrapping in 64 bits and kept to its low 50 bits. A quiet NaN
//!   carries bit 51, a signaling one bit 50; the sign applies to both;
//! - a hexadecimal float, `0x` (the `x` lowercase) then hex digits with an
//!   optional point and an optional `p`/`P` exponent, correctly rounded to
//!   nearest-even, subnormals included; an exponent past the range gives
//!   infinity or zero;
//! - a decimal float, correctly rounded, overflowing to infinity and
//!   underflowing to zero without complaint.
//!
//! Everything else — leading or trailing space, `1e`, `1_000`, a digit of
//! another script, an uppercase `0X` — is `nil`.

/// Swift's `Double(text)`; `None` where Swift answers `nil`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn swift_double(text: &str) -> Option<f64> {
    let text = text.split('\0').next().unwrap_or("");
    let first = *text.as_bytes().first()?;
    if matches!(first, 9..=13 | 32) {
        return None;
    }
    let (negative, body) = match first {
        b'+' => (false, &text[1..]),
        b'-' => (true, &text[1..]),
        _ => (false, text),
    };
    let magnitude = special(body)
        .or_else(|| hex_float(body))
        .or_else(|| decimal(body))?;
    Some(if negative { -magnitude } else { magnitude })
}

/// Swift's `Double(text)` for a `Substring`. The generic `StringProtocol`
/// path copies the bytes out and requires every one consumed, so an
/// embedded NUL — which the `String` path silently ends the text at — makes
/// the parse fail. Otherwise the two agree (the hazard-feeds oracle pins the
/// difference on the CRE price scan).
///
/// Deterministic; panics: none.
#[must_use]
pub fn swift_double_substring(text: &str) -> Option<f64> {
    if text.contains('\0') {
        return None;
    }
    swift_double(text)
}

const QUIET_NAN: u64 = 0x7FF8_0000_0000_0000;
const SIGNALING_NAN: u64 = 0x7FF4_0000_0000_0000;
const PAYLOAD_MASK: u64 = (1 << 50) - 1;

/// `inf`, `infinity`, `nan[(…)]` and `snan[(…)]`.
fn special(body: &str) -> Option<f64> {
    if body.eq_ignore_ascii_case("inf") || body.eq_ignore_ascii_case("infinity") {
        return Some(f64::INFINITY);
    }
    let (base, rest) = if body.len() >= 4 && body.as_bytes()[..4].eq_ignore_ascii_case(b"snan") {
        (SIGNALING_NAN, &body[4..])
    } else if body.len() >= 3 && body.as_bytes()[..3].eq_ignore_ascii_case(b"nan") {
        (QUIET_NAN, &body[3..])
    } else {
        return None;
    };
    let payload = if rest.is_empty() {
        0
    } else {
        let inner = rest.strip_prefix('(')?.strip_suffix(')')?;
        nan_payload(inner)?
    };
    Some(f64::from_bits(base | (payload & PAYLOAD_MASK)))
}

/// The number inside `nan(…)`: empty, `0x` hex, `0` octal or decimal digits,
/// wrapping in 64 bits; anything else is invalid.
fn nan_payload(inner: &str) -> Option<u64> {
    let bytes = inner.as_bytes();
    let (radix, digits): (u64, &[u8]) = match bytes {
        [] => return Some(0),
        [b'0', b'x', rest @ ..] => (16, rest),
        [b'0', rest @ ..] => (8, rest),
        _ => (10, bytes),
    };
    let mut acc: u64 = 0;
    for &b in digits {
        let d = u64::from((b as char).to_digit(36)?);
        if d >= radix {
            return None;
        }
        acc = acc.wrapping_mul(radix).wrapping_add(d);
    }
    Some(acc)
}

fn hex_digit(b: u8) -> Option<u64> {
    (b as char).to_digit(16).map(u64::from)
}

/// `0x…`: the significant hex digits are held in 64 bits with a sticky
/// flag for what falls below, then rounded once.
fn hex_float(body: &str) -> Option<f64> {
    let bytes = body.strip_prefix("0x")?.as_bytes();
    let mut i = 0;
    let mut mant: u64 = 0;
    let mut held = 0u32;
    let mut exp: i64 = 0;
    let mut sticky = false;
    let mut digits = 0usize;
    let mut seen_point = false;
    while i < bytes.len() {
        let b = bytes[i];
        if let Some(d) = hex_digit(b) {
            digits += 1;
            if held == 0 && d == 0 {
                if seen_point {
                    exp -= 4;
                }
            } else if held < 16 {
                mant = (mant << 4) | d;
                held += 1;
                if seen_point {
                    exp -= 4;
                }
            } else {
                if !seen_point {
                    exp += 4;
                }
                sticky |= d != 0;
            }
            i += 1;
        } else if b == b'.' && !seen_point {
            seen_point = true;
            i += 1;
        } else {
            break;
        }
    }
    if digits == 0 {
        return None;
    }
    if i < bytes.len() {
        if bytes[i] != b'p' && bytes[i] != b'P' {
            return None;
        }
        i += 1;
        let mut negative = false;
        if i < bytes.len() && (bytes[i] == b'+' || bytes[i] == b'-') {
            negative = bytes[i] == b'-';
            i += 1;
        }
        let start = i;
        let mut e: i64 = 0;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            e = e
                .saturating_mul(10)
                .saturating_add(i64::from(bytes[i] - b'0'));
            i += 1;
        }
        if i == start || i != bytes.len() {
            return None;
        }
        exp = exp.saturating_add(if negative { -e } else { e });
    }
    Some(assemble(mant, exp, sticky))
}

/// `mant × 2^exp` (plus a sticky trace below `mant`) rounded to the nearest
/// even double.
fn assemble(mant: u64, exp: i64, sticky: bool) -> f64 {
    if mant == 0 {
        return 0.0;
    }
    let lz = i64::from(mant.leading_zeros());
    let m = mant << lz;
    // The exponent of the leading bit: m is 1.xxx × 2^63 scaled by 2^(exp − lz).
    let e = exp - lz + 63;
    if e > 1023 {
        return f64::INFINITY;
    }
    let shift = if e >= -1022 { 11 } else { 11 + (-1022 - e) };
    let kept = round_shift(m, shift, sticky);
    if e >= -1022 {
        if kept == 1 << 53 {
            return if e + 1 > 1023 {
                f64::INFINITY
            } else {
                f64::from_bits(((e + 1 + 1023) as u64) << 52)
            };
        }
        return f64::from_bits((((e + 1023) as u64) << 52) | (kept & ((1 << 52) - 1)));
    }
    // Subnormal: `kept` is the whole bit pattern; 2^52 is the smallest normal.
    f64::from_bits(kept)
}

/// Drop `shift` low bits of `m` (whose top bit is set), rounding to nearest,
/// ties to even; `sticky` says non-zero bits lie below `m` already.
fn round_shift(m: u64, shift: i64, sticky: bool) -> u64 {
    if shift <= 0 {
        return m;
    }
    if shift >= 64 {
        // Everything is dropped: only exactly half of an ulp with nothing
        // below rounds down (to the even 0); more than half rounds to 1.
        return u64::from(shift == 64 && (m > 1 << 63 || sticky));
    }
    let kept = m >> shift;
    let rem = m & ((1u64 << shift) - 1);
    let half = 1u64 << (shift - 1);
    let up = rem > half || (rem == half && (sticky || kept & 1 == 1));
    if up {
        kept + 1
    } else {
        kept
    }
}

/// A decimal float in `strtod`'s grammar, parsed by the standard library's
/// correctly rounded parser once the grammar is confirmed.
fn decimal(body: &str) -> Option<f64> {
    let bytes = body.as_bytes();
    let mut i = 0;
    let mut digits = 0;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        i += 1;
        digits += 1;
    }
    if i < bytes.len() && bytes[i] == b'.' {
        i += 1;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            i += 1;
            digits += 1;
        }
    }
    if digits == 0 {
        return None;
    }
    if i < bytes.len() {
        if bytes[i] != b'e' && bytes[i] != b'E' {
            return None;
        }
        i += 1;
        if i < bytes.len() && (bytes[i] == b'+' || bytes[i] == b'-') {
            i += 1;
        }
        let start = i;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            i += 1;
        }
        if i == start || i != bytes.len() {
            return None;
        }
    }
    body.parse::<f64>().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bits(text: &str) -> Option<u64> {
        swift_double(text).map(f64::to_bits)
    }

    #[test]
    fn swift_refuses_what_darwin_refuses() {
        for text in [
            "",
            " 1",
            "\t1",
            "1 ",
            "1e",
            "1_000",
            "infx",
            "nanx",
            "nan(",
            "nan(1a)",
            "nan(08)",
            "nan(0X12)",
            "nan(+5)",
            "nan( 12)",
            "nan(12)5",
            "0X1p3",
            "0x",
            "0x.p3",
            "0xp3",
            "0x-1",
            "1e5.5",
            "+-5",
            "--5",
            "0b1",
            "1d",
            "\u{663}",
            "\0 50",
            "00x1",
            "\u{130}nf",
            "snan(5)x",
            "n",
            "i",
            "1e+",
            ".",
        ] {
            assert_eq!(bits(text), None, "{text:?}");
        }
    }

    #[test]
    fn specials_carry_apple_payloads_and_signs() {
        assert_eq!(bits("nan"), Some(0x7FF8_0000_0000_0000));
        assert_eq!(bits("-nan"), Some(0xFFF8_0000_0000_0000));
        assert_eq!(bits("NaN(18)"), Some(0x7FF8_0000_0000_0012));
        assert_eq!(bits("nan(0x12)"), Some(0x7FF8_0000_0000_0012));
        assert_eq!(bits("nan(012)"), Some(0x7FF8_0000_0000_000A));
        assert_eq!(bits("nan()"), Some(0x7FF8_0000_0000_0000));
        assert_eq!(bits("nan(0x)"), Some(0x7FF8_0000_0000_0000));
        assert_eq!(bits("nan(0xfffffffffffff)"), Some(0x7FFB_FFFF_FFFF_FFFF));
        assert_eq!(
            bits("nan(99999999999999999999)"),
            Some(0x7FFB_5E2D_630F_FFFF)
        );
        assert_eq!(
            bits("nan(18446744073709551616)"),
            Some(0x7FF8_0000_0000_0000)
        );
        assert_eq!(bits("nan(0x4000000000000)"), Some(0x7FF8_0000_0000_0000));
        assert_eq!(bits("snan"), Some(0x7FF4_0000_0000_0000));
        assert_eq!(bits("-snan"), Some(0xFFF4_0000_0000_0000));
        assert_eq!(bits("snan(5)"), Some(0x7FF4_0000_0000_0005));
        assert_eq!(bits("snan(0x4000000000000)"), Some(0x7FF4_0000_0000_0000));
        assert_eq!(bits("INF"), Some(0x7FF0_0000_0000_0000));
        assert_eq!(bits("-inf"), Some(0xFFF0_0000_0000_0000));
        assert_eq!(bits("infinity"), Some(0x7FF0_0000_0000_0000));
    }

    #[test]
    fn hex_floats_round_to_nearest_even_down_to_the_subnormals() {
        assert_eq!(bits("0x1e"), Some(0x403E_0000_0000_0000));
        assert_eq!(bits("0x1e3"), Some(0x407E_3000_0000_0000));
        assert_eq!(bits("0x1P3"), Some(0x4020_0000_0000_0000));
        assert_eq!(bits("0x1.p3"), Some(0x4020_0000_0000_0000));
        assert_eq!(bits("0x1.8p+1"), Some(0x4008_0000_0000_0000));
        assert_eq!(bits("0x.8"), Some(0x3FE0_0000_0000_0000));
        assert_eq!(bits("0x1p-1075"), Some(0));
        assert_eq!(bits("0x3p-1076"), Some(1));
        assert_eq!(bits("0x0.0000000000001p-1022"), Some(1));
        assert_eq!(bits("0x0.00000000000008p-1022"), Some(0));
        assert_eq!(bits("0x0.00000000000018p-1022"), Some(2));
        assert_eq!(bits("0x1.fffffffffffff8p1023"), Some(0x7FF0_0000_0000_0000));
        assert_eq!(bits("0x1.fffffffffffff7p1023"), Some(0x7FEF_FFFF_FFFF_FFFF));
        assert_eq!(
            bits("0x1.00000000000008000000000001p0"),
            Some(0x3FF0_0000_0000_0001)
        );
        assert_eq!(bits("0x1.000000000000080p0"), Some(0x3FF0_0000_0000_0000));
        assert_eq!(bits("0x1.00000000000018p0"), Some(0x3FF0_0000_0000_0002));
        assert_eq!(
            bits("0x.00000000000000000000000000001p120"),
            Some(0x4030_0000_0000_0000)
        );
        assert_eq!(
            bits("0x1p99999999999999999999"),
            Some(0x7FF0_0000_0000_0000)
        );
        assert_eq!(bits("-0x0p0"), Some(0x8000_0000_0000_0000));
        assert_eq!(bits("0x0"), Some(0));
    }

    #[test]
    fn a_substring_does_not_end_at_an_embedded_nul() {
        assert_eq!(swift_double_substring("24.\u{0}9"), None);
        assert_eq!(swift_double("24.\u{0}9"), Some(24.0));
        assert_eq!(swift_double_substring("24.9"), Some(24.9));
    }

    #[test]
    fn decimals_are_correctly_rounded_and_saturate_quietly() {
        assert_eq!(bits("1e999"), Some(0x7FF0_0000_0000_0000));
        assert_eq!(bits("1e-400"), Some(0));
        assert_eq!(bits("1e99999999999999999999"), Some(0x7FF0_0000_0000_0000));
        assert_eq!(bits("1e-99999999999999999999"), Some(0));
        assert_eq!(bits("2.4703282292062327e-324"), Some(0));
        assert_eq!(bits("2.4703282292062328e-324"), Some(1));
        assert_eq!(bits("7.4e-324"), Some(1));
        assert_eq!(bits("7.5e-324"), Some(2));
        assert_eq!(bits("+50"), Some(0x4049_0000_0000_0000));
        assert_eq!(bits("5."), Some(0x4014_0000_0000_0000));
        assert_eq!(bits(".5"), Some(0x3FE0_0000_0000_0000));
        assert_eq!(bits("-.5"), Some(0xBFE0_0000_0000_0000));
        assert_eq!(bits("1E5"), Some(0x40F8_6A00_0000_0000));
        assert_eq!(bits("1e-5"), Some(0x3EE4_F8B5_88E3_68F1));
        assert_eq!(bits("-0"), Some(0x8000_0000_0000_0000));
        assert_eq!(bits("50\0abc"), Some(0x4049_0000_0000_0000));
        assert_eq!(bits("4\u{0}5"), Some(0x4010_0000_0000_0000));
        assert_eq!(bits("0003.45"), swift_double("3.45").map(f64::to_bits));
    }
}
