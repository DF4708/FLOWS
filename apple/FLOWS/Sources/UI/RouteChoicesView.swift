// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import MapKit
import SwiftUI

/// Alternate-route cards: traffic ETA from Apple, weather-risk band from
/// FLOWS. Tapping one is the mode flip into turn-by-turn navigation.
struct RouteChoicesView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var camera: MapCameraPosition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Routes")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button {
                    model.routeChoices = []
                    model.mode = .planning
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.routeChoices) { route in
                        RouteCard(route: route) {
                            model.select(route: route)
                        }
                    }
                }
            }
        }
        .floatingCard()
    }
}

private struct RouteCard: View {
    let route: PlannedRoute
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(etaText)
                        .font(.system(size: 17, weight: .bold))
                    Spacer()
                    riskBadge
                }
                Text("\(milesText) · \(route.sourceName) → \(route.destinationName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let headline = route.alertHeadlines.first {
                    Label(headline, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(badgeColor)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var etaText: String {
        let mins = Int((route.eta / 60).rounded())
        return mins >= 90 ? String(format: "%d h %02d min", mins / 60, mins % 60) : "\(mins) min"
    }

    private var milesText: String {
        String(format: "%.0f mi", route.distanceMeters / 1609.344)
    }

    private var badgeColor: Color {
        switch route.riskBand {
        case .clear: return .secondary
        case .green: return Theme.riskGreen
        case .yellow: return Theme.riskYellow
        case .red: return Theme.riskRed
        }
    }

    @ViewBuilder
    private var riskBadge: some View {
        Text(route.riskBand == .clear ? "No alerts" : route.riskBand.rawValue)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(badgeColor.opacity(route.riskBand == .clear ? 0.12 : 0.2))
            .foregroundStyle(route.riskBand == .clear ? .secondary : badgeColor)
            .clipShape(Capsule())
    }
}
