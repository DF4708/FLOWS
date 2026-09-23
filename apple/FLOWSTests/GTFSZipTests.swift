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
/// schedule feed. Archives are built here byte by byte, so the test pins the
/// actual format rather than whatever a zip tool happened to emit.
final class GTFSZipTests: XCTestCase {
    // MARK: building an archive by hand

    private func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func u32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

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
            local += u32(0)  // crc — this reader does not check it
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
            central += u32(0)
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

    private func read(_ zip: Data, tailBytes: Int = 1024) throws -> [String: Data] {
        let tail = Data(zip.suffix(tailBytes))
        let range = try GTFSZip.directoryRange(tail: tail, totalSize: zip.count)
        let entries = try GTFSZip.entries(directory: zip.subdata(in: range))
        var out: [String: Data] = [:]
        for entry in entries {
            let chunk = zip.subdata(in: entry.safeRange.clamped(to: 0..<zip.count))
            out[entry.name] = try GTFSZip.contents(of: entry, localHeaderChunk: chunk)
        }
        return out
    }

    // MARK: the tests

    private var stops: Data { Data("stop_id,stop_name\nCHI,Chicago Union Station\n".utf8) }
    private var trips: Data { Data("route_id,service_id,trip_id\nR1,WK,t1\n".utf8) }

    func testStoredAndDeflatedMembersBothComeOutIntact() throws {
        let zip = archive([
            Member(name: "stops.txt", body: stops, method: 0, extra: 0),
            Member(name: "trips.txt", body: trips, method: 8, extra: 0),
        ])
        let files = try read(zip)
        XCTAssertEqual(files["stops.txt"], stops, "a stored member is its own bytes")
        XCTAssertEqual(files["trips.txt"], trips, "a deflated member inflates back")
    }

    func testTheLocalExtraFieldIsSkippedNotRead() throws {
        // The central directory's extra length and the local header's need not
        // match; only the local one says where the data starts. Reading the
        // wrong one shifts every byte of the file.
        let zip = archive([Member(name: "stops.txt", body: stops, method: 0, extra: 37)])
        XCTAssertEqual(try read(zip)["stops.txt"], stops)
    }

    func testTheHugeFileWeNeverReadIsNeverFetched() throws {
        let shapes = Data(repeating: 0x41, count: 200_000)
        let zip = archive([
            Member(name: "shapes.txt", body: shapes, method: 0, extra: 0),
            Member(name: "stops.txt", body: stops, method: 0, extra: 0),
        ])
        let tail = Data(zip.suffix(1024))
        let range = try GTFSZip.directoryRange(tail: tail, totalSize: zip.count)
        let entries = try GTFSZip.entries(directory: zip.subdata(in: range))
        XCTAssertEqual(entries.map(\.name), ["stops.txt"],
                       "shapes.txt is the bulk of a feed and the router never reads it")
        let asked = entries.reduce(0) { $0 + $1.safeRange.clamped(to: 0..<zip.count).count }
        XCTAssertLessThan(asked, zip.count / 2, "the big member is not in any range we ask for")
    }

    func testAFeedNestedInAFolderStillResolves() throws {
        let zip = archive([Member(name: "GTFS/stops.txt", body: stops, method: 0, extra: 0)])
        XCTAssertEqual(try read(zip)["stops.txt"], stops)
    }

    func testAnArchiveCommentDoesNotHideTheDirectory() throws {
        let zip = archive([Member(name: "stops.txt", body: stops, method: 0, extra: 0)],
                          comment: "built by a publisher that leaves notes")
        XCTAssertEqual(try read(zip)["stops.txt"], stops)
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
    }

    func testAnUnknownCompressionIsRefused() throws {
        let zip = archive([Member(name: "stops.txt", body: stops, method: 99, extra: 0)])
        let range = try GTFSZip.directoryRange(tail: Data(zip.suffix(1024)), totalSize: zip.count)
        let entry = try XCTUnwrap(try GTFSZip.entries(directory: zip.subdata(in: range)).first)
        XCTAssertThrowsError(
            try GTFSZip.contents(
                of: entry, localHeaderChunk: zip.subdata(in: entry.safeRange.clamped(to: 0..<zip.count))
            )
        ) { error in
            guard case GTFSZip.Failure.unsupported = error else {
                return XCTFail("expected an unsupported-compression refusal, got \(error)")
            }
        }
    }

    func testAnArchiveWithNothingWeReadIsRefused() throws {
        let zip = archive([Member(name: "shapes.txt", body: stops, method: 0, extra: 0)])
        let range = try GTFSZip.directoryRange(tail: Data(zip.suffix(1024)), totalSize: zip.count)
        XCTAssertThrowsError(try GTFSZip.entries(directory: zip.subdata(in: range)))
    }

    func testTheNarrowRangeIsTriedFirstAndTheWideOneRescuesIt() throws {
        // Real archives put 0–28 bytes in a local extra field (Amtrak's own is
        // empty), so the fetch asks for a 256-byte margin instead of the legal
        // 64 KiB and saves ~450 KB. An archive that does use a big extra field
        // must still work — the narrow read reports short, the wide one wins.
        let zip = archive([Member(name: "stops.txt", body: stops, method: 0, extra: 4_000)])
        let range = try GTFSZip.directoryRange(tail: Data(zip.suffix(1024)), totalSize: zip.count)
        let entry = try XCTUnwrap(try GTFSZip.entries(directory: zip.subdata(in: range)).first)

        XCTAssertLessThan(entry.likelyRange.count, entry.safeRange.count)
        XCTAssertNil(
            try GTFSZip.contents(
                of: entry,
                localHeaderChunk: zip.subdata(in: entry.likelyRange.clamped(to: 0..<zip.count))
            ),
            "the narrow range fell short and must say so"
        )
        XCTAssertEqual(
            try GTFSZip.contents(
                of: entry,
                localHeaderChunk: zip.subdata(in: entry.safeRange.clamped(to: 0..<zip.count))
            ),
            stops
        )
    }

    func testAShortBufferAsksAgainInsteadOfReturningHalfAFile() throws {
        let zip = archive([Member(name: "stops.txt", body: stops, method: 0, extra: 0)])
        let range = try GTFSZip.directoryRange(tail: Data(zip.suffix(1024)), totalSize: zip.count)
        let entry = try XCTUnwrap(try GTFSZip.entries(directory: zip.subdata(in: range)).first)
        let short = zip.subdata(in: 0..<(entry.headerOffset + 32))
        XCTAssertNil(try GTFSZip.contents(of: entry, localHeaderChunk: short),
                     "a truncated fetch must say so, not hand back a partial schedule")
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
