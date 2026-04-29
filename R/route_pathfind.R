# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/route_pathfind.R — graph indexing and shortest-path search for the
# routing engine. Each routing profile (Fastest / Safest / Metro-Rail) shares
# the same graph but uses a different edge-cost function. cppRouting's C++
# bidirectional Dijkstra is the primary search; the pure-R heap-based A* in
# this file (astar_route) is the fallback when cppRouting is unavailable.

# ---------------------------------------------------------------------------
# Binary min-heap priority queue, vector-backed in an environment for in-place
# mutation. Push/pop are O(log n).
# ---------------------------------------------------------------------------

# Allocates a new pq min-heap object (an environment with parallel keys / priorities vectors and a count n) sized to initial_capacity; the vectors auto-grow on push.
pq_new <- function(initial_capacity = 64L) {
  env <- new.env(parent = emptyenv())
  env$keys <- integer(initial_capacity)
  env$priorities <- numeric(initial_capacity)
  env$n <- 0L
  env
}

# Inserts (key, priority) into the pq min-heap and sifts up to restore the heap invariant; doubles the backing vectors when capacity is exhausted. O(log n).
pq_push <- function(pq, key, priority) {
  pq$n <- pq$n + 1L
  if (pq$n > length(pq$keys)) {
    new_size <- max(length(pq$keys) * 2L, 16L)
    pq$keys <- c(pq$keys, integer(new_size - length(pq$keys)))
    pq$priorities <- c(pq$priorities, numeric(new_size - length(pq$priorities)))
  }
  i <- pq$n
  pq$keys[i] <- key
  pq$priorities[i] <- priority
  while (i > 1L) {
    parent <- i %/% 2L
    if (pq$priorities[i] < pq$priorities[parent]) {
      tk <- pq$keys[i]; tp <- pq$priorities[i]
      pq$keys[i] <- pq$keys[parent]; pq$priorities[i] <- pq$priorities[parent]
      pq$keys[parent] <- tk; pq$priorities[parent] <- tp
      i <- parent
    } else break
  }
  invisible()
}

# Removes and returns the minimum-priority entry as list(key, priority), or NULL when pq is empty; sifts the moved last element down to restore the heap invariant. O(log n).
pq_pop <- function(pq) {
  if (pq$n == 0L) return(NULL)
  res <- list(key = pq$keys[1], priority = pq$priorities[1])
  pq$keys[1] <- pq$keys[pq$n]
  pq$priorities[1] <- pq$priorities[pq$n]
  pq$n <- pq$n - 1L
  i <- 1L
  n <- pq$n
  while (TRUE) {
    left <- 2L * i
    right <- left + 1L
    smallest <- i
    if (left <= n && pq$priorities[left] < pq$priorities[smallest]) smallest <- left
    if (right <= n && pq$priorities[right] < pq$priorities[smallest]) smallest <- right
    if (smallest == i) break
    tk <- pq$keys[i]; tp <- pq$priorities[i]
    pq$keys[i] <- pq$keys[smallest]; pq$priorities[i] <- pq$priorities[smallest]
    pq$keys[smallest] <- tk; pq$priorities[smallest] <- tp
    i <- smallest
  }
  res
}

# Predicate: TRUE when the pq min-heap holds zero entries.
pq_empty <- function(pq) pq$n == 0L

# Why: A polygon-shaped query (city / county / ZIP) whose nearest road snap
# lands on a local street can force A* into a long looping detour just to
# reach an arterial; the search needs a candidate set that includes both
# polygon-interior nodes (so the start/end look right on the map) and the
# nearest high-tier (Interstate / US / State) entry nodes (so A* has a fast
# corridor available from step one).
# What: returns up to max_candidates node_id strings, balancing two pools:
# nodes inside the search geometry and nodes that touch a high-tier road
# near the search point. Falls back to plain distance-nearest for point
# queries.
# How: intersects node_df against the projected polygon to find inside-nodes,
# orders them by distance to the polygon's representative point, then fills
# the remaining slots with the closest node_df rows whose is_high_tier flag
# is set (precomputed in prepare()). De-duplicates and trims to the cap.
# When: called twice per query in prepare() (once for start, once for end);
# its output drives the candidate cross-product in best_path_for_ctx.
# Impact: more than any other change, this controls whether short-distance
# urban routes find the natural highway access or loop through local streets
# - the 53203 -> 53184 detour was caused by an all-local candidate set.
find_polygon_or_point_nodes <- function(node_df, search_point, max_candidates = 4L) {
  geom <- search_point$geometry %||% NULL
  use_polygon <- !is.null(geom) && (inherits(geom, "sf") || inherits(geom, "sfc")) &&
                 (search_point$type %in% c("city", "county", "zip"))

  ids_inside <- character(0)
  centroid_xy <- NULL
  if (use_polygon) {
    geom_proj <- tryCatch(suppressWarnings(sf::st_transform(geom, 5070)), error = function(e) NULL)
    if (!is.null(geom_proj)) {
      pts <- sf::st_as_sf(node_df, coords = c("x", "y"), crs = 5070, remove = FALSE)
      hits <- tryCatch(suppressWarnings(sf::st_intersects(pts, geom_proj, sparse = FALSE)),
                       error = function(e) NULL)
      idx_inside <- if (is.null(hits)) integer(0) else which(rowSums(hits) > 0)
      cent <- tryCatch(sf::st_coordinates(suppressWarnings(sf::st_point_on_surface(geom_proj))),
                       error = function(e) NULL)
      if (!is.null(cent) && nrow(cent) >= 1L) centroid_xy <- c(cent[1, "X"], cent[1, "Y"])
      if (length(idx_inside) > 0 && !is.null(centroid_xy)) {
        d <- (node_df$x[idx_inside] - centroid_xy[1])^2 + (node_df$y[idx_inside] - centroid_xy[2])^2
        idx_inside <- idx_inside[order(d)]
        # Reserve about half the budget for inside-nodes so the candidate set
        # still looks like a search at the user's chosen polygon.
        n_in <- min(max(1L, ceiling(max_candidates / 2L)), length(idx_inside))
        ids_inside <- node_df$node_id[idx_inside[seq_len(n_in)]]
      }
    }
  }

  # Resolve a reference (X,Y) in EPSG:5070 for the high-tier nearest search.
  # Prefer the polygon centroid (consistent with the user's intent) but fall
  # back to projecting the search point if the polygon path was unavailable.
  ref_xy <- centroid_xy
  if (is.null(ref_xy) && !is.null(search_point$lon) && !is.null(search_point$lat)) {
    pt_sfc <- tryCatch(
      suppressWarnings(sf::st_transform(
        sf::st_sfc(sf::st_point(c(search_point$lon, search_point$lat)), crs = 4326), 5070
      )),
      error = function(e) NULL
    )
    if (!is.null(pt_sfc)) {
      ref_xy <- as.numeric(suppressWarnings(sf::st_coordinates(pt_sfc))[1, c("X", "Y")])
    }
  }

  ids_high <- character(0)
  if (!is.null(ref_xy) && "is_high_tier" %in% names(node_df)) {
    high_idx <- which(node_df$is_high_tier)
    if (length(high_idx) > 0) {
      d_hi <- (node_df$x[high_idx] - ref_xy[1])^2 + (node_df$y[high_idx] - ref_xy[2])^2
      high_idx <- high_idx[order(d_hi)]
      n_hi <- min(max_candidates - length(ids_inside), length(high_idx))
      if (n_hi > 0) ids_high <- node_df$node_id[high_idx[seq_len(n_hi)]]
    }
  }

  ids <- unique(c(ids_inside, ids_high))
  if (length(ids) > 0) {
    return(ids[seq_len(min(max_candidates, length(ids)))])
  }
  find_candidate_route_nodes(node_df, search_point, max_candidates = max_candidates)
}

# Why: A* needs O(1) "give me all outgoing edges of node u" access; an adjacency
# list backed by R lists is too slow at OSM scale, so we use a Compressed Sparse
# Row layout that lets the search loop slice by integer range.
# What: returns a list with node coordinate vectors, a u_starts integer vector
# whose i-th element is the first half-edge index for node i, half_to (target
# node index per half-edge), half_edge_row (row index back into edges_df), and
# bookkeeping for n_nodes / n_half.
# How: assigns each unique (snapped) endpoint an integer node index, doubles
# the edges to make them bidirectional, sorts the half-edges by source node,
# and uses tabulate + cumsum to produce u_starts in O(V+E) without an R loop.
# When: called once per query (per cache miss) inside native_plan_routes,
# before any A* search runs; result is cached on a key derived from segment
# count and horizon so repeated queries reuse it.
# Impact: graph build is in the hot path - tabulate/cumsum vectorisation
# replaced what used to be a per-node loop and made graph build viable for the
# 97k-edge OSM data set.
build_route_graph <- function(edges_df) {
  if (is.null(edges_df) || nrow(edges_df) == 0) return(NULL)
  n_orig <- nrow(edges_df)
  node_keys <- unique(c(edges_df$from_node, edges_df$to_node))
  node_idx <- stats::setNames(seq_along(node_keys), node_keys)
  n_nodes <- length(node_keys)

  # Per-node coordinates (projected EPSG:5070, in meters): take any incident edge.
  # Use a vectorised first-occurrence lookup so each node gets one (x,y).
  all_nodes <- c(edges_df$from_node, edges_df$to_node)
  all_x <- c(edges_df$from_x, edges_df$to_x)
  all_y <- c(edges_df$from_y, edges_df$to_y)
  first_occ <- match(node_keys, all_nodes)
  node_x <- all_x[first_occ]
  node_y <- all_y[first_occ]

  # Bidirectional adjacency: each undirected edge contributes two directed half-edges.
  from <- c(node_idx[edges_df$from_node], node_idx[edges_df$to_node])
  to   <- c(node_idx[edges_df$to_node],   node_idx[edges_df$from_node])
  edge_row <- c(seq_len(n_orig), seq_len(n_orig))

  ord <- order(from, to)
  from <- from[ord]
  to <- to[ord]
  edge_row <- edge_row[ord]

  # u_starts[u] = first index of node u's outgoing edges in the sorted list.
  # Vectorised via tabulate + cumsum: O(V + E) without an R-level loop.
  counts <- tabulate(from, nbins = n_nodes)
  u_starts <- as.integer(c(1L, cumsum(counts) + 1L))

  list(
    edges = edges_df,
    n_nodes = n_nodes,
    n_half = length(from),
    node_keys = node_keys,
    node_idx = node_idx,
    node_x = node_x,
    node_y = node_y,
    half_to = to,
    half_edge_row = edge_row,
    u_starts = u_starts
  )
}

# Looks up the integer node index for a node_id string in graph$node_idx — returns 0L on miss, since 0 is reserved as "no parent" in the A* prev_node array.
graph_node_for_id <- function(graph, node_id) {
  if (is.null(graph) || !nzchar(node_id %||% "")) return(NA_integer_)
  idx <- graph$node_idx[[node_id]]
  if (is.null(idx)) NA_integer_ else as.integer(idx)
}

# ---------------------------------------------------------------------------
# Profile-aware edge cost.
# Each profile uses (length / speed) as the time term, then multiplies by:
#   * a tier bonus that favours / discourages road tiers (highways for metro)
#   * a risk multiplier (1 + alpha * risk) where alpha varies per profile
#   * a closure multiplier that scales the route_closure_penalty term
# Speeds and tier bonuses come from the existing route_tier_speed_for_profile
# and route_tier_bonus_for_profile tables, so the calibration the project
# already has is preserved.
# ---------------------------------------------------------------------------

# Why: each profile's per-edge cost adds (1 + alpha * pmax(0, risk - floor))
# so the planner trades distance for risk avoidance; alpha is the lever for
# "how strongly" this profile dislikes any risk above its tolerance floor.
# What: returns the alpha multiplier for the named profile.
# How: simple table lookup, defaulting to the fastest value for unknown keys.
# When: called inside compute_profile_edge_weights once per profile per
# query.
# Impact: Metro now uses (alpha = 10, floor = RISK_GREEN_MIN) so it tolerates
# green-band risk freely but strongly fights yellow / red. Without the
# threshold, any uniform-alpha Metro setting between Fastest (4) and Safest
# (25) was forced to detour 60+ miles around even modest green-band stretches.
route_profile_risk_alpha <- function(profile_key) {
  switch(
    tolower(as.character(profile_key %||% "fastest")),
    # Fastest must be the strict time minimum - any non-zero alpha here lets
    # the planner trade extra miles for risk avoidance, which by definition
    # makes Fastest no longer "fastest." Closures are still avoided via the
    # separate closure_pen term.
    fastest = 0.0,
    safest = 25.0,
    metro = 10.0,
    metrorail = 10.0,
    0.0
  )
}

# Why: profiles differ not just in penalty strength but in WHICH risk they
# fight - Metro should accept "medium" (green-band) risk where the highway
# corridor passes through a town, while still fighting yellow / red.
# What: returns the risk-score floor below which the profile applies zero
# penalty (in [0, 1]).
# How: lookup of named profiles. fastest / safest penalize all non-zero
# risk; metro accepts up to the project's RISK_GREEN_MIN threshold before
# the alpha penalty kicks in.
# When: called by compute_profile_edge_weights immediately before forming
# the (1 + alpha * pmax(0, risk - floor)) term.
# Impact: this is the lever that lets Metro keep a highway through a low-
# moderate risk city instead of detouring around it. Setting the floor to 0
# returns the prior all-or-nothing behaviour.
route_profile_risk_floor <- function(profile_key) {
  switch(
    tolower(as.character(profile_key %||% "fastest")),
    fastest = 0.0,
    safest = 0.0,
    metro = RISK_GREEN_MIN,
    metrorail = RISK_GREEN_MIN,
    0.0
  )
}

# Returns the per-profile multiplier applied to closure_penalty when computing edge weights — Safest amplifies the penalty (so it routes around incidents), Fastest dampens it (so it accepts incidents when they're still on the quickest path).
route_profile_closure_scale <- function(profile_key) {
  switch(
    tolower(as.character(profile_key %||% "fastest")),
    fastest = 1.0,
    safest = 1.6,
    metro = 1.3,
    metrorail = 1.3,
    1.0
  )
}

# Why: A* needs a per-edge weight that captures travel time AND profile-specific
# preferences (highway preference for metro, risk avoidance for safest, etc.).
# What: returns a numeric vector of weights aligned to edges_df rows; the cost
# is (length/speed) * tier_bonus * (1 + alpha*risk + closure_scale*closure_pen).
# How: builds the profile speed/bonus tables once via the vectorised lookups
# (no per-edge function calls), pulls risk and closure columns, and combines
# them in one column-wise expression.
# When: called by search_profile() once per profile per query (cached by
# weights_cache), before the A* heap search runs.
# Impact: dominates pre-search cost; switching from per-edge vapply to named-
# vector lookup removes the largest pure-R hot spot in the routing pipeline.
compute_profile_edge_weights <- function(edges_df, profile_key) {
  if (is.null(edges_df) || nrow(edges_df) == 0) return(numeric(0))
  alpha <- route_profile_risk_alpha(profile_key)
  risk_floor <- route_profile_risk_floor(profile_key)
  closure_scale <- route_profile_closure_scale(profile_key)
  length_m <- pmax(suppressWarnings(as.numeric(edges_df$length_m)), 1)
  seg_risk <- pmax(0, pmin(1, suppressWarnings(as.numeric(edges_df$segment_risk %||% 0))))
  seg_risk[!is.finite(seg_risk)] <- 0
  closure_pen <- pmax(suppressWarnings(as.numeric(edges_df$closure_penalty %||% 0)), 0)
  closure_pen[!is.finite(closure_pen)] <- 0
  route_tier <- as.character(edges_df$route_tier %||% ifelse(edges_df$road_class == "Primary", "Primary", "Secondary"))
  speed_mph <- adjusted_route_speed_mph(route_tier_speed_lookup(route_tier, profile_key), seg_risk)
  tier_bonus <- route_tier_bonus_lookup(route_tier, profile_key)
  # Perimeter-aware risk attenuation: a road close to a "lower-risk" ZIP
  # (boundary_distance_m near 0) is genuinely less exposed than a road at
  # the core of the same risky polygon. Decay scale 2500 m (~1.5 mi) and a
  # 50% maximum reduction at the boundary keep the effect physically
  # plausible without ever zeroing out a yellow / red road.
  boundary_dist <- suppressWarnings(as.numeric(edges_df$boundary_distance_m %||% 1e6))
  boundary_dist[!is.finite(boundary_dist) | boundary_dist < 0] <- 1e6
  attenuation <- 1 - 0.5 * exp(-boundary_dist / 2500)
  attenuated_risk <- seg_risk * attenuation
  # risk_floor lets Metro accept green-band risk freely but fight yellow / red.
  effective_risk <- pmax(0, attenuated_risk - risk_floor)
  weight <- (length_m / speed_mph) * tier_bonus * (1 + alpha * effective_risk + closure_scale * closure_pen)
  weight[!is.finite(weight) | weight <= 0] <- length_m[!is.finite(weight) | weight <= 0] / 18
  weight
}

# Why: every profile must report the same physical drive time on the same
# physical road, otherwise a tied path looks "faster" purely because the
# planner used a higher per-profile speed table during cost search.
# What: returns per-edge minutes using the canonical "fastest" speed table
# (the closest stand-in for free-flow drive time), still risk-adjusted via
# adjusted_route_speed_mph so weather slowdowns are reflected.
# How: looks up tier->mph from the fastest table, applies a risk slowdown,
# converts (length_m/1609.344) miles by mph to minutes.
# When: called from build_native_route_object after a path is selected, and
# from the safest time-cap check that compares hours against fastest_hours.
# Impact: removes the spurious Metro<Fastest cases observed when the
# Metro/Fastest planners pick the same path; reported durations now reflect
# physical travel time, not the cost-search calibration.
edge_minutes_for_path <- function(edges_df, profile_key) {
  if (is.null(edges_df) || nrow(edges_df) == 0) return(numeric(0))
  length_m <- pmax(suppressWarnings(as.numeric(edges_df$length_m)), 0)
  seg_risk <- pmax(0, pmin(1, suppressWarnings(as.numeric(edges_df$segment_risk %||% 0))))
  seg_risk[!is.finite(seg_risk)] <- 0
  route_tier <- as.character(edges_df$route_tier %||% ifelse(edges_df$road_class == "Primary", "Primary", "Secondary"))
  # Canonical "fastest" speed table for reported time, regardless of which
  # profile the planner used to choose the path.
  speed_mph <- adjusted_route_speed_mph(route_tier_speed_lookup(route_tier, "fastest"), seg_risk)
  miles <- length_m / 1609.344
  miles / speed_mph * 60
}

# Safest-route time cap multiplier as a piecewise function of the fastest
# route's duration (hours). Per spec: 3x at <=1h, 2x at 2h, 1.1x at 24h, with
# linear interpolation between break points and 1.1x past 24h.
safest_time_cap_multiplier <- function(fastest_hours) {
  t <- suppressWarnings(as.numeric(fastest_hours))
  if (!is.finite(t) || t < 0) t <- 0
  if (t <= 1) return(3.0)
  if (t <= 2) return(3.0 - (t - 1) * 1.0)            # 3 -> 2 across [1,2]
  if (t <= 24) return(2.0 - (t - 2) * (0.9 / 22))    # 2 -> 1.1 across [2,24]
  1.1
}

# Why: A* finds a least-cost path between two nodes much faster than plain
# Dijkstra when a good admissible heuristic is available, which we have via
# straight-line projected distance divided by the maximum feasible speed.
# What: returns a list with the path's node-index sequence, the edge_rows it
# traversed (back into segments), and the total cost - or NULL if the goal is
# unreachable from the given source.
# How: maintains an integer-keyed binary min-heap of (g+h) priorities, expands
# the lowest-priority node, relaxes each outgoing half-edge using the supplied
# weights vector, and skips any edge in banned_edge_rows. Closed-set check
# uses an in-place visited bit-vector for O(1) membership.
# When: called once per profile per query inside native_plan_routes (after the
# corridor-then-full-graph fallback selects a context), wrapped by mclapply for
# parallel execution across profiles.
# Impact: the dominant cost in route planning - the heap implementation and
# vectorised neighbour-fetch directly determine end-to-end query latency.
astar_route <- function(graph, source_idx, target_idx, weights,
                        banned_edge_rows = integer(0)) {
  if (is.null(graph) || is.na(source_idx) || is.na(target_idx)) return(NULL)
  if (source_idx == target_idx) {
    return(list(node_idx = source_idx, edge_rows = integer(0), cost = 0))
  }
  n <- graph$n_nodes
  dist <- rep(Inf, n)
  prev_node <- integer(n)
  prev_edge <- integer(n)
  visited <- logical(n)
  banned <- logical(nrow(graph$edges))
  if (length(banned_edge_rows) > 0) {
    valid_bans <- banned_edge_rows[banned_edge_rows >= 1L & banned_edge_rows <= length(banned)]
    banned[valid_bans] <- TRUE
  }
  # Heuristic: admissible lower bound on remaining cost in the same units the
  # edge weights use (length_m / speed_mph * tier_bonus). Best feasible per-edge
  # multiplier is the smallest tier_bonus across all profiles (Interstate metro
  # = 0.38) at the highest feasible speed (Interstate fastest = 72 mph) with
  # zero risk and zero closure penalty.
  tx <- graph$node_x[target_idx]
  ty <- graph$node_y[target_idx]
  heuristic <- function(i) {
    dx <- graph$node_x[i] - tx
    dy <- graph$node_y[i] - ty
    sqrt(dx * dx + dy * dy) / 72 * 0.38
  }
  pq <- pq_new()
  dist[source_idx] <- 0
  pq_push(pq, source_idx, heuristic(source_idx))
  while (!pq_empty(pq)) {
    top <- pq_pop(pq)
    u <- top$key
    if (visited[u]) next
    visited[u] <- TRUE
    if (u == target_idx) break
    s <- graph$u_starts[u]
    e <- graph$u_starts[u + 1L] - 1L
    if (s > e) next
    for (k in s:e) {
      v <- graph$half_to[k]
      if (visited[v]) next
      er <- graph$half_edge_row[k]
      if (banned[er]) next
      w <- weights[er]
      if (!is.finite(w) || w < 0) next
      alt <- dist[u] + w
      if (alt < dist[v]) {
        dist[v] <- alt
        prev_node[v] <- u
        prev_edge[v] <- er
        pq_push(pq, v, alt + heuristic(v))
      }
    }
  }
  if (!is.finite(dist[target_idx])) return(NULL)

  path_nodes <- integer(0)
  path_edges <- integer(0)
  cur <- target_idx
  while (cur != source_idx) {
    path_nodes <- c(cur, path_nodes)
    path_edges <- c(prev_edge[cur], path_edges)
    cur <- prev_node[cur]
    if (cur == 0L) return(NULL)
  }
  path_nodes <- c(source_idx, path_nodes)
  list(node_idx = path_nodes, edge_rows = path_edges, cost = dist[target_idx])
}

# Why: pure-R A* on a 97k-edge graph still costs about a second per search;
# cppRouting's C++ bidirectional Dijkstra runs the same query in ~50 ms with
# bit-for-bit identical optimal cost, giving the routing pipeline a 10-30x
# speedup at the cost of one extra runtime dependency.
# What: returns a list with edge_rows (segments-row indices), node_idx
# (graph node indices), and cost - the same shape that astar_route returns -
# or NULL if no path exists.
# How: builds a cppRouting graph from the supplied weights, runs
# get_distance_pair across the cartesian product of source/target candidates
# to find the cheapest pair, then runs get_path_pair for that one pair and
# joins consecutive node IDs against pair_lookup to recover edge_rows.
# When: called from search_profile when cppRouting is available, in place of
# the legacy astar_route + best_path_for_ctx loop.
# Impact: makes the difference between sub-second routing and the prior 60-150 s
# queries; the legacy heap A* is kept as a fallback for environments where
# cppRouting is not installable.
cppr_best_path <- function(cppr_graph, graph, pair_lookup, src_ids, dst_ids) {
  if (is.null(cppr_graph) || is.null(graph)) return(NULL)
  src_ids <- as.character(src_ids); dst_ids <- as.character(dst_ids)
  src_ids <- src_ids[nzchar(src_ids)]
  dst_ids <- dst_ids[nzchar(dst_ids)]
  if (length(src_ids) == 0L || length(dst_ids) == 0L) return(NULL)
  pairs <- expand.grid(s = src_ids, d = dst_ids, stringsAsFactors = FALSE)
  pairs <- pairs[pairs$s != pairs$d, , drop = FALSE]
  if (nrow(pairs) == 0L) return(NULL)
  costs <- tryCatch(
    cppRouting::get_distance_pair(cppr_graph, from = pairs$s, to = pairs$d, algorithm = "bi"),
    error = function(e) NULL
  )
  if (is.null(costs) || length(costs) == 0L) return(NULL)
  costs[!is.finite(costs)] <- Inf
  best <- which.min(costs)
  if (!is.finite(costs[best])) return(NULL)
  res <- tryCatch(
    cppRouting::get_path_pair(cppr_graph, from = pairs$s[best], to = pairs$d[best], algorithm = "bi"),
    error = function(e) NULL
  )
  if (is.null(res) || length(res) == 0L) return(NULL)
  path_nodes <- res[[1]]
  if (length(path_nodes) < 2L) return(NULL)
  u <- path_nodes[-length(path_nodes)]
  v <- path_nodes[-1]
  keys <- ifelse(u < v, paste(u, v, sep = "|"), paste(v, u, sep = "|"))
  edge_rows <- pair_lookup[keys]
  if (any(is.na(edge_rows))) return(NULL)
  node_idx <- as.integer(graph$node_idx[path_nodes])
  if (any(is.na(node_idx))) return(NULL)
  list(node_idx = node_idx, edge_rows = as.integer(edge_rows), cost = as.numeric(costs[best]))
}

# Why: cppr_best_path needs to recover the segments-row index for each
# (u, v) consecutive pair on a path; an undirected edge can appear as either
# (from=u, to=v) or (from=v, to=u), so we hash on the unordered pair.
# What: returns a named integer vector keyed by "min_id|max_id" where the
# value is the segments row index (first occurrence wins on parallel edges).
# How: forms the canonical key by alphabetic ordering of from_node/to_node
# strings and then deduplicates on first occurrence.
# When: called once per (segments) graph build inside prepare(), cached
# alongside the graph object.
# Impact: O(E) memory and O(1) per-edge lookup at search time; without this
# we'd have to scan segments per consecutive pair and the cppRouting speedup
# would be wiped out by the conversion cost.
build_edge_pair_lookup <- function(segments) {
  fr <- as.character(segments$from_node)
  to <- as.character(segments$to_node)
  key <- ifelse(fr < to, paste(fr, to, sep = "|"), paste(to, fr, sep = "|"))
  keep <- !duplicated(key)
  stats::setNames(seq_along(key)[keep], key[keep])
}

# ---------------------------------------------------------------------------
# Native step-instruction generator: groups consecutive same-road edges into
# one instruction per group. Only the first edge of each group gets a non-empty
# step_instruction; downstream rendering ignores blanks.
# ---------------------------------------------------------------------------

generate_native_step_instructions <- function(route_edges) {
  n <- nrow(route_edges)
  if (n == 0) return(character(0))
  road_names <- as.character(route_edges$road_name %||% "Wisconsin road")
  road_names[!nzchar(trimws(road_names))] <- "Wisconsin road"
  group_break <- c(TRUE, road_names[-1] != road_names[-n])
  group_id <- cumsum(group_break)
  instructions <- character(n)
  for (gid in unique(group_id)) {
    idx <- which(group_id == gid)
    if (length(idx) == 0) next
    nm <- road_names[idx[1]]
    instructions[idx[1]] <- if (gid == 1L) paste("Take", nm) else paste("Continue on", nm)
  }
  instructions
}

# ---------------------------------------------------------------------------
# Build a route_obj (the structure server.R consumes) from a path returned by
# astar_route or cppr_best_path. The shape of route_obj is the contract the
# Shiny renderer depends on; keep it stable when editing build_native_route_object.
# ---------------------------------------------------------------------------

native_profile_meta <- function(profile_key) {
  switch(
    tolower(as.character(profile_key %||% "fastest")),
    fastest   = list(name = "Fastest",    color = "#111111", weight = 6.0, opacity = 0.95),
    safest    = list(name = "Safest",     color = "#0b7285", weight = 5.2, opacity = 0.88),
    metro     = list(name = "Metro/Rail", color = "#6f42c1", weight = 4.6, opacity = 0.82),
    metrorail = list(name = "Metro/Rail", color = "#6f42c1", weight = 4.6, opacity = 0.82),
    list(name = "Route", color = "#111111", weight = 5.0, opacity = 0.9)
  )
}

# Why: A* returns just a node sequence and edge rows - the UI needs a fully
# decorated sf object with geometry, mileage/time totals, exposure breakdown,
# step-by-step instructions, and connector lines from the search points to
# the snapped graph nodes.
# What: returns a list with key/route_sf/display_sf/summary aligned to the
# legacy contract that the Shiny renderer expects; summary contains
# total_miles, duration_minutes, avg_risk, peak_risk, exposure tiers, and a
# human-readable reason string.
# How: pulls the original linestring geometry from the cached WI roads via
# segment_index, computes physical drive minutes via edge_minutes_for_path
# (canonical speed), builds origin/destination connectors with
# make_route_connector_sf, and aggregates exposure and highway summaries.
# When: called once per resolved profile path inside native_plan_routes, after
# search_profile returns a winning A* result.
# Impact: the only place where A*'s abstract result becomes a renderable route;
# any field the UI displays must be set here or its renderer will fall through
# to a default.
build_native_route_object <- function(path, segments, profile_key, route_rank,
                                       start_point, end_point, node_df, graph,
                                       extra_note = NULL) {
  if (is.null(path) || length(path$edge_rows) == 0) return(NULL)
  meta <- native_profile_meta(profile_key)
  route_edges <- segments[path$edge_rows, , drop = FALSE]
  if (nrow(route_edges) == 0) return(NULL)
  route_edges$route_rank <- route_rank
  route_edges$route_name <- meta$name
  route_edges$route_color <- meta$color
  route_edges$route_weight <- meta$weight
  route_edges$route_opacity <- meta$opacity
  route_edges$route_connector <- FALSE
  route_edges$step_instruction <- generate_native_step_instructions(route_edges)

  # Geometry from base WI roads (LINESTRING). segment_index points at the row
  # in the base data set; pin to that for an authentic shape.
  route_base <- load_wi_roads()
  route_base <- suppressWarnings(sf::st_cast(route_base, "LINESTRING", warn = FALSE))
  route_base <- ensure_crs_4326(route_base)
  match_idx <- pmin(nrow(route_base), pmax(1, route_edges$segment_index))
  route_geom <- route_base[match_idx, c("geometry"), drop = FALSE]
  route_sf <- sf::st_sf(route_edges, geometry = sf::st_geometry(route_geom), crs = 4326)
  display_sf <- build_route_display_sf(route_sf)

  # Connectors from start/end points to the first/last graph nodes used.
  start_node_id <- graph$node_keys[path$node_idx[1]]
  end_node_id <- graph$node_keys[path$node_idx[length(path$node_idx)]]
  start_node_row <- node_df[node_df$node_id == start_node_id, , drop = FALSE]
  end_node_row <- node_df[node_df$node_id == end_node_id, , drop = FALSE]
  connector_lengths <- c(
    tryCatch({
      conn <- make_route_connector_sf(start_point, start_node_row, meta$name, route_rank, meta$color, meta$weight, meta$opacity, "Origin")
      if (is.null(conn) || nrow(conn) == 0) 0 else suppressWarnings(as.numeric(conn$length_m[1] %||% 0))
    }, error = function(e) 0),
    tryCatch({
      conn <- make_route_connector_sf(end_point, end_node_row, meta$name, route_rank, meta$color, meta$weight, meta$opacity, "Destination")
      if (is.null(conn) || nrow(conn) == 0) 0 else suppressWarnings(as.numeric(conn$length_m[1] %||% 0))
    }, error = function(e) 0)
  )
  connector_lengths[!is.finite(connector_lengths)] <- 0
  connector_minutes <- sum((connector_lengths / 1609.344) / 18 * 60, na.rm = TRUE)
  total_miles <- (sum(route_sf$length_m, na.rm = TRUE) + sum(connector_lengths, na.rm = TRUE)) / 1609.344
  route_minutes <- sum(edge_minutes_for_path(route_edges, profile_key), na.rm = TRUE) + connector_minutes
  if (!is.finite(route_minutes) || route_minutes <= 0) route_minutes <- total_miles / 32 * 60

  exposure <- route_exposure_summary(route_sf)
  highway <- route_highway_summary(route_sf)
  avg_risk <- stats::weighted.mean(route_sf$segment_risk, w = pmax(route_sf$length_m, 1), na.rm = TRUE)
  if (!is.finite(avg_risk)) avg_risk <- 0
  peak_risk <- max(route_sf$segment_risk, na.rm = TRUE)
  if (!is.finite(peak_risk)) peak_risk <- 0
  reason_candidates <- unique(route_sf$reason_text[nzchar(trimws(route_sf$reason_text %||% ""))])
  official_impact_count <- sum(route_sf$closure_penalty > 0, na.rm = TRUE)
  high_risk_miles <- exposure$yellow_miles + exposure$red_miles
  reason_candidates <- reason_candidates[nzchar(trimws(reason_candidates))]
  official_reason_candidates <- unique(route_sf$official_reason_text[nzchar(trimws(route_sf$official_reason_text %||% ""))])
  official_source_candidates <- unique(route_sf$official_source[nzchar(trimws(route_sf$official_source %||% ""))])
  official_cause_summary <- summarize_official_transport_causes(route_sf$official_cause_kind, route_sf$official_source)
  summary_reason <- if (length(reason_candidates) == 0) "All clear." else paste(utils::head(reason_candidates, 2L), collapse = " ")
  if (nzchar(trimws(extra_note %||% ""))) summary_reason <- paste(summary_reason, extra_note)
  if (nzchar(trimws(official_cause_summary %||% ""))) {
    summary_reason <- paste(summary_reason, "Official causes:", official_cause_summary)
  } else if (length(official_reason_candidates) > 0) {
    summary_reason <- paste(summary_reason, "Official causes:", paste(utils::head(official_reason_candidates, 2L), collapse = " "))
  }

  list(
    key = tolower(as.character(profile_key %||% "fastest")),
    route_sf = route_sf,
    display_sf = display_sf,
    summary = list(
      route_rank = route_rank,
      route_name = meta$name,
      total_miles = total_miles,
      avg_risk = avg_risk,
      peak_risk = peak_risk,
      transparent_miles = exposure$transparent_miles,
      green_miles = exposure$green_miles,
      yellow_miles = exposure$yellow_miles,
      red_miles = exposure$red_miles,
      red_weighted_miles = exposure$red_weighted_miles,
      nontransparent_miles = exposure$nontransparent_miles,
      highway_miles = highway$highway_miles,
      highway_share = highway$highway_share,
      pre_highway_miles = highway$pre_highway_miles,
      post_highway_miles = highway$post_highway_miles,
      interior_local_miles = highway$interior_local_miles,
      official_impact_count = official_impact_count,
      high_risk_miles = high_risk_miles,
      duration_minutes = route_minutes,
      summary_reason = summary_reason,
      route_reused_fallback = FALSE,
      official_cause_summary = official_cause_summary,
      official_source_summary = if (length(official_source_candidates) == 0) NA_character_ else paste(utils::head(official_source_candidates, 3L), collapse = ", "),
      waypoint_count = 0L,
      hub_waypoint_count = 0L,
      zip_waypoint_count = 0L,
      waypoint_labels = "",
      label = risk_label_from_score(avg_risk)
    )
  )
}

# ---------------------------------------------------------------------------
# Why: plan_route_options needs a single function that produces the three
# profile routes the UI displays - the orchestrator owns graph caching,
# corridor-vs-full-graph fallback, the safest-route time cap, and parallel
# execution of the three searches.
# What: returns a list with three route objects (fastest/safest/metro), the
# resolved start/end points, and a human-readable status message; falls back
# gracefully if a corridor graph is too sparse to connect both endpoints.
# How: tries the corridor-restricted graph first for speed, falls back to the
# full graph if connectivity fails, snaps endpoints via
# find_polygon_or_point_nodes (multi-candidate to dodge isolated centroids),
# then runs the three A* searches under mclapply with per-profile cached edge
# weights. The safest result is re-validated against safest_time_cap_multiplier
# and replaced with the fastest's path if it overshoots the cap.
# When: called from plan_route_options after build_route_segments and any
# corridor pre-filter complete; runs once per user route request.
# Impact: end-to-end query latency lives here - the corridor fallback, the
# weights cache, and the mclapply parallelism are the three biggest knobs that
# control how long a user waits for a plan.
native_plan_routes <- function(start_point, end_point, full_segments,
                               corridor_segments = NULL, progress = NULL,
                               horizon_key = "live") {
  empty_result <- function(msg) {
    list(routes = list(), start_point = start_point, end_point = end_point, message = msg %||% "")
  }
  if (is.null(start_point) || is.null(end_point)) {
    return(empty_result("Route start or destination could not be resolved in Wisconsin."))
  }
  if (is.null(full_segments) || nrow(full_segments) == 0) {
    return(empty_result("No routable Wisconsin road segments were available for this request."))
  }

  # Build a graph + lookup-friendly node_df. `full` is always available; `corr`
  # is built only when the corridor subset is meaningfully smaller than the
  # full set. A* tries the corridor first for speed; if a profile's path is
  # blocked because the corridor cut a connection, we fall back to `full`.
  notify_progress(progress, 0.40, "Indexing the Wisconsin route graph.")
  prepare <- function(segments) {
    if (is.null(segments) || nrow(segments) == 0) return(NULL)
    # Cache the indexed graph + node_df by horizon: it depends only on the
    # segment set, not on the start/end points, so 20 consecutive route plans
    # share one graph build.
    # v3 adds pair_lookup (edge_row index keyed by canonical "u|v") for the
    # cppRouting integration path. Bump the key any time the cached payload
    # schema changes so stale entries are rebuilt rather than reused.
    graph_cache_key <- paste0("route-graph-v3-", horizon_key, "-", nrow(segments))
    cached <- cache_get("derived", graph_cache_key)
    graph <- cached$graph
    if (is.null(graph)) {
      graph <- build_route_graph(segments)
      if (is.null(graph)) return(NULL)
    }
    pair_lookup <- cached$pair_lookup
    if (is.null(pair_lookup)) pair_lookup <- build_edge_pair_lookup(segments)
    node_df <- cached$node_df
    if (is.null(graph)) return(NULL)
    if (is.null(node_df)) {
      node_df <- data.frame(
        node_id = graph$node_keys, x = graph$node_x, y = graph$node_y,
        stringsAsFactors = FALSE
      )
      node_pts_proj <- sf::st_as_sf(node_df, coords = c("x", "y"), crs = 5070, remove = FALSE)
      node_pts_lonlat <- suppressWarnings(sf::st_transform(node_pts_proj, 4326))
      node_coords_lonlat <- suppressWarnings(sf::st_coordinates(node_pts_lonlat))
      if (!is.null(node_coords_lonlat) && nrow(node_coords_lonlat) == nrow(node_df)) {
        node_df$lon <- node_coords_lonlat[, "X"]
        node_df$lat <- node_coords_lonlat[, "Y"]
      } else {
        node_df$lon <- node_df$x
        node_df$lat <- node_df$y
      }
      # Mark nodes that touch a high-tier (Interstate / US / State) edge so
      # find_polygon_or_point_nodes can offer the planner a natural highway
      # access point in addition to polygon-interior locals. Without this,
      # downtown ZIP starts always begin on a local street, forcing A* to
      # loop through the city before reaching any arterial.
      high_tier_edges <- as.character(segments$route_tier %||% "") %in% c("Interstate", "US", "State")
      high_tier_node_ids <- unique(c(
        as.character(segments$from_node[high_tier_edges]),
        as.character(segments$to_node[high_tier_edges])
      ))
      node_df$is_high_tier <- node_df$node_id %in% high_tier_node_ids
      cache_put("derived", graph_cache_key,
                list(graph = graph, node_df = node_df, pair_lookup = pair_lookup),
                ttl_seconds = if (identical(horizon_key, "live")) max(600L, ALERT_TTL_SECONDS) else FORECAST_TTL_SECONDS)
    }
    # Find candidate snap nodes. For polygon-shaped queries (counties, ZIPs)
    # the centroid alone is unreliable: the centroid of Door County lands in a
    # remote part of the peninsula whose nearest filtered-network road sits in
    # a disconnected sub-component. find_polygon_or_point_nodes prefers nodes
    # that lie *inside* the polygon, falling back to centroid-nearest for plain
    # ZIP/text queries.
    start_ids <- find_polygon_or_point_nodes(node_df, start_point, max_candidates = 4L)
    end_ids <- find_polygon_or_point_nodes(node_df, end_point, max_candidates = 4L)
    start_ids <- start_ids[nzchar(start_ids %||% "")]
    end_ids <- end_ids[nzchar(end_ids %||% "")]
    if (length(start_ids) == 0L || length(end_ids) == 0L) return(NULL)
    src_idx <- vapply(start_ids, function(id) graph_node_for_id(graph, id), integer(1))
    dst_idx <- vapply(end_ids, function(id) graph_node_for_id(graph, id), integer(1))
    src_idx <- src_idx[!is.na(src_idx)]
    dst_idx <- dst_idx[!is.na(dst_idx)]
    if (length(src_idx) == 0L || length(dst_idx) == 0L) return(NULL)
    list(segments = segments, graph = graph, node_df = node_df,
         pair_lookup = pair_lookup,
         src_candidates = unique(src_idx), dst_candidates = unique(dst_idx),
         start_point = start_point, end_point = end_point,
         weights_cache = list())
  }

  full_ctx <- prepare(full_segments)
  if (is.null(full_ctx)) {
    return(empty_result("Could not index the Wisconsin road graph for this request."))
  }
  # Corridor pruning is intentionally disabled. Cross-state Interstate routes
  # frequently sit outside a tight buffer around the start-end line (e.g.
  # Milwaukee -> Wausau via I-94 -> I-39 takes a southern dogleg through
  # Madison that escapes a 30%-of-span buffer). Heap A* with the great-circle
  # heuristic searches the full statewide graph in well under a second, so the
  # corridor optimisation is no longer worth the loss of route quality.
  corr_ctx <- NULL

  # Pick the lowest-total-cost path across all (start_candidate, end_candidate)
  # combinations on `ctx`. Multi-candidate is what lets the search escape grid-
  # snap fragmentation: the single nearest node may sit in a small disconnected
  # component, but one of the next-nearest nodes will be on the main network.
  cppr_available <- requireNamespace("cppRouting", quietly = TRUE)
  best_path_for_ctx <- function(ctx, weights) {
    if (cppr_available && !is.null(ctx$pair_lookup)) {
      cppr_g <- tryCatch(
        cppRouting::makegraph(
          data.frame(
            from = as.character(ctx$segments$from_node),
            to   = as.character(ctx$segments$to_node),
            dist = as.numeric(weights),
            stringsAsFactors = FALSE
          ),
          directed = FALSE
        ),
        error = function(e) NULL
      )
      if (!is.null(cppr_g)) {
        src_ids <- ctx$graph$node_keys[ctx$src_candidates]
        dst_ids <- ctx$graph$node_keys[ctx$dst_candidates]
        cp <- cppr_best_path(cppr_g, ctx$graph, ctx$pair_lookup, src_ids, dst_ids)
        if (!is.null(cp)) return(cp)
      }
    }
    # Fallback: legacy in-process heap A* (kept for environments where
    # cppRouting cannot be installed).
    best <- NULL
    best_cost <- Inf
    for (s in ctx$src_candidates) {
      for (d in ctx$dst_candidates) {
        if (s == d) next
        p <- astar_route(ctx$graph, s, d, weights)
        if (is.null(p)) next
        if (p$cost < best_cost) {
          best <- p
          best_cost <- p$cost
        }
      }
    }
    best
  }

  # Search a single profile, preferring the corridor graph but falling back to
  # the full graph when the corridor doesn't connect source to target.
  search_profile <- function(profile_key) {
    if (!is.null(corr_ctx)) {
      w <- corr_ctx$weights_cache[[profile_key]]
      if (is.null(w)) {
        w <- compute_profile_edge_weights(corr_ctx$segments, profile_key)
        corr_ctx$weights_cache[[profile_key]] <<- w
      }
      p <- best_path_for_ctx(corr_ctx, w)
      if (!is.null(p)) return(list(path = p, ctx = corr_ctx, fallback = FALSE))
    }
    w <- full_ctx$weights_cache[[profile_key]]
    if (is.null(w)) {
      w <- compute_profile_edge_weights(full_ctx$segments, profile_key)
      full_ctx$weights_cache[[profile_key]] <<- w
    }
    p <- best_path_for_ctx(full_ctx, w)
    if (is.null(p)) return(NULL)
    list(path = p, ctx = full_ctx, fallback = TRUE)
  }

  build_for_profile <- function(profile_key, route_rank, base_note = NULL) {
    res <- search_profile(profile_key)
    if (is.null(res)) return(NULL)
    note <- base_note
    if (isTRUE(res$fallback)) {
      note <- paste(c(note,
        "The statewide Wisconsin road network was used to bridge a corridor gap."),
        collapse = " ")
    }
    build_native_route_object(
      res$path, res$ctx$segments, profile_key, route_rank,
      start_point, end_point, res$ctx$node_df, res$ctx$graph,
      extra_note = if (nzchar(trimws(note %||% ""))) note else NULL
    )
  }

  notify_progress(progress, 0.55, "Computing all three profile routes in parallel.")
  # Run the three profile searches in parallel across mc.cores. Each profile is
  # a CPU-bound A* over the same shared graph; mclapply forks the R process so
  # the graph and node_df are shared via copy-on-write rather than copied. On
  # macOS / Linux this gives ~3x speedup; on Windows mclapply silently falls
  # back to lapply.
  profile_jobs <- list(
    list(key = "fastest", rank = 1L),
    list(key = "safest",  rank = 2L),
    list(key = "metro",   rank = 3L)
  )
  worker_count <- min(length(profile_jobs), max(1L, parallel::detectCores(logical = FALSE)))
  profile_results <- tryCatch(
    parallel::mclapply(profile_jobs, function(job) build_for_profile(job$key, job$rank),
                        mc.cores = worker_count, mc.preschedule = FALSE),
    error = function(e) lapply(profile_jobs, function(job) build_for_profile(job$key, job$rank))
  )
  # mclapply returns errors as list elements with try-error class; coerce.
  profile_results <- lapply(profile_results, function(x) if (inherits(x, "try-error")) NULL else x)

  fastest_route <- profile_results[[1]]
  raw_safest <- profile_results[[2]]
  raw_metro <- profile_results[[3]]

  if (is.null(fastest_route)) {
    return(empty_result("No fastest route could be computed from the current Wisconsin road graph."))
  }
  fastest_minutes <- fastest_route$summary$duration_minutes %||% NA_real_
  if (!is.finite(fastest_minutes) || fastest_minutes <= 0) fastest_minutes <- 60

  safest_route <- NULL
  if (!is.null(raw_safest)) {
    cap_mult <- safest_time_cap_multiplier(fastest_minutes / 60)
    cap_minutes <- fastest_minutes * cap_mult
    if (is.finite(raw_safest$summary$duration_minutes) && raw_safest$summary$duration_minutes <= cap_minutes) {
      safest_route <- raw_safest
    }
  }
  if (is.null(safest_route)) {
    safest_route <- clone_route_profile(
      fastest_route,
      list(route_rank = 2L, route_name = "Safest",
           route_color = "#0b7285", route_weight = 5.2, route_opacity = 0.88,
           key = "safest"),
      note = "No materially safer route fits the time budget; reusing the fastest corridor."
    )
  }

  metro_route <- raw_metro
  if (is.null(metro_route)) {
    metro_route <- clone_route_profile(
      fastest_route,
      list(route_rank = 3L, route_name = "Metro/Rail",
           route_color = "#6f42c1", route_weight = 4.6, route_opacity = 0.82,
           key = "metro"),
      note = "No distinct city-corridor route was found; reusing the fastest corridor."
    )
  }

  routes <- Filter(Negate(is.null), list(fastest_route, safest_route, metro_route))
  notify_progress(progress, 0.93, "Native route candidates ready.")
  list(routes = routes, start_point = start_point, end_point = end_point, message = "")
}
