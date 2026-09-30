// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

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
/// Members are not unpacked here: a deflated one is kept as the archive stores
/// it and unpacked as the timetable builder reads it, so a big city's schedule
/// never sits whole in a phone's memory. Verified on Chicago's own archive:
/// every member, kept this way, builds a timetable byte-identical to the one
/// built from `unzip`'s output.
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
        /// The CRC-32 of the unpacked file, as the directory records it —
        /// checked when the timetable builder unpacks a packed member.
        var crc32: UInt32 = 0

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
        /// 448 KB down a phone's connection, so ask for a realistic margin; when
        /// ``dataRange(of:localHeader:)`` shows the data runs past what came
        /// down, the caller asks again with ``safeRange``.
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
                  let crc = u32(directory, i + 16),
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
                                 uncompressedSize: uncompressed, headerOffset: offset,
                                 crc32: UInt32(crc)))
            }
            i += 46 + nameLen + extraLen + commentLen
        }
        guard !out.isEmpty else { throw Failure.unsupported("no schedule files in this archive") }
        return out
    }

    // MARK: keeping one file

    /// A deflated member is kept exactly as the archive stores it, behind a
    /// 16-byte header, and unpacked only as the timetable builder reads it
    /// (`flows_core::transit::inflate`). Chicago's `stop_times.txt` is 367 MB
    /// unpacked and 54 MB as stored: unpacking it here held all of it in a
    /// phone's memory at once, and then on its disk.
    static let packedSuffix = ".fz"
    static let packedMagic = Data("FZ01".utf8)

    /// The file a member is kept in: the publisher's name for a stored one,
    /// the packed name (`stop_times.txt.fz`) for a deflated one.
    static func fileName(for entry: Entry) throws -> String {
        switch entry.method {
        case 0: return entry.name
        case 8: return entry.name + packedSuffix
        default: throw Failure.unsupported("\(entry.name) uses an unknown compression")
        }
    }

    /// What goes before a packed member's data: the magic, the CRC-32 and the
    /// unpacked length, little-endian — the builder checks both at the end.
    /// Empty for a stored member, which is kept as its own bytes.
    static func packedHeader(for entry: Entry) -> Data {
        guard entry.method == 8 else { return Data() }
        var header = packedMagic
        withUnsafeBytes(of: entry.crc32.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(max(0, entry.uncompressedSize)).littleEndian) {
            header.append(contentsOf: $0)
        }
        return header
    }

    /// Where a member's data sits, counted from the start of its LOCAL header,
    /// given at least that header's first 30 bytes. Nil when fewer arrived.
    static func dataRange(of entry: Entry, localHeader: Data) throws -> Range<Int>? {
        guard localHeader.count >= 30 else { return nil }
        guard u32(localHeader, 0) == 0x0403_4B50 else { throw Failure.notAZip }
        guard let nameLen = u16(localHeader, 26), let extraLen = u16(localHeader, 28) else {
            return nil
        }
        let start = 30 + nameLen + extraLen
        return start..<(start + entry.compressedSize)
    }

    /// A kept file's unpacked size: its own length when stored, what a packed
    /// member's header records when packed, 0 when absent. With both forms
    /// present the larger counts — a budget should guess high.
    static func unpackedSize(of name: String, in folder: URL) -> Int {
        let plain = folder.appendingPathComponent(name).path
        let plainSize = ((try? FileManager.default.attributesOfItem(atPath: plain))?[.size]
            as? NSNumber)?.intValue ?? 0
        var packedSize = 0
        let packed = folder.appendingPathComponent(name + packedSuffix)
        if let handle = try? FileHandle(forReadingFrom: packed) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 16), head.count == 16,
               head.prefix(4) == packedMagic {
                var length: UInt64 = 0
                for (i, byte) in head.suffix(8).enumerated() {
                    length |= UInt64(byte) << (8 * UInt64(i))
                }
                packedSize = Int(min(length, UInt64(Int.max)))
            }
        }
        return max(plainSize, packedSize)
    }

    /// Whether a feed folder holds a file, in either form.
    static func hasMember(_ name: String, in folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent(name).path)
            || fm.fileExists(atPath: folder.appendingPathComponent(name + packedSuffix).path)
    }
}
