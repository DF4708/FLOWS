// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
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
struct PlacesShard: @unchecked Sendable {
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

    /// The shard's bytes as loaded — memory-mapped by the store. They stay
    /// here and are lent to every Rust call, so the mapping is never copied.
    private let data: Data
    /// The Rust index over `data` (rust/flows-core places.rs through
    /// rust/flows-bridge): the byte offset of every record and the cell
    /// table, built by the validation pass. Nothing mutates it after init,
    /// which is what makes the shard safe to hand from the loading task to
    /// its readers. Pinned to the original by
    /// rust/flows-bridge/tests/fixtures/swift_places_oracle.tsv.
    private let index: FlowsPlacesIndex

    /// Parse + validate a shard; nil on any structural or hash mismatch
    /// (a corrupt shard is refused, never "repaired").
    init?(data: Data) {
        guard !data.isEmpty,
              let index = data.withUnsafeBytes({ raw -> FlowsPlacesIndex? in
                  flows_places_index_parse(raw.bindMemory(to: UInt8.self))
              })
        else { return nil }
        self.data = data
        self.index = index
    }

    /// The builder's cell key: 0.2° cells, always positive. A key that would
    /// overflow (where the original trapped) answers Int64.min, which no
    /// shard's grid holds.
    static func cellKey(lat5: Int, lon5: Int) -> Int64 {
        let key = flows_places_cell_key(Int64(lat5), Int64(lon5))
        return key.has ? key.key : .min
    }

    /// All places of the given groups within `radiusMeters` of `center`,
    /// nearest-first, capped. Walks only the 0.2° cells the radius covers,
    /// peeking each record's position and group before decoding its texts.
    func places(near center: CLLocationCoordinate2D, groups: Set<UInt8>,
                radiusMeters: CLLocationDistance, limit: Int) -> [Place] {
        guard !groups.isEmpty else { return [] }
        let wanted = Array(groups)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Place] in
            let bytes = raw.bindMemory(to: UInt8.self)
            let hits = wanted.withUnsafeBufferPointer { g in
                index.places_near(bytes, center.latitude, center.longitude, g, radiusMeters, Int64(limit))
            }
            return hits.compactMap { decode(recordAt: $0, in: bytes) }
        }
    }

    private func decode(recordAt i: Int64, in bytes: UnsafeBufferPointer<UInt8>) -> Place? {
        let numbers = index.place_numbers(bytes, i)
        let texts = index.place_texts(bytes, i).map { $0.text }
        guard numbers.count == 4, texts.count == 5 else { return nil }
        return Place(
            coordinate: CLLocationCoordinate2D(latitude: numbers[0], longitude: numbers[1]),
            group: UInt8(numbers[2]), name: texts[0], street: texts[1], city: texts[2],
            website: texts[3], tel: texts[4], postcode: UInt32(numbers[3]))
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
                radiusMeters: CLLocationDistance, limit: Int = 12) async -> [PlacesShard.Place] {
        guard !groups.isEmpty else { return [] }
        var out: [PlacesShard.Place] = []
        for state in Self.states(containing: center) {
            guard let shard = await shard(for: state) else { continue }
            out.append(contentsOf: shard.places(
                near: center, groups: groups, radiusMeters: radiusMeters, limit: limit))
        }
        return POIRanking.byDistance(out.map(\.coordinate), from: center, limit: limit)
            .map { out[$0.index] }
    }

    /// One in-flight parse per state — concurrent corridor queries join it.
    private var shardLoads: [String: Task<PlacesShard?, Never>] = [:]

    private func shard(for state: String) async -> PlacesShard? {
        if let hit = cache[state] { return hit }
        if let running = shardLoads[state] { return await running.value }
        // Construction runs DETACHED: PlacesShard.init hashes every byte of
        // the 10 MB+ file and builds an offset per record (~1M for a big
        // state) — that ran synchronously on the main actor on the first POI
        // query in each new state, a visible hitch mid-drive.
        let task = Task<PlacesShard?, Never>.detached(priority: .utility) {
            for root in Self.candidateRoots() {
                let path = "\(root)/\(state).fps"
                // Map, don't copy: shards are 10 MB+ each and queries touch
                // only a few cells after the one-time validation pass. Mapped
                // pages are clean and file-backed, so memory pressure evicts
                // them instead of jetsamming the app; .mappedIfSafe falls
                // back to a read on filesystems where mapping is unsafe.
                let sp = flowsSignposter.beginInterval("shard-parse")
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                           options: .mappedIfSafe),
                      let shard = PlacesShard(data: data)
                else { flowsSignposter.endInterval("shard-parse", sp); continue }
                flowsSignposter.endInterval("shard-parse", sp)
                return shard
            }
            return nil
        }
        shardLoads[state] = task
        let shard = await task.value
        shardLoads[state] = nil
        guard let shard else { return nil }
        if cache[state] == nil {
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
        }
        return shard
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

    /// States whose rough bbox contains the point (1–3 near borders), in
    /// code order — the alert service's state boxes, in Rust.
    nonisolated static func states(containing c: CLLocationCoordinate2D) -> [String] {
        flows_hazard_states_containing(c.latitude, c.longitude).map { $0.text }
    }
}
