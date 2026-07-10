// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// One shared, throttled HTTP path for the whole app. Two problems it fixes:
///   1. There were 8+ independent `URLSession`s, each with its own per-host
///      connection budget — so a viewport sweep could open dozens of sockets
///      to the same source at once. This is ONE session with a small per-host
///      cap.
///   2. Fan-outs (a 5×5 hazard grid, a corridor's alert points, a route's
///      elevation samples) could each spawn 25–75 simultaneous requests. Every
///      fetch here passes through a GLOBAL permit gate sized to
///      `AdaptiveTuning.maxInFlight`, so no matter how wide the fan-out, only a
///      device-appropriate number are ever in flight; the rest wait for a slot
///      instead of hammering the network and the CPU. Excess work queues, it
///      doesn't pile on — which is exactly what an old iPhone needs.
enum ThrottledNet {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 30
        cfg.httpMaximumConnectionsPerHost = 3
        cfg.waitsForConnectivity = true
        cfg.httpAdditionalHeaders = ["User-Agent": "FLOWS (davidfoster4708@gmail.com)"]
        return URLSession(configuration: cfg)
    }()

    /// GET a URL through the global gate.
    static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        try await RequestGate.shared.withPermit { try await session.data(from: url) }
    }

    /// Perform a request (POST/custom headers) through the global gate.
    static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await RequestGate.shared.withPermit { try await session.data(for: request) }
    }

    // MARK: - Graceful source fallback

    /// Ordered fallback: return the first producer that yields a non-nil value,
    /// short-circuiting the rest. The pure building block for "primary →
    /// secondary → …" source chains — no network, so its ordering and
    /// short-circuit contract is unit-tested directly (see `ThrottledNetTests`).
    static func firstNonNil<T>(_ producers: [() async -> T?]) async -> T? {
        for produce in producers {
            if let value = await produce() { return value }
        }
        return nil
    }

    /// Try each candidate URL in order, returning the first that fetches with
    /// HTTP 200 AND parses to a usable value via the caller's `parse`. A primary
    /// that is down, times out, is rate-limited, or returns a 200 wrapping an
    /// error/token body (common on these government feeds — a bare 200 is never
    /// proof of good data) falls through to the next source. `nil` only when
    /// every source failed; `nil` entries in `urls` (bad URL strings) are
    /// skipped. Sources still ride the global gate, so a chain never fans out —
    /// it tries one at a time until one works.
    static func firstValid<T>(
        _ urls: [URL?],
        parse: @Sendable @escaping (Data, HTTPURLResponse) -> T?
    ) async -> T? {
        await firstNonNil(urls.map { maybeURL in
            { () async -> T? in
                guard let url = maybeURL,
                      let (data, resp) = try? await fetch(url),
                      let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let value = parse(data, http)
                else { return nil }
                return value
            }
        })
    }

    /// Request-based twin of `firstValid(_:parse:)` for POST / custom-header
    /// sources (e.g. Overpass, keyed APIs) that need more than a bare GET URL.
    static func firstValid<T>(
        _ requests: [URLRequest],
        parse: @Sendable @escaping (Data, HTTPURLResponse) -> T?
    ) async -> T? {
        await firstNonNil(requests.map { req in
            { () async -> T? in
                guard let (data, resp) = try? await fetch(req),
                      let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let value = parse(data, http)
                else { return nil }
                return value
            }
        })
    }
}

/// App-wide concurrency limiter: an async counting gate whose ceiling is read
/// live from `AdaptiveTuning`, so it tightens automatically when the device is
/// weak, hot, or in Low Power Mode. Callers waiting for a slot are resumed
/// FIFO as slots free.
actor RequestGate {
    static let shared = RequestGate()

    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if active < AdaptiveTuning.shared.maxInFlight {
            active += 1
            return
        }
        // No slot: park until release() hands one over (the slot count stays
        // put across the handoff, so we don't double-count).
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()   // transfer the permit directly
        }
    }

    /// Run `op` while holding one permit. Reentrant-safe: the actor is only
    /// held across the cheap counter bookkeeping, not the awaited work.
    func withPermit<T: Sendable>(_ op: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await op()
    }
}
