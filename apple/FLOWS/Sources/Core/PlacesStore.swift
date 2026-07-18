// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// FLOWS's OWN offline POI database: per-state ".fps" shards compiled from the
/// Foursquare OS Places open dataset (Apache 2.0 — legally shipped/distributed,
/// no key, no ToS exposure) by `rust/flows-train/src/bin/places-shard.rs`.
/// 7.5M US places across 8 groups; grid-indexed for viewport/corridor queries.
/// This is the keyless replacement for platform POI dependence — MKLocalSearch
/// becomes an online enricher instead of the only source.
///
/// Format "FPS1" (little-endian): 32-byte header (magic, version, record
/// count, grid-index offset u64, fnv1a-64 body hash over bytes[32...], cell
/// count u32), variable-length records sorted by 0.2° cell, then a sorted
/// (cellKey i64, startRecord u32, count u32) grid index. Records are
/// variable-length, so the reader builds a byte-offset table in one
/// sequential load-time scan; queries then decode only matching cells.
struct PlacesShard {
    struct Place {
        let coordinate: CLLocationCoordinate2D
        let group: UInt8
        let name: String
        let street: String
        let city: String
        let website: String
        let tel: String
        let postcode: UInt32
    }

    private let data: Data
    private let recordOffsets: [Int]
    private let cellKeys: [Int64]
    private let cellStart: [Int]
    private let cellCount: [Int]

    /// Parse + validate a shard; nil on any structural or hash mismatch
    /// (a corrupt shard is refused, never "repaired").
    init?(data: Data) {
        guard data.count > 32 else { return nil }
        func u32(_ at: Int) -> Int {
            data.subdata(in: at..<(at + 4)).withUnsafeBytes {
                Int($0.loadUnaligned(as: UInt32.self))
            }
        }
        func u64(_ at: Int) -> UInt64 {
            data.subdata(in: at..<(at + 8)).withUnsafeBytes {
                $0.loadUnaligned(as: UInt64.self)
            }
        }
        guard data.prefix(4) == Data("FPS1".utf8), u32(4) == 1 else { return nil }
        let nRecords = u32(8)
        let gridOffset = Int(u64(12))
        let storedHash = u64(20)
        let nCells = u32(28)
        guard nRecords >= 0, nCells >= 0, gridOffset >= 32,
              gridOffset + nCells * 16 == data.count else { return nil }
        // fnv1a-64 over records + grid index — reject corruption.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 32..<data.count {
                hash ^= UInt64(raw[i])
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        guard hash == storedHash else { return nil }

        // One sequential scan → byte offset of every record (variable length).
        var offsets = [Int]()
        offsets.reserveCapacity(nRecords)
        var ok = true
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 32
            for _ in 0..<nRecords {
                guard off + 10 <= gridOffset else { ok = false; return }
                offsets.append(off)
                off += 10   // lat f32 + lon f32 + group u8 + flags u8
                for _ in 0..<5 {   // name, street, city, website, tel
                    guard off + 2 <= gridOffset else { ok = false; return }
                    let len = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
                    off += 2 + len
                    guard off <= gridOffset else { ok = false; return }
                }
                off += 4           // postcode u32
                guard off <= gridOffset else { ok = false; return }
            }
            ok = ok && off == gridOffset
        }
        guard ok, offsets.count == nRecords else { return nil }

        var keys = [Int64](); keys.reserveCapacity(nCells)
        var starts = [Int](); starts.reserveCapacity(nCells)
        var counts = [Int](); counts.reserveCapacity(nCells)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = gridOffset
            for _ in 0..<nCells {
                keys.append(raw.loadUnaligned(fromByteOffset: off, as: Int64.self))
                starts.append(Int(raw.loadUnaligned(fromByteOffset: off + 8, as: UInt32.self)))
                counts.append(Int(raw.loadUnaligned(fromByteOffset: off + 12, as: UInt32.self)))
                off += 16
            }
        }
        self.data = data
        recordOffsets = offsets
        cellKeys = keys
        cellStart = starts
        cellCount = counts
    }

    /// The builder's cell key: 0.2° cells, always positive.
    static func cellKey(lat5: Int, lon5: Int) -> Int64 {
        Int64(lat5 + 9_000) * 100_000 + Int64(lon5 + 18_000)
    }

    private func decode(recordAt index: Int) -> Place? {
        guard index < recordOffsets.count else { return nil }
        var off = recordOffsets[index]
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Place? in
            let lat = raw.loadUnaligned(fromByteOffset: off, as: Float.self)
            let lon = raw.loadUnaligned(fromByteOffset: off + 4, as: Float.self)
            let group = raw[off + 8]
            off += 10
            var strings: [String] = []
            for _ in 0..<5 {
                let len = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
                off += 2
                let s = String(decoding: raw[off..<(off + len)], as: UTF8.self)
                strings.append(s)
                off += len
            }
            let postcode = raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)
            return Place(
                coordinate: CLLocationCoordinate2D(latitude: Double(lat),
                                                   longitude: Double(lon)),
                group: group, name: strings[0], street: strings[1], city: strings[2],
                website: strings[3], tel: strings[4], postcode: postcode)
        }
    }

    /// All places of the given groups within `radiusMeters` of `center`,
    /// nearest-first, capped. Walks only the 0.2° cells the radius covers.
    func places(near center: CLLocationCoordinate2D, groups: Set<UInt8>,
                radiusMeters: CLLocationDistance, limit: Int) -> [Place] {
        let dLat = radiusMeters / 111_320.0
        let dLon = radiusMeters / max(111_320.0 * cos(center.latitude * .pi / 180), 1)
        let lat5Lo = Int(floor((center.latitude - dLat) * 5))
        let lat5Hi = Int(floor((center.latitude + dLat) * 5))
        let lon5Lo = Int(floor((center.longitude - dLon) * 5))
        let lon5Hi = Int(floor((center.longitude + dLon) * 5))
        var out: [(Place, CLLocationDistance)] = []
        for lat5 in lat5Lo...lat5Hi {
            for lon5 in lon5Lo...lon5Hi {
                guard let ci = cellIndex(Self.cellKey(lat5: lat5, lon5: lon5))
                else { continue }
                for r in cellStart[ci]..<(cellStart[ci] + cellCount[ci]) {
                    guard let p = decode(recordAt: r), groups.contains(p.group)
                    else { continue }
                    let d = POIRanking.meters(p.coordinate, center)
                    if d <= radiusMeters { out.append((p, d)) }
                }
            }
        }
        out.sort { $0.1 < $1.1 }
        return out.prefix(limit).map(\.0)
    }

    private func cellIndex(_ key: Int64) -> Int? {
        var lo = 0, hi = cellKeys.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cellKeys[mid] == key { return mid }
            if cellKeys[mid] < key { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }
}

/// Shard resolver + LRU cache: maps query points to their state shard(s) via
/// the WZDx state-bbox table and keeps the last few parsed shards in memory
/// (a parsed CA shard holds a ~few-MB offset table; three states cover any
/// realistic corridor query burst).
@MainActor
final class PlacesStore: ObservableObject {
    static let shared = PlacesStore()

    private var cache: [String: PlacesShard] = [:]
    private var lru: [String] = []

    /// The driver's home/current state — its shard stays resident (the user's
    /// rule: the home region keeps a permanently cached radius; everything
    /// else loads on demand and can be evicted).
    var pinnedState: String?

    /// Offline places near a point: resolve the state shard(s) whose bbox
    /// contains the query, load (cached), query. Returns [] when no shard
    /// file is present — the online path continues to serve alone.
    /// (Group bytes: 0=fuel 1=food 2=stores 3=hotel 4=medical 5=tourist
    /// 6=transit 7=rest/truckstop; the POIService.Kind mapping lives with
    /// POIService so this reader stays dependency-free.)
    func places(near center: CLLocationCoordinate2D, groups: Set<UInt8>,
                radiusMeters: CLLocationDistance, limit: Int = 12) -> [PlacesShard.Place] {
        guard !groups.isEmpty else { return [] }
        var out: [PlacesShard.Place] = []
        for state in Self.states(containing: center) {
            guard let shard = shard(for: state) else { continue }
            out.append(contentsOf: shard.places(
                near: center, groups: groups, radiusMeters: radiusMeters, limit: limit))
        }
        out.sort { POIRanking.meters($0.coordinate, center) < POIRanking.meters($1.coordinate, center) }
        return Array(out.prefix(limit))
    }

    private func shard(for state: String) -> PlacesShard? {
        if let hit = cache[state] { return hit }
        for root in Self.candidateRoots() {
            let path = "\(root)/\(state).fps"
            guard let data = FileManager.default.contents(atPath: path),
                  let shard = PlacesShard(data: data) else { continue }
            cache[state] = shard
            lru.append(state)
            if lru.count > 3 {                    // LRU cap: 3 parsed states
                // Never evict the pinned (home/current) state's shard.
                if let evict = lru.firstIndex(where: { $0 != pinnedState }) {
                    cache.removeValue(forKey: lru.remove(at: evict))
                } else {
                    lru.removeFirst()
                }
            }
            return shard
        }
        return nil
    }

    nonisolated private static func candidateRoots() -> [String] {
        #if os(macOS)
        let repo = ProcessInfo.processInfo.environment["FLOWS_REPO"]
            ?? "\(NSHomeDirectory())/Documents/Coding_Files/FLOWS"
        return [
            "\(repo)/data/places",
            "/Users/Shared/flows/repo/data/places",
            Bundle.main.resourcePath.map { "\($0)/places" },
        ].compactMap { $0 }
        #else
        return [Bundle.main.resourcePath.map { "\($0)/places" }].compactMap { $0 }
        #endif
    }

    /// States whose rough bbox contains the point (1–3 near borders).
    nonisolated static func states(containing c: CLLocationCoordinate2D) -> [String] {
        LiveHazardFeedFetcher.stateBBoxes.filter { _, b in
            c.latitude >= b.s && c.latitude <= b.n
                && c.longitude >= b.w && c.longitude <= b.e
        }.map(\.key).sorted()
    }
}
