// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The .fps offline-places reader: format parse, hash refusal, grid query —
/// plus a real-shard validation against the tool-built data when present.
final class PlacesStoreTests: XCTestCase {

    /// Build a minimal valid FPS1 shard: 2 records in one 0.2° cell.
    private func fixture(corrupt: Bool = false) -> Data {
        var body = Data()
        func u16(_ v: UInt16, into d: inout Data) {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        func str(_ s: String, into d: inout Data) {
            u16(UInt16(s.utf8.count), into: &d)
            d.append(contentsOf: s.utf8)
        }
        func record(lat: Float, lon: Float, group: UInt8, name: String) {
            withUnsafeBytes(of: lat.bitPattern.littleEndian) { body.append(contentsOf: $0) }
            withUnsafeBytes(of: lon.bitPattern.littleEndian) { body.append(contentsOf: $0) }
            body.append(group)
            body.append(0)   // flags
            str(name, into: &body)
            str("1 Main St", into: &body)
            str("Madison", into: &body)
            str("", into: &body)     // website
            str("", into: &body)     // tel
            withUnsafeBytes(of: UInt32(53703).littleEndian) { body.append(contentsOf: $0) }
        }
        record(lat: 43.07, lon: -89.40, group: 0, name: "Test Fuel")
        record(lat: 43.08, lon: -89.41, group: 2, name: "Test Store")
        let gridOffsetInBody = body.count
        // One cell: lat5 = floor(43.07*5)=215, lon5 = floor(-89.40*5)=-447.
        let key = PlacesShard.cellKey(lat5: 215, lon5: -447)
        withUnsafeBytes(of: key.littleEndian) { body.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0).littleEndian) { body.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(2).littleEndian) { body.append(contentsOf: $0) }

        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in body { hash ^= UInt64(b); hash = hash &* 0x0000_0100_0000_01b3 }
        if corrupt { hash &+= 1 }

        var d = Data("FPS1".utf8)
        func u32h(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32h(1)                                   // version
        u32h(2)                                   // records
        withUnsafeBytes(of: UInt64(32 + gridOffsetInBody).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: hash.littleEndian) { d.append(contentsOf: $0) }
        u32h(1)                                   // cells
        d.append(body)
        return d
    }

    func testParseAndQuery() {
        let shard = PlacesShard(data: fixture())
        XCTAssertNotNil(shard)
        let madison = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)
        let fuel = shard?.places(near: madison, groups: [0], radiusMeters: 5_000,
                                 limit: 5) ?? []
        XCTAssertEqual(fuel.count, 1)
        XCTAssertEqual(fuel.first?.name, "Test Fuel")
        XCTAssertEqual(fuel.first?.city, "Madison")
        XCTAssertEqual(fuel.first?.postcode, 53703)
        // Group filter separates; both groups come back together.
        let both = shard?.places(near: madison, groups: [0, 2], radiusMeters: 5_000,
                                 limit: 5) ?? []
        XCTAssertEqual(both.count, 2)
        // Far away → nothing.
        let phoenix = CLLocationCoordinate2D(latitude: 33.45, longitude: -112.07)
        XCTAssertEqual(shard?.places(near: phoenix, groups: [0], radiusMeters: 5_000,
                                     limit: 5).count ?? -1, 0)
    }

    func testCorruptionRefused() {
        XCTAssertNil(PlacesShard(data: fixture(corrupt: true)))
        XCTAssertNil(PlacesShard(data: fixture().prefix(40)))
        var bad = fixture()
        bad.replaceSubrange(0..<4, with: "XXXX".utf8)
        XCTAssertNil(PlacesShard(data: bad))
    }

    /// Real-data validation: parse the tool-built Wisconsin shard and find a
    /// gas station near the Capitol. Skips on machines without shards.
    func testRealShardWhenPresent() throws {
        let path = "\(NSHomeDirectory())/Documents/Coding_Files/FLOWS/data/places/WI.fps"
        guard let data = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("no local WI shard — pipeline machine only")
        }
        let shard = PlacesShard(data: data)
        XCTAssertNotNil(shard, "tool-built shard must parse + hash-validate")
        let capitol = CLLocationCoordinate2D(latitude: 43.0747, longitude: -89.3844)
        let fuel = shard?.places(near: capitol, groups: [0], radiusMeters: 8_000,
                                 limit: 10) ?? []
        XCTAssertFalse(fuel.isEmpty, "central Madison must have fuel POIs")
        let food = shard?.places(near: capitol, groups: [1], radiusMeters: 3_000,
                                 limit: 10) ?? []
        XCTAssertFalse(food.isEmpty, "downtown Madison must have restaurants")
        // Sanity: every result is inside the radius and the right group.
        for p in fuel {
            XCTAssertEqual(p.group, 0)
            XCTAssertLessThan(POIRanking.meters(p.coordinate, capitol), 8_000)
        }
    }
}
