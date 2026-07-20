// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Google encoded-polyline decoder (in-house, overflow-safe).
//!
//! Mirrors `R/polyline.R::decode_polyline_matrix` exactly:
//!   - varints accumulate in 64-bit space (a valid delta needs <= 32 bits);
//!   - a varint longer than `MAX_CHUNKS` is malformed -> decoding stops there,
//!     keeping the pairs decoded so far;
//!   - a truncated trailing varint, or a dangling lat without its lon, is
//!     dropped;
//!   - output is (lon, lat) pairs, cumulative integer deltas divided by 1e5.
//!
//! Both implementations of the hot loop are kept and equivalence-tested:
//!   - `decode_deltas_rust`: portable reference.
//!   - `bench::deltas_rust_rawptr`: the SHIPPED kernel (portable, writes
//!     through reserve + raw pointer; formerly an AArch64 inline-asm kernel —
//!     iPhone / iPad). Integer-only varint+zigzag work is the profitable kind
//!     of hand-assembly; float math stays in Rust where the compiler is
//!     already optimal.
//!
//! Byte-identical to the R decoder by construction: both divide the same
//! exact i64 cumulative sums by 1e5 with one IEEE-754 double division.

/// A valid |delta| <= 2*180e5 fits in 7 five-bit chunks; anything past 10
/// chunks (50 bits) is malformed input, matching the R decoder's guard.
/// (The fast kernel enforces the same bound in its chunk counter.)
#[cfg_attr(target_arch = "aarch64", allow(dead_code))] // test oracle on aarch64
const MAX_CHUNKS: u32 = 10;

/// Portable reference: decode zigzag varints into signed deltas.
/// Appends to `out`; stops at a truncated trailing varint or the first
/// overlong (malformed) varint. On AArch64 builds this stays compiled as the
/// equivalence-test oracle for the fast kernel.
fn decode_deltas_rust(bytes: &[u8], out: &mut Vec<i64>) {
    let mut acc: u64 = 0;
    let mut shift: u32 = 0;
    let mut chunks: u32 = 0;
    for &raw in bytes {
        let b = i32::from(raw) - 63; // may be negative for chars below '?'
        chunks += 1;
        if chunks > MAX_CHUNKS {
            return; // malformed varint: drop it and everything after
        }
        acc |= u64::from((b & 0x1f) as u32) << shift;
        shift += 5;
        if b < 0x20 {
            // end of varint: zigzag un-shift, exact in 64-bit space
            let v = ((acc >> 1) as i64) ^ -((acc & 1) as i64);
            out.push(v);
            acc = 0;
            shift = 0;
            chunks = 0;
        }
    }
    // trailing incomplete varint falls off the end and is dropped
}

/// The shipped kernel + the safe oracle, exposed for `bin/bench.rs`.
/// (`deltas_rust_rawptr` IS `decode_deltas`; the module keeps the bake-off
/// interface that retired the asm kernel — see decode_deltas' history note.)
#[doc(hidden)]
pub mod bench {
    pub fn deltas_rust(bytes: &[u8], out: &mut Vec<i64>) {
        super::decode_deltas_rust(bytes, out)
    }

    pub fn deltas_rust_rawptr(bytes: &[u8], out: &mut Vec<i64>) {
        if bytes.is_empty() {
            return;
        }
        out.reserve(bytes.len());
        let mut acc: u64 = 0;
        let mut shift: u32 = 0;
        let mut chunks: u32 = 0;
        let mut count = 0usize;
        unsafe {
            let base = out.as_mut_ptr().add(out.len());
            for &raw in bytes {
                let b = i32::from(raw) - 63;
                chunks += 1;
                if chunks > super::MAX_CHUNKS {
                    break; // malformed varint: drop it and everything after
                }
                acc |= u64::from((b & 0x1f) as u32) << shift;
                shift += 5;
                if b < 0x20 {
                    let v = ((acc >> 1) as i64) ^ -((acc & 1) as i64);
                    // SAFETY: count <= bytes.len() (one store per terminator
                    // byte), within the reserve above — same argument as the
                    // asm wrapper's set_len.
                    base.add(count).write(v);
                    count += 1;
                    acc = 0;
                    shift = 0;
                    chunks = 0;
                }
            }
            out.set_len(out.len() + count);
        }
    }
}

/// Decode zigzag varints into signed deltas.
///
/// HISTORY: this dispatched to a hand-written AArch64 assembly kernel. A
/// three-way bake-off (bin/bench.rs, 2026-07-19: asm 3.20 ns/byte vs
/// portable-raw-pointer 2.59 vs portable-Vec::push 2.83 on M-series)
/// showed rustc out-scheduling the hand kernel, so it was retired per the
/// repo doctrine — asm must EARN its keep against the compiler, and dead
/// fast-variants get deleted, not kept for sentiment. The shipped kernel is
/// the portable body writing through reserve + raw pointer (the asm
/// wrapper's one real trick, kept); `decode_deltas_rust` stays as the
/// fully-safe oracle the tests pin both against.
pub fn decode_deltas(bytes: &[u8], out: &mut Vec<i64>) {
    bench::deltas_rust_rawptr(bytes, out);
}

/// Decode an encoded polyline into (lon, lat) pairs — same column order as the
/// R decoder's matrix.
pub fn decode_polyline(encoded: &str) -> Vec<[f64; 2]> {
    let mut deltas: Vec<i64> = Vec::new();
    decode_deltas(encoded.as_bytes(), &mut deltas);
    let n_pairs = deltas.len() / 2; // dangling lat without lon is dropped
    let mut out = Vec::with_capacity(n_pairs);
    let mut lat: i64 = 0;
    let mut lon: i64 = 0;
    for pair in deltas.chunks_exact(2) {
        lat += pair[0];
        lon += pair[1];
        out.push([lon as f64 / 1e5, lat as f64 / 1e5]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reference encoder (Google spec) for round-trip tests.
    fn encode_value(v: i64, out: &mut String) {
        let mut zig: u64 = if v < 0 { (-2 * v - 1) as u64 } else { (2 * v) as u64 };
        loop {
            let mut chunk = (zig & 0x1f) as u32;
            zig >>= 5;
            if zig > 0 {
                chunk |= 0x20;
            }
            out.push(char::from_u32(chunk + 63).unwrap());
            if zig == 0 {
                break;
            }
        }
    }

    fn encode_polyline(latlon: &[(f64, f64)]) -> String {
        let mut prev = (0i64, 0i64);
        let mut s = String::new();
        for &(lat, lon) in latlon {
            let ilat = (lat * 1e5).round() as i64;
            let ilon = (lon * 1e5).round() as i64;
            encode_value(ilat - prev.0, &mut s);
            encode_value(ilon - prev.1, &mut s);
            prev = (ilat, ilon);
        }
        s
    }

    /// Deterministic LCG so the corpus is reproducible without a rand dep.
    struct Lcg(u64);
    impl Lcg {
        fn next_f64(&mut self) -> f64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (self.0 >> 11) as f64 / (1u64 << 53) as f64
        }
    }

    #[test]
    fn google_spec_reference_vector() {
        let got = decode_polyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@");
        let want = [
            [-12020000f64 / 1e5, 3850000f64 / 1e5],
            [-12095000f64 / 1e5, 4070000f64 / 1e5],
            [-12645300f64 / 1e5, 4325200f64 / 1e5],
        ];
        assert_eq!(got.len(), 3);
        for (g, w) in got.iter().zip(want.iter()) {
            // byte-identical, not approximately equal
            assert_eq!(g[0].to_bits(), w[0].to_bits());
            assert_eq!(g[1].to_bits(), w[1].to_bits());
        }
    }

    #[test]
    fn asm_and_rust_kernels_are_equivalent() {
        let mut rng = Lcg(4708);
        for case in 0..2000 {
            let n_pts = 1 + (rng.next_f64() * 40.0) as usize;
            let mut lat = rng.next_f64() * 180.0 - 90.0;
            let mut lon = rng.next_f64() * 360.0 - 180.0;
            let mut pts = Vec::with_capacity(n_pts);
            for _ in 0..n_pts {
                lat = (lat + rng.next_f64() - 0.5).clamp(-90.0, 90.0);
                lon = (lon + rng.next_f64() - 0.5).clamp(-180.0, 180.0);
                pts.push((lat, lon));
            }
            let enc = encode_polyline(&pts);
            let mut a: Vec<i64> = Vec::new();
            let mut b: Vec<i64> = Vec::new();
            decode_deltas_rust(enc.as_bytes(), &mut a);
            decode_deltas(enc.as_bytes(), &mut b);
            assert_eq!(a, b, "kernel divergence in case {case}: {enc}");
            let mut c: Vec<i64> = Vec::new();
            bench::deltas_rust_rawptr(enc.as_bytes(), &mut c);
            assert_eq!(a, c, "rawptr kernel divergence in case {case}: {enc}");
        }
    }

    #[test]
    fn kernels_agree_on_malformed_and_truncated_input() {
        let overflow = format!("{}^{}^", "~".repeat(6), "~".repeat(6));
        let overlong = format!("{}{}^", encode_polyline(&[(43.07, -89.40)]), "~".repeat(15));
        let full = encode_polyline(&[(43.07, -89.40), (43.10, -89.35)]);
        let truncated = &full[..full.len() - 1];
        for input in [overflow.as_str(), overlong.as_str(), truncated, "", "~", "^"] {
            let mut a: Vec<i64> = Vec::new();
            let mut b: Vec<i64> = Vec::new();
            decode_deltas_rust(input.as_bytes(), &mut a);
            decode_deltas(input.as_bytes(), &mut b);
            assert_eq!(a, b, "kernel divergence on malformed input {input:?}");
            let mut c: Vec<i64> = Vec::new();
            bench::deltas_rust_rawptr(input.as_bytes(), &mut c);
            assert_eq!(a, c, "rawptr divergence on malformed input {input:?}");
        }
    }

    #[test]
    fn overlong_varint_stops_cleanly_keeping_prior_pairs() {
        let prefix = encode_polyline(&[(43.07, -89.40)]);
        let malformed = format!("{}{}^", prefix, "~".repeat(15));
        assert_eq!(decode_polyline(&malformed), decode_polyline(&prefix));
    }

    #[test]
    fn bit31_overflow_input_yields_finite_values() {
        // 7-chunk varints with bit 31 set — the R decoder's old NA-producing case.
        let enc = format!("{}^{}^", "~".repeat(6), "~".repeat(6));
        let out = decode_polyline(&enc);
        assert_eq!(out.len(), 1);
        assert!(out[0][0].is_finite() && out[0][1].is_finite());
    }

    #[test]
    fn round_trip_identity() {
        let pts = [(90.0, 180.0), (-90.0, -180.0), (0.0, 0.0), (44.5, -89.5)];
        let dec = decode_polyline(&encode_polyline(&pts));
        assert_eq!(dec.len(), pts.len());
        for (d, p) in dec.iter().zip(pts.iter()) {
            assert_eq!(d[1].to_bits(), p.0.to_bits(), "lat");
            assert_eq!(d[0].to_bits(), p.1.to_bits(), "lon");
        }
    }
}
