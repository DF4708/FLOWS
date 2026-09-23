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

    /// Where a network's published schedule comes from.
    struct Source: Sendable, Equatable {
        let name: String
        let url: URL
        /// Shown wherever its times are, because they are the operator's.
        let credit: String
    }

    static let amtrak = Source(
        name: "amtrak",
        url: URL(string: "https://content.amtrak.com/content/gtfs/GTFS.zip")!,
        credit: "Schedule from Amtrak"
    )

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

    // MARK: asking

    /// The timetable for `day`, building or fetching only as much as it must.
    ///
    /// `allowNetwork` is false while navigating: a driver's connection belongs
    /// to the road ahead, not to next week's train times.
    func ready(
        _ source: Source = TransitFeeds.amtrak, on day: Date = Date(), allowNetwork: Bool = true
    ) async throws -> Ready {
        // Two screens asking at once must not fetch twice.
        if let running = building[source.name] {
            return try await running.value
        }
        let task = Task<Ready, Error> { [self] in
            try await make(source, day: day, allowNetwork: allowNetwork)
        }
        building[source.name] = task
        defer { building[source.name] = nil }
        return try await task.value
    }

    private func make(_ source: Source, day: Date, allowNetwork: Bool) async throws -> Ready {
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

        // The service day is the OPERATOR's day, not the device's: at 9pm in
        // Honolulu, Amtrak is already running tomorrow's timetable.
        let zone = TransitShard.agencyZone(feedDirectory: feed.path)
        let date = Self.serviceDate(day, zone: zone.isEmpty ? TimeZone.current.identifier : zone)

        let prefix = shardPrefix(source, date: date)
        if let stamp = TransitShard.stamp(prefix: prefix.path), stamp.serviceDate == date {
            return Ready(prefix: prefix.path, stamp: stamp, credit: source.credit)
        }
        do {
            let stamp = try TransitShard.build(
                feedDirectory: feed.path, prefix: prefix.path, serviceDate: date
            )
            sweepOldShards(source, keeping: date)
            return Ready(prefix: prefix.path, stamp: stamp, credit: source.credit)
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

    private func root() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("flows-transit", isDirectory: true)
    }

    private func feedDirectory(_ source: Source) -> URL {
        root().appendingPathComponent(source.name, isDirectory: true)
    }

    private func stampFile(_ source: Source) -> URL {
        feedDirectory(source).appendingPathComponent(".fetched")
    }

    private func shardPrefix(_ source: Source, date: Int) -> URL {
        root().appendingPathComponent("\(source.name)-\(date)")
    }

    private func isStale(_ feed: URL) -> Bool {
        let marker = feed.appendingPathComponent(".fetched")
        guard let modified = try? FileManager.default
            .attributesOfItem(atPath: marker.path)[.modificationDate] as? Date
        else { return true }
        return Date().timeIntervalSince(modified) > refetchAfter
    }

    /// Yesterday's timetable is dead weight the moment today's exists.
    private func sweepOldShards(_ source: Source, keeping date: Int) {
        let keep = "\(source.name)-\(date)"
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root(), includingPropertiesForKeys: nil
        )) ?? []
        for file in contents {
            let base = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension
            guard ext == "ftt" || ext == "fts" else { continue }
            guard base.hasPrefix("\(source.name)-"), base != keep else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
