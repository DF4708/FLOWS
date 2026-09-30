// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Compression
import Foundation
import XCTest

/// The partial-archive reader that lets a phone fetch 1.5 MB of a 19.5 MB
/// schedule feed, and keep a big city's files packed as the archive stores
/// them. Archives are built here byte by byte, so the test pins the actual
/// format rather than whatever a zip tool happened to emit.
final class GTFSZipTests: XCTestCase {
    // MARK: building an archive by hand

    private func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func u32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// Raw DEFLATE, which is what `COMPRESSION_ZLIB` writes and ZIP stores.
    private func deflate(_ data: Data) -> Data {
        let capacity = max(data.count * 2, 1024)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        out.removeSubrange(written..<out.count)
        return out
    }

    private func inflate(_ data: Data, expected: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = max(expected, 64)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.removeSubrange(written..<out.count)
        return out
    }

    /// CRC-32 as ZIP records it — the archives here carry real ones, so the
    /// timetable builder's check is exercised.
    private func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data {
            c ^= UInt32(byte)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return ~c
    }

    private struct Member {
        let name: String
        let body: Data
        let method: Int
        /// Bytes of padding in the LOCAL header's extra field — real archives
        /// carry timestamps and alignment here, and the data sits past it.
        let extra: Int
    }

    private func archive(_ members: [Member], comment: String = "") -> Data {
        var file = Data()
        var offsets: [Int] = []
        var stored: [Data] = []
        for m in members {
            offsets.append(file.count)
            let payload = m.method == 8 ? deflate(m.body) : m.body
            stored.append(payload)
            var local: [UInt8] = []
            local += u32(0x0403_4B50)
            local += u16(20) + u16(0) + u16(m.method) + u16(0) + u16(0)
            local += u32(Int(crc32(m.body)))
            local += u32(payload.count) + u32(m.body.count)
            local += u16(m.name.utf8.count) + u16(m.extra)
            file.append(contentsOf: local)
            file.append(contentsOf: Array(m.name.utf8))
            file.append(Data(repeating: 0xAB, count: m.extra))
            file.append(payload)
        }
        let directoryStart = file.count
        for (i, m) in members.enumerated() {
            var central: [UInt8] = []
            central += u32(0x0201_4B50)
            central += u16(20) + u16(20) + u16(0) + u16(m.method) + u16(0) + u16(0)
            central += u32(Int(crc32(m.body)))
            central += u32(stored[i].count) + u32(m.body.count)
            central += u16(m.name.utf8.count) + u16(0) + u16(0)
            central += u16(0) + u16(0) + u32(0)
            central += u32(offsets[i])
            file.append(contentsOf: central)
            file.append(contentsOf: Array(m.name.utf8))
        }
        let directorySize = file.count - directoryStart
        var end: [UInt8] = []
        end += u32(0x0605_4B50)
        end += u16(0) + u16(0) + u16(members.count) + u16(members.count)
        end += u32(directorySize) + u32(directoryStart)
        end += u16(comment.utf8.count)
        file.append(contentsOf: end)
        file.append(contentsOf: Array(comment.utf8))
        return file
    }

    private func entries(_ zip: Data, tailBytes: Int = 1024) throws -> [GTFSZip.Entry] {
        let range = try GTFSZip.directoryRange(tail: Data(zip.suffix(tailBytes)), totalSize: zip.count)
        return try GTFSZip.entries(directory: zip.subdata(in: range))
    }

    /// Each member as it would be kept on disk: the packed header (none for a
    /// stored member), then its data exactly as the archive holds it.
    private func kept(_ zip: Data, tailBytes: Int = 1024) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for entry in try entries(zip, tailBytes: tailBytes) {
            let chunk = zip.subdata(in: entry.safeRange.clamped(to: 0..<zip.count))
            let data = try XCTUnwrap(try GTFSZip.dataRange(of: entry, localHeader: chunk))
            XCTAssertLessThanOrEqual(data.upperBound, chunk.count)
            var file = GTFSZip.packedHeader(for: entry)
            file.append(chunk.subdata(in: data))
            out[try GTFSZip.fileName(for: entry)] = file
        }
        return out
    }

    // MARK: the tests

    private var stops: Data { Data("stop_id,stop_name\nCHI,Chicago Union Station\n".utf8) }
    private var trips: Data { Data("route_id,service_id,trip_id\nR1,WK,t1\n".utf8) }

    func testAStoredMemberIsKeptAsItsOwnBytesAndADeflatedOnePacked() throws {
        let zip = archive([
            Member(name: "stops.txt", body: stops, method: 0, extra: 0),
            Member(name: "trips.txt", body: trips, method: 8, extra: 0),
        ])
        let files = try kept(zip)
        XCTAssertEqual(files["stops.txt"], stops, "a stored member is its own bytes")

        // A deflated one: the header, then the archive's own compressed bytes.
        let packed = try XCTUnwrap(files["trips.txt.fz"])
        XCTAssertEqual(packed.prefix(4), Data("FZ01".utf8))
        let crc = packed.subdata(in: 4..<8).enumerated()
            .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        XCTAssertEqual(crc, crc32(trips), "the directory's CRC, for the builder to check")
        let length = packed.subdata(in: 8..<16).enumerated()
            .reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        XCTAssertEqual(length, UInt64(trips.count))
        XCTAssertEqual(inflate(packed.subdata(in: 16..<packed.count), expected: trips.count), trips,
                       "and what follows is the member, still compressed")
    }

    func testTheLocalExtraFieldIsSkippedNotRead() throws {
        // The central directory's extra length and the local header's need not
        // match; only the local one says where the data starts. Reading the
        // wrong one shifts every byte of the file.
        let zip = archive([Member(name: "stops.txt", body: stops, method: 0, extra: 37)])
        XCTAssertEqual(try kept(zip)["stops.txt"], stops)
    }

    func testTheHugeFileWeNeverReadIsNeverFetched() throws {
        let shapes = Data(repeating: 0x41, count: 200_000)
        let zip = archive([
            Member(name: "shapes.txt", body: shapes, method: 0, extra: 0),
            Member(name: "stops.txt", body: stops, method: 0, extra: 0),
        ])
        let found = try entries(zip)
        XCTAssertEqual(found.map(\.name), ["stops.txt"],
                       "shapes.txt is the bulk of a feed and the router never reads it")
        let asked = found.reduce(0) { $0 + $1.safeRange.clamped(to: 0..<zip.count).count }
        XCTAssertLessThan(asked, zip.count / 2, "the big member is not in any range we ask for")
    }

    func testAFeedNestedInAFolderStillResolves() throws {
        let zip = archive([Member(name: "GTFS/stops.txt", body: stops, method: 0, extra: 0)])
        XCTAssertEqual(try kept(zip)["stops.txt"], stops)
    }

    func testAnArchiveCommentDoesNotHideTheDirectory() throws {
        let zip = archive([Member(name: "stops.txt", body: stops, method: 0, extra: 0)],
                          comment: "built by a publisher that leaves notes")
        XCTAssertEqual(try kept(zip)["stops.txt"], stops)
    }

    func testRubbishAndTruncationAreRefusedNotGuessed() {
        let junk = Data(repeating: 0x7F, count: 512)
        XCTAssertThrowsError(try GTFSZip.directoryRange(tail: junk, totalSize: junk.count))

        let zip = archive([Member(name: "stops.txt", body: stops, method: 0, extra: 0)])
        // A directory that claims to start past the end of the file.
        var lying = zip
        let eocd = lying.count - 22
        lying.replaceSubrange((lying.startIndex + eocd + 16)..<(lying.startIndex + eocd + 20),
                              with: u32(zip.count * 4))
        XCTAssertThrowsError(
            try GTFSZip.directoryRange(tail: Data(lying.suffix(1024)), totalSize: lying.count)
        )
        // Something other than a local header where one should start.
        XCTAssertThrowsError(try GTFSZip.dataRange(
            of: try XCTUnwrap(try? entries(zip).first), localHeader: junk))
    }

    func testAnUnknownCompressionIsRefused() throws {
        let zip = archive([Member(name: "stops.txt", body: stops, method: 99, extra: 0)])
        let entry = try XCTUnwrap(try entries(zip).first)
        XCTAssertThrowsError(try GTFSZip.fileName(for: entry)) { error in
            guard case GTFSZip.Failure.unsupported = error else {
                return XCTFail("expected an unsupported-compression refusal, got \(error)")
            }
        }
    }

    func testAnArchiveWithNothingWeReadIsRefused() throws {
        let zip = archive([Member(name: "shapes.txt", body: stops, method: 0, extra: 0)])
        XCTAssertThrowsError(try entries(zip))
    }

    func testTheNarrowRangeIsTriedFirstAndTheWideOneRescuesIt() throws {
        // Real archives put 0–28 bytes in a local extra field (Amtrak's own is
        // empty), so the fetch asks for a 256-byte margin instead of the legal
        // 64 KiB and saves ~450 KB. An archive that does use a big extra field
        // must still work — the narrow read shows the data runs past it, and
        // the wide one holds it.
        let zip = archive([Member(name: "stops.txt", body: stops, method: 0, extra: 4_000)])
        let entry = try XCTUnwrap(try entries(zip).first)
        XCTAssertLessThan(entry.likelyRange.count, entry.safeRange.count)

        let narrow = zip.subdata(in: entry.likelyRange.clamped(to: 0..<zip.count))
        let inNarrow = try XCTUnwrap(try GTFSZip.dataRange(of: entry, localHeader: narrow))
        XCTAssertGreaterThan(inNarrow.upperBound, narrow.count, "the narrow range fell short")

        let wide = zip.subdata(in: entry.safeRange.clamped(to: 0..<zip.count))
        let inWide = try XCTUnwrap(try GTFSZip.dataRange(of: entry, localHeader: wide))
        XCTAssertLessThanOrEqual(inWide.upperBound, wide.count)
        XCTAssertEqual(wide.subdata(in: inWide), stops)
    }

    func testAShortBufferAsksAgainInsteadOfReturningHalfAFile() throws {
        let zip = archive([Member(name: "stops.txt", body: stops, method: 0, extra: 0)])
        let entry = try XCTUnwrap(try entries(zip).first)
        XCTAssertNil(try GTFSZip.dataRange(of: entry, localHeader: zip.prefix(29)),
                     "not even a whole header yet")
        let short = zip.subdata(in: 0..<(entry.headerOffset + 32))
        let data = try XCTUnwrap(try GTFSZip.dataRange(of: entry, localHeader: short))
        XCTAssertGreaterThan(data.upperBound, short.count,
                             "a truncated fetch must say so, not hand back a partial schedule")
    }

    // MARK: packed files, end to end through the timetable builder

    private func folder(_ files: [String: Data]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-zip-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private var feed: [String: Data] {
        let calendar = "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,"
            + "start_date,end_date\nWK,1,1,1,1,1,1,1,20260901,20261231\n"
        return [
            "agency.txt": Data("agency_id,agency_name,agency_timezone\n1,Rail,America/Chicago\n".utf8),
            "stops.txt": Data(("stop_id,stop_name,stop_lat,stop_lon\n"
                + "A,Alpha,41.88,-87.64\nB,Bravo,41.97,-87.66\n").utf8),
            "routes.txt": Data("route_id,route_short_name,route_long_name,route_type\nR,22,Clark,3\n".utf8),
            "calendar.txt": Data(calendar.utf8),
            "trips.txt": Data("route_id,service_id,trip_id\nR,WK,t1\nR,WK,t2\n".utf8),
            "stop_times.txt": Data(("trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
                + "t1,08:00:00,08:00:00,A,1\nt1,08:30:00,08:30:00,B,2\n"
                + "t2,09:00:00,09:00:00,A,1\nt2,09:30:00,09:30:00,B,2\n").utf8),
        ]
    }

    func testAPackedFeedBuildsTheSameTimetableAsAPlainOne() throws {
        let members = feed.map { Member(name: $0.key, body: $0.value, method: 8, extra: 0) }
        let packed = try kept(archive(members))
        XCTAssertEqual(Set(packed.keys), Set(feed.keys.map { $0 + ".fz" }))

        let (plainDir, packedDir) = (try folder(feed), try folder(packed))
        let (plainOut, packedOut) = (plainDir.path + "-shard", packedDir.path + "-shard")
        defer {
            for p in [plainDir.path, packedDir.path] { try? FileManager.default.removeItem(atPath: p) }
            for p in [plainOut, packedOut] {
                try? FileManager.default.removeItem(atPath: p + ".ftt")
                try? FileManager.default.removeItem(atPath: p + ".fts")
            }
        }
        XCTAssertTrue(GTFSZip.hasMember("stops.txt", in: packedDir))
        XCTAssertEqual(GTFSZip.unpackedSize(of: "stop_times.txt", in: packedDir),
                       feed["stop_times.txt"]?.count, "read from the packed header")
        XCTAssertEqual(TransitShard.agencyZone(feedDirectory: packedDir.path), "America/Chicago")

        try TransitShard.build(feedDirectory: plainDir.path, prefix: plainOut, serviceDate: 20260930)
        try TransitShard.build(feedDirectory: packedDir.path, prefix: packedOut, serviceDate: 20260930)
        for ext in [".ftt", ".fts"] {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: plainOut + ext)),
                           try Data(contentsOf: URL(fileURLWithPath: packedOut + ext)),
                           "byte for byte, \(ext)")
        }
    }

    func testAPackedFileThatDoesNotCheckOutBuildsNothing() throws {
        let members = feed.map { Member(name: $0.key, body: $0.value, method: 8, extra: 0) }
        var packed = try kept(archive(members))
        // The CRC the archive recorded no longer matches what unpacks.
        var times = try XCTUnwrap(packed["stop_times.txt.fz"])
        times[4] ^= 0xFF
        packed["stop_times.txt.fz"] = times
        let dir = try folder(packed)
        let out = dir.path + "-shard"
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(atPath: out + ".ftt")
            try? FileManager.default.removeItem(atPath: out + ".fts")
        }
        XCTAssertThrowsError(
            try TransitShard.build(feedDirectory: dir.path, prefix: out, serviceDate: 20260930),
            "a corrupted download is an error, not a timetable missing trips")
    }

    // MARK: the service day is the operator's day

    func testTheServiceDayFollowsTheOperatorNotTheDevice() {
        // 9pm in Honolulu on the 22nd is already the 23rd in New York, and
        // Amtrak is already running the 23rd's timetable.
        var honolulu = DateComponents()
        honolulu.year = 2026
        honolulu.month = 9
        honolulu.day = 22
        honolulu.hour = 21
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        guard let moment = calendar.date(from: honolulu) else { return XCTFail("no date") }

        XCTAssertEqual(
            TransitFeeds.serviceDate(moment, zone: "Pacific/Honolulu"), 20260922,
            "locally it is still the 22nd"
        )
        XCTAssertEqual(
            TransitFeeds.serviceDate(moment, zone: "America/New_York"), 20260923,
            "the operator is already on the 23rd"
        )
    }
}
