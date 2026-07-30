// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Euclidean distance kernel — the Rust counterpart of R's
//! `euclidean_distance_matrix` (R/resource_governor.R). Given two coordinate
//! sets A (n x 2) and B (m x 2), produce the n x m distance matrix.
//!
//! Scalar f64 reference implementation, byte-identical to the R `outer()`
//! oracle: one IEEE-754 rounding per op, no reassociation. This kernel is
//! reached ONLY through the R `.C()` bridge (`flows_distance_matrix`) — the app
//! never links it — so it is deliberately kept plain and verifiable rather than
//! hand-optimised.
//!
//! On the "assembly-level" tier (see docs/CODING_STANDARDS.md): SIMD intrinsics
//! or hand-assembly are used ONLY where a profiler proves a kernel dominates.
//! The one kernel that met that bar was the polyline varint decoder — first
//! hand-written AArch64 asm, then retired 2026-07-19 when a bench bake-off
//! showed rustc's portable raw-pointer kernel faster (`polyline::decode_deltas`).
//! This float matrix never met the bar, so it stays scalar. If a future
//! profile shows it dominating a hot path, the SIMD seam drops in behind this
//! same signature (NEON `float64x2_t` = 2 f64 lanes), and MUST stay
//! byte-identical via separate `vmulq`+`vaddq` — never a fused multiply-add,
//! whose single rounding would diverge from this scalar/R oracle by ~1 ULP.

/// Row-major output: out[i*m + j] is the distance from A[i] to B[j].
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_distances_are_correct() {
        // 3-4-5 triangle: distance from origin to (3,4) is exactly 5.
        let a = [[0.0, 0.0]];
        let b = [[3.0, 4.0]];
        let d = distance_matrix_scalar(&a, &b);
        assert!((d[0] - 5.0).abs() < 1e-15);
    }

    #[test]
    fn row_major_layout_and_values() {
        // Two A rows × three B cols → 2×3 row-major matrix.
        let a = [[0.0, 0.0], [1.0, 0.0]];
        let b = [[0.0, 0.0], [0.0, 1.0], [2.0, 0.0]];
        let d = distance_matrix_scalar(&a, &b);
        assert_eq!(d.len(), 6);
        assert_eq!(d[0], 0.0); // A0→B0
        assert_eq!(d[1], 1.0); // A0→B1
        assert_eq!(d[2], 2.0); // A0→B2
        assert_eq!(d[3], 1.0); // A1→B0
        assert_eq!(d[5], 1.0); // A1→B2
    }
}
