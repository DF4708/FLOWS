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
#if os(iOS)
import UIKit
#endif

/// Trucker radio: play highway-relevant broadcasts through the app.
///
/// Phone hardware has no VHF/CB receiver, so live listening rides INTERNET
/// RELAYS of those frequencies (NOAA Weather Radio relays, highway advisory
/// relays). Channels are user-configurable: drop a `trucker_radio.json`
/// (array of {"name", "detail", "url"}) into the app's Application Support
/// directory — or use the bundled defaults. Streams that are offline fail
/// soft with a status message, never a hang.
///
/// The frequency GUIDE below is reference for the cab's actual radio: which
/// CB channels and NOAA WX frequencies matter on a haul.
@MainActor
final class TruckerRadio: ObservableObject {
    struct Channel: Codable, Identifiable, Equatable {
        var name: String
        var detail: String
        /// Stream URL (internet relay). Empty = reference-only entry.
        var url: String
        /// Transmitter city coordinates (bundled list) — drive the
        /// nearest-by-GPS auto-tune. nil on scraped entries until merged.
        var latitude: Double?
        var longitude: Double?

        var id: String { name }
        /// ATS blocks cleartext, so an http relay URL (user-supplied lists
        /// sometimes carry them) would fail silently — the relay hosts all
        /// serve the same stream over TLS, so upgrade the scheme here.
        var streamURL: URL? {
            guard !url.isEmpty else { return nil }
            let secured = url.hasPrefix("http://")
                ? "https://" + url.dropFirst("http://".count)
                : url
            return URL(string: secured)
        }
    }

    /// Reference card: what to tune on the physical radio.
    static let frequencyGuide: [(String, String)] = [
        ("CB 19 (27.185 MHz)", "Highway channel — traffic, hazards, E/W convention"),
        ("CB 17 (27.165 MHz)", "N/S highway channel (West Coast convention)"),
        ("CB 9 (27.065 MHz)", "Emergency + motorist assistance (monitored)"),
        ("NOAA WX 162.400–162.550 MHz", "Weather Radio — 7 channels, all-hazards alerts"),
        ("Highway Advisory 530/1610 kHz AM", "State DOT advisories near construction/incidents"),
    ]

    /// Two-or-three plain words on WHY you'd tune a channel — the radio
    /// card's car-radio line stays one breath instead of a paragraph.
    static func shortPurpose(_ channel: String) -> String {
        if channel.hasPrefix("CB 19") { return "traffic" }
        if channel.hasPrefix("CB 17") { return "west-coast traffic" }
        if channel.hasPrefix("CB 9") { return "emergency help" }
        if channel.hasPrefix("NOAA") { return "weather alerts" }
        return "road work alerts"
    }

    /// The AM/FM dial position for channels a NORMAL car radio can tune —
    /// nil for CB and weather-band channels, which need their own sets.
    /// Outside trucker mode the radio card lists only these.
    static func carBandLabel(_ channel: String) -> String? {
        guard channel.hasPrefix("Highway Advisory") else { return nil }
        return "AM 530 or 1610 kHz"
    }

    @Published private(set) var channels: [Channel]
    @Published private(set) var playingChannelID: String?
    @Published private(set) var status: String?

    private var player: AVPlayer?

    /// True when channels came from the user's Application Support
    /// trucker_radio.json — that list WINS and the relay scrape must not
    /// replace it (it was silently wiping custom stations every launch).
    private let usingCustomList: Bool

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
        usingCustomList = dir.map {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("trucker_radio.json").path)
        } ?? false
        channels = Self.loadChannels()
        // Relay hosts rotate stations — refresh the live list once per
        // launch and prune entries that stopped streaming.
        Task { await refreshStations() }
    }

    /// Re-scrape the weatherusa relay directory (the bundled list rots —
    /// stations move hosts); keeps the bundle as fallback.
    func refreshStations() async {
        guard let url = URL(string: "https://www.weatherusa.net/radio"),
              let (data, resp) = try? await ThrottledNet.fetch(url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return }
        var fresh: [Channel] = []
        var seen = Set<String>()
        for chunk in html.components(separatedBy: "<option value=\"") {
            guard chunk.hasPrefix("https://radio.weatherusa.net/NWR/"),
                  let urlEnd = chunk.firstIndex(of: "\"") else { continue }
            let streamURL = String(chunk[..<urlEnd])
            guard !seen.contains(streamURL) else { continue }
            seen.insert(streamURL)
            guard let labelStart = chunk.range(of: ">"),
                  let labelEnd = chunk.range(of: "<", range: labelStart.upperBound..<chunk.endIndex)
            else { continue }
            let label = String(chunk[labelStart.upperBound..<labelEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            fresh.append(Channel(name: "NOAA WX " + label,
                                 detail: "NOAA Weather Radio relay (weatherusa.net)",
                                 url: streamURL))
        }
        guard fresh.count >= 10, !usingCustomList else { return }
        // Carry the bundled transmitter coordinates over to the refreshed list
        // (matched by callsign) so nearest-by-GPS keeps working after refresh.
        let bundled = Self.loadChannels()
        func callsign(_ n: String) -> String? {
            n.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let coordsByCall = Dictionary(
            bundled.compactMap { ch -> (String, (Double, Double))? in
                guard let cs = callsign(ch.name), let la = ch.latitude,
                      let lo = ch.longitude else { return nil }
                return (cs, (la, lo))
            }, uniquingKeysWith: { a, _ in a })
        channels = fresh.map { ch in
            var c = ch
            if let cs = callsign(ch.name), let (la, lo) = coordsByCall[cs] {
                c.latitude = la; c.longitude = lo
            }
            return c
        }
    }

    private static func loadChannels() -> [Channel] {
        // User-supplied list wins (Application Support/trucker_radio.json).
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first {
            let custom = dir.appendingPathComponent("trucker_radio.json")
            if let data = try? Data(contentsOf: custom),
               let parsed = try? JSONDecoder().decode([Channel].self, from: data),
               !parsed.isEmpty {
                return parsed
            }
        }
        // Bundled defaults: the weatherusa.net public NOAA Weather Radio
        // relays (67 stations, verified streaming audio/mpeg at build time).
        if let url = Bundle.main.url(forResource: "nwr_stations", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode([Channel].self, from: data),
           !parsed.isEmpty {
            return parsed
        }
        return [
            Channel(name: "NOAA Weather Radio",
                    detail: "Add your area's relay stream URL (trucker_radio.json)",
                    url: ""),
        ]
    }

    private var statusObservation: NSKeyValueObservation?
    /// `nonisolated(unsafe)` because deinit runs off the actor: by the time
    /// it does, nothing else holds a reference, so the exclusive access the
    /// annotation promises is real rather than asserted.
    private nonisolated(unsafe) var failureObserver: NSObjectProtocol?
    /// Called when playback starts, so the AM/FM dial can stand down — one
    /// car, one pair of speakers.
    var willStartPlaying: (() -> Void)?

    /// Tear the relay down with the object: an emergency radio that goes
    /// away mid-broadcast otherwise leaves an AVPlayer running with nothing
    /// left to stop it, and its observer registered for the process's life.
    deinit {
        player?.pause()
        statusObservation?.invalidate()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }

    func play(_ channel: Channel) {
        guard let url = channel.streamURL else {
            status = "\(channel.name): no stream configured — see the frequency guide "
                + "for the cab radio, or add a relay URL in trucker_radio.json."
            return
        }
        willStartPlaying?()
        stop()
        #if os(iOS)
        // Without an active playback session iOS keeps AVPlayer SILENT —
        // the "no stream works" failure mode.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        status = "Tuning \(channel.name)…"
        playingChannelID = channel.id
        // NO preflight: a ranged GET on an infinite stream never completes,
        // which read as "no station works". Play immediately; the item's
        // status KVO reports dead relays within seconds.
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        p.volume = 1
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in
                switch item.status {
                case .readyToPlay: self?.status = "Playing \(channel.name)"
                case .failed:
                    // Raw AVFoundation error text is jargon — the driver
                    // only needs to know the station can't be reached.
                    self?.status = "Station is offline right now."
                    self?.playingChannelID = nil
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
                self?.status = "Station cut out. Press play to try again."
                self?.playingChannelID = nil
            }
        }
    }

    /// State code parsed from the relay name ("AL-Mobile: KEC61" → "AL").
    nonisolated static func stateCode(of channel: Channel) -> String? {
        let name = channel.name.replacingOccurrences(of: "NOAA WX ", with: "")
        guard let dash = name.firstIndex(of: "-"), name.distance(
            from: name.startIndex, to: dash) == 2 else { return nil }
        return String(name[..<dash]).uppercased()
    }

    /// Nearest-by-state station: same state first, else first available.
    func nearestChannel(stateCode: String?) -> Channel? {
        if let code = stateCode,
           let match = channels.first(where: { Self.stateCode(of: $0) == code }) {
            return match
        }
        return channels.first
    }

    /// Where a transmitter is, for the nearest-station math. Its own listed
    /// coordinates when it has them; the middle of its state otherwise.
    ///
    /// The fallback matters: the relay directory is re-scraped every launch
    /// and stations that weren't in the bundle come back with no
    /// coordinates. Skipping those made them INVISIBLE to auto-tune, so a
    /// driver could sit inside a station's coverage while the app stayed on
    /// a listed one two states away. A state centre is coarse, but it is on
    /// the right side of the country.
    nonisolated static func position(of channel: Channel)
        -> (coordinate: CLLocationCoordinate2D, isExact: Bool)? {
        if let la = channel.latitude, let lo = channel.longitude {
            return (CLLocationCoordinate2D(latitude: la, longitude: lo), true)
        }
        guard let code = stateCode(of: channel),
              let box = LiveHazardFeedFetcher.stateBBoxes[code] else { return nil }
        return (CLLocationCoordinate2D(latitude: (box.s + box.n) / 2,
                                       longitude: (box.w + box.e) / 2), false)
    }

    /// Every channel the tuner can rank, as RadioTuning sees them.
    var tunableStations: [RadioTuning.Station] {
        channels.compactMap { ch in
            guard let p = Self.position(of: ch) else { return nil }
            return RadioTuning.Station(id: ch.id, coordinate: p.coordinate,
                                       isExact: p.isExact)
        }
    }

    /// Nearest transmitter by straight-line distance to the GPS position —
    /// the default station, and what auto-switching follows as you drive.
    /// Returns (channel, meters); nil when no channel can be placed at all.
    func nearestChannel(to c: CLLocationCoordinate2D) -> (channel: Channel, meters: Double)? {
        guard let best = RadioTuning.nearest(to: c, in: tunableStations),
              let channel = channels.first(where: { $0.id == best.station.id })
        else { return nil }
        return (channel: channel, meters: best.meters)
    }

    /// The station the tuner should move to for this position, or nil to
    /// stay where it is (nothing playing, already closest, or the next one
    /// isn't meaningfully closer).
    func retuneTarget(for position: CLLocationCoordinate2D) -> Channel? {
        let playing = channels.first { $0.id == playingChannelID }
        let coordinate = playing.flatMap { Self.position(of: $0)?.coordinate }
        guard let id = RadioTuning.retarget(playingID: playingChannelID,
                                            playingCoordinate: coordinate,
                                            position: position,
                                            stations: tunableStations)
        else { return nil }
        return channels.first { $0.id == id }
    }

    /// A streamable channel for a cab-radio guide entry, when one exists: the
    /// user can supply relay URLs in trucker_radio.json using the guide line's
    /// exact name (e.g. "CB 19 (27.185 MHz)"). CB and Highway Advisory have no
    /// licensed public internet relays, so these are nil out of the box.
    func cabStream(for guideName: String) -> Channel? {
        channels.first { $0.name == guideName && $0.streamURL != nil }
    }

    func stop() {
        player?.pause()
        player = nil
        statusObservation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        playingChannelID = nil
        status = nil
    }
}
