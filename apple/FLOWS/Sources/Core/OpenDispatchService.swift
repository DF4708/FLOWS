// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// Reads the city 911 feeds (OpenDispatch) while "Show calls heard nearby" is
/// on: the feed covering the driver, or the one picked in the radio card,
/// every two minutes. Its calls are pins like the scanner's; a new call that
/// is a threat (a gun, a robbery, a fire) within about a mile is handed to
/// `onThreat` once, so FLOWS can say it out loud. Nothing about the driver is
/// sent: the request is the city's public list, the same for everyone.
@MainActor
final class OpenDispatchService: ObservableObject {
    @Published private(set) var incidents: [ScannerIncidents.Incident] = []
    /// The feed the radio card picked, read wherever the driver is; nil =
    /// the one covering the driver, if any.
    @Published var watchedFeedID: String? {
        didSet {
            lastFetch = [:]
            if let lastPosition { refresh(near: lastPosition) }
        }
    }
    @Published private(set) var status: String?

    /// A new threat near the driver, once per call.
    var onThreat: ((ScannerIncidents.Incident) -> Void)?

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled {
                startPolling()
            } else {
                poll?.cancel()
                poll = nil
                incidents = []
                status = nil
            }
        }
    }

    private var lastPosition: CLLocationCoordinate2D?
    private var lastFetch: [String: Date] = [:]
    private var announced = Set<String>()
    private var poll: Task<Void, Never>?

    /// The feeds read right now: the picked one, else those covering the
    /// driver (at most two, nearest first).
    var activeFeeds: [OpenDispatch.Feed] {
        if let id = watchedFeedID, let feed = OpenDispatch.feeds.first(where: { $0.id == id }) {
            return [feed]
        }
        return Array(OpenDispatch.covering(lastPosition).prefix(2))
    }

    func refresh(near position: CLLocationCoordinate2D?) {
        if let position { lastPosition = position }
        guard enabled else { return }
        let feeds = activeFeeds
        if feeds.isEmpty {
            status = "No city near you publishes its 911 calls yet."
        }
        for feed in feeds {
            if let last = lastFetch[feed.id], Date().timeIntervalSince(last) < 110 { continue }
            lastFetch[feed.id] = Date()
            Task { await fetch(feed) }
        }
        prune()
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh(near: self.lastPosition)
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private func fetch(_ feed: OpenDispatch.Feed) async {
        guard let url = URL(string: feed.url),
              let (data, resp) = try? await ThrottledNet.fetch(url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            status = "\(feed.city)'s 911 list didn't answer — trying again in two minutes."
            return
        }
        guard enabled else { return }
        let fresh = OpenDispatch.incidents(from: data, feed: feed)
        // This feed's calls are replaced wholesale; the others stay.
        incidents = incidents.filter { !$0.id.hasPrefix(feed.id + "|") } + fresh
        status = "\(feed.what) from \(feed.city)'s public 911 list, \(feed.delay)."
        FlowsDiag.log(.info, "dispatch", "\(feed.id): \(fresh.count) live call(s)")
        announceThreats(in: fresh)
    }

    private func announceThreats(in fresh: [ScannerIncidents.Incident]) {
        guard let position = lastPosition else { return }
        for incident in fresh where !announced.contains(incident.id) {
            announced.insert(incident.id)
            guard OpenDispatch.isThreat(incident),
                  POIRanking.meters(position, incident.coordinate) <= OpenDispatch.threatMeters
            else { continue }
            onThreat?(incident)
        }
    }

    private func prune(now: Date = Date()) {
        incidents.removeAll {
            now.timeIntervalSince($0.heardAt) >= ($0.lifetime ?? OpenDispatch.lifetime(for: $0.kind))
        }
    }

    /// The pins worth drawing: near the driver or the route — or, for the
    /// feed picked in the card, anywhere in its city.
    func visible(near position: CLLocationCoordinate2D?,
                 corridor: [CLLocationCoordinate2D]) -> [ScannerIncidents.Incident] {
        let now = Date()
        return incidents.filter { incident in
            guard now.timeIntervalSince(incident.heardAt)
                    < (incident.lifetime ?? OpenDispatch.lifetime(for: incident.kind)) else { return false }
            if let id = watchedFeedID, incident.id.hasPrefix(id + "|") { return true }
            let near = { (c: CLLocationCoordinate2D) in
                POIRanking.meters(c, incident.coordinate) <= ScannerIncidents.relevantMeters
            }
            return position.map(near) == true || corridor.contains(where: near)
        }
    }
}
