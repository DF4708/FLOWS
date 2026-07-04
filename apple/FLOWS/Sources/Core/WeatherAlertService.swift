// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// NWS active-alert ingest, corridor-scoped.
///
/// The web app scores whole states of ZIPs; the app only ever asks about the
/// corridor it is planning or driving — a handful of api.weather.gov point
/// queries, deduplicated by alert zone. Severity folds into the same 0…1 risk
/// scale the rest of FLOWS uses (cuts in FlowsCore.riskBand).
@MainActor
final class WeatherAlertService: ObservableObject {
    @Published private(set) var activeHeadlines: [String] = []

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = [
            // NWS API policy: identify the client.
            "User-Agent": "FLOWS (davidfoster4708@gmail.com)",
            "Accept": "application/geo+json",
        ]
        cfg.timeoutIntervalForRequest = 8
        return URLSession(configuration: cfg)
    }()

    private var watchTask: Task<Void, Never>?
    private var seenAlertIDs = Set<String>()

    struct CorridorScore {
        var risk: Double
        var headlines: [String]
    }

    /// One-shot corridor score for route ranking.
    func corridorRisk(at samples: [CLLocationCoordinate2D]) async -> CorridorScore {
        var headlines: [String] = []
        var maxSeverity = 0.0
        var seen = Set<String>()
        for pt in samples {
            guard let alerts = await activeAlerts(at: pt) else { continue }
            for alert in alerts where !seen.contains(alert.id) {
                seen.insert(alert.id)
                headlines.append(alert.headline)
                maxSeverity = max(maxSeverity, alert.severityScore)
            }
        }
        return CorridorScore(risk: maxSeverity, headlines: headlines)
    }

    /// While navigating: re-check the corridor ahead every few minutes —
    /// turn-by-turn is time-sensitive, so the weather picture refreshes at a
    /// driving cadence, not the web app's whole-map cadence.
    func beginCorridorWatch(along route: PlannedRoute) {
        watchTask?.cancel()
        seenAlertIDs.removeAll()
        let polyline = route.route.polyline
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let samples = RouteService.samplePoints(of: polyline, everyMeters: 40_000)
                let score = await self.corridorRisk(at: samples)
                self.activeHeadlines = score.headlines
                try? await Task.sleep(for: .seconds(240))
            }
        }
    }

    func endCorridorWatch() {
        watchTask?.cancel()
        watchTask = nil
        activeHeadlines = []
    }

    // MARK: NWS fetch

    struct NWSAlert {
        let id: String
        let headline: String
        let severityScore: Double
    }

    private func activeAlerts(at point: CLLocationCoordinate2D) async -> [NWSAlert]? {
        let lat = String(format: "%.4f", point.latitude)
        let lon = String(format: "%.4f", point.longitude)
        guard let url = URL(string: "https://api.weather.gov/alerts/active?point=\(lat),\(lon)") else {
            return nil
        }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]]
        else { return nil }

        return features.compactMap { feature in
            guard let props = feature["properties"] as? [String: Any],
                  let id = props["id"] as? String ?? feature["id"] as? String,
                  let headline = (props["headline"] as? String) ?? (props["event"] as? String)
            else { return nil }
            let severity = (props["severity"] as? String) ?? "Unknown"
            // Same spirit as the web app's alert weighting: Extreme dominates,
            // Minor barely registers.
            let score: Double = switch severity {
            case "Extreme": 0.95
            case "Severe": 0.88
            case "Moderate": 0.72
            case "Minor": 0.45
            default: 0.30
            }
            return NWSAlert(id: id, headline: headline, severityScore: score)
        }
    }
}
