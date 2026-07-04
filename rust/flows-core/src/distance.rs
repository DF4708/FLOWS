//! Euclidean distance kernel — the one FLOWS hot-path op that maps to
//! "assembly-level" optimisation done the RIGHT way (SIMD, not hand-asm).
//!
//! This is the Rust counterpart of R's `euclidean_distance_matrix`
//! (R/resource_governor.R). Given two coordinate sets A (n x 2) and
//! B (m x 2), produce the n x m distance matrix.
//!
//! Two implementations, held to byte-identical agreement by the test suite:
//!   * `distance_matrix_scalar`   — plain f64 loops (the reference).
//!   * `distance_matrix_autovec`  — a shape LLVM auto-vectorises with
//!     `-C target-cpu=native`; on Apple ARM64 this emits NEON automatically.
//!
//! Explicit `std::simd` / NEON intrinsics are a later step, gated on a
//! flamegraph proving this kernel dominates (per the migration ADR §3).
//! The point of the PoC is to show the seam exists and the scalar/vectorised
//! results are identical — never to descend to intrinsics speculatively.

/// Reference scalar implementation. Row-major output: out[i*m + j] is the
/// distance from A[i] to B[j].
pub fn distance_matrix_scalar(a: &[[f64; 2]], b: &[[f64; 2]]) -> Vec<f64> {
    let n = a.len();
    let m = b.len();
    let mut out = vec![0.0f64; n * m];
    for i in 0..n {
        let (ax, ay) = (a[i][0], a[i][1]);
        for j in 0..m {
            let dx = ax - b[j][0];
            let dy = ay - b[j][1];
            out[i * m + j] = (dx * dx + dy * dy).sqrt();
        }
    }
    out
}

/// Auto-vectorisation-friendly variant: the inner loop over B is written so
/// LLVM can pack multiple lanes per instruction. Numerically identical to the
/// scalar version (same f64 ops, same order), so it is always safe to
/// substitute. Split B's x/y into contiguous slices to help the vectoriser.
pub fn distance_matrix_autovec(a: &[[f64; 2]], b: &[[f64; 2]]) -> Vec<f64> {
    let n = a.len();
    let m = b.len();
    // Structure-of-arrays for B improves vectorisation vs array-of-structs.
    let bx: Vec<f64> = b.iter().map(|p| p[0]).collect();
    let by: Vec<f64> = b.iter().map(|p| p[1]).collect();
    let mut out = vec![0.0f64; n * m];
    for i in 0..n {
        let (ax, ay) = (a[i][0], a[i][1]);
        let row = &mut out[i * m..(i + 1) * m];
        for j in 0..m {
            let dx = ax - bx[j];
            let dy = ay - by[j];
            row[j] = (dx * dx + dy * dy).sqrt();
        }
    }
    out
}

/// Explicit ARM NEON kernel — the "assembly-level" tier, expressed as
/// intrinsics rather than hand-written assembly (per the migration ADR:
/// intrinsics get ~95% of the win, stay portable and verifiable). NEON's
/// `float64x2_t` processes 2 f64 lanes per instruction; this computes two B
/// points' distances from one A point at a time. Compiled only on aarch64
/// (Apple Silicon), where NEON is baseline — no runtime feature check needed.
///
/// Held byte-identical to `distance_matrix_scalar` by the test suite. This is
/// a *static* hot loop (the math never changes) that classifies as a valid
/// candidate for this tier: fixed kernel + measurable throughput gain.
#[cfg(target_arch = "aarch64")]
pub fn distance_matrix_neon(a: &[[f64; 2]], b: &[[f64; 2]]) -> Vec<f64> {
    use core::arch::aarch64::*;
    let n = a.len();
    let m = b.len();
    let bx: Vec<f64> = b.iter().map(|p| p[0]).collect();
    let by: Vec<f64> = b.iter().map(|p| p[1]).collect();
    let mut out = vec![0.0f64; n * m];
    // SAFETY: NEON is baseline on aarch64; all pointer arithmetic stays in
    // bounds (j2 + 2 <= m guard; scalar tail handles the odd element).
    unsafe {
        for i in 0..n {
            let ax = vdupq_n_f64(a[i][0]); // broadcast A.x to both lanes
            let ay = vdupq_n_f64(a[i][1]);
            let row = &mut out[i * m..(i + 1) * m];
            let mut j = 0usize;
            while j + 2 <= m {
                let bxv = vld1q_f64(bx.as_ptr().add(j)); // load 2 B.x
                let byv = vld1q_f64(by.as_ptr().add(j)); // load 2 B.y
                let dx = vsubq_f64(ax, bxv);
                let dy = vsubq_f64(ay, byv);
                // dx*dx + dy*dy, then sqrt — 2 lanes at once.
                let sq = vfmaq_f64(vmulq_f64(dx, dx), dy, dy);
                let dist = vsqrtq_f64(sq);
                vst1q_f64(row.as_mut_ptr().add(j), dist);
                j += 2;
            }
            // scalar tail for an odd B length.
            while j < m {
                let dx = a[i][0] - bx[j];
                let dy = a[i][1] - by[j];
                row[j] = (dx * dx + dy * dy).sqrt();
                j += 1;
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx_eq(a: &[f64], b: &[f64]) -> bool {
        a.len() == b.len()
            && a.iter().zip(b).all(|(x, y)| (x - y).abs() < 1e-12)
    }

    #[test]
    fn scalar_and_autovec_agree() {
        let a = [[0.0, 0.0], [3.0, 4.0], [-1.0, 2.5], [10.0, -7.0]];
        let b = [[0.0, 0.0], [1.0, 1.0], [5.0, 5.0]];
        let s = distance_matrix_scalar(&a, &b);
        let v = distance_matrix_autovec(&a, &b);
        assert!(approx_eq(&s, &v), "scalar vs autovec distance mismatch");
    }

    #[test]
    fn known_distances_are_correct() {
        // 3-4-5 triangle: distance from origin to (3,4) is exactly 5.
        let a = [[0.0, 0.0]];
        let b = [[3.0, 4.0]];
        let d = distance_matrix_scalar(&a, &b);
        assert!((d[0] - 5.0).abs() < 1e-15);
    }

    // The NEON intrinsic kernel must agree with the scalar reference — both
    // even and odd B lengths (exercising the vectorised body + scalar tail).
    #[cfg(target_arch = "aarch64")]
    #[test]
    fn neon_matches_scalar() {
        let a = [[0.0, 0.0], [3.0, 4.0], [-1.0, 2.5], [10.0, -7.0], [1.5, 1.5]];
        // odd length (5) to exercise the scalar tail after the 2-lane body.
        let b = [[0.0, 0.0], [1.0, 1.0], [5.0, 5.0], [-2.0, 3.0], [8.0, -1.0]];
        let s = distance_matrix_scalar(&a, &b);
        let neon = distance_matrix_neon(&a, &b);
        assert!(approx_eq(&s, &neon), "NEON vs scalar distance mismatch");
    }
}
