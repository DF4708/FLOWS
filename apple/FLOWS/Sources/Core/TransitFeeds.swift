// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Keeps a real published timetable on the device: fetches the operator's own
/// schedule feed, keeps the part of it we read, and builds the day's shard.
///
/// The frugality here is deliberate. A GTFS archive is mostly the drawn shape
/// of each route, which the router never looks at, so this fetches the
/// archive's index and then only the files it parses — about 1.5 MB of
/// Amtrak's 19.5 MB. The extracted files are kept, so tomorrow's timetable is
/// built from disk with no network at all, and the feed itself is refetched
/// only about once a week.
actor TransitFeeds {
    static let shared = TransitFeeds()

    /// Where feeds and shards live. The app uses its Caches folder; a test
    /// passes a temporary one, so it never writes into a real cache.
    private let cacheRoot: URL

    init(cacheRoot: URL? = nil) {
        self.cacheRoot = cacheRoot ?? {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return caches.appendingPathComponent("flows-transit", isDirectory: true)
        }()
    }

    /// Where a network's published schedule comes from.
    struct Source: Sendable, Equatable {
        /// Short, file-safe, unique: it names the cache folder and the shard.
        let name: String
        let url: URL
        /// The operator as a rider knows it — "Amtrak", "LA Metro".
        let operatorName: String
        /// Where the service runs. Nil for a national network asked about
        /// every trip; a city feed is fetched only for trips that END inside
        /// its box, because that is the last leg it can carry.
        var area: Area?

        /// Shown wherever its times are, because they are the operator's.
        var credit: String { TransitFeeds.credit(for: [operatorName]) }
    }

    /// A latitude/longitude box, the shape feed catalogs publish.
    struct Area: Sendable, Equatable {
        let minLatitude: Double
        let maxLatitude: Double
        let minLongitude: Double
        let maxLongitude: Double

        func contains(latitude: Double, longitude: Double) -> Bool {
            (minLatitude...maxLatitude).contains(latitude)
                && (minLongitude...maxLongitude).contains(longitude)
        }
    }

    static let amtrak = Source(
        name: "amtrak",
        url: URL(string: "https://content.amtrak.com/content/gtfs/GTFS.zip")!,
        operatorName: "Amtrak",
        area: nil
    )

    /// City and regional feeds FLOWS may fetch to carry the last leg of a
    /// train trip by local bus or rail.
    ///
    /// EMPTY ON PURPOSE. Which operators' schedules FLOWS downloads and shows
    /// is the owner's decision, and it is still open: of the 1,336 US and
    /// Canadian feeds in the MobilityData catalog, only 290 state a licence.
    /// Everything else — fetching, merging with Amtrak, the walk between a
    /// station and the bus stop outside it, each operator's own clock, the
    /// credit line — is built and tested, so switching city buses on is
    /// adding entries here, not writing code.
    static let cityFeeds: [Source] = []

    /// The feeds to ask for a trip ending at a point: Amtrak, then any
    /// allowed city feed whose service area holds the destination.
    static func sources(
        endingAt latitude: Double, _ longitude: Double, from cities: [Source] = cityFeeds
    ) -> [Source] {
        [amtrak] + cities.filter {
            $0.area?.contains(latitude: latitude, longitude: longitude) ?? false
        }
    }

    /// "Schedule from Amtrak"; "Schedules from Amtrak and LA Metro"; a
    /// comma list before "and" for three or more. Every operator whose times
    /// are on screen is named, because they are theirs.
    static func credit(for operators: [String]) -> String {
        switch operators.count {
        case 0: return ""
        case 1: return "Schedule from \(operators[0])"
        default:
            let head = operators.dropLast().joined(separator: ", ")
            return "Schedules from \(head) and \(operators[operators.count - 1])"
        }
    }

    /// The cache name for a set of feeds on a day: "amtrak-20260929" for
    /// Amtrak alone — exactly the name used before feeds could merge, so no
    /// timetable already on a device is rebuilt — and "amtrak+lametro-…"
    /// for a merge.
    static func shardName(_ sources: [Source], date: Int) -> String {
        sources.map(\.name).joined(separator: "+") + "-\(date)"
    }

    /// A built timetable, ready to be asked.
    struct Ready: Sendable, Equatable {
        let prefix: String
        let stamp: TransitShard.Stamp
        let credit: String
    }

    enum Failure: Error, Equatable {
        /// No timetable on disk and the caller said not to use the network —
        /// which is what happens mid-drive, on purpose.
        case notCachedAndOffline
        case feedUnavailable(String)
        case feedUnusable(String)
    }

    /// Refetch the archive no more often than this. Operators republish weekly;
    /// the calendar inside covers a year, so a week-old copy still has today.
    private let refetchAfter: TimeInterval = 6 * 24 * 3600
    /// A schedule archive far larger than this is not one we asked for.
    private let maxArchiveBytes = 300 << 20

    private var building: [String: Task<Ready, Error>] = [:]
    /// Secondary feeds that would not load, by name, with the service day they
    /// failed on. Kept for the day so a lapsed city feed costs one rebuild,
    /// not one per question.
    private var unusable: [String: Int] = [:]

    // MARK: asking

    /// The timetable for `day`, building or fetching only as much as it must.
    ///
    /// `allowNetwork` is false while navigating: a driver's connection belongs
    /// to the road ahead, not to next week's train times.
    func ready(
        _ source: Source = TransitFeeds.amtrak, on day: Date = Date(), allowNetwork: Bool = true
    ) async throws -> Ready {
        try await ready([source], on: day, allowNetwork: allowNetwork)
    }

    /// One timetable holding every feed in `sources`, so a trip can ride the
    /// first operator's train and then a later one's bus. The FIRST source is
    /// the one that must work — its times, its clock, its failure is the
    /// answer's failure. The rest are best effort: a city feed that will not
    /// download or parse is left out, never allowed to cost the train times.
    func ready(
        _ sources: [Source], on day: Date = Date(), allowNetwork: Bool = true
    ) async throws -> Ready {
        guard !sources.isEmpty else { throw Failure.feedUnusable("no feeds asked for") }
        let key = sources.map(\.name).joined(separator: "+")
        // Two screens asking at once must not fetch twice.
        if let running = building[key] {
            return try await running.value
        }
        let task = Task<Ready, Error> { [self] in
            try await make(sources, day: day, allowNetwork: allowNetwork)
        }
        building[key] = task
        defer { building[key] = nil }
        return try await task.value
    }

    /// Have `source`'s files on disk, fetching or refreshing only if allowed.
    /// Returns the folder, or throws when there is nothing usable.
    private func feedOnDisk(_ source: Source, allowNetwork: Bool) async throws -> URL {
        let feed = feedDirectory(source)
        var haveFeed = FileManager.default.fileExists(atPath: feed.appendingPathComponent("stops.txt").path)
        if !haveFeed || (allowNetwork && isStale(feed)) {
            guard allowNetwork else { throw Failure.notCachedAndOffline }
            do {
                try await fetch(source, into: feed)
                haveFeed = true
            } catch {
                // A refresh that fails is survivable; a first fetch is not.
                guard haveFeed else { throw Failure.feedUnavailable(String(describing: error)) }
            }
        }
        guard haveFeed else { throw Failure.notCachedAndOffline }
        return feed
    }

    private func make(_ sources: [Source], day: Date, allowNetwork: Bool) async throws -> Ready {
        let primary = sources[0]
        let primaryFeed = try await feedOnDisk(primary, allowNetwork: allowNetwork)

        // The service day is the OPERATOR's day, not the device's: at 9pm in
        // Honolulu, Amtrak is already running tomorrow's timetable. Every
        // merged feed is read for that same day, in the primary's reckoning.
        let primaryZone = TransitShard.agencyZone(feedDirectory: primaryFeed.path)
        let zone = primaryZone.isEmpty ? TimeZone.current.identifier : primaryZone
        let date = Self.serviceDate(day, zone: zone)

        // The rest: on disk, and with a zone we can shift from, or left out.
        var parts: [(source: Source, feed: URL, shift: Int)] = [(primary, primaryFeed, 0)]
        for source in sources.dropFirst() where unusable[source.name] != date {
            guard let feed = try? await feedOnDisk(source, allowNetwork: allowNetwork) else { continue }
            let own = TransitShard.agencyZone(feedDirectory: feed.path)
            guard !own.isEmpty,
                  let shift = TransitClock.shift(from: own, into: zone, serviceDate: date)
            else { continue } // a feed with no clock cannot be placed in ours
            parts.append((source, feed, shift))
        }

        let used = parts.map(\.source)
        let name = Self.shardName(used, date: date)
        let prefix = root().appendingPathComponent(name)
        if let stamp = TransitShard.stamp(prefix: prefix.path), stamp.serviceDate == date {
            return Ready(prefix: prefix.path, stamp: stamp,
                         credit: Self.credit(for: used.map(\.operatorName)))
        }
        do {
            if parts.count == 1 {
                // Amtrak alone: exactly the single-feed build it always was.
                let stamp = try TransitShard.build(
                    feedDirectory: primaryFeed.path, prefix: prefix.path, serviceDate: date
                )
                sweepOldShards(before: date)
                return Ready(prefix: prefix.path, stamp: stamp, credit: primary.credit)
            }
            let merged = try TransitShard.build(
                feeds: parts.map { .init(directory: $0.feed.path, shiftSeconds: $0.shift) },
                prefix: prefix.path, serviceDate: date
            )
            if !merged.skipped.isEmpty {
                // A city feed that would not load today (its calendar has
                // lapsed, its files are malformed). This shard is NAMED as if
                // it held that feed, so a later cache hit would credit an
                // operator whose times are not in it. Remember the feed as
                // unusable for the day, drop this build, and build once more
                // without it — name, contents and credit then always agree.
                for index in merged.skipped.keys where index > 0 && index < used.count {
                    unusable[used[index].name] = date
                }
                try? FileManager.default.removeItem(atPath: prefix.path + ".ftt")
                try? FileManager.default.removeItem(atPath: prefix.path + ".fts")
                return try await make(sources, day: day, allowNetwork: false)
            }
            sweepOldShards(before: date)
            return Ready(prefix: prefix.path, stamp: merged.stamp,
                         credit: Self.credit(for: used.map(\.operatorName)))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.feedUnusable(String(describing: error))
        }
    }

    /// YYYYMMDD for a moment, as the operator's calendar counts days.
    static func serviceDate(_ moment: Date, zone: String) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        let p = calendar.dateComponents([.year, .month, .day], from: moment)
        return (p.year ?? 1970) * 10000 + (p.month ?? 1) * 100 + (p.day ?? 1)
    }

    // MARK: fetching only the part we read

    private func fetch(_ source: Source, into feed: URL) async throws {
        // 1. The archive's last kilobyte, which holds the index of everything
        //    inside it. Asking for a range also tells us the full length.
        let (tail, total, servedWhole) = try await tailOfArchive(source.url)
        guard total > 0, total <= maxArchiveBytes else {
            throw Failure.feedUnavailable("the schedule archive is an unexpected size")
        }

        let whole: Data? = servedWhole ? tail : nil
        let directoryRange = try GTFSZip.directoryRange(tail: tail, totalSize: total)

        // 2. The index itself.
        let directory: Data
        if let whole {
            directory = whole.subdata(in: directoryRange.clamped(to: 0..<whole.count))
        } else {
            directory = try await bytes(source.url, directoryRange)
        }
        let entries = try GTFSZip.entries(directory: directory)

        // 3. Each file we actually parse — and nothing else.
        try FileManager.default.createDirectory(at: feed, withIntermediateDirectories: true)
        for entry in entries {
            let body = try await member(entry, of: source, whole: whole, total: total)
            try body.write(to: feed.appendingPathComponent(entry.name), options: .atomic)
        }
        // Files we kept from an older copy that this archive no longer has
        // would otherwise linger and be parsed as current.
        let kept = Set(entries.map(\.name))
        for name in GTFSZip.wanted.subtracting(kept) {
            try? FileManager.default.removeItem(at: feed.appendingPathComponent(name))
        }
        try? Data().write(to: stampFile(source), options: .atomic)
    }

    /// One file out of the archive. Asks for the range a real archive needs,
    /// and only widens to the format's legal maximum if that fell short.
    private func member(
        _ entry: GTFSZip.Entry, of source: Source, whole: Data?, total: Int
    ) async throws -> Data {
        for range in [entry.likelyRange, entry.safeRange] {
            let want = range.clamped(to: 0..<total)
            let chunk: Data
            if let whole {
                chunk = whole.subdata(in: want.clamped(to: 0..<whole.count))
            } else {
                chunk = try await bytes(source.url, want)
            }
            if let body = try GTFSZip.contents(of: entry, localHeaderChunk: chunk) {
                return body
            }
            // The whole archive is already in hand; a wider range cannot help.
            if whole != nil { break }
        }
        throw Failure.feedUnusable("\(entry.name) did not unpack")
    }

    /// The end of the archive, plus its full length. Hosts that ignore `Range`
    /// answer 200 with the whole file; that is fine and the third value says so.
    private func tailOfArchive(_ url: URL) async throws -> (Data, Int, Bool) {
        var request = URLRequest(url: url)
        request.setValue("bytes=-1024", forHTTPHeaderField: "Range")
        let (data, response) = try await ThrottledNet.fetch(request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.feedUnavailable("no answer from the schedule host")
        }
        guard (200...299).contains(http.statusCode) else {
            throw Failure.feedUnavailable("the schedule host answered \(http.statusCode)")
        }
        if http.statusCode == 206,
           let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let total = Int(contentRange.split(separator: "/").last ?? "") {
            return (data, total, false)
        }
        return (data, data.count, true)
    }

    private func bytes(_ url: URL, _ range: Range<Int>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                         forHTTPHeaderField: "Range")
        let (data, response) = try await ThrottledNet.fetch(request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw Failure.feedUnavailable("the schedule host refused a range")
        }
        return data
    }

    // MARK: where things live

    private func root() -> URL { cacheRoot }

    private func feedDirectory(_ source: Source) -> URL {
        root().appendingPathComponent(source.name, isDirectory: true)
    }

    private func stampFile(_ source: Source) -> URL {
        feedDirectory(source).appendingPathComponent(".fetched")
    }

    private func isStale(_ feed: URL) -> Bool {
        let marker = feed.appendingPathComponent(".fetched")
        guard let modified = try? FileManager.default
            .attributesOfItem(atPath: marker.path)[.modificationDate] as? Date
        else { return true }
        return Date().timeIntervalSince(modified) > refetchAfter
    }

    /// Yesterday's timetable is dead weight the moment today's exists — for
    /// every combination of feeds, not just the one being built, or a merge
    /// asked for once (Amtrak plus a city visited last month) would sit in
    /// the cache forever.
    private func sweepOldShards(before date: Int) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root(), includingPropertiesForKeys: nil
        )) ?? []
        for file in contents where Self.isShard(file.lastPathComponent, before: date) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Whether a cache file is a shard ("amtrak+lametro-20260928.ftt") for a
    /// service day earlier than `date`. Anything not named like a shard —
    /// the feed folders, stray files — is never touched.
    static func isShard(_ fileName: String, before date: Int) -> Bool {
        let url = URL(fileURLWithPath: fileName)
        guard url.pathExtension == "ftt" || url.pathExtension == "fts" else { return false }
        let base = url.deletingPathExtension().lastPathComponent
        guard let dash = base.lastIndex(of: "-"),
              let day = Int(base[base.index(after: dash)...]),
              (19000101...21001231).contains(day)
        else { return false }
        return day < date
    }
}
