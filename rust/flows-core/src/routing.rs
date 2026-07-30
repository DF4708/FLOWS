// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! routing.rs — shortest-path core for the CONUS router (phase R-route).
//!
//! Pure-std Dijkstra over a CSR (compressed-sparse-row) directed weighted graph.
//! This is the foundation the contraction-hierarchy (CH) preprocessor will build
//! on to make cross-country routing load as fast as local: CH precomputes node
//! shortcuts so a query touches O(log n) of the graph instead of all of it.
//!
//! For now this is a correct, allocation-lean Dijkstra baseline verified against
//! known-answer graphs (the math ground truth). It intentionally has NO external
//! crate dependency (pure std BinaryHeap) so it builds fast and small even under
//! the memory ceiling; the `fast_paths` CH crate arrives in a later phase once
//! the graph-ingest + FFI surface here is settled and measured.
//!
//! Design notes for the CH phase (see docs/RUST_SWIFT_MIGRATION.md):
//!   * CSR is the right in-memory shape: cache-friendly, O(1) neighbour scan,
//!     and directly what an R edge list (from/to/weight) marshals into.
//!   * Weights are per-PROFILE (fastest/safest/metro) — the graph topology is
//!     shared; only the `weights` vector changes, so profiles reuse offsets+targets.
//!   * Non-negative weights are a Dijkstra/CH requirement; risk penalties are
//!     added to (never subtracted from) travel time, so this holds.

use std::cmp::Ordering;
use std::collections::BinaryHeap;

/// Directed weighted graph in CSR form. Node `i`'s out-edges are
/// `targets[offsets[i]..offsets[i+1]]` with the matching slice of `weights`.
pub struct CsrGraph {
    /// Length n+1; offsets[i]..offsets[i+1] is node i's edge range.
    pub offsets: Vec<u32>,
    /// Length m; edge target node ids.
    pub targets: Vec<u32>,
    /// Length m; edge weights (non-negative).
    pub weights: Vec<f64>,
}

impl CsrGraph {
    /// Number of nodes.
    pub fn num_nodes(&self) -> usize {
        self.offsets.len().saturating_sub(1)
    }

    /// Single-source shortest paths from `source`. Returns the length-n distance
    /// vector (f64::INFINITY for unreachable nodes). O((n + m) log n).
    pub fn dijkstra(&self, source: usize) -> Vec<f64> {
        let n = self.num_nodes();
        let mut dist = vec![f64::INFINITY; n];
        if source >= n {
            return dist;
        }
        dist[source] = 0.0;
        let mut heap = BinaryHeap::new();
        heap.push(HeapItem {
            dist: 0.0,
            node: source as u32,
        });
        while let Some(HeapItem { dist: d, node }) = heap.pop() {
            let u = node as usize;
            // Stale entry (a shorter path was already finalised) — skip.
            if d > dist[u] {
                continue;
            }
            let (s, e) = (self.offsets[u] as usize, self.offsets[u + 1] as usize);
            for k in s..e {
                let v = self.targets[k] as usize;
                let nd = d + self.weights[k];
                if nd < dist[v] {
                    dist[v] = nd;
                    heap.push(HeapItem {
                        dist: nd,
                        node: v as u32,
                    });
                }
            }
        }
        dist
    }

    /// Shortest-path distance from `source` to `target` (early-exit Dijkstra),
    /// or f64::INFINITY if unreachable.
    /// Test-only ORACLE: the early-exit Dijkstra the CH tests compare
    /// against — not app API (the FFI path uses `dijkstra`).
    #[cfg(test)]
    pub(crate) fn shortest_distance(&self, source: usize, target: usize) -> f64 {
        let n = self.num_nodes();
        if source >= n || target >= n {
            return f64::INFINITY;
        }
        let mut dist = vec![f64::INFINITY; n];
        dist[source] = 0.0;
        let mut heap = BinaryHeap::new();
        heap.push(HeapItem {
            dist: 0.0,
            node: source as u32,
        });
        while let Some(HeapItem { dist: d, node }) = heap.pop() {
            let u = node as usize;
            if u == target {
                return d;
            }
            if d > dist[u] {
                continue;
            }
            let (s, e) = (self.offsets[u] as usize, self.offsets[u + 1] as usize);
            for k in s..e {
                let v = self.targets[k] as usize;
                let nd = d + self.weights[k];
                if nd < dist[v] {
                    dist[v] = nd;
                    heap.push(HeapItem {
                        dist: nd,
                        node: v as u32,
                    });
                }
            }
        }
        f64::INFINITY
    }
}

/// Min-heap item. std BinaryHeap is a MAX-heap, so `Ord` is reversed on `dist`
/// to pop the smallest tentative distance first. Ties break on node id for a
/// deterministic settle order (matters when we later prove equivalence).
/// Min-heap item shared by the plain Dijkstra here and the CH searches in
/// ch.rs (pub(crate) so it isn't duplicated per module).
pub(crate) struct HeapItem {
    pub(crate) dist: f64,
    pub(crate) node: u32,
}

impl PartialEq for HeapItem {
    fn eq(&self, other: &Self) -> bool {
        self.dist == other.dist && self.node == other.node
    }
}
impl Eq for HeapItem {}
impl PartialOrd for HeapItem {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for HeapItem {
    fn cmp(&self, other: &Self) -> Ordering {
        // Reverse dist for min-heap; NaN-safe (weights are finite non-negative).
        other
            .dist
            .partial_cmp(&self.dist)
            .unwrap_or(Ordering::Equal)
            .then_with(|| other.node.cmp(&self.node))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Classic Dijkstra reference graph (Wikipedia). 6 nodes, undirected edges
    // encoded as directed both ways:
    //   0-1:7  0-2:9  0-5:14  1-2:10  1-3:15  2-3:11  2-5:2  3-4:6  4-5:9
    fn ref_graph() -> CsrGraph {
        // adjacency per node (target, weight)
        let adj: [&[(u32, f64)]; 6] = [
            &[(1, 7.0), (2, 9.0), (5, 14.0)],
            &[(0, 7.0), (2, 10.0), (3, 15.0)],
            &[(0, 9.0), (1, 10.0), (3, 11.0), (5, 2.0)],
            &[(1, 15.0), (2, 11.0), (4, 6.0)],
            &[(3, 6.0), (5, 9.0)],
            &[(0, 14.0), (2, 2.0), (4, 9.0)],
        ];
        let mut offsets = vec![0u32];
        let mut targets = Vec::new();
        let mut weights = Vec::new();
        for edges in adj.iter() {
            for &(t, w) in edges.iter() {
                targets.push(t);
                weights.push(w);
            }
            offsets.push(targets.len() as u32);
        }
        CsrGraph {
            offsets,
            targets,
            weights,
        }
    }

    #[test]
    fn dijkstra_matches_known_distances() {
        let g = ref_graph();
        // Ground-truth shortest distances from node 0.
        let expected = [0.0, 7.0, 9.0, 20.0, 20.0, 11.0];
        let got = g.dijkstra(0);
        assert_eq!(got, expected);
        // Point-to-point early-exit agrees with the full sweep.
        for (t, &e) in expected.iter().enumerate() {
            assert_eq!(g.shortest_distance(0, t), e, "s->t {t}");
        }
    }

    #[test]
    fn unreachable_is_infinity() {
        // Two isolated nodes, no edges.
        let g = CsrGraph {
            offsets: vec![0, 0, 0],
            targets: vec![],
            weights: vec![],
        };
        let d = g.dijkstra(0);
        assert_eq!(d[0], 0.0);
        assert!(d[1].is_infinite());
        assert!(g.shortest_distance(0, 1).is_infinite());
    }
}
