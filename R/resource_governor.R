# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------
#
# R/resource_governor.R — dynamic memory + compute resource governor.
#
# Keeps FLOWS' parallel work from pushing the system past a memory ceiling
# (default 90%), accounting for *other* background tasks, and routes eligible
# calculations to the least-loaded accurate compute backend. On Apple Silicon
# the memory accounting mirrors what Activity Monitor calls "memory pressure":
# used = wired + active + compressed (inactive/speculative are reclaimable and
# do NOT count as pressure).
#
# What maps to what accelerator (honest accounting for M-series):
#   * CPU (10 cores, 8P+2E)  — everything: GEOS geometry, A*/Dijkstra graph
#     search, all current hot paths. Default and always-correct.
#   * GPU (32 Metal cores)   — ONLY large dense linear-algebra: the outer()
#     Euclidean distance matrices, and (future) contraction-hierarchy batch
#     shortest paths. Requires the `torch` package with its MPS backend;
#     absent by default. compute_backend() reports "gpu" only when torch+MPS
#     is genuinely available AND the op is GPU-amenable — never fabricated.
#   * NPU / Neural Engine    — NOT usable for FLOWS' calculations. The ANE is
#     a fixed-function ML-inference accelerator reachable only via CoreML;
#     FLOWS has no ML model in its hot path (geometry + graph search do not
#     map to convolution/matmul-only silicon). Deliberately never targeted.

# ---------------------------------------------------------------------------
# Memory accounting
# ---------------------------------------------------------------------------

# Why: parallel fan-out (mclapply forks) and heavy sf builds can push a
# machine that is ALREADY loaded by other apps past a safe memory ceiling,
# triggering swap/compression thrash that slows everything. We need a live
# read of how much memory is genuinely committed right now.
# What: returns the fraction (0..1) of physical RAM committed as
# wired + active + compressed — the macOS "memory pressure" definition.
# On non-macOS falls back to a proc-based estimate or 0.5 if unknown.
# How: parses `vm_stat` page counts + `sysctl hw.memsize`; used pages =
# wired + active + compressor; total = memsize / page_size.
# When: called before any heavy parallel launch and by the continuous test
# runner between jobs.
# Impact: an over-estimate needlessly throttles throughput; an under-estimate
# risks the thrash we are trying to avoid. The wired+active+compressed
# definition is deliberately conservative (counts compressed as used).
system_memory_used_fraction <- function() {
  if (Sys.info()[["sysname"]] != "Darwin") {
    # Linux fallback: MemAvailable from /proc/meminfo.
    mi <- tryCatch(readLines("/proc/meminfo", warn = FALSE), error = function(e) NULL)
    if (is.null(mi)) return(0.5)
    total <- as.numeric(sub("[^0-9]*([0-9]+).*", "\\1",
                            grep("^MemTotal:", mi, value = TRUE)))
    avail <- as.numeric(sub("[^0-9]*([0-9]+).*", "\\1",
                            grep("^MemAvailable:", mi, value = TRUE)))
    if (length(total) == 0 || length(avail) == 0 || total <= 0) return(0.5)
    return(1 - avail / total)
  }
  memsize <- suppressWarnings(as.numeric(
    system2("sysctl", c("-n", "hw.memsize"), stdout = TRUE, stderr = FALSE)))
  vm <- tryCatch(system2("vm_stat", stdout = TRUE, stderr = FALSE),
                 error = function(e) character(0))
  if (length(vm) == 0 || !is.finite(memsize) || memsize <= 0) return(0.5)
  page_size <- suppressWarnings(as.numeric(
    sub(".*page size of ([0-9]+) bytes.*", "\\1", vm[1])))
  if (!is.finite(page_size) || page_size <= 0) page_size <- 16384
  grab <- function(label) {
    ln <- grep(label, vm, value = TRUE, fixed = TRUE)
    if (length(ln) == 0) return(0)
    suppressWarnings(as.numeric(gsub("[^0-9]", "", ln[1])))
  }
  wired      <- grab("Pages wired down:")
  active     <- grab("Pages active:")
  compressor <- grab("Pages occupied by compressor:")
  used_bytes <- (wired + active + compressor) * page_size
  frac <- used_bytes / memsize
  if (!is.finite(frac)) return(0.5)
  max(0, min(1, frac))
}

# Why: a single boolean gate is the cleanest interface for "should I hold off
# launching more work right now?".
# What: returns TRUE when current memory usage is at/above the ceiling.
# How: thin wrapper over system_memory_used_fraction().
# When: checked before heavy launches; the runner loops on it.
# Impact: the ceiling is the one knob controlling the safety margin. 0.90
# leaves 10% headroom for spikes; lower is safer but slower.
system_under_memory_pressure <- function(ceiling = 0.90) {
  system_memory_used_fraction() >= ceiling
}

# Why: forking N mclapply workers each copies the parent's resident set; with
# large sf objects in memory, too many workers can blow past the ceiling even
# though CPU cores are idle. Core count must be bounded by MEMORY, not just
# by detectCores().
# What: returns an integer worker count sized by BOTH available memory
# headroom (below the ceiling) and a CPU cap.
# How: available_gb = (ceiling - used_frac) * total_gb; workers =
# floor(available_gb / mem_per_worker_gb), clamped to [1, cpu_cap].
# When: passed as mc.cores to every mclapply / mcparallel launch that could
# be memory-heavy.
# Impact: mem_per_worker_gb is the estimate of each fork's incremental RSS;
# too low over-commits, too high under-utilises. 1.5 GB is a safe default for
# the FLOWS sf working set.
dynamic_mc_cores <- function(mem_per_worker_gb = 1.5,
                             cpu_cap = max(1L, parallel::detectCores() - 2L),
                             ceiling = 0.90) {
  memsize_gb <- tryCatch(
    as.numeric(system2("sysctl", c("-n", "hw.memsize"),
                       stdout = TRUE, stderr = FALSE)) / 2^30,
    error = function(e) 8)
  if (Sys.info()[["sysname"]] != "Darwin") {
    memsize_gb <- tryCatch({
      mi <- readLines("/proc/meminfo", warn = FALSE)
      as.numeric(sub("[^0-9]*([0-9]+).*", "\\1",
                     grep("^MemTotal:", mi, value = TRUE))) / 2^20
    }, error = function(e) 8)
  }
  used <- system_memory_used_fraction()
  available_gb <- max(0, (ceiling - used) * memsize_gb)
  workers <- floor(available_gb / max(mem_per_worker_gb, 0.25))
  as.integer(max(1L, min(cpu_cap, workers)))
}

# Why: when the system is momentarily over the ceiling (another app spiked),
# the right move for a background test job is to WAIT, not to pile on.
# What: blocks until memory drops below the ceiling or the timeout elapses;
# returns TRUE if headroom was reached, FALSE on timeout.
# How: polls system_memory_used_fraction() every `poll_seconds`, up to
# `timeout_seconds`.
# When: the continuous runner calls this between jobs; heavy foreground
# builds can call it before the memory-intensive stage.
# Impact: too long a timeout stalls throughput under sustained pressure; the
# default 120 s / 3 s poll balances patience against progress.
wait_for_memory_headroom <- function(ceiling = 0.90,
                                     timeout_seconds = 120,
                                     poll_seconds = 3) {
  deadline <- as.numeric(Sys.time()) + timeout_seconds
  repeat {
    if (!system_under_memory_pressure(ceiling)) return(TRUE)
    if (as.numeric(Sys.time()) >= deadline) return(FALSE)
    Sys.sleep(poll_seconds)
  }
}

# ---------------------------------------------------------------------------
# Compute backend selection (honest — GPU only when genuinely available)
# ---------------------------------------------------------------------------

# Why: the ONLY FLOWS computations that map accurately to the Apple GPU are
# large dense linear-algebra ops (outer-product distance matrices; future CH
# batch shortest paths). We want a single seam that routes those to the GPU
# when a real MPS-backed tensor library is present, and to the CPU otherwise
# — never a fabricated GPU claim.
# What: returns "gpu" only when the `torch` package is installed AND its MPS
# (Metal) backend reports available; otherwise "cpu".
# How: requireNamespace + backends_mps_is_available(), both guarded.
# When: consulted by gpu_amenable ops (e.g. euclidean_distance_matrix) to
# decide where to run.
# Impact: if torch is later installed, GPU offload turns on automatically for
# eligible ops; until then everything stays correct on CPU. The NPU is never
# a candidate here — it cannot run these ops.
#
# The one-time float64-on-MPS probe matters: Apple's Metal/MPS backend does
# NOT support float64, so "MPS available" alone advertised a GPU path that
# threw and fell back on EVERY call — eligibility must prove the exact dtype
# our byte-identical contract requires, not just device presence. Cached so
# the probe cost is paid once per process.
.flows_backend_state <- new.env(parent = emptyenv())
compute_backend <- function() {
  cached <- .flows_backend_state$backend
  if (!is.null(cached)) return(cached)
  backend <- "cpu"
  if (requireNamespace("torch", quietly = TRUE)) {
    ok <- tryCatch({
      isTRUE(torch::backends_mps_is_available()) && {
        probe <- torch::torch_tensor(matrix(1.0), dtype = torch::torch_float64())$to(device = "mps")
        TRUE  # float64 tensor accepted on MPS
      }
    }, error = function(e) FALSE)
    if (isTRUE(ok)) backend <- "gpu"
  }
  .flows_backend_state$backend <- backend
  backend
}

# Why: the outer-product Euclidean distance matrix (roads vs official
# centroids; ZIP vs signs) is the single largest dense-linear-algebra op in
# the hot path and the one op that would genuinely benefit from the GPU at
# CONUS scale. Centralising it behind one function lets the backend switch be
# a one-line change with identical numeric output.
# What: given two coordinate matrices A (n x 2) and B (m x 2), returns the
# n x m Euclidean distance matrix. Byte-for-byte equivalent on CPU and GPU
# (same float64 math) so it is always accuracy-preserving.
# How: CPU path uses outer()/sqrt (current behaviour). GPU path (torch+MPS)
# uses torch_cdist on double tensors, only when compute_backend()=="gpu" AND
# the matrix is large enough that the transfer cost is amortised.
# When: called by compute_511_road_proximity_signal and the message-sign
# signals in place of the inline outer() blocks (migration is incremental —
# this function is the drop-in).
# Impact: on CPU, identical to the current code. On GPU, large matrices move
# to the 32-core GPU; the min-size guard prevents GPU use where CPU is faster
# (small matrices, where host<->device transfer dominates).
euclidean_distance_matrix <- function(A, B, gpu_min_cells = 2e6) {
  A <- as.matrix(A); B <- as.matrix(B)
  n <- nrow(A); m <- nrow(B)
  use_gpu <- (as.numeric(n) * as.numeric(m) >= gpu_min_cells) &&
             identical(compute_backend(), "gpu")
  if (use_gpu) {
    out <- tryCatch({
      ta <- torch::torch_tensor(A, dtype = torch::torch_float64())$to(device = "mps")
      tb <- torch::torch_tensor(B, dtype = torch::torch_float64())$to(device = "mps")
      d  <- torch::torch_cdist(ta, tb)
      as.matrix(torch::as_array(d$to(device = "cpu")))
    }, error = function(e) NULL)
    if (!is.null(out)) return(out)
    # fall through to CPU on any GPU error — correctness over speed.
  }
  x_diff <- outer(A[, 1], B[, 1], "-")
  y_diff <- outer(A[, 2], B[, 2], "-")
  sqrt(x_diff * x_diff + y_diff * y_diff)
}

# Why: a compact, greppable line describing the current resource posture is
# useful in the warmer log and the continuous-runner heartbeat.
# What: returns a one-line string like
# "mem 88.4% used | mc.cores 3 | backend cpu".
# How: composes the three accessors above.
# When: logged by the warmer and the runner.
# Impact: informational only; never gates behaviour.
resource_posture_line <- function() {
  sprintf("mem %.1f%% used | mc.cores %d | backend %s",
          100 * system_memory_used_fraction(),
          dynamic_mc_cores(),
          compute_backend())
}
