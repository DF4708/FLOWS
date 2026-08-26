// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import MapKit
import SwiftUI

/// Detail card for a tapped tourist star: what the place is, what it costs
/// to get in, review stars (Google/Yelp ladder — hidden without a key), and
/// today's open hours when a provider has them.
struct TouristStopCard: View {
    let stop: POIService.RankedPOI
    let onClose: () -> Void

    /// Ratings-ladder result for THIS stop, fetched on appear (nil hides
    /// the stars and hours sections — never invented).
    @State private var info: YelpLink.BusinessInfo?

    /// NPS posted entry fees, loaded once per launch.
    private static let fees = TouristInfo.FeeTable.loadBundled()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "star.fill")
                    .scaledFont(size: 18, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Theme.riskGreen)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(stop.item.name ?? "Stop")
                        .scaledFont(size: 15, weight: .bold)
                        .lineLimit(2)
                    Text(whatItIs)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 18)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(String(format: "About %.0f mi ahead · about +%.0f min off your route",
                        max(stop.aheadMeters, 0) / 1609.344,
                        2 * stop.detourMeters / POIRanking.detourSpeedMps / 60))
                .font(.caption)
                .foregroundStyle(.secondary)

            sectionHeader("Cost to get in")
            Text(TouristInfo.feeNote(name: stop.item.name, table: Self.fees))
                .font(.footnote)

            if let stars = info?.rating {
                sectionHeader("Stars")
                StarsAndBucks(stars: stars, costTier: nil)
            }

            if hoursToday != nil || info?.isOpenNow != nil {
                sectionHeader("Open hours")
                HStack(spacing: 8) {
                    if let line = hoursToday {
                        Text(line).font(.footnote)
                    }
                    if let open = info?.isOpenNow {
                        Text(open ? "Open now" : "Closed now")
                            .font(.caption.weight(.heavy))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background((open ? Theme.riskGreen : Theme.riskRed).opacity(0.15))
                            .foregroundStyle(open ? Theme.riskGreen : Theme.riskRed)
                            .clipShape(Capsule())
                    }
                }
            }

            if let url = stop.item.url {
                Link("Their website →", destination: url)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.riskGreen)
            }
        }
        .floatingCard()
        .task(id: stop.id) {
            info = nil
            let c = stop.item.placemark.coordinate
            info = await RatingsProvider.info(name: stop.item.name ?? "",
                                              latitude: c.latitude,
                                              longitude: c.longitude)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.heavy))
            .foregroundStyle(Theme.riskGreen)
            .textCase(.uppercase)
    }

    /// "National park · Estes Park, CO" — plain kind plus where it sits.
    private var whatItIs: String {
        let kind = TouristInfo.plainKind(
            name: stop.item.name,
            categoryRaw: stop.item.pointOfInterestCategory?.rawValue)
        let place = [stop.item.placemark.locality,
                     stop.item.placemark.administrativeArea]
            .compactMap { $0 }
            .joined(separator: ", ")
        return place.isEmpty ? kind : "\(kind) · \(place)"
    }

    /// Today's line from the provider's Monday-first weekly hours.
    private var hoursToday: String? {
        guard let hours = info?.hours, hours.count == 7 else { return nil }
        let weekday = Calendar.current.component(.weekday, from: Date())
        return hours[TouristInfo.mondayFirstIndex(weekday: weekday)]
    }
}
