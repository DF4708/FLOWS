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
                unspoken = []
                status = nil
                // The calls are gone, so the next switch-on reads them
                // again at once, not after up to two minutes of no pins.
                lastFetch = [:]
            }
        }
    }

    private var lastPosition: CLLocationCoordinate2D?
    private var lastFetch: [String: Date] = [:]
    /// Calls already said out loud — only those, so the set stays small.
    private var announced = Set<String>()
    /// Threat calls not said yet because they were more than a mile off,
    /// checked again on every fix: a shooting three miles ahead is one the
    /// driver may reach in three minutes.
    private var unspoken: [ScannerIncidents.Incident] = []
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
            setStatus("No city near you publishes its 911 calls yet.")
        }
        let now = Date()
        for feed in feeds {
            if let last = lastFetch[feed.id], now.timeIntervalSince(last) < 110 { continue }
            lastFetch[feed.id] = now
            Task { await fetch(feed) }
        }
        prune(now: now)
        announceThreats()
    }

    /// Every fix lands here, and each write to a published value re-renders
    /// every view of the model — so only a change is written.
    private func setStatus(_ text: String?) {
        if status != text { status = text }
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
        var answer: (Data, URLResponse)?
        if let url = URL(string: feed.url) { answer = try? await ThrottledNet.fetch(url) }
        // Switched off while the request was out: no list, and no "didn't
        // answer" line left behind under a switch that is off.
        guard enabled else { return }
        guard let (data, resp) = answer, (resp as? HTTPURLResponse)?.statusCode == 200 else {
            setStatus("\(feed.city)'s 911 list didn't answer — trying again in two minutes.")
            return
        }
        let fresh = OpenDispatch.incidents(from: data, feed: feed)
        // This feed's calls are replaced wholesale; the others stay.
        let mine = { (incident: ScannerIncidents.Incident) in incident.id.hasPrefix(feed.id + "|") }
        incidents = incidents.filter { !mine($0) } + fresh
        unspoken = unspoken.filter { !mine($0) }
            + fresh.filter { !announced.contains($0.id) && OpenDispatch.isThreat($0) }
        setStatus("\(feed.what) from \(feed.city)'s public 911 list, \(feed.delay).")
        FlowsDiag.log(.info, "dispatch", "\(feed.id): \(fresh.count) live call(s)")
        announceThreats()
    }

    /// Says each threat call once, when the driver is within about a mile of
    /// it — when the list arrives, or later as the driver comes near.
    private func announceThreats() {
        guard let position = lastPosition, !unspoken.isEmpty else { return }
        var waiting: [ScannerIncidents.Incident] = []
        for incident in unspoken {
            if POIRanking.meters(position, incident.coordinate) <= OpenDispatch.threatMeters {
                announced.insert(incident.id)
                onThreat?(incident)
            } else {
                waiting.append(incident)
            }
        }
        unspoken = waiting
    }

    private func prune(now: Date = Date()) {
        let expired = { (incident: ScannerIncidents.Incident) in
            now.timeIntervalSince(incident.heardAt)
                >= (incident.lifetime ?? OpenDispatch.lifetime(for: incident.kind))
        }
        // Only write the published list when a call has aged out (see
        // setStatus).
        if incidents.contains(where: expired) { incidents.removeAll(where: expired) }
        unspoken.removeAll(where: expired)
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
