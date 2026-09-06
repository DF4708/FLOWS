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
#if canImport(Speech)
import Speech
#endif

/// A dispatch feed the app may listen to.
///
/// Feeds are supplied BY THE OPERATOR, not shipped in the app: drop a
/// `scanner_feeds.json` (an array of `{"name", "url", "latitude",
/// "longitude"}`) into Application Support. Every scanner provider licenses
/// listening to the person who holds the account, so the app carries no
/// feed list of its own and ships with the feature switched off.
struct ScannerFeed: Codable, Identifiable, Equatable {
    var name: String
    var url: String
    /// Roughly where this feed's agency covers — used to pick the feed for
    /// the area being driven, and as the fallback anchor for a call whose
    /// address won't geocode.
    var latitude: Double?
    var longitude: Double?

    var id: String { name }

    var streamURL: URL? {
        let secured = url.hasPrefix("http://")
            ? "https://" + url.dropFirst("http://".count) : url
        return URL(string: secured)
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Loads the operator's feed list. Empty by default, which is what keeps
/// the feature off until someone with a listening agreement turns it on.
enum ScannerFeedStore {
    static func load() -> [ScannerFeed] {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first,
              let data = try? Data(contentsOf:
                dir.appendingPathComponent("scanner_feeds.json")),
              let parsed = try? JSONDecoder().decode([ScannerFeed].self, from: data)
        else { return [] }
        return parsed
    }

    /// The feed covering a position — nearest by the agency's own anchor.
    static func nearest(to position: CLLocationCoordinate2D,
                        in feeds: [ScannerFeed]) -> ScannerFeed? {
        feeds
            .compactMap { f -> (ScannerFeed, Double)? in
                guard let c = f.coordinate else { return nil }
                return (f, POIRanking.meters(c, position))
            }
            .min { $0.1 < $1.1 }?.0
    }
}

/// Listens to one dispatch feed and turns what it hears into map incidents,
/// entirely on this device.
///
/// The audio is decoded, transcribed with on-device speech recognition, and
/// discarded. Nothing is uploaded, nothing is written to disk, and the
/// stream is never re-served — see ScannerIncidents for why that boundary
/// is the whole basis for this being allowed to exist.
@MainActor
final class ScannerListener: ObservableObject {
    /// Live incidents, newest last. Expired ones are swept out.
    @Published private(set) var incidents: [ScannerIncidents.Incident] = []
    @Published private(set) var isListening = false
    @Published private(set) var status: String?
    /// Feeds the operator supplied. Empty means the feature is unavailable.
    @Published private(set) var feeds: [ScannerFeed] = []

    /// Off unless the driver turns it on AND a feed list exists.
    @Published var enabled: Bool =
        UserDefaults.standard.bool(forKey: "flows.scannerEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "flows.scannerEnabled")
            if !enabled { stop() }
        }
    }

    /// True when there is anything to listen to at all.
    var available: Bool { !feeds.isEmpty }

    private var player: AVPlayer?
    private var currentFeed: ScannerFeed?
    /// True from start() until the authorization callback lands, so the
    /// per-fix listen() does not request authorization again meanwhile.
    private var starting = false
    /// After a recognition failure, no restart before this. listen() runs
    /// on every GPS fix; without a backoff a recognizer that cannot
    /// initialize would be restarted once a second for the whole drive.
    private var retryAfter = Date.distantPast
    private let geocoder = CLGeocoder()
    /// Places already looked up, so repeated dispatch of the same address
    /// doesn't hit the geocoder over and over.
    private var placeCache: [String: CLLocationCoordinate2D] = [:]
    private var sweepTimer: Timer?

    #if canImport(Speech)
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tap: MTAudioProcessingTap?
    #endif

    init() {
        feeds = ScannerFeedStore.load()
        if feeds.isEmpty { enabled = false }
    }

    // MARK: listening

    /// Start on the feed covering this position, if the feature is on and a
    /// feed exists for it.
    func listen(near position: CLLocationCoordinate2D?) {
        // One line per state change, so a feed that never starts can say
        // why — this path had no journal line before its first callback.
        if !enabled {
            FlowsDiag.logThrottled(key: "scanner.off", .info, "scanner",
                                   "off (\(feeds.count) feed(s) configured)")
            return
        }
        // Position chooses BETWEEN feeds. Without one (a Mac with no fix,
        // the first seconds after launch) the first feed is still worth
        // hearing — this used to wait for a fix that a desk never gets.
        guard let feed = position.flatMap({ ScannerFeedStore.nearest(to: $0, in: feeds) })
                ?? feeds.first else { return }
        guard feed.id != currentFeed?.id || (!isListening && !starting) else { return }
        guard Date() >= retryAfter else { return }
        start(feed)
    }

    func stop() {
        player?.pause()
        player = nil
        currentFeed = nil
        isListening = false
        sweepTimer?.invalidate()
        sweepTimer = nil
        #if canImport(Speech)
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        #endif
    }

    private func start(_ feed: ScannerFeed) {
        stop()
        guard let url = feed.streamURL else {
            FlowsDiag.log(.warn, "scanner", "feed \(feed.name): unusable URL")
            return
        }
        FlowsDiag.log(.info, "scanner", "feed \(feed.name): requesting speech authorization")
        currentFeed = feed
        starting = true
        #if canImport(Speech)
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                self.starting = false
                guard auth == .authorized else {
                    self.status = "Speech recognition is off in Settings."
                    FlowsDiag.log(.warn, "scanner", "speech recognition not authorized — feed idle")
                    return
                }
                FlowsDiag.log(.info, "scanner", "listening: \(feed.name)")
                self.beginRecognition(url: url, feed: feed)
            }
        }
        #else
        status = "Not available on this device."
        #endif
    }

    #if canImport(Speech)
    private func beginRecognition(url: URL, feed: ScannerFeed) {
        let recognizer = SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            // Without on-device recognition the audio would be sent to
            // Apple for transcription — which is exactly the off-device
            // handling this feature promises not to do. So it stays off.
            status = "This device can't transcribe without sending audio away."
            FlowsDiag.log(.warn, "scanner", "no on-device recognizer — feed idle")
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true   // never leaves the device
        request.shouldReportPartialResults = true
        self.request = request

        let item = AVPlayerItem(url: url)
        installTap(on: item, request: request)
        let p = AVPlayer(playerItem: item)
        p.volume = 0            // transcribed, not played aloud
        p.isMuted = true
        p.play()
        player = p
        isListening = true
        status = "Listening to \(feed.name)"

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.status = "Feed dropped."; self.isListening = false
                    self.retryAfter = Date().addingTimeInterval(60)
                    FlowsDiag.log(.warn, "scanner", "recognition ended: \(error.localizedDescription) — retry in 60 s")
                }
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                // Only act on a settled phrase, not every partial guess.
                guard result.isFinal || text.count > 60 else { return }
                // The count, never the words: dispatch audio is not the
                // driver's, but the journal is exportable all the same.
                let before = self.incidents.count
                self.consider(transcript: text, feed: feed)
                FlowsDiag.log(.info, "scanner",
                              "heard \(text.count) chars (final: \(result.isFinal)); "
                              + "incidents \(before) → \(self.incidents.count)")
            }
        }
        // Sweep expired pins so nothing stale sits on the map.
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.incidents = self.incidents.filter {
                    !ScannerIncidents.isExpired($0)
                }
            }
        }
    }

    /// Fan the decoded audio into the recognizer without playing it.
    private func installTap(on item: AVPlayerItem,
                            request: SFSpeechAudioBufferRecognitionRequest) {
        // AVPlayer gives no direct buffer access, so the audio mix's tap is
        // the supported route to sample buffers.
        let asset = item.asset
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first
            else { return }
            await MainActor.run {
                let params = AVMutableAudioMixInputParameters(track: track)
                let mix = AVMutableAudioMix()
                mix.inputParameters = [params]
                // The tap callbacks are C function pointers and cannot
                // capture Swift context, so the recognizer request rides
                // through the tap's storage as an unmanaged box.
                ScannerAudioTap.attach(to: params, request: request)
                item.audioMix = mix
            }
        }
    }
    #endif

    // MARK: transcript → map pin

    private func consider(transcript: String, feed: ScannerFeed) {
        guard let kind = ScannerIncidents.kind(inTranscript: transcript),
              let place = ScannerIncidents.placePhrase(inTranscript: transcript)
        else { return }   // no kind or no place = nothing trustworthy to draw
        if let cached = placeCache[place] {
            add(kind: kind, at: cached, place: place)
            return
        }
        // Geocode inside the feed's own area so "Washington Road" resolves
        // to the right Washington Road.
        let region = feed.coordinate.map {
            CLCircularRegion(center: $0, radius: 40_000, identifier: feed.id)
        }
        geocoder.geocodeAddressString(place, in: region) { [weak self] marks, _ in
            Task { @MainActor in
                guard let self, let c = marks?.first?.location?.coordinate else { return }
                self.placeCache[place] = c
                self.add(kind: kind, at: c, place: place)
            }
        }
    }

    private func add(kind: ScannerIncidents.Kind,
                     at coordinate: CLLocationCoordinate2D, place: String) {
        let incident = ScannerIncidents.Incident(
            id: "\(kind.rawValue)|\(place)|\(Int(Date().timeIntervalSince1970 / 60))",
            kind: kind, coordinate: coordinate, placeText: place, heardAt: Date())
        incidents = ScannerIncidents.merged(incidents, adding: incident)
    }
}

#if canImport(Speech)
/// The audio tap that feeds decoded samples to the recognizer.
///
/// Kept in its own type because MTAudioProcessingTap callbacks are C
/// function pointers: they cannot capture Swift context, so the request is
/// passed through the tap's storage as an unmanaged reference.
enum ScannerAudioTap {
    private final class Box {
        let request: SFSpeechAudioBufferRecognitionRequest
        init(_ r: SFSpeechAudioBufferRecognitionRequest) { request = r }
    }

    static func attach(to params: AVMutableAudioMixInputParameters,
                       request: SFSpeechAudioBufferRecognitionRequest) {
        let box = Unmanaged.passRetained(Box(request)).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: box,
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                if let storage = MTAudioProcessingTapGetStorage(tap) as UnsafeMutableRawPointer? {
                    Unmanaged<Box>.fromOpaque(storage).release()
                }
            },
            prepare: nil, unprepare: nil,
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }
                let storage = MTAudioProcessingTapGetStorage(tap)
                let box = Unmanaged<Box>.fromOpaque(storage).takeUnretainedValue()
                guard let format = ScannerAudioTap.format(frames: numberFrames),
                      let buffer = AVAudioPCMBuffer(
                        pcmFormat: format,
                        bufferListNoCopy: bufferListInOut) else { return }
                box.request.append(buffer)
            })
        // The current SDK imports the out-parameter as a managed optional,
        // so ARC balances the tap for us.
        var tap: MTAudioProcessingTap?
        let err = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard err == noErr, let created = tap else {
            Unmanaged<Box>.fromOpaque(box).release()
            return
        }
        params.audioTapProcessor = created
    }

    /// The tap delivers 32-bit float, non-interleaved, at the stream's rate;
    /// relay feeds are 22.05 kHz mono in practice.
    private static let sharedFormat =
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050,
                      channels: 1, interleaved: false)

    nonisolated static func format(frames: CMItemCount) -> AVAudioFormat? {
        sharedFormat
    }
}
#endif
