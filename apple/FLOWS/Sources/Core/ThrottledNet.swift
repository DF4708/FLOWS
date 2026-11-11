// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation
import Network
import os

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
    #if os(iOS)
        /// Multipath TCP for Wi-Fi ↔ cellular HANDOVER — exactly the moment a
        /// driver pulls out of their driveway mid-plan and the phone walks off
        /// home Wi-Fi. Requires the paid-team
        /// com.apple.developer.networking.multipath entitlement, which
        /// ad-hoc/local signing cannot carry (same situation as the WeatherKit
        /// hook): WITHOUT the entitlement iOS refuses multipath sockets, so the
        /// default stays .none. When the app is provisioned for it, set this to
        /// .handover — the session below picks it up with no other changes.
        static let multipathService: URLSessionConfiguration.MultipathServiceType = .none
    #endif

    static let session: URLSession = {
        // Start watching the network path now: first met inside a failed
        // request, it still said "online" and a dead zone at launch was
        // counted against the hosts.
        _ = NetworkPath.shared
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 30
        cfg.httpMaximumConnectionsPerHost = 3
        cfg.waitsForConnectivity = true
        cfg.httpAdditionalHeaders = ["User-Agent": "FLOWS (wizeman555@gmail.com)"]
        #if os(iOS)
            cfg.multipathServiceType = Self.multipathService
        #endif
        // Real protocol-level HTTP cache (probed 2026-08: api.weather.gov
        // sends ETag/Last-Modified on alerts and forecasts, and marks /points
        // grid metadata fresh for HOURS). With capacity to actually hold this
        // app's bodies, URLSession then serves still-fresh responses with no
        // request at all and turns TTL-expiry refetches into ~200-byte 304
        // revalidations instead of full bodies — the corridor watch re-checks
        // ~25 alert cells every 4 min on a drive, and during active weather
        // each unchanged body it no longer re-downloads is tens of KB.
        // Disk-backed, so the cache is warm across launches. App-level parsed
        // caches (AlertZoneCache etc.) sit above this unchanged; failures
        // still surface as errors, never as cached bodies.
        cfg.urlCache = cache
        return URLSession(configuration: cfg)
    }()

    /// The session's HTTP cache, held here so "Erase everything" can empty
    /// it: its request URLs are positions and route points.
    static let cache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 50 << 20)

    /// GET a URL through the global gate.
    static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        try await fetchGuarded(host: url.host) { try await session.data(from: url) }
    }

    /// Perform a request (POST/custom headers) through the global gate.
    static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await fetchGuarded(host: request.url?.host) { try await session.data(for: request) }
    }

    /// The session for BIG bodies — a city's schedule is tens of megabytes.
    /// Written straight to disk, never held in memory; ten minutes to arrive
    /// instead of thirty seconds, because 54 MB on a slow cellular link takes
    /// longer than that; kept out of the HTTP cache it would flush; and it
    /// stays off a connection the person has put in Low Data Mode.
    static let bulkSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        cfg.httpMaximumConnectionsPerHost = 2
        // Not waiting for a connection: in Low Data Mode (refused below) or
        // a dead zone the download sat for the full ten minutes, and its
        // card span that long. It fails at once and the card says so.
        cfg.waitsForConnectivity = false
        cfg.allowsConstrainedNetworkAccess = false
        cfg.urlCache = nil
        cfg.httpAdditionalHeaders = ["User-Agent": "FLOWS (wizeman555@gmail.com)"]
        #if os(iOS)
            cfg.multipathServiceType = Self.multipathService
        #endif
        return URLSession(configuration: cfg)
    }()

    /// Big downloads take turns on a gate of their own. On the shared one a
    /// schedule archive held one of two to ten permits for up to ten
    /// minutes, and route scoring ran on what was left.
    private static let bulkGate = RequestGate(baseCeiling: { 1 }, burstCeiling: { 1 })

    /// Set for work nobody is waiting on (the map's hazard sweep): its
    /// requests take a permit only when no other request is queued, so a
    /// route being scored is never behind them.
    @TaskLocal static var lowPriority = false

    /// Download a request's body into `destination` (replacing anything
    /// there), through its own one-at-a-time gate and the host breaker.
    static func download(_ request: URLRequest, to destination: URL) async throws -> URLResponse {
        try await fetchGuarded(host: request.url?.host, gate: bulkGate) {
            let file: URL
            let response: URLResponse
            do {
                (file, response) = try await bulkSession.download(for: request)
            } catch {
                // Callers show an estimate when a timetable does not come;
                // this is how they can say why.
                if LowDataRefusal.isOne(error) { LowDataRefusal.shared.note() }
                throw error
            }
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: file, to: destination)
            return response
        }
    }

    /// Permit + per-host breaker around one transport attempt. The breaker
    /// check happens AFTER permit acquisition — a queued call to a host that
    /// died while it waited must fast-fail and hand its permit on, not hold
    /// it for a full connect timeout. (EPQS outage: 300 queued elevation
    /// calls × 10 s timeouts starved every healthy feed for minutes.)
    private static func fetchGuarded<T: Sendable>(
        host: String?, gate: RequestGate = .shared, _ op: @Sendable () async throws -> T
    ) async throws -> T {
        try await gate.withPermit(low: lowPriority) {
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
                // Nor is the PHONE being offline: a dead zone timed every
                // request out against the host, and after a 30 s gap the
                // breaker kept Overpass and weather.gov shut for two minutes
                // of good signal — speed limits and cameras went blank.
                if !(error is CancellationError),
                    (error as? URLError)?.code != .cancelled,
                    !NetworkPath.shared.saysOffline(error)
                {
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
        await firstNonNil(
            urls.map { maybeURL in
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
        await firstNonNil(
            requests.map { req in
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
/// A big download the system refused because the person has Low Data Mode
/// on. The refusal is right; saying nothing about it was not: the card fell
/// back to an estimate with no reason given.
final class LowDataRefusal: Sendable {
    static let shared = LowDataRefusal()
    private let last = OSAllocatedUnfairLock<Date?>(initialState: nil)

    static let notice =
        "Low Data Mode is on, so FLOWS did not download bus and train times. These are estimates."

    static func isOne(_ error: Error) -> Bool {
        (error as? URLError)?.networkUnavailableReason == .constrained
    }

    func note(_ now: Date = Date()) {
        last.withLock { $0 = now }
    }

    /// Whether a download was refused at or after `start` (a lookup's start:
    /// an older refusal belongs to an earlier plan).
    func happened(since start: Date) -> Bool {
        last.withLock { $0.map { $0 >= start } ?? false }
    }
}

/// Whether the device has a network path right now — a request that failed
/// while it had none says nothing about the host it asked.
final class NetworkPath: Sendable {
    static let shared = NetworkPath()
    private let monitor = NWPathMonitor()
    private struct State: Sendable {
        var up = true
        var lowData = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Posted when Low Data Mode comes or goes (AdaptiveTuning listens).
    static let lowDataChanged = Notification.Name("flows.network.lowDataChanged")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.set(path.status == .satisfied, lowData: path.isConstrained)
        }
        monitor.start(queue: DispatchQueue(label: "flows.network-path"))
    }

    private func set(_ satisfied: Bool, lowData constrained: Bool) {
        let changed = state.withLock { now -> Bool in
            now.up = satisfied
            let changed = now.lowData != constrained
            now.lowData = constrained
            return changed
        }
        if changed { NotificationCenter.default.post(name: Self.lowDataChanged, object: nil) }
    }

    /// The person put this connection in Low Data Mode: ask for less.
    var isLowData: Bool { state.withLock { $0.lowData } }

    /// The error is the device's, not the host's: no path now, or an
    /// error that only an unconnected device gives.
    func saysOffline(_ error: Error) -> Bool {
        let offlineCodes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost,
            .dataNotAllowed, .internationalRoamingOff,
        ]
        if let code = (error as? URLError)?.code, offlineCodes.contains(code) { return true }
        return state.withLock { !$0.up }
    }
}

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
            probing.insert(host)  // half-open: one probe carries the verdict
            return true
        }
        return false
    }

    func recordSuccess(_ host: String) {
        probing.remove(host)
        failures[host] = 0
        if openedAt[host] != nil {
            FlowsDiag.log(.info, "net", "breaker closed for \(host) — probe succeeded")
        }
        openedAt[host] = nil
    }

    func recordFailure(_ host: String) {
        probing.remove(host)
        let n = (failures[host] ?? 0) + 1
        failures[host] = n
        if n >= trip {
            if openedAt[host] == nil {
                FlowsDiag.log(
                    .warn, "net",
                    "breaker OPEN for \(host) after \(n) transport failures")
            }
            openedAt[host] = Date()  // (re)open, restart cooldown
        }
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
    /// Low-priority callers (ThrottledNet.lowPriority), served only when
    /// `waiters` is empty.
    private var lowWaiters: [CheckedContinuation<Void, Never>] = []
    private var burstDepth = 0
    private var burstExpiry = Date.distantPast
    private let baseCeiling: @Sendable () -> Int
    private let burstCeiling: @Sendable () -> Int
    private let burstSafetyWindow: TimeInterval

    /// Ceiling providers are injectable so gate behavior is testable with
    /// fixed numbers; the app's shared instance reads AdaptiveTuning live.
    init(
        baseCeiling: @escaping @Sendable () -> Int = { AdaptiveTuning.shared.maxInFlight },
        burstCeiling: @escaping @Sendable () -> Int = { AdaptiveTuning.shared.settings.planningMaxInFlight },
        burstSafetyWindow: TimeInterval = 90
    ) {
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
        while !lowWaiters.isEmpty, active < ceiling {
            active += 1
            lowWaiters.removeFirst().resume()
        }
    }

    /// Close one planning burst. The ceiling drops when the last one closes;
    /// in-flight requests above the lower ceiling drain naturally (release
    /// stops handing permits to waiters until `active` sinks back under).
    func endPlanningBurst() {
        burstDepth = max(0, burstDepth - 1)
    }

    /// Run `op` inside one planning burst: begin/end are paired by the SCOPE,
    /// not by call-site discipline, so a new burst site can't leak the
    /// elevated ceiling on an early return. `op` is @MainActor because every
    /// burst site in the app is (scoring, hydration, prefetch); the refcount
    /// and safety window still backstop the shared instance.
    nonisolated func withPlanningBurst<T: Sendable>(_ op: @MainActor () async -> T) async -> T {
        await beginPlanningBurst()
        let out = await Self.$insidePlanningBurst.withValue(true) { await op() }
        await endPlanningBurst()
        return out
    }

    /// True in the task that runs a planning burst, and in the tasks it
    /// starts. The safety window used to run from the burst's start alone,
    /// so a plan longer than the window (a long corridor on a slow link)
    /// fell back to the background pace partway through, with the driver
    /// still watching the spinner. A request made from inside the burst
    /// now moves the window on: it is proof the plan is still working. A
    /// leaked burst makes no such request, so it still runs out.
    @TaskLocal static var insidePlanningBurst = false

    private func acquire(low: Bool) async {
        if Self.insidePlanningBurst, burstDepth > 0 {
            burstExpiry = max(burstExpiry, Date().addingTimeInterval(burstSafetyWindow))
        }
        if active < ceiling, !low || waiters.isEmpty {
            active += 1
            return
        }
        // No slot: park until release() hands one over (the slot count stays
        // put across the handoff, so we don't double-count).
        await withCheckedContinuation { low ? lowWaiters.append($0) : waiters.append($0) }
    }

    private func release() {
        // Hand the permit to the next waiter ONLY while within the current
        // ceiling — after a burst ends (or the device heats up) the pool must
        // shrink to the lower ceiling before waiters run again.
        if !waiters.isEmpty, active <= ceiling {
            waiters.removeFirst().resume()  // transfer the permit directly
        } else if !lowWaiters.isEmpty, active <= ceiling {
            lowWaiters.removeFirst().resume()
        } else {
            active = max(0, active - 1)
        }
    }

    /// Run `op` while holding one permit. Reentrant-safe: the actor is only
    /// held across the cheap counter bookkeeping, not the awaited work.
    /// `throws` (not rethrows): cancellation below throws its own error.
    func withPermit<T: Sendable>(
        low: Bool = false,
        _ op: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire(low: low)
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
