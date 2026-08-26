// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// The FLOWS diagnostic journal: a bounded in-memory ring plus a size-capped
/// ROTATING file pair, so a field report ("scoring hung on I-80 yesterday")
/// comes with the app's own account of what its sources were doing — which
/// breaker tripped, which provider fell back, which degraded mode engaged —
/// without ever growing unbounded or needing a debugger attached.
///
/// Discipline: entries are EVENTS, not traffic — breaker trips, fallback
/// activations, degraded modes, exhausted retries. Routine success is
/// silent, so the ~256 KB the two files hold spans days of driving, and the
/// throttled variant keeps a repeating condition (every corridor cell of a
/// Canada trip using the same fallback) to one line per interval.
///
/// Plain text, one line per event, newest last:  `2026-08-26T12:00:00Z WARN
/// [net] breaker OPEN epqs.nationalmap.gov after 5 failures`. Owned code,
/// no dependencies (os.Logger feeds Console live; this journal is the
/// persistent, exportable complement).
actor FlowsDiag {
    static let shared = FlowsDiag()

    enum Level: String, Sendable {
        case info = "INFO"
        case warn = "WARN"
        case fail = "FAIL"
    }

    private let ringCap: Int
    private let fileCap: Int
    private let fileURL: URL
    private let rolledURL: URL
    private var ring: [String] = []
    private var fileSize: Int
    private var lastEmit: [String: Date] = [:]

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `directory` is injectable for tests; the app instance journals to
    /// Caches (regenerable data — a cleared journal is not a loss).
    init(directory: URL? = nil, ringCap: Int = 400, fileCap: Int = 128 * 1024) {
        self.ringCap = ringCap
        self.fileCap = fileCap
        let dir = directory
            ?? (try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("flows_diag.log")
        rolledURL = dir.appendingPathComponent("flows_diag.1.log")
        fileSize = (try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? Int).flatMap { $0 } ?? 0
    }

    /// Fire-and-forget from anywhere — actors, tasks, the main thread.
    nonisolated static func log(_ level: Level = .info, _ area: String, _ message: String) {
        Task { await FlowsDiag.shared.append(level, area, message) }
    }

    /// Once-per-interval variant for conditions that REPEAT (a provider
    /// fallback firing per corridor cell must not fill the journal).
    nonisolated static func logThrottled(
        key: String, interval: TimeInterval = 600,
        _ level: Level = .warn, _ area: String, _ message: String
    ) {
        Task { await FlowsDiag.shared.appendThrottled(
            key: key, interval: interval, level, area, message) }
    }

    func append(_ level: Level, _ area: String, _ message: String) {
        let line = "\(Self.stamp.string(from: Date())) \(level.rawValue) [\(area)] \(message)"
        ring.append(line)
        if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }
        write(line + "\n")
    }

    func appendThrottled(
        key: String, interval: TimeInterval,
        _ level: Level, _ area: String, _ message: String
    ) {
        let now = Date()
        if let last = lastEmit[key], now.timeIntervalSince(last) < interval { return }
        lastEmit[key] = now
        if lastEmit.count > 200 { CacheEviction.dropOldestHalf(&lastEmit) { $0 } }
        append(level, area, message)
    }

    /// Newest-last recent lines (the Settings health view + bug reports).
    /// A cold launch reloads the tail of the on-disk journal so the view is
    /// never empty just because the app restarted.
    func recent(_ n: Int = 60) -> [String] {
        if ring.isEmpty,
           let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            ring = text.split(separator: "\n").suffix(ringCap).map(String.init)
        }
        return Array(ring.suffix(n))
    }

    /// Both journal files, newest first (share/export).
    nonisolated var fileURLs: [URL] { [fileURL, rolledURL] }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
            fileSize = data.count
        } else if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            fileSize += data.count
        }
        // Rotate: current → .1 (replacing the previous rollover). Two files
        // bound the journal at ~2× fileCap forever.
        if fileSize > fileCap {
            try? FileManager.default.removeItem(at: rolledURL)
            try? FileManager.default.moveItem(at: fileURL, to: rolledURL)
            fileSize = 0
        }
    }
}
