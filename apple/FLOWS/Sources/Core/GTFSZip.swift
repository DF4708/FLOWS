// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Compression
import Foundation

/// Just enough ZIP to take a schedule feed apart — and, more usefully, to take
/// only the PART of one we need.
///
/// A GTFS archive is mostly `shapes.txt`, the drawn line of each route: 17.9 MB
/// of Amtrak's 19.5 MB, and nothing the router reads. The central directory
/// that says where every file sits is 455 bytes at the end of the archive, and
/// the feed's host serves byte ranges. So the device reads the tail, picks the
/// handful of files it actually parses, and fetches about 1.5 MB instead of
/// 19.5 — the difference between a refresh someone notices on their data plan
/// and one they never do.
///
/// Verified against the published Amtrak archive and a re-compressed copy of
/// it: every member comes out byte-identical to `unzip`, stored or deflated.
enum GTFSZip {
    /// The files the timetable builder reads. Everything else in the archive
    /// is downloaded by nobody.
    static let wanted: Set<String> = [
        "agency.txt", "calendar.txt", "calendar_dates.txt", "feed_info.txt",
        "frequencies.txt", "routes.txt", "stops.txt", "stop_times.txt",
        "transfers.txt", "trips.txt",
    ]

    /// One file inside the archive, as the central directory describes it.
    struct Entry: Equatable {
        let name: String
        /// 0 = stored, 8 = deflate.
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        /// Where the file's LOCAL header starts — not its data, which sits past
        /// a name and an extra field whose lengths only that header knows.
        let headerOffset: Int

        /// A byte range certain to contain the whole member: its local header,
        /// whatever padding that header carries, and the data. 64 KiB is the
        /// most a local extra field may hold, so this cannot fall short.
        var safeRange: Range<Int> {
            headerOffset..<(headerOffset + 30 + name.utf8.count + 65_536 + compressedSize)
        }

        /// The range worth ASKING for first. A local header's extra field may
        /// hold 64 KiB, but real archives put almost nothing there — Amtrak's
        /// own is empty, and a `zip -9` archive uses 28 bytes for a timestamp.
        /// Reserving the legal maximum for every member would pull a needless
        /// 448 KB down a phone's connection, so ask for a realistic margin and
        /// let ``contents(of:localHeaderChunk:)`` say when it was not enough —
        /// it returns nil rather than a half file, and the caller asks again.
        var likelyRange: Range<Int> {
            headerOffset..<(headerOffset + 30 + name.utf8.count + 256 + compressedSize)
        }
    }

    enum Failure: Error, Equatable {
        case notAZip
        case truncated
        case unsupported(String)
    }

    // MARK: reading the directory

    private static func u16(_ d: Data, _ i: Int) -> Int? {
        guard i >= 0, i + 2 <= d.count else { return nil }
        return Int(d[d.startIndex + i]) | Int(d[d.startIndex + i + 1]) << 8
    }

    private static func u32(_ d: Data, _ i: Int) -> Int? {
        guard i >= 0, i + 4 <= d.count else { return nil }
        let b = d.startIndex + i
        return Int(d[b]) | Int(d[b + 1]) << 8 | Int(d[b + 2]) << 16 | Int(d[b + 3]) << 24
    }

    /// Where the central directory lives, found in the archive's last bytes.
    /// `tail` is the end of the file and `totalSize` its full length, so the
    /// answer is an absolute range into the archive.
    static func directoryRange(tail: Data, totalSize: Int) throws -> Range<Int> {
        guard totalSize - tail.count >= 0 else { throw Failure.truncated }
        // The end-of-central-directory record is last, but a trailing comment
        // may follow it, so scan backwards for its signature.
        var i = tail.count - 22
        while i >= 0 {
            if u32(tail, i) == 0x0605_4B50 {
                guard let size = u32(tail, i + 12), let offset = u32(tail, i + 16),
                      size > 0, offset >= 0, offset + size <= totalSize
                else { throw Failure.notAZip }
                // 0xFFFF_FFFF means the real values live in a ZIP64 record.
                guard offset != 0xFFFF_FFFF, size != 0xFFFF_FFFF else {
                    throw Failure.unsupported("this feed is a ZIP64 archive")
                }
                return offset..<(offset + size)
            }
            i -= 1
        }
        throw Failure.notAZip
    }

    /// The entries the central directory lists, keeping only the files we read.
    static func entries(directory: Data) throws -> [Entry] {
        var out: [Entry] = []
        var i = 0
        while i + 46 <= directory.count {
            guard u32(directory, i) == 0x0201_4B50 else { break }
            guard let method = u16(directory, i + 10),
                  let compressed = u32(directory, i + 20),
                  let uncompressed = u32(directory, i + 24),
                  let nameLen = u16(directory, i + 28),
                  let extraLen = u16(directory, i + 30),
                  let commentLen = u16(directory, i + 32),
                  let offset = u32(directory, i + 42)
            else { throw Failure.truncated }
            let nameStart = directory.startIndex + i + 46
            guard nameStart + nameLen <= directory.endIndex else { throw Failure.truncated }
            let name = String(decoding: directory[nameStart..<(nameStart + nameLen)], as: UTF8.self)
            // Some publishers nest their files inside a folder.
            let leaf = name.split(separator: "/").last.map(String.init) ?? name
            if wanted.contains(leaf) {
                out.append(Entry(name: leaf, method: method, compressedSize: compressed,
                                 uncompressedSize: uncompressed, headerOffset: offset))
            }
            i += 46 + nameLen + extraLen + commentLen
        }
        guard !out.isEmpty else { throw Failure.unsupported("no schedule files in this archive") }
        return out
    }

    // MARK: reading one file

    /// The bytes of one member, given a buffer that starts at its local header
    /// (what ``Entry/safeRange`` asks for). Returns nil when the buffer stops
    /// short, so the caller can fetch the exact range rather than guess.
    static func contents(of entry: Entry, localHeaderChunk chunk: Data) throws -> Data? {
        guard u32(chunk, 0) == 0x0403_4B50 else { throw Failure.notAZip }
        guard let nameLen = u16(chunk, 26), let extraLen = u16(chunk, 28) else { return nil }
        let start = 30 + nameLen + extraLen
        let end = start + entry.compressedSize
        guard end <= chunk.count else { return nil }
        let body = chunk.subdata(in: (chunk.startIndex + start)..<(chunk.startIndex + end))
        switch entry.method {
        case 0:
            return body
        case 8:
            return inflate(body, expected: entry.uncompressedSize)
        default:
            throw Failure.unsupported("\(entry.name) uses an unknown compression")
        }
    }

    /// Raw DEFLATE — which is what `COMPRESSION_ZLIB` decodes here, the same
    /// call `InternationalWeather.gunzip` makes once it has stripped a gzip
    /// header.
    static func inflate(_ body: Data, expected: Int) -> Data? {
        guard !body.isEmpty else { return nil }
        let capacity = max(expected, body.count * 4, 64_000)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            body.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, body.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.removeSubrange(written..<out.count)
        return out
    }
}
