// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
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
        cfg.httpAdditionalHeaders = ["User-Agent": "FLOWS (wizeman555@gmail.com)"]
        return URLSession(configuration: cfg)
    }()

    /// GET a URL through the global gate.
    static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        try await fetchGuarded(host: url.host) { try await session.data(from: url) }
    }

    /// Perform a request (POST/custom headers) through the global gate.
    static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await fetchGuarded(host: request.url?.host) { try await session.data(for: request) }
    }

    /// Permit + per-host breaker around one transport attempt. The breaker
    /// check happens AFTER permit acquisition — a queued call to a host that
    /// died while it waited must fast-fail and hand its permit on, not hold
    /// it for a full connect timeout. (EPQS outage: 300 queued elevation
    /// calls × 10 s timeouts starved every healthy feed for minutes.)
    private static func fetchGuarded(
        host: String?, _ op: @Sendable () async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        try await RequestGate.shared.withPermit {
            let host = host ?? ""
            guard await HostBreaker.shared.admits(host) else {
                throw URLError(.cannotConnectToHost)
            }
            do {
                let out = try await op()
                await HostBreaker.shared.recordSuccess(host)
                return out
            } catch {
                // CANCELLATION is not a host failure — a camera move that
                // supersedes a viewport sweep cancels its in-flight fetches,
                // and counting those tripped the breaker on a HEALTHY host
                // (launch: GPS fix → map flies → mass-cancel → NWS "down").
                if !(error is CancellationError),
                   (error as? URLError)?.code != .cancelled {
                    await HostBreaker.shared.recordFailure(host)
                } else {
                    // Cancelled: not a failure, but must release a half-open
                    // probe slot or the host stays blacklisted for the session.
                    await HostBreaker.shared.probeAborted(host)
                }
                throw error
            }
        }
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

/// Cap-overflow eviction for the app's in-memory fetch caches. The old
/// policy — wipe the whole dictionary at the cap — discarded entries fetched
/// seconds earlier, so the next viewport sweep or route re-score missed on
/// everything and refetched a full round from the polite endpoints.
enum CacheEviction {
    /// Dated caches: drop the OLDEST half, keep the fresh half alive.
    static func dropOldestHalf<V>(_ cache: inout [String: V], date: (V) -> Date) {
        let doomed = cache.sorted { date($0.value) < date($1.value) }
            .prefix(cache.count / 2)
        for (k, _) in doomed { cache.removeValue(forKey: k) }
    }

    /// Undated caches (static data with no fetch stamp): drop an arbitrary
    /// half — still strictly better than losing everything.
    static func dropHalf<K, V>(_ cache: inout [K: V]) {
        for k in Array(cache.keys.prefix(cache.count / 2)) {
            cache.removeValue(forKey: k)
        }
    }
}

/// Per-host circuit breaker. A host that fails at the TRANSPORT level (times
/// out, refuses connections) `trip` times in a row stops receiving requests
/// for `cooldown` — its zombie sockets must not hold the app-wide permit
/// pool hostage while every healthy feed queues behind them. After the
/// cooldown exactly ONE probe is admitted (no thundering herd); its outcome
/// closes or re-opens the breaker. An HTTP response of any status is a
/// SUCCESS here — the host answered; status handling belongs to callers.
actor HostBreaker {
    static let shared = HostBreaker()

    private var failures: [String: Int] = [:]
    private var openedAt: [String: Date] = [:]
    private var probing: Set<String> = []
    private let trip: Int
    private let cooldown: TimeInterval

    init(trip: Int = 5, cooldown: TimeInterval = 120) {
        self.trip = trip
        self.cooldown = cooldown
    }

    func admits(_ host: String) -> Bool {
        guard let opened = openedAt[host] else { return true }
        if Date().timeIntervalSince(opened) >= cooldown, !probing.contains(host) {
            probing.insert(host)   // half-open: one probe carries the verdict
            return true
        }
        return false
    }

    func recordSuccess(_ host: String) {
        probing.remove(host)
        failures[host] = 0
        openedAt[host] = nil
    }

    func recordFailure(_ host: String) {
        probing.remove(host)
        let n = (failures[host] ?? 0) + 1
        failures[host] = n
        if n >= trip { openedAt[host] = Date() }   // (re)open, restart cooldown
    }

    /// A half-open probe was CANCELLED (not a real success or failure) — clear
    /// the probing flag so the next request can probe again. Without this a
    /// cancelled probe (e.g. a panned-away viewport sweep) left the host
    /// permanently in `probing`, so admits() blacklisted it for the session.
    func probeAborted(_ host: String) {
        probing.remove(host)
    }
}

/// App-wide concurrency limiter: an async counting gate whose ceiling is read
/// live from `AdaptiveTuning`, so it tightens automatically when the device is
/// weak, hot, or in Low Power Mode. Callers waiting for a slot are resumed
/// FIFO as slots free.
///
/// Two ceilings, one pool: the BACKGROUND ceiling (`maxInFlight`) applies at
/// rest; while at least one PLANNING BURST is open (`beginPlanningBurst` /
/// `endPlanningBurst`, refcounted) the elevated `planningMaxInFlight` ceiling
/// applies instead. The burst lane exists for user-initiated route scoring —
/// the driver is watching a spinner until GO unlocks — and every request
/// still passes through this one gate, so the fan-out stays bounded either
/// way. A safety window expires a leaked burst so a lost `end` can't pin the
/// elevated ceiling for the rest of the session.
actor RequestGate {
    static let shared = RequestGate()

    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var burstDepth = 0
    private var burstExpiry = Date.distantPast
    private let baseCeiling: @Sendable () -> Int
    private let burstCeiling: @Sendable () -> Int
    private let burstSafetyWindow: TimeInterval

    /// Ceiling providers are injectable so gate behavior is testable with
    /// fixed numbers; the app's shared instance reads AdaptiveTuning live.
    init(baseCeiling: @escaping @Sendable () -> Int = { AdaptiveTuning.shared.maxInFlight },
         burstCeiling: @escaping @Sendable () -> Int = { AdaptiveTuning.shared.settings.planningMaxInFlight },
         burstSafetyWindow: TimeInterval = 90) {
        self.baseCeiling = baseCeiling
        self.burstCeiling = burstCeiling
        self.burstSafetyWindow = burstSafetyWindow
    }

    private var ceiling: Int {
        burstDepth > 0 && Date() < burstExpiry
            ? max(baseCeiling(), burstCeiling()) : baseCeiling()
    }

    /// Open the elevated planning lane. Waiters already parked are admitted
    /// up to the new ceiling immediately — the queued corridor fetches of the
    /// plan that just began must not trickle out at the background pace.
    func beginPlanningBurst() {
        burstDepth += 1
        burstExpiry = Date().addingTimeInterval(burstSafetyWindow)
        while !waiters.isEmpty, active < ceiling {
            active += 1
            waiters.removeFirst().resume()
        }
    }

    /// Close one planning burst. The ceiling drops when the last one closes;
    /// in-flight requests above the lower ceiling drain naturally (release
    /// stops handing permits to waiters until `active` sinks back under).
    func endPlanningBurst() {
        burstDepth = max(0, burstDepth - 1)
    }

    private func acquire() async {
        if active < ceiling {
            active += 1
            return
        }
        // No slot: park until release() hands one over (the slot count stays
        // put across the handoff, so we don't double-count).
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        // Hand the permit to the next waiter ONLY while within the current
        // ceiling — after a burst ends (or the device heats up) the pool must
        // shrink to the lower ceiling before waiters run again.
        if !waiters.isEmpty, active <= ceiling {
            waiters.removeFirst().resume()   // transfer the permit directly
        } else {
            active = max(0, active - 1)
        }
    }

    /// Run `op` while holding one permit. Reentrant-safe: the actor is only
    /// held across the cheap counter bookkeeping, not the awaited work.
    /// `throws` (not rethrows): cancellation below throws its own error.
    func withPermit<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        // A cancelled caller must not spend its permit on transport work: a
        // panned-away viewport sweep can park ~40 dead waiters, and on a
        // thermally-throttled 2-permit pool the user's route-scoring fetches
        // would serialize behind every one of them entering URLSession just
        // to throw. Fail fast here — the permit recycles immediately.
        if Task.isCancelled { throw CancellationError() }
        return try await op()
    }
}
