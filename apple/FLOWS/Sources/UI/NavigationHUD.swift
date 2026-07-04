// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import SwiftUI

/// Turn-by-turn chrome: instruction banner up top, trip stats + gas/food +
/// end-navigation controls at the bottom. Same floating-card language as the
/// planning UI so the mode flip still feels like one app.
struct NavigationHUD: View {
    @EnvironmentObject private var model: AppModel
    let isCompact: Bool

    var body: some View {
        VStack {
            instructionBanner
            if !model.alerts.activeHeadlines.isEmpty {
                alertStrip
            }
            Spacer()
            bottomBar
        }
        .padding(isCompact ? 8 : 16)
    }

    // MARK: instruction banner

    @ViewBuilder
    private var instructionBanner: some View {
        if let g = model.navigation.guidance {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.system(size: 28))
                VStack(alignment: .leading, spacing: 2) {
                    Text(distanceText(g.distanceToManeuver))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(g.instruction)
                        .font(.system(size: 19, weight: .bold))
                        .lineLimit(2)
                }
                Spacer()
                if model.navigation.isRerouting {
                    ProgressView()
                }
            }
            .padding(14)
            .frame(maxWidth: isCompact ? .infinity : 560)
            .background(Theme.chrome.opacity(0.92))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: Theme.cardShadow, radius: 14, y: 5)
        }
    }

    private var alertStrip: some View {
        Label(model.alerts.activeHeadlines[0], systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.riskYellow.opacity(0.92))
            .foregroundStyle(.black)
            .clipShape(Capsule())
    }

    // MARK: bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let g = model.navigation.guidance {
                VStack(alignment: .leading, spacing: 2) {
                    Text(etaText(g.remainingTime))
                        .font(.system(size: 17, weight: .bold))
                    Text(distanceText(g.remainingDistance))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ForEach(POIService.Kind.allCases) { kind in
                Button {
                    Task {
                        if model.poi.activeKind == kind {
                            model.poi.clearResults()
                        } else {
                            await model.poi.search(kind, aheadOf: model.location.coordinate)
                        }
                    }
                } label: {
                    Label(kind.rawValue, systemImage: kind.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: Theme.tapMinimum)
                        .background(model.poi.activeKind == kind
                                    ? Theme.cta : Color.black.opacity(0.06))
                        .foregroundStyle(model.poi.activeKind == kind ? .white : .primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Button("End") { model.endNavigation() }
                .buttonStyle(PillCTAStyle())
                .frame(width: 90)
        }
        .floatingCard()
        .frame(maxWidth: isCompact ? .infinity : 640)
    }

    // MARK: formatting

    private func distanceText(_ meters: Double) -> String {
        let miles = meters / 1609.344
        if miles < 0.19 { return "\(Int((meters / 0.3048 / 50).rounded() * 50)) ft" }
        return String(format: miles < 10 ? "%.1f mi" : "%.0f mi", miles)
    }

    private func etaText(_ seconds: Double) -> String {
        let mins = Int((seconds / 60).rounded())
        return mins >= 90 ? String(format: "%d h %02d min", mins / 60, mins % 60) : "\(mins) min"
    }
}
