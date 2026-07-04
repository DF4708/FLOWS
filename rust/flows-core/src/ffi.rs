//! C-ABI FFI surface — how the Swift UI calls into the Rust core.
//!
//! Phase R0 uses the raw C ABI (smallest surface, proves the link works).
//! Later phases migrate to UniFFI for ergonomic struct/enum/async marshalling
//! (per docs/RUST_SWIFT_MIGRATION.md §4). These `extern "C"` functions are
//! callable from Swift via a bridging header:
//!
//!   // flows_core.h (bridging header)
//!   const char* flows_risk_label(double score);
//!   const char* flows_risk_rgb_hex(double score);
//!
//!   // Swift
//!   let label = String(cString: flows_risk_label(0.75))  // "Yellow"

use crate::risk::risk_band;
use std::os::raw::c_char;

/// Return the risk band label for a score as a static C string.
/// The returned pointer is to a 'static NUL-terminated string owned by the
/// library — the caller must NOT free it. This keeps the FFI allocation-free
/// and leak-free for the fixed label set.
#[no_mangle]
pub extern "C" fn flows_risk_label(score: f64) -> *const c_char {
    // Each label has a matching NUL-terminated 'static byte string so we can
    // hand out a stable pointer with no allocation.
    let s: &'static [u8] = match risk_band(score).label() {
        "Transparent" => b"Transparent\0",
        "Green" => b"Green\0",
        "Yellow" => b"Yellow\0",
        "Red" => b"Red\0",
        _ => b"Transparent\0",
    };
    s.as_ptr() as *const c_char
}

/// Return the CSS hex colour for a score as a static C string (see above for
/// ownership: 'static, do not free).
#[no_mangle]
pub extern "C" fn flows_risk_rgb_hex(score: f64) -> *const c_char {
    let s: &'static [u8] = match risk_band(score).rgb_hex() {
        "transparent" => b"transparent\0",
        "#2ecc71" => b"#2ecc71\0",
        "#f1c40f" => b"#f1c40f\0",
        "#dc3545" => b"#dc3545\0",
        _ => b"transparent\0",
    };
    s.as_ptr() as *const c_char
}

/// Fill a caller-provided buffer with the n x m Euclidean distance matrix.
/// `a` points to n*2 doubles (row-major x,y pairs), `b` to m*2, `out` to
/// n*m doubles the caller owns. Returns 0 on success, -1 on a null/size
/// error. This is the allocation-across-FFI-free pattern: Swift owns the
/// output buffer, Rust just fills it.
///
/// # Safety
/// Caller must ensure `a` has 2*n, `b` has 2*m, and `out` has n*m valid
/// f64 elements. Standard C-ABI contract.
#[no_mangle]
pub unsafe extern "C" fn flows_distance_matrix(
    a: *const f64,
    n: usize,
    b: *const f64,
    m: usize,
    out: *mut f64,
) -> i32 {
    if a.is_null() || b.is_null() || out.is_null() {
        return -1;
    }
    // Delegate to the canonical kernel in distance.rs (same f64 ops, same
    // row-major order) instead of re-implementing the loop inline — one
    // implementation to test/optimise, and the SIMD variants stay swappable.
    let a_slice = std::slice::from_raw_parts(a as *const [f64; 2], n);
    let b_slice = std::slice::from_raw_parts(b as *const [f64; 2], m);
    let res = crate::distance::distance_matrix_scalar(a_slice, b_slice);
    std::slice::from_raw_parts_mut(out, n * m).copy_from_slice(&res);
    0
}

/// R `.C()`-callable wrapper for `flows_distance_matrix`. R's `.C()` marshals
/// every argument as a pointer, so the sizes arrive as `*const i32` rather
/// than `usize`-by-value. This shim dereferences them and delegates to the
/// core kernel (no logic duplication). Returns void per the `.C()` contract;
/// results land in `out` (row-major n*m), which R reshapes with byrow=TRUE.
///
/// # Safety
/// `a` must have 2*(*n) f64s, `b` 2*(*m), `out` (*n)*(*m); `n`,`m` non-null.
#[no_mangle]
pub unsafe extern "C" fn flows_distance_matrix_c(
    a: *const f64,
    n: *const i32,
    b: *const f64,
    m: *const i32,
    out: *mut f64,
) {
    if n.is_null() || m.is_null() {
        return;
    }
    let nn = (*n).max(0) as usize;
    let mm = (*m).max(0) as usize;
    flows_distance_matrix(a, nn, b, mm, out);
}

/// Scalar piecewise hazard score (see crate::scoring::piecewise_score).
/// Byte-identical to R `piecewise_score`. Plain f64 in/out — callable from
/// Swift directly and from R via `.C()` (R marshals scalars as length-1
/// double pointers, but a by-value f64 also works through `.C` when passed
/// as `as.double`; prefer the batch form below for R vector inputs).
#[no_mangle]
pub extern "C" fn flows_piecewise_score(value: f64, low: f64, medium: f64, high: f64) -> f64 {
    crate::scoring::piecewise_score(value, low, medium, high)
}

/// R `.C()`-callable rowwise batch: score `*n` values against PER-ELEMENT
/// threshold arrays `low`,`mid`,`high` (each `*n` long), writing `*n` results
/// to `out`. This is the hottest scoring path — the per-zip risk builder with
/// spatially-varying thresholds. Every arg is a pointer per the `.C()` ABI; the
/// R wrapper recycles the threshold vectors to length n before calling.
///
/// # Safety
/// `values`,`low`,`mid`,`high`,`out` must each have `*n` valid f64s; `n` non-null.
#[no_mangle]
pub unsafe extern "C" fn flows_piecewise_score_rowwise_batch(
    values: *const f64,
    n: *const i32,
    low: *const f64,
    mid: *const f64,
    high: *const f64,
    out: *mut f64,
) {
    if values.is_null() || n.is_null() || low.is_null() || mid.is_null()
        || high.is_null() || out.is_null()
    {
        return;
    }
    let nn = (*n).max(0) as usize;
    let v = std::slice::from_raw_parts(values, nn);
    let lo = std::slice::from_raw_parts(low, nn);
    let mi = std::slice::from_raw_parts(mid, nn);
    let hi = std::slice::from_raw_parts(high, nn);
    let o = std::slice::from_raw_parts_mut(out, nn);
    for i in 0..nn {
        o[i] = crate::scoring::piecewise_score_rowwise(v[i], lo[i], mi[i], hi[i]);
    }
}

/// Scalar symmetric temperature risk (see crate::scoring::temperature_risk).
/// Byte-identical to R `temperature_risk`. Plain f64 in/out for Swift + R `.C`.
#[no_mangle]
pub extern "C" fn flows_temperature_risk(
    temp_f: f64,
    comfort_low_f: f64,
    comfort_high_f: f64,
    record_low_f: f64,
    record_high_f: f64,
) -> f64 {
    crate::scoring::temperature_risk(temp_f, comfort_low_f, comfort_high_f, record_low_f, record_high_f)
}

/// R `.C()`-callable batch: score `*n` values against the SCALAR thresholds
/// (`*low`, `*medium`, `*high`), writing `*n` results into `out`. Every arg is
/// a pointer per the `.C()` ABI. This is the vector hot path — it replaces an
/// R-level `vapply(values, piecewise_score, ...)` loop with one compiled pass.
///
/// # Safety
/// `values` and `out` must each have `*n` valid f64s; `n`,`low`,`medium`,`high`
/// non-null. Standard C-ABI contract.
#[no_mangle]
pub unsafe extern "C" fn flows_piecewise_score_batch(
    values: *const f64,
    n: *const i32,
    low: *const f64,
    medium: *const f64,
    high: *const f64,
    out: *mut f64,
) {
    if values.is_null() || n.is_null() || out.is_null()
        || low.is_null() || medium.is_null() || high.is_null()
    {
        return;
    }
    let nn = (*n).max(0) as usize;
    let (lo, me, hi) = (*low, *medium, *high);
    let vs = std::slice::from_raw_parts(values, nn);
    let os = std::slice::from_raw_parts_mut(out, nn);
    for i in 0..nn {
        os[i] = crate::scoring::piecewise_score(vs[i], lo, me, hi);
    }
}

/// R `.C()`-callable single-source Dijkstra. Builds a CsrGraph from R vectors
/// (0-based node ids) and writes the `*n_nodes` shortest distances from
/// `*source` into `out_dist` (R receives f64::INFINITY as Inf for unreachable).
/// This is the graph-ingest surface for the CONUS router; production edge
/// lists (1-based) convert to 0-based on the R side before calling.
///
/// # Safety
/// `offsets` must have `*n_nodes + 1` i32s; `targets`/`weights` `*n_edges` each;
/// `out_dist` `*n_nodes`; all pointers non-null; ids in range.
#[no_mangle]
pub unsafe extern "C" fn flows_dijkstra_c(
    offsets: *const i32,
    n_nodes: *const i32,
    targets: *const i32,
    weights: *const f64,
    n_edges: *const i32,
    source: *const i32,
    out_dist: *mut f64,
) {
    if offsets.is_null() || n_nodes.is_null() || targets.is_null() || weights.is_null()
        || n_edges.is_null() || source.is_null() || out_dist.is_null()
    {
        return;
    }
    let nn = (*n_nodes).max(0) as usize;
    let me = (*n_edges).max(0) as usize;
    let out = std::slice::from_raw_parts_mut(out_dist, nn);
    // Error sentinel: fill with NaN (valid distances are finite or +Inf, never
    // NaN), so the R wrapper can detect failure and fall back to pure R
    // instead of the old behaviour — an index-out-of-bounds PANIC that cannot
    // unwind across extern "C" and aborted the entire R process.
    let src_raw = *source;
    let off_raw = std::slice::from_raw_parts(offsets, nn + 1);
    let tgt_raw = std::slice::from_raw_parts(targets, me);
    let valid = src_raw >= 0 && (src_raw as usize) < nn
        && off_raw.first().is_some_and(|&o| o == 0)
        && off_raw.last().is_some_and(|&o| o >= 0 && o as usize == me)
        && off_raw.windows(2).all(|w| w[0] >= 0 && w[1] >= w[0])
        && tgt_raw.iter().all(|&t| t >= 0 && (t as usize) < nn);
    if !valid {
        out.fill(f64::NAN);
        return;
    }
    let computed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let off: Vec<u32> = off_raw.iter().map(|&x| x as u32).collect();
        let tgt: Vec<u32> = tgt_raw.iter().map(|&x| x as u32).collect();
        let wts: Vec<f64> = std::slice::from_raw_parts(weights, me).to_vec();
        let g = crate::routing::CsrGraph { offsets: off, targets: tgt, weights: wts };
        g.dijkstra(src_raw as usize)
    }));
    match computed {
        Ok(dist) => out.copy_from_slice(&dist),
        Err(_) => out.fill(f64::NAN), // belt-and-suspenders: never panic across FFI
    }
}

/// R `.C()`-callable contraction-hierarchy batch query. Builds a CsrGraph from
/// R vectors (0-based), preprocesses the CH ONCE, then answers `*n_queries`
/// (source, target) pairs, writing costs into `out` (f64::INFINITY = Inf for
/// unreachable). Amortises the CH preprocessing across all queries — the whole
/// point of CH. Costs equal the plain Dijkstra costs (cargo-proven).
///
/// # Safety
/// `offsets` has `*n_nodes+1` i32s; `targets`/`weights` `*n_edges`; `srcs`/`dsts`
/// `*n_queries`; `out` `*n_queries`; all non-null; ids in range.
#[no_mangle]
pub unsafe extern "C" fn flows_ch_query_c(
    offsets: *const i32,
    n_nodes: *const i32,
    targets: *const i32,
    weights: *const f64,
    n_edges: *const i32,
    srcs: *const i32,
    dsts: *const i32,
    n_queries: *const i32,
    out: *mut f64,
) {
    if offsets.is_null() || n_nodes.is_null() || targets.is_null() || weights.is_null()
        || n_edges.is_null() || srcs.is_null() || dsts.is_null() || n_queries.is_null() || out.is_null()
    {
        return;
    }
    let nn = (*n_nodes).max(0) as usize;
    let me = (*n_edges).max(0) as usize;
    let nq = (*n_queries).max(0) as usize;
    let os = std::slice::from_raw_parts_mut(out, nq);
    let off_raw = std::slice::from_raw_parts(offsets, nn + 1);
    let tgt_raw = std::slice::from_raw_parts(targets, me);
    let ss = std::slice::from_raw_parts(srcs, nq);
    let ds = std::slice::from_raw_parts(dsts, nq);
    // Validate ids/offsets up front; on failure fill the NaN error sentinel
    // rather than clamping negatives to node 0 (silently wrong answers) or
    // panicking on out-of-range ids (aborts the whole R process — a panic
    // cannot unwind across extern "C").
    let valid = off_raw.first().is_some_and(|&o| o == 0)
        && off_raw.last().is_some_and(|&o| o >= 0 && o as usize == me)
        && off_raw.windows(2).all(|w| w[0] >= 0 && w[1] >= w[0])
        && tgt_raw.iter().all(|&t| t >= 0 && (t as usize) < nn)
        && ss.iter().all(|&s| s >= 0 && (s as usize) < nn)
        && ds.iter().all(|&d| d >= 0 && (d as usize) < nn);
    if !valid {
        os.fill(f64::NAN);
        return;
    }
    let computed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let off: Vec<u32> = off_raw.iter().map(|&x| x as u32).collect();
        let tgt: Vec<u32> = tgt_raw.iter().map(|&x| x as u32).collect();
        let wts: Vec<f64> = std::slice::from_raw_parts(weights, me).to_vec();
        let g = crate::routing::CsrGraph { offsets: off, targets: tgt, weights: wts };
        let ch = crate::ch::ContractionHierarchy::preprocess(&g);
        (0..nq).map(|i| ch.query(ss[i] as usize, ds[i] as usize)).collect::<Vec<f64>>()
    }));
    match computed {
        Ok(costs) => os.copy_from_slice(&costs),
        Err(_) => os.fill(f64::NAN),
    }
}

/// Decode a Google encoded polyline into interleaved lon,lat doubles.
/// `bytes`/`len` is the encoded string (need not be NUL-terminated); `out`
/// receives up to `cap_pairs` pairs (2 doubles each, lon first — matching the
/// R decoder's column order). Returns the TOTAL number of pairs in the input,
/// which may exceed `cap_pairs`; call with `out == NULL` / `cap_pairs == 0`
/// to size the buffer first (a `len / 2 + 1` pair buffer is always enough).
/// Returns -1 on a NULL `bytes` with nonzero `len`. Swift owns the buffer —
/// same allocation-across-FFI-free pattern as `flows_distance_matrix`.
///
/// # Safety
/// `bytes` must be valid for `len` reads and `out` for `2 * cap_pairs` f64
/// writes (or NULL with `cap_pairs == 0`). Standard C-ABI contract.
#[no_mangle]
pub unsafe extern "C" fn flows_polyline_decode(
    bytes: *const u8,
    len: usize,
    out: *mut f64,
    cap_pairs: usize,
) -> i64 {
    if bytes.is_null() && len != 0 {
        return -1;
    }
    let encoded = if len == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(bytes, len)
    };
    let mut deltas: Vec<i64> = Vec::new();
    crate::polyline::decode_deltas(encoded, &mut deltas);
    let n_pairs = deltas.len() / 2;
    if !out.is_null() && cap_pairs > 0 {
        let os = std::slice::from_raw_parts_mut(out, 2 * cap_pairs.min(n_pairs));
        let mut lat: i64 = 0;
        let mut lon: i64 = 0;
        for (i, pair) in deltas.chunks_exact(2).take(cap_pairs).enumerate() {
            lat += pair[0];
            lon += pair[1];
            os[2 * i] = lon as f64 / 1e5;
            os[2 * i + 1] = lat as f64 / 1e5;
        }
    }
    n_pairs as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    #[test]
    fn ffi_label_roundtrips() {
        // SAFETY: pointer is to a 'static NUL-terminated string.
        let got = unsafe { CStr::from_ptr(flows_risk_label(0.75)) }
            .to_str()
            .unwrap();
        assert_eq!(got, "Yellow");
    }

    #[test]
    fn ffi_dijkstra_invalid_ids_fill_nan_no_abort() {
        // Out-of-range target id: must fill the NaN sentinel, NOT panic
        // (a panic across extern "C" aborts the process).
        let offsets = [0i32, 1, 2];
        let targets = [9i32, 0]; // 9 >= n_nodes=2 -> invalid
        let weights = [1.0f64, 1.0];
        let (nn, me, src) = (2i32, 2i32, 0i32);
        let mut out = [0.0f64; 2];
        unsafe {
            flows_dijkstra_c(offsets.as_ptr(), &nn, targets.as_ptr(), weights.as_ptr(), &me, &src, out.as_mut_ptr());
        }
        assert!(out.iter().all(|v| v.is_nan()), "expected NaN sentinel, got {out:?}");
        // Negative source: also invalid (was silently clamped to node 0).
        let targets_ok = [1i32, 0];
        let bad_src = -1i32;
        let mut out2 = [0.0f64; 2];
        unsafe {
            flows_dijkstra_c(offsets.as_ptr(), &nn, targets_ok.as_ptr(), weights.as_ptr(), &me, &bad_src, out2.as_mut_ptr());
        }
        assert!(out2.iter().all(|v| v.is_nan()));
        // Valid input still works.
        let good_src = 0i32;
        let mut out3 = [0.0f64; 2];
        unsafe {
            flows_dijkstra_c(offsets.as_ptr(), &nn, targets_ok.as_ptr(), weights.as_ptr(), &me, &good_src, out3.as_mut_ptr());
        }
        assert_eq!(out3[0], 0.0);
        assert_eq!(out3[1], 1.0);
    }

    #[test]
    fn ffi_ch_query_invalid_ids_fill_nan_no_abort() {
        let offsets = [0i32, 1, 2];
        let targets = [1i32, 0];
        let weights = [1.0f64, 1.0];
        let (nn, me, nq) = (2i32, 2i32, 1i32);
        let srcs = [0i32];
        let bad_dsts = [5i32]; // >= n_nodes -> invalid
        let mut out = [0.0f64; 1];
        unsafe {
            flows_ch_query_c(offsets.as_ptr(), &nn, targets.as_ptr(), weights.as_ptr(), &me,
                             srcs.as_ptr(), bad_dsts.as_ptr(), &nq, out.as_mut_ptr());
        }
        assert!(out[0].is_nan());
        let good_dsts = [1i32];
        let mut out2 = [0.0f64; 1];
        unsafe {
            flows_ch_query_c(offsets.as_ptr(), &nn, targets.as_ptr(), weights.as_ptr(), &me,
                             srcs.as_ptr(), good_dsts.as_ptr(), &nq, out2.as_mut_ptr());
        }
        assert_eq!(out2[0], 1.0);
    }

    #[test]
    fn ffi_polyline_decode_two_pass() {
        let enc = "_p~iF~ps|U_ulLnnqC_mqNvxq`@";
        // pass 1: size query
        let n = unsafe { flows_polyline_decode(enc.as_ptr(), enc.len(), std::ptr::null_mut(), 0) };
        assert_eq!(n, 3);
        // pass 2: fill
        let mut buf = vec![0.0f64; 2 * n as usize];
        let n2 = unsafe { flows_polyline_decode(enc.as_ptr(), enc.len(), buf.as_mut_ptr(), n as usize) };
        assert_eq!(n2, 3);
        assert_eq!(buf[0].to_bits(), (-120.2f64).to_bits()); // lon first
        assert_eq!(buf[1].to_bits(), 38.5f64.to_bits());
        // capped fill only writes cap pairs but still reports the total
        let mut small = vec![0.0f64; 2];
        let n3 = unsafe { flows_polyline_decode(enc.as_ptr(), enc.len(), small.as_mut_ptr(), 1) };
        assert_eq!(n3, 3);
        assert_eq!(small[1].to_bits(), 38.5f64.to_bits());
        // degenerate inputs
        assert_eq!(unsafe { flows_polyline_decode(std::ptr::null(), 5, std::ptr::null_mut(), 0) }, -1);
        assert_eq!(unsafe { flows_polyline_decode(std::ptr::null(), 0, std::ptr::null_mut(), 0) }, 0);
    }

    #[test]
    fn ffi_distance_matrix_fills_buffer() {
        let a = [0.0f64, 0.0]; // one point (0,0)
        let b = [3.0f64, 4.0]; // one point (3,4)
        let mut out = [0.0f64; 1];
        let rc = unsafe {
            flows_distance_matrix(a.as_ptr(), 1, b.as_ptr(), 1, out.as_mut_ptr())
        };
        assert_eq!(rc, 0);
        assert!((out[0] - 5.0).abs() < 1e-15);
    }
}
