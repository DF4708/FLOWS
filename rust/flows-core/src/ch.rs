// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! ch.rs — contraction hierarchies over the CSR graph (CONUS router phase 2).
//!
//! CH precomputes "shortcut" edges so a shortest-path query only ever walks
//! toward higher-importance nodes, touching O(log n)-ish of the graph instead
//! of all of it — that's what makes cross-country routing load as fast as
//! local. Correctness is INDEPENDENT of the contraction order (order only
//! changes how many shortcuts are added, i.e. query speed), so this first
//! correct version contracts in a simple order and is proven by cargo test to
//! return the SAME shortest-path cost as a plain Dijkstra on random graphs.
//! Order optimisation (edge-difference heuristic) is a later, speed-only step.
//!
//! Graph model: our routing graph is bidirectional with symmetric weights, so
//! we contract it as an undirected weighted graph (parallel edges collapsed to
//! the min weight). The query is a bidirectional "upward" search.

use std::collections::{BTreeMap, BinaryHeap};
use std::cmp::Reverse;

use crate::routing::{CsrGraph, HeapItem};

/// A preprocessed contraction hierarchy: `up[u]` holds only the edges from `u`
/// to strictly-higher-rank neighbours (rank = contraction order), which is all
/// a correct bidirectional query needs.
pub struct ContractionHierarchy {
    /// up[u] = list of (neighbour, weight) with rank[neighbour] > rank[u].
    up: Vec<Vec<(u32, f64)>>,
    /// Number of shortcut edges inserted during preprocessing (lower = faster
    /// queries; the whole point of a good node ordering).
    pub shortcuts: usize,
    /// Shortcut-unpacking table: `middle[(a,b)]` (with a<b) is the contracted
    /// node `v` that the current min-weight edge a<->b bypasses (a..v..b).
    /// Absent => a<->b is an ORIGINAL graph edge. Populated as a pure by-product
    /// of contraction (it never touches the cost/up-graph the query locks), so
    /// `query` stays byte-identical; only `query_path` reads it.
    middle: BTreeMap<(u32, u32), u32>,
}

impl ContractionHierarchy {
    /// Build the mutable undirected min-weight adjacency from a CsrGraph.
    fn build_adj(g: &CsrGraph) -> Vec<BTreeMap<u32, f64>> {
        let n = g.num_nodes();
        let mut adj: Vec<BTreeMap<u32, f64>> = vec![BTreeMap::new(); n];
        for u in 0..n {
            let (s, e) = (g.offsets[u] as usize, g.offsets[u + 1] as usize);
            for k in s..e {
                let v = g.targets[k];
                let w = g.weights[k];
                if !(w.is_finite() && w >= 0.0) { continue; }
                relax_min(&mut adj[u], v, w);
                relax_min(&mut adj[v as usize], u as u32, w);
            }
        }
        adj
    }

    /// Preprocess with DYNAMIC LAZY node ordering: repeatedly contract the
    /// currently least-important node, where importance(v) = (shortcuts v would
    /// add now) − (v's live degree). Because contraction changes the graph, the
    /// scores go stale, so we lazily recompute: pop the heap-min, recompute its
    /// importance, and if it is no longer <= the next-best, re-push it and try
    /// again; otherwise contract it. Yields far fewer shortcuts than a static
    /// order (that's the query-speed lever). Any order is CORRECT — only the
    /// shortcut count differs — so the cost==Dijkstra gate still holds.
    pub fn preprocess(g: &CsrGraph) -> ContractionHierarchy {
        let n = g.num_nodes();
        let mut adj = Self::build_adj(g);
        let mut contracted = vec![false; n];
        let mut rank = vec![0u32; n];
        let mut level = vec![0u32; n];
        let mut shortcuts = 0usize;
        let mut middle: BTreeMap<(u32, u32), u32> = BTreeMap::new();
        let mut heap: BinaryHeap<Reverse<(i64, u32)>> = BinaryHeap::new();
        for v in 0..n {
            heap.push(Reverse((importance(&adj, &contracted, &level, v), v as u32)));
        }
        let mut order = 0u32;
        while let Some(Reverse((_imp, vn))) = heap.pop() {
            let v = vn as usize;
            if contracted[v] { continue; } // stale duplicate
            let imp_now = importance(&adj, &contracted, &level, v);
            if let Some(&Reverse((next_imp, _))) = heap.peek() {
                if imp_now > next_imp {
                    heap.push(Reverse((imp_now, vn))); // stale score: defer
                    continue;
                }
            }
            // Push live neighbours one level deeper (spread the hierarchy).
            let vl = level[v];
            for (&x, _) in adj[v].iter() {
                let xi = x as usize;
                if !contracted[xi] && level[xi] < vl + 1 { level[xi] = vl + 1; }
            }
            rank[v] = order;
            order += 1;
            shortcuts += contract_node(&mut adj, &contracted, v, &mut middle);
            contracted[v] = true;
        }
        ContractionHierarchy { up: build_up_graph(&adj, &rank), shortcuts, middle }
    }

    /// Preprocess contracting nodes in the given explicit order (order[k] gets
    /// rank k). Any order is CORRECT; only the shortcut count (query speed)
    /// differs. Exposed so tests can compare orderings.
    pub fn preprocess_with_order(g: &CsrGraph, order: &[usize]) -> ContractionHierarchy {
        let n = g.num_nodes();
        let mut adj = Self::build_adj(g);
        let mut contracted = vec![false; n];
        let mut rank = vec![0u32; n];
        let mut shortcuts = 0usize;
        let mut middle: BTreeMap<(u32, u32), u32> = BTreeMap::new();
        for (k, &v) in order.iter().enumerate() {
            rank[v] = k as u32;
            shortcuts += contract_node(&mut adj, &contracted, v, &mut middle);
            contracted[v] = true;
        }
        ContractionHierarchy { up: build_up_graph(&adj, &rank), shortcuts, middle }
    }

    /// Shortest-path cost from `s` to `t` via bidirectional upward search with
    /// early termination — no O(n) meet loop. Forward from s and backward from t
    /// both walk only up-edges (symmetric up-graph); the meeting cost `best` is
    /// updated as nodes are relaxed, and each side stops advancing once its
    /// frontier distance can no longer beat `best`. Equal to the Dijkstra cost.
    pub fn query(&self, s: usize, t: usize) -> f64 {
        let n = self.up.len();
        if s >= n || t >= n { return f64::INFINITY; }
        if s == t { return 0.0; }
        let mut df = vec![f64::INFINITY; n]; df[s] = 0.0;
        let mut db = vec![f64::INFINITY; n]; db[t] = 0.0;
        let mut hf = BinaryHeap::new(); hf.push(HeapItem { dist: 0.0, node: s as u32 });
        let mut hb = BinaryHeap::new(); hb.push(HeapItem { dist: 0.0, node: t as u32 });
        let mut best = f64::INFINITY;
        loop {
            let ftop = hf.peek().map(|h| h.dist);
            let btop = hb.peek().map(|h| h.dist);
            let f_live = ftop.is_some_and(|d| d < best);
            let b_live = btop.is_some_and(|d| d < best);
            let go_fwd = match (f_live, b_live) {
                (true, true) => ftop.unwrap() <= btop.unwrap(),
                (true, false) => true,
                (false, true) => false,
                (false, false) => break,
            };
            if go_fwd {
                let HeapItem { dist: d, node } = hf.pop().unwrap();
                let u = node as usize;
                if d > df[u] { continue; }
                if db[u].is_finite() { let c = d + db[u]; best = best.min(c); }
                for &(x, w) in &self.up[u] {
                    let nd = d + w; let xi = x as usize;
                    if nd < df[xi] {
                        df[xi] = nd;
                        hf.push(HeapItem { dist: nd, node: x });
                        if db[xi].is_finite() { let c = nd + db[xi]; best = best.min(c); }
                    }
                }
            } else {
                let HeapItem { dist: d, node } = hb.pop().unwrap();
                let u = node as usize;
                if d > db[u] { continue; }
                if df[u].is_finite() { let c = df[u] + d; best = best.min(c); }
                for &(x, w) in &self.up[u] {
                    let nd = d + w; let xi = x as usize;
                    if nd < db[xi] {
                        db[xi] = nd;
                        hb.push(HeapItem { dist: nd, node: x });
                        if df[xi].is_finite() { let c = df[xi] + nd; best = best.min(c); }
                    }
                }
            }
        }
        best
    }

    /// Shortest path from `s` to `t` as a full node sequence in the ORIGINAL
    /// graph, plus its cost. Same bidirectional upward search as `query`, but
    /// tracks a predecessor on each side and the meeting node, reconstructs the
    /// up-graph node sequence s→meet→t, then expands every shortcut edge back
    /// into its two halves (recursively, via `middle`) so the result walks only
    /// real edges. Returns `(cost, path)`; `path` is `[s]` when s==t and empty
    /// when t is unreachable (cost `INFINITY`). Cost equals `query(s,t)`.
    pub fn query_path(&self, s: usize, t: usize) -> (f64, Vec<u32>) {
        let n = self.up.len();
        if s >= n || t >= n { return (f64::INFINITY, Vec::new()); }
        if s == t { return (0.0, vec![s as u32]); }
        const NONE: u32 = u32::MAX;
        let mut df = vec![f64::INFINITY; n]; df[s] = 0.0;
        let mut db = vec![f64::INFINITY; n]; db[t] = 0.0;
        let mut pf = vec![NONE; n]; // forward predecessor (toward s)
        let mut pb = vec![NONE; n]; // backward predecessor (toward t)
        let mut hf = BinaryHeap::new(); hf.push(HeapItem { dist: 0.0, node: s as u32 });
        let mut hb = BinaryHeap::new(); hb.push(HeapItem { dist: 0.0, node: t as u32 });
        let mut best = f64::INFINITY;
        let mut meet = NONE;
        loop {
            let ftop = hf.peek().map(|h| h.dist);
            let btop = hb.peek().map(|h| h.dist);
            let f_live = ftop.is_some_and(|d| d < best);
            let b_live = btop.is_some_and(|d| d < best);
            let go_fwd = match (f_live, b_live) {
                (true, true) => ftop.unwrap() <= btop.unwrap(),
                (true, false) => true,
                (false, true) => false,
                (false, false) => break,
            };
            if go_fwd {
                let HeapItem { dist: d, node } = hf.pop().unwrap();
                let u = node as usize;
                if d > df[u] { continue; }
                if db[u].is_finite() { let c = d + db[u]; if c < best { best = c; meet = node; } }
                for &(x, w) in &self.up[u] {
                    let nd = d + w; let xi = x as usize;
                    if nd < df[xi] {
                        df[xi] = nd; pf[xi] = node;
                        hf.push(HeapItem { dist: nd, node: x });
                        if db[xi].is_finite() { let c = nd + db[xi]; if c < best { best = c; meet = x; } }
                    }
                }
            } else {
                let HeapItem { dist: d, node } = hb.pop().unwrap();
                let u = node as usize;
                if d > db[u] { continue; }
                if df[u].is_finite() { let c = df[u] + d; if c < best { best = c; meet = node; } }
                for &(x, w) in &self.up[u] {
                    let nd = d + w; let xi = x as usize;
                    if nd < db[xi] {
                        db[xi] = nd; pb[xi] = node;
                        hb.push(HeapItem { dist: nd, node: x });
                        if df[xi].is_finite() { let c = df[xi] + nd; if c < best { best = c; meet = x; } }
                    }
                }
            }
        }
        if meet == NONE || !best.is_finite() { return (f64::INFINITY, Vec::new()); }
        // Reconstruct the up-graph node sequence s → meet (forward preds) then
        // meet → t (backward preds). Each consecutive pair is one up-edge.
        let mut up_nodes: Vec<u32> = Vec::new();
        let mut x = meet;
        while x != NONE { up_nodes.push(x); if x as usize == s { break; } x = pf[x as usize]; }
        up_nodes.reverse(); // now s .. meet
        let mut x = pb[meet as usize];
        while x != NONE { up_nodes.push(x); if x as usize == t { break; } x = pb[x as usize]; }
        // Expand every up-edge (some are shortcuts) into original edges.
        let mut path: Vec<u32> = vec![up_nodes[0]];
        for w in up_nodes.windows(2) { self.unpack_edge_into(w[0], w[1], &mut path); }
        (best, path)
    }

    /// Append the interior + endpoint of edge (a,b) to `out` (everything AFTER
    /// `a`, ending at `b`), expanding shortcuts recursively via `middle`.
    /// Iterative (explicit stack) so deep shortcut nesting on a large graph
    /// cannot overflow the call stack; the push order (right half, then left
    /// half) makes the pops emit strictly left-to-right.
    fn unpack_edge_into(&self, a: u32, b: u32, out: &mut Vec<u32>) {
        let mut stack: Vec<(u32, u32)> = vec![(a, b)];
        while let Some((x, y)) = stack.pop() {
            let key = if x < y { (x, y) } else { (y, x) };
            match self.middle.get(&key) {
                Some(&mid) => { stack.push((mid, y)); stack.push((x, mid)); }
                None => out.push(y), // original edge x->y
            }
        }
    }
}

/// Count the shortcuts contracting `v` would add now (witness-checked), without
/// mutating the graph. Each undirected shortcut counts once (the reverse
/// ordered pair sees the just-decided edge and is skipped).
fn count_shortcuts_if_contracted(adj: &[BTreeMap<u32, f64>], contracted: &[bool], v: usize) -> usize {
    let nbrs: Vec<(u32, f64)> = adj[v]
        .iter()
        .filter(|(&x, _)| !contracted[x as usize])
        .map(|(&x, &w)| (x, w))
        .collect();
    let mut seen: BTreeMap<(u32, u32), f64> = BTreeMap::new();
    let mut cnt = 0usize;
    for i in 0..nbrs.len() {
        for j in 0..nbrs.len() {
            if i == j { continue; }
            let (u, wuv) = nbrs[i];
            let (w, wvw) = nbrs[j];
            let key = if u < w { (u, w) } else { (w, u) };
            let direct = wuv + wvw;
            if seen.contains_key(&key) { continue; }
            if !witness_within(adj, contracted, u as usize, w as usize, v, direct) {
                let existed = adj[u as usize].get(&w).is_some_and(|&e| e <= direct);
                if !existed { cnt += 1; seen.insert(key, direct); }
            }
        }
    }
    cnt
}

/// Contract node `v`: for each ordered live-neighbour pair (u, w), add an
/// undirected shortcut u<->w of weight dist(u,v)+dist(v,w) unless a witness path
/// avoiding v is already <= that. Returns the count of NEW shortcuts (each
/// undirected shortcut once). Mutates `adj`, and records the bypassed node `v`
/// in `middle` for every shortcut that becomes the new min edge on its pair
/// (exactly the `!existed` case — so path unpacking always resolves the min
/// edge, and originals that stay cheapest keep no middle).
fn contract_node(
    adj: &mut [BTreeMap<u32, f64>],
    contracted: &[bool],
    v: usize,
    middle: &mut BTreeMap<(u32, u32), u32>,
) -> usize {
    let nbrs: Vec<(u32, f64)> = adj[v]
        .iter()
        .filter(|(&x, _)| !contracted[x as usize])
        .map(|(&x, &w)| (x, w))
        .collect();
    let mut added = 0usize;
    for i in 0..nbrs.len() {
        for j in 0..nbrs.len() {
            if i == j { continue; }
            let (u, wuv) = nbrs[i];
            let (w, wvw) = nbrs[j];
            let direct = wuv + wvw;
            if !witness_within(adj, contracted, u as usize, w as usize, v, direct) {
                let existed = adj[u as usize].get(&w).is_some_and(|&e| e <= direct);
                relax_min(&mut adj[u as usize], w, direct);
                relax_min(&mut adj[w as usize], u, direct);
                if !existed {
                    added += 1;
                    let key = if u < w { (u, w) } else { (w, u) };
                    middle.insert(key, v as u32);
                }
            }
        }
    }
    added
}

/// Number of not-yet-contracted neighbours of `v`.
fn live_degree(adj: &[BTreeMap<u32, f64>], contracted: &[bool], v: usize) -> usize {
    adj[v].keys().filter(|&&x| !contracted[x as usize]).count()
}

/// Node importance for contraction ordering. Two standard terms:
///   * edge difference = (shortcuts added now) − (live degree) — favour nodes
///     whose removal barely grows the graph;
///   * hierarchy level  — how deep in the contraction order this node has been
///     pushed (a neighbour of an already-contracted node inherits level+1).
///
/// Adding `level` spreads contractions out spatially and keeps the hierarchy
/// shallow, which bounds shortcut density as the graph grows (the scaling
/// lever). Lower importance = contract earlier.
fn importance(adj: &[BTreeMap<u32, f64>], contracted: &[bool], level: &[u32], v: usize) -> i64 {
    count_shortcuts_if_contracted(adj, contracted, v) as i64
        - live_degree(adj, contracted, v) as i64
        + level[v] as i64
}

/// The up-graph: for each node, only its edges to strictly-higher-rank
/// neighbours (all a correct bidirectional query needs).
fn build_up_graph(adj: &[BTreeMap<u32, f64>], rank: &[u32]) -> Vec<Vec<(u32, f64)>> {
    let n = adj.len();
    let mut up = vec![Vec::new(); n];
    for u in 0..n {
        for (&x, &w) in adj[u].iter() {
            if rank[x as usize] > rank[u] {
                up[u].push((x, w));
            }
        }
    }
    up
}

fn relax_min(m: &mut BTreeMap<u32, f64>, k: u32, w: f64) {
    m.entry(k).and_modify(|e| { if w < *e { *e = w; } }).or_insert(w);
}

/// Limited Dijkstra: is there a path `u -> w` avoiding `banned` (and any
/// contracted node) with total cost <= `limit`? Bounded by `limit` so it stays
/// local. Returns true if a witness within `limit` exists.
fn witness_within(
    adj: &[BTreeMap<u32, f64>],
    contracted: &[bool],
    u: usize,
    w: usize,
    banned: usize,
    limit: f64,
) -> bool {
    if u == w { return true; }
    let n = adj.len();
    let mut dist = vec![f64::INFINITY; n];
    dist[u] = 0.0;
    let mut heap = BinaryHeap::new();
    heap.push(HeapItem { dist: 0.0, node: u as u32 });
    while let Some(HeapItem { dist: d, node }) = heap.pop() {
        let x = node as usize;
        if d > dist[x] { continue; }
        if d > limit { break; } // nothing else can be within limit (min-heap)
        if x == w { return d <= limit; }
        for (&y, &wt) in adj[x].iter() {
            let yi = y as usize;
            if yi == banned || contracted[yi] { continue; }
            let nd = d + wt;
            if nd <= limit && nd < dist[yi] {
                dist[yi] = nd;
                heap.push(HeapItem { dist: nd, node: y });
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Static edge-difference order — REFUTED as a production default (it made
    /// MORE shortcuts than id-order on a weighted grid; the live preprocess
    /// uses dynamic lazy ordering). Kept only for the order-correctness test,
    /// hence test-module scope (a private fn in the lib emitted a release
    /// dead_code warning).
    fn edge_difference_order(g: &CsrGraph) -> Vec<usize> {
        let n = g.num_nodes();
        let adj = ContractionHierarchy::build_adj(g);
        let none = vec![false; n];
        let mut scored: Vec<(i64, usize)> = (0..n)
            .map(|v| {
                let deg = adj[v].len() as i64;
                let sc = count_shortcuts_if_contracted(&adj, &none, v) as i64;
                (sc - deg, v)
            })
            .collect();
        scored.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
        scored.into_iter().map(|(_, v)| v).collect()
    }

    fn from_undirected(n: usize, edges: &[(u32, u32, f64)]) -> CsrGraph {
        let mut adj: Vec<Vec<(u32, f64)>> = vec![Vec::new(); n];
        for &(a, b, w) in edges {
            adj[a as usize].push((b, w));
            adj[b as usize].push((a, w));
        }
        let mut offsets = vec![0u32];
        let mut targets = Vec::new();
        let mut weights = Vec::new();
        for es in adj.iter() {
            for &(t, w) in es { targets.push(t); weights.push(w); }
            offsets.push(targets.len() as u32);
        }
        CsrGraph { offsets, targets, weights }
    }

    #[test]
    fn ch_matches_dijkstra_reference() {
        // Wikipedia graph; CH query cost must equal Dijkstra distance.
        let g = from_undirected(6, &[
            (0,1,7.0),(0,2,9.0),(0,5,14.0),(1,2,10.0),(1,3,15.0),
            (2,3,11.0),(2,5,2.0),(3,4,6.0),(4,5,9.0),
        ]);
        let ch = ContractionHierarchy::preprocess(&g);
        let dij_all = g.dijkstra(0);
        for (t, &dij) in dij_all.iter().enumerate() {
            let q = ch.query(0, t);
            assert!((dij - q).abs() < 1e-9 || (dij.is_infinite() && q.is_infinite()),
                    "CH query 0->{t} = {q}, Dijkstra = {dij}");
        }
    }

    fn grid_graph(k: usize) -> CsrGraph {
        // Road-like grid with VARIED weights so equal-cost alternate paths don't
        // trivially witness every pair (a uniform grid needs ~0 shortcuts, which
        // hides the ordering effect). Deterministic weights, no clean ties.
        let idx = |i: usize, j: usize| (i * k + j) as u32;
        let mut edges = Vec::new();
        let mut c = 0u64;
        let mut w = || { c += 1; 1.0 + (c % 7) as f64 * 0.137 + (c % 3) as f64 * 0.041 };
        for i in 0..k {
            for j in 0..k {
                if j + 1 < k { edges.push((idx(i, j), idx(i, j + 1), w())); }
                if i + 1 < k { edges.push((idx(i, j), idx(i + 1, j), w())); }
            }
        }
        from_undirected(k * k, &edges)
    }

    #[test]
    fn ch_orders_are_all_cost_correct() {
        // ANY contraction order must give CH query cost == Dijkstra cost. Verify
        // that invariant for both id-order and the static edge-difference order
        // on a weighted grid, and REPORT their shortcut counts. We do NOT assert
        // one has fewer shortcuts: the static edge-difference heuristic is not
        // reliably better (it was worse here) — that's why proper CH uses dynamic
        // lazy ordering. The correctness invariant is what's gated.
        let g = grid_graph(12); // 144 nodes, varied weights
        let id_order: Vec<usize> = (0..g.num_nodes()).collect();
        let ch_id = ContractionHierarchy::preprocess_with_order(&g, &id_order);
        let ch_ed = ContractionHierarchy::preprocess_with_order(&g, &edge_difference_order(&g));
        for s in [0usize, 7, 100] {
            let dij = g.dijkstra(s);
            for (t, &e) in dij.iter().enumerate() {
                for ch in [&ch_id, &ch_ed] {
                    let q = ch.query(s, t);
                    assert!((e - q).abs() < 1e-9 || (e.is_infinite() && q.is_infinite()),
                            "s={s} t={t}: CH={q} Dijkstra={e}");
                }
            }
        }
        eprintln!("grid12 shortcuts (info): id-order={} static-edge-diff={}",
                  ch_id.shortcuts, ch_ed.shortcuts);
    }

    #[test]
    fn ch_query_speed_vs_dijkstra() {
        // Correctness is the PASS/FAIL; timing is reported (informational, so it
        // never flakes under memory pressure). Answers: does the CH query (even
        // with the plain id-order) already beat early-exit Dijkstra?
        let g = grid_graph(30); // 900 nodes, varied weights
        let n = g.num_nodes();
        let tp = std::time::Instant::now();
        let ch = ContractionHierarchy::preprocess(&g); // id-order default
        let prep = tp.elapsed();
        let mut seed = 0x1234_5678u64;
        let mut next = || { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; seed };
        let pairs: Vec<(usize, usize)> = (0..500)
            .map(|_| ((next() % n as u64) as usize, (next() % n as u64) as usize))
            .collect();
        let tc = std::time::Instant::now();
        let ch_costs: Vec<f64> = pairs.iter().map(|&(s, t)| ch.query(s, t)).collect();
        let ch_time = tc.elapsed();
        let td = std::time::Instant::now();
        let dij_costs: Vec<f64> = pairs.iter().map(|&(s, t)| g.shortest_distance(s, t)).collect();
        let dij_time = td.elapsed();
        for i in 0..pairs.len() {
            let (a, b) = (ch_costs[i], dij_costs[i]);
            assert!((a - b).abs() < 1e-9 || (a.is_infinite() && b.is_infinite()),
                    "pair {i}: CH={a} Dijkstra={b}");
        }
        eprintln!("grid30 n={n} shortcuts={} prep={:?} | {} queries: CH={:?} Dijkstra={:?} ratio={:.2}x",
                  ch.shortcuts, prep, pairs.len(), ch_time, dij_time,
                  dij_time.as_secs_f64() / ch_time.as_secs_f64().max(1e-12));
    }

    #[test]
    fn ch_speedup_scales_with_size() {
        // The CONUS argument: CH's advantage over Dijkstra should GROW with n.
        // Correctness asserted; ratios reported (informational, never flakes).
        for k in [15usize, 20, 25, 30, 40] {
            let g = grid_graph(k);
            let n = g.num_nodes();
            let ch = ContractionHierarchy::preprocess(&g);
            let mut seed = 0x00AB_CDEFu64 ^ (k as u64).wrapping_mul(0x9E37);
            let mut next = || { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; seed };
            let pairs: Vec<(usize, usize)> = (0..400)
                .map(|_| ((next() % n as u64) as usize, (next() % n as u64) as usize))
                .collect();
            let tc = std::time::Instant::now();
            let cc: Vec<f64> = pairs.iter().map(|&(s, t)| ch.query(s, t)).collect();
            let ct = tc.elapsed();
            let td = std::time::Instant::now();
            let dc: Vec<f64> = pairs.iter().map(|&(s, t)| g.shortest_distance(s, t)).collect();
            let dt = td.elapsed();
            for i in 0..pairs.len() {
                assert!((cc[i] - dc[i]).abs() < 1e-9 || (cc[i].is_infinite() && dc[i].is_infinite()),
                        "k={k} pair {i}: CH={} Dij={}", cc[i], dc[i]);
            }
            eprintln!("scale k={k} n={n} shortcuts={} ratio={:.2}x  (CH {:?} vs Dijkstra {:?})",
                      ch.shortcuts, dt.as_secs_f64() / ct.as_secs_f64().max(1e-12), ct, dt);
        }
    }

    /// Undirected min-weight adjacency read straight off the CsrGraph — the
    /// ground-truth edge set a valid path may step along (parallel edges
    /// collapsed to min, exactly as build_adj does).
    fn min_edge_map(g: &CsrGraph) -> BTreeMap<(u32, u32), f64> {
        let mut m: BTreeMap<(u32, u32), f64> = BTreeMap::new();
        for u in 0..g.num_nodes() {
            let (s, e) = (g.offsets[u] as usize, g.offsets[u + 1] as usize);
            for k in s..e {
                let v = g.targets[k]; let w = g.weights[k];
                if !(w.is_finite() && w >= 0.0) { continue; }
                let key = if (u as u32) < v { (u as u32, v) } else { (v, u as u32) };
                m.entry(key).and_modify(|x| { if w < *x { *x = w; } }).or_insert(w);
            }
        }
        m
    }

    /// A reconstructed path is VALID iff it starts at s, ends at t, and every
    /// consecutive pair is a real (min-weight) edge; its cost is the summed
    /// edge weights. Returns that cost (INF if any step isn't a real edge).
    fn path_cost(edges: &BTreeMap<(u32, u32), f64>, path: &[u32], s: usize, t: usize) -> f64 {
        if path.first() != Some(&(s as u32)) || path.last() != Some(&(t as u32)) {
            return f64::INFINITY;
        }
        let mut total = 0.0;
        for w in path.windows(2) {
            let key = if w[0] < w[1] { (w[0], w[1]) } else { (w[1], w[0]) };
            match edges.get(&key) { Some(&c) => total += c, None => return f64::INFINITY }
        }
        total
    }

    #[test]
    fn ch_query_path_valid_and_cost_correct() {
        // For random graphs: the unpacked path must be a real walk s..t whose
        // summed original-edge cost equals both query() and Dijkstra. This is
        // the non-circular gate for shortcut unpacking (Dijkstra is the oracle).
        let mut seed: u64 = 0xD1CE_5EED_1234_5678;
        let mut next = || { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; seed };
        for _ in 0..60 {
            let n = 4 + (next() % 22) as usize;
            let mut edges = Vec::new();
            let m = n + (next() % (3 * n as u64)) as usize;
            for _ in 0..m {
                let a = (next() % n as u64) as u32;
                let b = (next() % n as u64) as u32;
                if a == b { continue; }
                let w = 1.0 + (next() % 1000) as f64 / 10.0;
                edges.push((a, b, w));
            }
            let g = from_undirected(n, &edges);
            let emap = min_edge_map(&g);
            let ch = ContractionHierarchy::preprocess(&g);
            for _ in 0..10 {
                let s = (next() % n as u64) as usize;
                let t = (next() % n as u64) as usize;
                let dij = g.dijkstra(s)[t];
                let (cost, path) = ch.query_path(s, t);
                let q = ch.query(s, t);
                // Cost channel: query_path == query == Dijkstra.
                assert!((cost - q).abs() < 1e-9 || (cost.is_infinite() && q.is_infinite()),
                        "n={n} s={s} t={t}: query_path cost={cost} query={q}");
                assert!((cost - dij).abs() < 1e-9 || (cost.is_infinite() && dij.is_infinite()),
                        "n={n} s={s} t={t}: query_path cost={cost} Dijkstra={dij}");
                if dij.is_finite() {
                    // Path channel: it's a real walk s..t and its edges sum to cost.
                    let pc = path_cost(&emap, &path, s, t);
                    assert!((pc - dij).abs() < 1e-9,
                            "n={n} s={s} t={t}: unpacked path cost={pc} Dijkstra={dij} path={path:?}");
                } else {
                    assert!(path.is_empty(), "n={n} s={s} t={t}: unreachable but path={path:?}");
                }
            }
        }
    }

    #[test]
    fn ch_query_path_grid_and_edges() {
        // Weighted grid (nontrivial shortcuts) + the s==t and single-edge cases.
        let g = grid_graph(14); // 196 nodes
        let emap = min_edge_map(&g);
        let ch = ContractionHierarchy::preprocess(&g);
        for s in [0usize, 5, 97, 195] {
            let dij = g.dijkstra(s);
            for (t, &e) in dij.iter().enumerate() {
                let (cost, path) = ch.query_path(s, t);
                assert!((cost - e).abs() < 1e-9,
                        "grid s={s} t={t}: CH path cost={cost} Dijkstra={e}");
                let pc = path_cost(&emap, &path, s, t);
                assert!((pc - e).abs() < 1e-9,
                        "grid s={s} t={t}: unpacked cost={pc} Dijkstra={e}");
            }
        }
        // s == t is a length-1 path at zero cost.
        let (c0, p0) = ch.query_path(42, 42);
        assert_eq!((c0, p0), (0.0, vec![42u32]));
    }

    #[test]
    fn ch_matches_dijkstra_random() {
        // Deterministic LCG so the test is reproducible without rand.
        let mut seed: u64 = 0x9E3779B97F4A7C15;
        let mut next = || { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; seed };
        for _ in 0..40 {
            let n = 4 + (next() % 20) as usize;
            let mut edges = Vec::new();
            let m = n + (next() % (2 * n as u64)) as usize;
            for _ in 0..m {
                let a = (next() % n as u64) as u32;
                let b = (next() % n as u64) as u32;
                if a == b { continue; }
                let w = 1.0 + (next() % 1000) as f64 / 10.0;
                edges.push((a, b, w));
            }
            let g = from_undirected(n, &edges);
            let ch = ContractionHierarchy::preprocess(&g);
            for _ in 0..8 {
                let s = (next() % n as u64) as usize;
                let t = (next() % n as u64) as usize;
                let dij = g.dijkstra(s)[t];
                let q = ch.query(s, t);
                assert!((dij - q).abs() < 1e-9 || (dij.is_infinite() && q.is_infinite()),
                        "n={n} s={s} t={t}: CH={q} Dijkstra={dij}");
            }
        }
    }
}
