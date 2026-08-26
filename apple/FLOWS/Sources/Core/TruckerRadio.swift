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
import MediaPlayer
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

    @Published private(set) var channels: [Channel]
    @Published private(set) var playingChannelID: String?
    @Published private(set) var status: String?

    /// The last channel play() tuned (any kind — NOAA relay or AM/FM),
    /// persisted so the lock-screen play button and Siri have a target
    /// after a stop or relaunch.
    private(set) var lastPlayed: Channel?
    private static let lastPlayedKey = "flows.radio.lastPlayed"

    // MARK: station queue (radio as a music service)

    /// A genre/search result set the driver moves through like a
    /// playlist: "play rock" fills this, next/previous walk it.
    @Published private(set) var queue: [Channel] = []
    @Published private(set) var queueIndex = 0
    /// True while the stream is paused (radio's "mute" — the connection
    /// is dropped to save data; resuming re-tunes LIVE, since a live
    /// broadcast has no "where you left off").
    @Published private(set) var isPaused = false
    /// What the queue was built from ("rock") — names the genre in
    /// announcements and drives the offline handoff's like-for-like pick.
    @Published private(set) var queueLabel = ""

    /// Wrap-around step through a queue — pure so the walk is pinned.
    /// Returns 0 for an empty queue (nothing to play).
    nonisolated static func advance(index: Int, count: Int, by step: Int) -> Int {
        guard count > 0 else { return 0 }
        let raw = (index + step) % count
        return raw < 0 ? raw + count : raw
    }

    /// Start a genre/search result set: play the first station and keep
    /// the rest queued for next/previous.
    func playQueue(_ channels: [Channel], label: String, startAt: Int = 0) {
        guard !channels.isEmpty else { return }
        let start = max(0, min(startAt, channels.count - 1))
        play(channels[start], clearQueue: false)
        queue = channels
        queueLabel = label
        queueIndex = start
    }

    /// Next station of the same genre (wraps). Returns what it tuned.
    @discardableResult
    func nextStation() -> Channel? { step(by: 1) }

    @discardableResult
    func previousStation() -> Channel? { step(by: -1) }

    private func step(by delta: Int) -> Channel? {
        guard !queue.isEmpty else { return nil }
        queueIndex = Self.advance(index: queueIndex, count: queue.count, by: delta)
        let channel = queue[queueIndex]
        play(channel, clearQueue: false)
        return channel
    }

    /// The transport pause: silence the station and drop the stream
    /// (a paused live stream would otherwise keep burning cellular
    /// data). Resuming re-tunes to LIVE.
    func pauseOrResume() {
        if isPaused {
            if let channel = lastPlayed { play(channel) }
            return
        }
        guard playingChannelID != nil else {
            // Nothing playing: resume the last station instead.
            if let channel = lastPlayed { play(channel) }
            return
        }
        player?.pause()
        isPaused = true
        status = "Paused — press play to go back on air."
    }

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
        if let data = UserDefaults.standard.data(forKey: Self.lastPlayedKey) {
            lastPlayed = try? JSONDecoder().decode(Channel.self, from: data)
        }
        configureRemoteCommands()
        // Relay hosts rotate stations — refresh the live list once per
        // launch and prune entries that stopped streaming.
        Task { await refreshStations() }
    }

    /// Lock-screen / steering-wheel transport for the radio (iOS): play
    /// resumes the last channel, pause and stop end it. Without these the
    /// background-audio session shows a dead now-playing card.
    private func configureRemoteCommands() {
        #if os(iOS)
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if let self, self.playingChannelID == nil, let last = self.lastPlayed {
                    self.play(last)
                }
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stop() }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stop() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.playingChannelID != nil {
                    self.stop()
                } else if let last = self.lastPlayed {
                    self.play(last)
                }
            }
            return .success
        }
        #endif
    }

    /// The lock-screen card: station name + live-stream flag (no scrubber).
    private func updateNowPlaying(_ channel: Channel?) {
        #if os(iOS)
        guard let channel else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: channel.name,
            MPMediaItemPropertyArtist: channel.detail,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        #endif
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
    private var failureObserver: NSObjectProtocol?

    /// Tune a station. `clearQueue` defaults true so a one-off pick (a
    /// NOAA relay, a tapped row) ends the previous genre run; the queue
    /// walkers pass false to stay inside their own list.
    func play(_ channel: Channel, clearQueue: Bool = true) {
        if clearQueue {
            queue = []
            queueIndex = 0
            queueLabel = ""
        }
        guard let url = channel.streamURL else {
            status = "\(channel.name): no stream configured — see the frequency guide "
                + "for the cab radio, or add a relay URL in trucker_radio.json."
            return
        }
        stop()
        #if os(iOS)
        // Without an active playback session iOS keeps AVPlayer SILENT —
        // the "no stream works" failure mode. (.playback + the audio
        // background mode also keep the stream alive at screen lock.)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        status = "Tuning \(channel.name)…"
        playingChannelID = channel.id
        isPaused = false
        lastPlayed = channel
        if let data = try? JSONEncoder().encode(channel) {
            UserDefaults.standard.set(data, forKey: Self.lastPlayedKey)
        }
        updateNowPlaying(channel)
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

    /// Nearest transmitter by straight-line distance to the GPS position —
    /// the default station, and what auto-switching follows as you drive.
    /// Returns (channel, meters); nil when no channel carries coordinates.
    func nearestChannel(to c: CLLocationCoordinate2D) -> (channel: Channel, meters: Double)? {
        channels.compactMap { ch -> (Channel, Double)? in
            guard let la = ch.latitude, let lo = ch.longitude else { return nil }
            return (ch, POIRanking.meters(
                CLLocationCoordinate2D(latitude: la, longitude: lo), c))
        }
        .min { $0.1 < $1.1 }
        .map { (channel: $0.0, meters: $0.1) }
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
        isPaused = false
        updateNowPlaying(nil)
    }
}
