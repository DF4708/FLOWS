// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import AVFoundation
import CoreLocation
import Foundation

/// The AM/FM set: it holds the catalogue of nearby stations filed by kind,
/// plays one, and steps to the next or previous within that kind.
///
/// Catalogue is fetched once per region and cached to disk, so opening the
/// radio on a drive with no signal still offers the stations of the last
/// place with one. Nothing here touches the emergency radio's player —
/// AppModel makes the two mutually exclusive, because a car has one set of
/// speakers.
@MainActor
final class BroadcastRadioTuner: ObservableObject {
    /// Stations filed by kind, nearest first inside each.
    @Published private(set) var byKind: [BroadcastRadio.Kind: [BroadcastRadio.Station]] = [:]
    /// The kind the driver last chose. Stepping never leaves it.
    @Published var kind: BroadcastRadio.Kind = .news {
        didSet {
            guard kind != oldValue else { return }
            UserDefaults.standard.set(kind.rawValue, forKey: Self.kindKey)
            // A new kind means a new dial: start at its nearest station if
            // something was already playing, so the change is audible.
            if playing != nil { play(stations.first) }
        }
    }
    @Published private(set) var playing: BroadcastRadio.Station?
    @Published private(set) var status: String?
    @Published private(set) var loading = false

    /// Every kind that actually has a station here — the picker shows these
    /// and not the empty ones, so a driver never taps into silence.
    var availableKinds: [BroadcastRadio.Kind] {
        BroadcastRadio.Kind.allCases.filter { !(byKind[$0]?.isEmpty ?? true) }
    }

    /// The stations of the current kind.
    var stations: [BroadcastRadio.Station] { byKind[kind] ?? [] }

    private static let kindKey = "flows.radioKind"
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var catalogueTask: Task<Void, Never>?
    /// Where the last catalogue was built for — refetch after a real move.
    private var cataloguedNear: CLLocationCoordinate2D?
    /// Called when playback starts, so the emergency radio can stand down.
    var willStartPlaying: (() -> Void)?

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.kindKey),
           let saved = BroadcastRadio.Kind(rawValue: raw) {
            kind = saved
        }
        byKind = Self.loadCache()
    }

    // MARK: the dial

    /// Play a station, or stop when handed nil.
    func play(_ station: BroadcastRadio.Station?) {
        guard let station, let url = station.streamURL else { return stop() }
        willStartPlaying?()
        stopPlayer()
        #if os(iOS)
        // Without an active playback session iOS keeps AVPlayer silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        playing = station
        status = "Tuning…"
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        p.volume = 1
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in
                switch item.status {
                case .readyToPlay: self?.status = nil
                case .failed:
                    // A dead stream should move the dial on, not sit silent:
                    // this is a radio, and the next station is the fix.
                    self?.status = "That station is off the air."
                    self?.skipDeadStation()
                default: break
                }
            }
        }
        p.play()
        player = p
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.status = "That station cut out."
                self?.skipDeadStation()
            }
        }
    }

    /// Forward and back along the current kind, wrapping at both ends.
    func next() { play(BroadcastRadio.step(from: playing?.id, in: stations, forward: true)) }
    func previous() { play(BroadcastRadio.step(from: playing?.id, in: stations, forward: false)) }

    func stop() {
        stopPlayer()
        playing = nil
        status = nil
    }

    private func stopPlayer() {
        player?.pause()
        player = nil
        statusObservation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
    }

    /// Drop a station that won't play and move to the next one — but only
    /// once per press, so a whole kind of dead streams can't spin forever.
    private var skipsSinceUserAction = 0
    private func skipDeadStation() {
        guard skipsSinceUserAction < 3, stations.count > 1 else {
            skipsSinceUserAction = 0
            stopPlayer()
            playing = nil
            return
        }
        skipsSinceUserAction += 1
        let n = BroadcastRadio.step(from: playing?.id, in: stations, forward: true)
        play(n)
    }

    // MARK: the catalogue

    /// Build (or reuse) the list of stations around a position. Cheap: one
    /// fetch per region, and only when the vehicle has really moved on.
    func catalogue(near position: CLLocationCoordinate2D?) {
        guard let position else { return }
        if let last = cataloguedNear,
           POIRanking.meters(last, position) < 120_000, !byKind.isEmpty { return }
        cataloguedNear = position
        catalogueTask?.cancel()
        loading = byKind.isEmpty
        catalogueTask = Task { [weak self] in
            let found = await RadioDirectory.stations(near: position)
            guard let self, !Task.isCancelled, !found.isEmpty else {
                await MainActor.run { self?.loading = false }
                return
            }
            await MainActor.run {
                var filed: [BroadcastRadio.Kind: [BroadcastRadio.Station]] = [:]
                for s in found { filed[s.kind, default: []].append(s) }
                for k in filed.keys {
                    filed[k] = BroadcastRadio.ranked(filed[k] ?? [], near: position)
                }
                self.byKind = filed
                self.loading = false
                // Land on a kind that actually has stations here.
                if filed[self.kind]?.isEmpty ?? true,
                   let first = self.availableKinds.first {
                    self.kind = first
                }
                Self.saveCache(filed)
            }
        }
    }

    // MARK: disk cache — the last place with signal keeps its dial

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first?
            .appendingPathComponent("broadcast_radio.json")
    }

    private static func loadCache() -> [BroadcastRadio.Kind: [BroadcastRadio.Station]] {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([BroadcastRadio.Station].self,
                                                   from: data) else { return [:] }
        var filed: [BroadcastRadio.Kind: [BroadcastRadio.Station]] = [:]
        for s in rows { filed[s.kind, default: []].append(s) }
        return filed
    }

    private static func saveCache(_ filed: [BroadcastRadio.Kind: [BroadcastRadio.Station]]) {
        guard let url = cacheURL else { return }
        let rows = filed.values.flatMap { $0 }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The Radio Browser directory (radio-browser.info) — a keyless, community
/// catalogue of broadcasters' own public streams. Only the fields the dial
/// needs are decoded.
enum RadioDirectory {
    /// The directory's mirrors. Tried in order; the first that answers wins.
    /// (Community-run, hosted in Germany, Austria and the Netherlands.)
    static let hosts = ["https://de1.api.radio-browser.info",
                        "https://at1.api.radio-browser.info",
                        "https://nl1.api.radio-browser.info"]

    private struct Row: Decodable {
        var stationuuid: String
        var name: String
        var url_resolved: String?
        var url: String
        var tags: String
        var geo_lat: Double?
        var geo_long: Double?
        var bitrate: Int?
    }

    /// Stations for the state the position falls in, already filed by kind.
    /// Empty on any failure — an unreachable directory is a quiet radio, not
    /// an error card.
    static func stations(near position: CLLocationCoordinate2D) async
        -> [BroadcastRadio.Station] {
        let country = RatingsAndCost.Country.forCoordinate(
            latitude: position.latitude, longitude: position.longitude)
        var query = "limit=400&hidebroken=true&order=clickcount&reverse=true"
            + "&countrycode=\(country.radioBrowserCode)"
        // Inside the US the state narrows it to a real local dial; elsewhere
        // the country list is already the right size.
        if country == .us,
           let state = LiveHazardFeedFetcher.stateBBoxes.first(where: { _, b in
               position.latitude >= b.s && position.latitude <= b.n
                   && position.longitude >= b.w && position.longitude <= b.e
           })?.key, let name = Self.stateNames[state] {
            let escaped = name.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) ?? name
            query += "&state=" + escaped
        }
        for host in hosts {
            guard let url = URL(string: "\(host)/json/stations/search?\(query)"),
                  let (data, resp) = try? await ThrottledNet.fetch(url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let rows = try? JSONDecoder().decode([Row].self, from: data)
            else { continue }
            var seen = Set<String>()
            return rows.compactMap { row -> BroadcastRadio.Station? in
                let stream = row.url_resolved?.isEmpty == false
                    ? row.url_resolved! : row.url
                guard !stream.isEmpty, !row.name.isEmpty,
                      let kind = BroadcastRadio.kind(forTags: row.tags),
                      seen.insert(stream).inserted else { return nil }
                return BroadcastRadio.Station(
                    id: row.stationuuid,
                    name: row.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    url: stream, tags: row.tags,
                    latitude: row.geo_lat, longitude: row.geo_long,
                    bitrate: row.bitrate ?? 0, kind: kind)
            }
        }
        return []
    }

    /// The directory keys states by full name, and the app keys them by
    /// code — this is the bridge.
    static let stateNames: [String: String] = [
        "AL": "Alabama", "AZ": "Arizona", "AR": "Arkansas", "CA": "California",
        "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware",
        "FL": "Florida", "GA": "Georgia", "ID": "Idaho", "IL": "Illinois",
        "IN": "Indiana", "IA": "Iowa", "KS": "Kansas", "KY": "Kentucky",
        "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
        "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota",
        "MS": "Mississippi", "MO": "Missouri", "MT": "Montana",
        "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire",
        "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
        "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio",
        "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania",
        "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota",
        "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont",
        "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
        "WI": "Wisconsin", "WY": "Wyoming",
    ]
}
