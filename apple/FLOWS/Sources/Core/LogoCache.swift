// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// How one chain's logo was used since the last weekly check.
struct LogoUse: Codable, Equatable {
    /// Times its tile came on screen since the last check (counted at most
    /// once every ten minutes, so one long list is one sighting).
    var shown = 0
    var lastShown: Date
    /// The last time the driver added one of this chain's stops.
    var lastPicked: Date?
}

/// The weekly check (owner, 2026-11-10): a logo stays cached while it is
/// used. Pure, so it is tested.
enum LogoKeepRule {
    static let reviewEvery: TimeInterval = 7 * 86_400
    /// A chain the driver picked stays for four weeks after the pick.
    static let pickedKeeps: TimeInterval = 28 * 86_400
    /// Seen on at least this many occasions in the week.
    static let shownKeeps = 2
    static let countAgainAfter: TimeInterval = 600

    static func keeps(_ use: LogoUse, now: Date) -> Bool {
        if let picked = use.lastPicked, now.timeIntervalSince(picked) < pickedKeeps { return true }
        return use.shown >= shownKeeps
    }

    /// The uses that stay (their sightings start again from zero for the
    /// next week) and the domains whose cached logo goes.
    static func review(_ uses: [String: LogoUse], now: Date)
        -> (kept: [String: LogoUse], dropped: [String]) {
        var kept: [String: LogoUse] = [:]
        var dropped: [String] = []
        for (domain, use) in uses {
            if keeps(use, now: now) {
                var next = use
                next.shown = 0
                kept[domain] = next
            } else {
                dropped.append(domain)
            }
        }
        return (kept, dropped.sorted())
    }

    /// One more sighting, unless the last one was minutes ago.
    static func sighted(_ use: LogoUse?, now: Date) -> LogoUse {
        guard var use else { return LogoUse(shown: 1, lastShown: now) }
        if now.timeIntervalSince(use.lastShown) >= countAgainAfter {
            use.shown += 1
            use.lastShown = now
        }
        return use
    }

    static func picked(_ use: LogoUse?, now: Date) -> LogoUse {
        var use = use ?? LogoUse(shown: 1, lastShown: now)
        use.lastPicked = now
        return use
    }
}

/// Chain logos, kept so a stop list does not ask for the same picture on
/// every open.
///
/// The copy on disk is the HTTP cache's (`ThrottledNet.cache`), kept and
/// re-checked the way the logo host's own headers say, as a web browser
/// keeps an embedded picture; nothing is saved outside it (Brandfetch's
/// terms). This class adds the picture held in memory, so a tile does not
/// blink in, and the weekly check that lets go of logos no longer used.
///
/// Which chains a driver sees and picks is behaviour: the use record is
/// sealed (SecureBehaviorStore) and the erase button clears it.
@MainActor
final class LogoCache {
    static let shared = LogoCache()

    private struct Saved: Codable {
        var reviewedAt: Date
        var uses: [String: LogoUse]
    }

    private let url: URL
    private var uses: [String: LogoUse] = [:]
    private var reviewedAt: Date
    private var held: [String: Data] = [:]
    private var loading: [String: Task<Data?, Never>] = [:]
    /// A logo the host did not have is not asked for again this launch.
    private var missing: Set<String> = []
    private var saveQueued = false

    init(directory: URL? = nil, now: Date = Date()) {
        let dir = directory
            ?? (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_logo_use.json")
        if let saved = SecureBehaviorStore.load(Saved.self, from: url) {
            uses = saved.uses
            reviewedAt = saved.reviewedAt
        } else {
            reviewedAt = now
        }
    }

    /// The logo already in memory, for a tile's first frame.
    func ready(_ domain: String) -> Data? { held[domain] }

    /// The chain's logo: from memory, else from the HTTP cache or the host.
    /// Nil when there is none (the tile keeps its initials).
    func data(domain: String) async -> Data? {
        if let data = held[domain] { return data }
        if missing.contains(domain) { return nil }
        if let task = loading[domain] { return await task.value }
        guard let request = Self.request(domain: domain) else { return nil }
        let task = Task<Data?, Never> {
            // Low priority: a logo never holds a route's scoring back.
            await ThrottledNet.$lowPriority.withValue(true) {
                guard let (data, response) = try? await ThrottledNet.fetch(request),
                      (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty
                else { return nil }
                return data
            }
        }
        loading[domain] = task
        let data = await task.value
        loading[domain] = nil
        if let data {
            if held.count >= 64 { CacheEviction.dropHalf(&held) }
            held[domain] = data
        } else if !Task.isCancelled {
            missing.insert(domain)
        }
        return data
    }

    private static func request(domain: String) -> URLRequest? {
        guard let url = BrandMark.logoURL(domain: domain) else { return nil }
        var request = URLRequest(url: url)
        // The host serves only requests that say which site embeds them.
        if !BrandMark.logoReferer.isEmpty {
            request.setValue(BrandMark.logoReferer, forHTTPHeaderField: "Referer")
        }
        return request
    }

    /// A tile with this chain's logo came on screen.
    func noteShown(_ domain: String, now: Date = Date()) {
        reviewIfDue(now: now)
        let next = LogoKeepRule.sighted(uses[domain], now: now)
        guard next != uses[domain] else { return }
        uses[domain] = next
        save()
    }

    /// The driver added one of this chain's stops.
    func notePicked(_ domain: String, now: Date = Date()) {
        uses[domain] = LogoKeepRule.picked(uses[domain], now: now)
        save()
    }

    /// Once a week: logos not used since the last check leave the cache.
    func reviewIfDue(now: Date = Date()) {
        // A clock set back must not put the check off for good.
        guard now.timeIntervalSince(reviewedAt) >= LogoKeepRule.reviewEvery
                || now < reviewedAt else { return }
        let answer = LogoKeepRule.review(uses, now: now)
        uses = answer.kept
        reviewedAt = now
        for domain in answer.dropped {
            held[domain] = nil
            if let request = Self.request(domain: domain) {
                ThrottledNet.cache.removeCachedResponse(for: request)
            }
        }
        missing = []
        save()
    }

    /// What the weekly check would see (tests).
    var useRecord: [String: LogoUse] { uses }

    /// One write for a burst of sightings (a list opens twenty tiles).
    private func save() {
        guard !saveQueued else { return }
        saveQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.saveQueued = false
            let snapshot = Saved(reviewedAt: self.reviewedAt, uses: self.uses)
            let url = self.url
            SecureBehaviorStore.persistQueue.async { SecureBehaviorStore.save(snapshot, to: url) }
        }
    }

    /// Forget which logos were seen and picked. (The pictures themselves go
    /// with the network cache, which the erase button clears as well.)
    func erase() {
        uses = [:]
        held = [:]
        missing = []
        reviewedAt = Date()
        let url = self.url
        SecureBehaviorStore.persistQueue.sync { SecureBehaviorStore.shred(url) }
    }
}
